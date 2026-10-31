# Independent audit evidence for hardening/v2 de8801d plus the local native bridge.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed=0; $script:failed=0
function Check([string]$Name,[scriptblock]$Body) {
    $db=New-LocalBase
    try {& $Body $db; $script:passed++; Write-Host "[PASS] $Name"}
    catch {$script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)"}
    finally {$db.close()}
}
Check 'Control: failed writes retain key and excluded document' {
    param($db)
    $null=$db.collection('items').createIndex('email',@{unique=$true})
    $db.collection('items').doc('a').set(@{email='a';n=1})
    $db.collection('items').doc('b').set(@{email='b';n=2})
    foreach($method in @('set','update','upsert')) {
        $q=$db.collection('items').doc('a'); $rejected=$false
        try {switch($method) {set {$q.set(@{email='b'})}; update {$q.update(@{email='b'})}; upsert {$null=$q.upsert(@{email='b'})}}}
        catch [System.InvalidOperationException] {$rejected=$true}
        if(-not $rejected -or $q.get().n -ne 1 -or $db.collection('items').doc('b').get().n -ne 2) {throw "$method changed data or scope after UNIQUE failure"}
    }
    $q.delete(); $q.delete()
    if(-not $db.collection('items').doc('b').exists()) {throw 'Repeated cleanup deleted excluded b'}
}
Check 'Control: global union page and NUL wildcard retain previous fixes' {
    param($db)
    foreach($n in 1..3) {$db.collection('a').doc("a$n").set(@{n=$n})}
    foreach($n in 4..5) {$db.collection('b').doc("b$n").set(@{n=$n})}
    $q=$db.collection('a').unionAll($db.collection('b')).orderBy('n').skip(2).limit(2)
    if((@($q.get()).n -join ',') -ne '3,4' -or $q.count() -ne 2) {throw 'Global union page regressed'}
    $db.collection('patterns').doc('a').set(@{name='a'})
    $db.collection('patterns').doc('tail').set(@{name="a`0tail"})
    $db.collection('patterns').where('name','-like','a').delete()
    if(-not $db.collection('patterns').doc('tail').exists()) {throw 'NUL wildcard regression'}
}
foreach($kind in @('limit0','skip1','skip1limit1')) {
    Check "V2-F01 point pagination parity: $kind" {
        param($db)
        $db.collection('items').doc('a').set(@{n=1})
        $base=$db.collection('items').doc('a')
        $q=switch($kind) {'limit0' {$base.limit(0)} 'skip1' {$base.skip(1)} 'skip1limit1' {$base.skip(1).limit(1)}}
        # Point lookups return $null when empty; @($null).Count is not a document count.
        $actual=if($null -eq $q.get()) {0}else{1}
        if($actual -ne 0 -or $q.count() -ne 0 -or $q.exists() -or $null -ne $q.first()) {throw "Expected empty point result; get=$actual count=$($q.count()) exists=$($q.exists()) firstNull=$($null -eq $q.first())"}
    }
}
Write-Host "Review-v2-de8801d: passed=$script:passed; failed=$script:failed"
if($script:failed -gt 0) {exit 1}
