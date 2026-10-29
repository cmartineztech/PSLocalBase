# Native resource and shared-memory locking probes, independent of the runner.
# Run in a fresh process. No on-disk databases or external services are used.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
public static class PSLocalBaseAuditNative {
    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_memory_used", CallingConvention=CallingConvention.Cdecl)]
    public static extern long MemoryUsed();
    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_next_stmt", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr NextStatement(IntPtr db, IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_open_v2", CallingConvention=CallingConvention.Cdecl)]
    private static extern int OpenNative(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    public static IntPtr OpenSharedMemory(string name) {
        IntPtr db;
        byte[] uri = System.Text.Encoding.UTF8.GetBytes("file:" + name + "?mode=memory&cache=shared\0");
        int rc = OpenNative(uri, out db, 2 | 4 | 0x40 | 0x10000, IntPtr.Zero);
        if (rc != 0) throw new InvalidOperationException("OpenSharedMemory rc=" + rc);
        return db;
    }
}
'@

# Warm up native SQLite allocations before measuring.
$warm = New-LocalBase
$warm.close()
$baseline = [PSLocalBaseAuditNative]::MemoryUsed()

$db = New-LocalBase
try {
    [void]$db.collection('items').createIndex('n', @{ unique = $true })
    for ($i = 0; $i -lt 500; $i++) {
        $db.collection('items').doc('one').set(@{ n = 1; value = "payload`0tail" })
        [void]$db.collection('items').doc('one').get()
        try { [void]$db.query('SELECT ?;', @()) } catch [System.InvalidOperationException] { }
        try { [void]$db.query('SELECT invalid_column FROM items;') } catch [System.InvalidOperationException] { }
        try { [void]$db.collection('items').add(@{ n = 1 }, 'duplicate') } catch [System.InvalidOperationException] { }
        if ([PSLocalBaseAuditNative]::NextStatement($db.DbHandle, [IntPtr]::Zero) -ne [IntPtr]::Zero) {
            throw "Statement leak at iteration $i"
        }
    }
    $child = $db.collection('items')
    $db.close()
    $rejected = $false
    try { [void]$child.get() } catch [System.InvalidOperationException] { $rejected = $true }
    if (-not $rejected) { throw 'Orphan child accepted access.' }
} finally { $db.close() }
Write-Host '[PASS] N01 - 500 mixed success/error cycles leave no prepared statements; orphan rejected.'

for ($i = 0; $i -lt 100; $i++) {
    $instance = New-LocalBase
    try { $instance.collection('items').doc('one').set(@{ value = ('x' * 1024) }) }
    finally { $instance.Dispose() }
}
$afterDisposed = [PSLocalBaseAuditNative]::MemoryUsed()
if ($afterDisposed -ne $baseline) { throw "Native bytes differ after disposal: baseline=$baseline after=$afterDisposed" }
Write-Host "[PASS] N02 - 100 disposed databases return SQLite allocations to baseline ($baseline bytes)."

