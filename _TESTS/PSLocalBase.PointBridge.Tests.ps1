$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'PSLocalBase.psd1') -Force
$passed=0; $failed=0
foreach($exists in @($true,$false)) {
    $db=New-LocalBase
    try {
        $db.collection('refs').doc('r').set(@{label='reference'})
        if($exists) {$db.collection('items').doc('a').set(@{n=1;ref='r'})}
        foreach($view in @('plain','select','populate')) {
            foreach($page in @('none','zero','skip','skiplimit','one','many')) {
                try {
                    $q=$db.collection('items').doc('a')
                    if($view -eq 'select') {$q=$q.select('n')}
                    if($view -eq 'populate') {$q=$q.populate('ref','refs')}
                    $q=switch($page) {'zero' {$q.limit(0)} 'skip' {$q.skip(1)} 'skiplimit' {$q.skip(1).limit(1)} 'one' {$q.skip(0).limit(1)} 'many' {$q.limit(5)} default {$q}}
                    $visible=$exists -and $page -notin @('zero','skip','skiplimit')
                    $result=$q.get(); $first=$q.first()
                    if(($null -ne $result) -ne $visible -or ($null -ne $first) -ne $visible -or $q.count() -ne [int]$visible -or $q.exists() -ne $visible) {throw 'Point result/count/exists/first disagree'}
                    if($visible -and ($result.n -ne 1 -or $q.get().n -ne 1)) {throw 'Read lost data or scope'}
                    $passed++
                }catch {$failed++;Write-Host "[FAIL] point exists=$exists view=$view page=$page : $($_.Exception.Message)"}
            }
        }
    }finally {$db.close()}
}
# Fresh processes are essential: .NET types cannot be replaced in an existing process.
$dir=Join-Path ([IO.Path]::GetTempPath()) ('pslb-bridge-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $dir
$native=Get-Content (Join-Path $root 'InitWinSqlite3Native.ps1') -Raw
$old=Join-Path $dir 'old.ps1'; $child=Join-Path $dir 'child.ps1'
Set-Content -LiteralPath $old -Encoding UTF8 -Value ($native.Replace('BridgeVersion = 4','BridgeVersion = 3'))
$childSource=@'
param($modulePath,$bridgePath,$reject)
$ErrorActionPreference='Stop'
if($bridgePath -ne 'cold') {& $bridgePath}
Import-Module $modulePath -Force
Add-Type 'using System; using System.Runtime.InteropServices; public class BridgeMemoryProbe { [DllImport("winsqlite3.dll",EntryPoint="sqlite3_memory_used",CallingConvention=CallingConvention.Cdecl)] public static extern long Used(); }'
$before=[BridgeMemoryProbe]::Used()
for($i=0;$i -lt 5;$i++) {
    $db=$null
    try {
        $db=New-LocalBase
        if($reject -eq 'yes') {throw 'Incompatible bridge was accepted'}
        $blocked=$false
        try {$null=$db.query("SELECT 1;`0 SELECT 2;")}catch [System.InvalidOperationException] {$blocked=$true}
        if(-not $blocked) {throw 'SQL NUL suffix accepted'}
        $db.collection('items').doc('a').set(@{s="a`0b"})
        if(@($db.collection('items').where('s','=',"a`0b").get()).Count -ne 1) {throw 'NUL data changed'}
    }catch {
        if($reject -ne 'yes' -or $_.Exception.Message -notmatch 'Restart PowerShell') {throw}
    }finally {if($db) {$db.close()}}
}
if([BridgeMemoryProbe]::Used() -ne $before) {throw 'Native allocations retained after initialization/close'}
'@
Set-Content -LiteralPath $child -Encoding UTF8 -Value $childSource
try {
    foreach($mode in @('cold','current','old')) {
        $bridgePath=switch($mode) {'cold' {'cold'} 'current' {Join-Path $root 'InitWinSqlite3Native.ps1'} 'old' {$old}}
        $reject=if($mode -eq 'old') {'yes'}else{'no'}
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $child (Join-Path $root 'PSLocalBase.psd1') $bridgePath $reject
        if($LASTEXITCODE -ne 0) {$failed++;Write-Host "[FAIL] bridge mode=$mode"}else{$passed++;Write-Host "[PASS] bridge mode=$mode"}
    }
}finally {Remove-Item -LiteralPath $old,$child -Force; Remove-Item -LiteralPath $dir}
Write-Host "PointBridge: passed=$passed; failed=$failed"
if($failed -gt 0) {exit 1}
