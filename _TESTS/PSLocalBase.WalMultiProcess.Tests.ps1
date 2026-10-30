# Independent processes write to one WAL database file at the same time.
# Uses Windows PowerShell 5.1 and PowerShell 7 together when both are installed.
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1'
Import-Module $modulePath -Force

$iterations = 40
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pslb-wal-" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($workDir)
$dbPath = Join-Path $workDir 'shared.db'
$goFile = Join-Path $workDir 'go'
$workerScript = Join-Path $workDir 'worker.ps1'

Set-Content -Path $workerScript -Encoding UTF8 -Value @'
param($ModulePath, $DbPath, $WorkerId, $Iterations, $GoFile)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$db = New-LocalBase -Path $DbPath -Options @{ busyTimeout = 30000 }
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path $GoFile)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Start signal timeout.' }
        Start-Sleep -Milliseconds 10
    }
    for ($i = 0; $i -lt $Iterations; $i++) {
        [void]$db.collection('events').add(@{ worker = $WorkerId; i = $i })
        $db.collection('shared').doc('members').update(@{ list = @{ '$arrayUnion' = @("$WorkerId/$i") } })
        # Read-modify-write inside an explicit transaction: lost updates would show as a short counter.
        $db.beginTransaction()
        try {
            $current = $db.collection('shared').doc('counter').get()
            $db.collection('shared').doc('counter').set(@{ n = ([int]$current.n + 1) })
            $db.commit()
        } catch {
            try { $db.rollback() } catch { }
            throw
        }
    }
} finally { $db.close() }
'@

$hosts = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @('pwsh.exe', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $hosts.Add($cmd.Source) }
}
if ($hosts.Count -eq 1) { $hosts.Add($hosts[0]) }

$failed = $false
$processes = @()
try {
    $setup = New-LocalBase -Path $dbPath
    try {
        if ($setup.JournalMode -ne 'wal') { throw "Expected WAL journal mode, got $($setup.JournalMode)" }
        [void]$setup.collection('events').create()
        $setup.collection('shared').doc('counter').set(@{ n = 0 })
        $setup.collection('shared').doc('members').set(@{ list = @() })
    } finally { $setup.close() }

    for ($w = 0; $w -lt $hosts.Count; $w++) {
        $info = [System.Diagnostics.ProcessStartInfo]::new($hosts[$w])
        $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -ModulePath `"$modulePath`" -DbPath `"$dbPath`" -WorkerId w$w -Iterations $iterations -GoFile `"$goFile`""
        $info.UseShellExecute = $false
        $info.RedirectStandardError = $true
        $info.RedirectStandardOutput = $true
        $info.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $processes += [pscustomobject]@{ Host = (Split-Path $hosts[$w] -Leaf); Process = $process; Stdout = $process.StandardOutput.ReadToEndAsync(); Stderr = $process.StandardError.ReadToEndAsync() }
    }
    Start-Sleep -Seconds 3
    Set-Content -Path $goFile -Value 'go'

    foreach ($p in $processes) {
        if (-not $p.Process.WaitForExit(240000)) { $p.Process.Kill(); throw "Worker $($p.Host) timed out." }
        $p.Process.WaitForExit()
        $stderr = $p.Stderr.Result
        if ($p.Process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) {
            throw "Worker $($p.Host) failed (exit $($p.Process.ExitCode)): $stderr $($p.Stdout.Result)"
        }
        Write-Host "[OBSERVATION] worker $($p.Host) completed $iterations iterations."
    }

    $verify = New-LocalBase -Path $dbPath
    try {
        $expected = $iterations * $hosts.Count
        $events = $verify.collection('events').count()
        $members = @($verify.collection('shared').doc('members').get().list)
        $counter = [int]$verify.collection('shared').doc('counter').get().n
        $integrity = $verify.query('PRAGMA integrity_check;')[0].integrity_check
        if ($events -ne $expected) { throw "Lost add() writes: $events of $expected" }
        if ($members.Count -ne $expected -or @($members | Sort-Object -Unique).Count -ne $expected) { throw "Lost array mutations: $($members.Count) of $expected" }
        if ($counter -ne $expected) { throw "Lost transactional increments: $counter of $expected" }
        if ($integrity -ne 'ok') { throw "integrity_check returned $integrity" }
        Write-Host "[PASS] W01 - $($hosts.Count) processes ($((($processes | ForEach-Object Host) -join ', '))) wrote $expected adds, array unions and transactional increments to one WAL file without loss or lock errors."
    } finally { $verify.close() }
} catch {
    $failed = $true
    Write-Host "[FAIL] W01 - $($_.Exception.Message)"
} finally {
    foreach ($p in $processes) { if (-not $p.Process.HasExited) { $p.Process.Kill() }; $p.Process.Dispose() }
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
Write-Host "WAL multi-process: passed=1; failed=0"
