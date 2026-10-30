# Test runner for PSLocalBase. Each suite runs in its own process of the current edition
# so the native bridge and module state are fresh, and a failing suite does not hide later ones.
[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$tests = @(
    "PSLocalBase.Tests.ps1",
    "PSLocalBase.Audit.Tests.ps1",
    "PSLocalBase.Reevaluation.Tests.ps1",
    "PSLocalBase.NativeStress.Tests.ps1",
    "PSLocalBase.Independent-c57b52c.Tests.ps1",
    "PSLocalBase.Revalidation-3ecc2c1.Tests.ps1",
    "PSLocalBase.Review-83ed742.Tests.ps1",
    "PSLocalBase.Followup-a526708.Tests.ps1",
    "PSLocalBase.Boundary-86483c7.Tests.ps1",
    "PSLocalBase.Review-3c890fd.Tests.ps1",
    "PSLocalBase.Review-158582f.Tests.ps1",
    "PSLocalBase.Review-fb3da3b.Tests.ps1",
    "PSLocalBase.Issues31-32.Tests.ps1",
    "PSLocalBase.Hardening-v2.Tests.ps1",
    "PSLocalBase.Property.Tests.ps1",
    "PSLocalBase.WalMultiProcess.Tests.ps1"
)

$hostExe = (Get-Process -Id $PID).Path
$results = [System.Collections.Generic.List[object]]::new()

foreach ($testFile in $tests) {
    $script = Join-Path $PSScriptRoot $testFile
    if (-not (Test-Path $script)) {
        Write-Host "Required test suite file not found: $testFile" -ForegroundColor Red
        $results.Add([pscustomobject]@{ Suite = $testFile; ExitCode = -1; Seconds = 0 })
        continue
    }
    Write-Host "`n>>> Running $testFile <<<" -ForegroundColor Cyan
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    if ($VerboseOutput -and $testFile -eq 'PSLocalBase.Tests.ps1') { $arguments += '-VerboseOutput' }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    & $hostExe @arguments
    $exitCode = $LASTEXITCODE
    $timer.Stop()
    $results.Add([pscustomobject]@{ Suite = $testFile; ExitCode = $exitCode; Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1) })
}

Write-Host "`n==================== Summary ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)) ====================" -ForegroundColor Cyan
foreach ($r in $results) {
    $status = if ($r.ExitCode -eq 0) { 'PASS' } else { "FAIL (exit $($r.ExitCode))" }
    $color = if ($r.ExitCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("{0,-48} {1,-16} {2,6}s" -f $r.Suite, $status, $r.Seconds) -ForegroundColor $color
}
$failedSuites = @($results | Where-Object { $_.ExitCode -ne 0 })
Write-Host "Suites passed: $($results.Count - $failedSuites.Count)/$($results.Count)"
if ($failedSuites.Count -gt 0) { exit 1 }
exit 0