# A raw pointer list permits deterministic cleanup without retaining wrappers.
# This is an architectural diagnostic: IDisposable still requires caller use.
$retainedHandles = [System.Collections.Generic.List[IntPtr]]::new()
try {
    for ($i = 0; $i -lt 20; $i++) {
        $abandoned = New-LocalBase
        $abandoned.collection('items').doc('one').set(@{ value = ('x' * 65536) })
        $retainedHandles.Add($abandoned.DbHandle)
        $abandoned = $null
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $afterAbandoned = [PSLocalBaseAuditNative]::MemoryUsed()
    Write-Host "[OBSERVATION] N03 - 20 undisposed wrappers after GC retain $($afterAbandoned - $baseline) native bytes."
} finally {
    foreach ($handle in $retainedHandles) { [void][WinSqlite3]::CloseV2($handle) }
}

function New-SharedConnection([string]$Name) {
    $connection = New-LocalBase
    $connection.close()
    $connection.DbHandle = [PSLocalBaseAuditNative]::OpenSharedMemory($Name)
    [void][WinSqlite3]::BusyTimeout($connection.DbHandle, 100)
    return $connection
}

# Deterministic interleaving of two native connections to the same in-memory DB.
# Shared memory uses journal_mode=memory, not WAL. Lock errors are expected.
$sharedName = 'audit_' + [Guid]::NewGuid().ToString('N')
$first = New-SharedConnection $sharedName
$second = New-SharedConnection $sharedName
try {
    Write-Host "[OBSERVATION] N04 - shared database journal_mode=$($first.query('PRAGMA journal_mode;').journal_mode)."
    $first.collection('items').doc('one').set(@{ a = 0; b = 0 })
    $first.beginTransaction()
    $first.collection('items').doc('one').update(@{ a = 1 })
    $locked = $false
    try { $second.collection('items').doc('one').update(@{ b = 1 }) }
    catch [System.InvalidOperationException] { $locked = $true; Write-Host "[OBSERVATION] N04 - competing write rejected: $($_.Exception.Message)" }
    if (-not $locked) { throw 'Competing uncommitted write unexpectedly succeeded.' }
    $first.commit()
    $second.collection('items').doc('one').update(@{ b = 1 })
    $actual = $first.collection('items').doc('one').get()
    if ($actual.a -ne 1 -or $actual.b -ne 1 -or $second.InTransaction) { throw 'Lost update or open transaction after retry.' }
    Write-Host '[PASS] N04 - competing writer lock is surfaced; explicit retry preserves both updates.'
    if ([PSLocalBaseAuditNative]::NextStatement($second.DbHandle, [IntPtr]::Zero) -ne [IntPtr]::Zero) { throw 'Lock failure leaked a statement.' }

    $first.collection('parallel').doc('one').set(@{ members = @() })
    $startGate = [System.Threading.ManualResetEventSlim]::new($false)
    $readyGate = [System.Threading.CountdownEvent]::new(2)
    $workers = @()
    $workerScript = @'
param($modulePath, $sharedName, $workerId, $startGate, $readyGate)
$ErrorActionPreference = 'Stop'
Import-Module $modulePath -Force
$workerDb = New-LocalBase
$workerDb.close()
$workerDb.DbHandle = [PSLocalBaseAuditNative]::OpenSharedMemory($sharedName)
$retries = 0
try {
    [void]$readyGate.Signal()
    if (-not $startGate.Wait(10000)) { throw 'Worker start timeout.' }
    for ($i = 0; $i -lt 25; $i++) {
        $done = $false
        for ($attempt = 0; $attempt -lt 2000 -and -not $done; $attempt++) {
            try {
                $workerDb.collection('parallel').doc('one').update(@{ members = @{ '$arrayUnion' = @("$workerId/$i") } })
                $done = $true
            } catch {
                if ($_.Exception.Message -notmatch 'locked|busy') { throw }
                $retries++
                [System.Threading.Thread]::Sleep(2 + ($attempt % 5))
            }
        }
        if (-not $done) { throw "Retry limit reached for $workerId/$i" }
    }
    [pscustomobject]@{ Worker = $workerId; Writes = 25; Retries = $retries }
} finally { $workerDb.close() }
'@
    try {
        for ($workerId = 0; $workerId -lt 2; $workerId++) {
            $pipeline = [System.Management.Automation.PowerShell]::Create()
            [void]$pipeline.AddScript($workerScript).AddArgument((Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1')).AddArgument($sharedName).AddArgument($workerId).AddArgument($startGate).AddArgument($readyGate)
            $workers += @{ Pipeline = $pipeline; Async = $pipeline.BeginInvoke() }
        }
        if (-not $readyGate.Wait(10000)) { throw 'Workers failed to become ready.' }
        $startGate.Set()
        foreach ($worker in $workers) {
            if (-not $worker.Async.AsyncWaitHandle.WaitOne(20000)) { throw 'Parallel worker timeout.' }
            $result = $worker.Pipeline.EndInvoke($worker.Async)
            if ($worker.Pipeline.HadErrors) { throw ($worker.Pipeline.Streams.Error -join '; ') }
            foreach ($row in $result) { Write-Host "[OBSERVATION] N05 - worker=$($row.Worker) writes=$($row.Writes) retries=$($row.Retries)" }
        }
        $members = @($first.collection('parallel').doc('one').get().members)
        if ($members.Count -ne 50 -or @($members | Sort-Object -Unique).Count -ne 50) { throw "Lost concurrent array mutations: members=$($members.Count)" }
        Write-Host '[PASS] N05 - two concurrent runspaces retained all 50 atomic array mutations with explicit lock retries.'
    } finally {
        $startGate.Set()
        foreach ($worker in $workers) { $worker.Pipeline.Stop(); $worker.Pipeline.Dispose() }
        $startGate.Dispose(); $readyGate.Dispose()
    }
} finally { $first.close(); $second.close() }

if ([PSLocalBaseAuditNative]::MemoryUsed() -ne $baseline) { throw 'Probe cleanup did not return native memory to baseline.' }
Write-Host '[PASS] Native probes cleaned all retained connections; no native allocations remain above baseline.'
