# Independent review evidence; the existing engine and runner remain unchanged.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed=0; $script:failed=0
function Check([string]$Name,[scriptblock]$Body) {
    $db=New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally {$db.close()}
}
function Seed($db) {
    foreach($n in 1..3) {$db.collection('a').doc("a$n").set(@{n=$n;profile=@{name="a$n"}})}
    foreach($n in 4..5) {$db.collection('b').doc("b$n").set(@{n=$n;profile=@{name="b$n"}})}
}
Check 'Control: repeated filtered delete preserves another key' {
    param($db)
    $db.collection('items').doc('a').set(@{n=1})
    $db.collection('items').doc('b').set(@{n=2})
    $q=$db.collection('items').where('n','=',1)
    $q.delete(); $q.delete()
    if(-not $db.collection('items').doc('b').exists()) {throw 'Repeated delete removed excluded b'}
}
Check 'Control: RHS reuse preserves first union snapshot and terminal parity' {
    param($db)
    foreach($name in @('a','b','c')) {$db.collection($name).doc('one').set(@{tag=$name})}
    $right=$db.collection('b')
    $first=$db.collection('a').union($right)
    $second=$right.union($db.collection('c'))
    if(@($first.get()).Count -ne 2 -or $first.count() -ne 2 -or -not $first.exists() -or @($first.clone().get()).Count -ne 2 -or @($second.get()).Count -ne 2) {throw 'Independent union snapshots changed'}
}
Check 'N1: global union skip applies once' {
    param($db); Seed $db
    $q=$db.collection('a').unionAll($db.collection('b')).orderBy('n').skip(1)
    $actual=@($q.get()).n
    if(($actual -join ',') -ne '2,3,4,5' -or $q.count() -ne 4) {throw "Expected2,3,4,5/count4 actual=$($actual -join ',')/count$($q.count())"}
}
Check 'N1: global union skip-limit applies once' {
    param($db); Seed $db
    $q=$db.collection('a').union($db.collection('b')).orderBy('n').skip(2).limit(2)
    $actual=@($q.get()).n
    if(($actual -join ',') -ne '3,4' -or $q.count() -ne 2) {throw "Expected3,4/count2 actual=$($actual -join ',')/count$($q.count())"}
}
Check 'N1: global nested projection preserves values in both branches' {
    param($db); Seed $db
    $q=$db.collection('a').unionAll($db.collection('b')).select('profile.name')
    $actual=@($q.get() | ForEach-Object {$_.'profile.name'})
    $expected=@('a1','a2','a3','b4','b5')
    if((($actual | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',')) {throw "Expected a1,a2,a3,b4,b5 actual=$($actual -join ',')"}
}
Check 'N2: PowerShell-like literal a preserves a-NUL-tail during delete' {
    param($db)
    $tail="a`0tail"
    if($tail -like 'a') {throw 'PowerShell oracle unexpectedly matched'}
    $db.collection('items').doc('literal').set(@{name='a'})
    $db.collection('items').doc('tail').set(@{name=$tail})
    if($db.collection('items').doc('tail').get().name -cne $tail) {throw 'Fixture lost NUL content'}
    $db.collection('items').where('name','-like','a').delete()
    if(-not $db.collection('items').doc('tail').exists()) {throw 'Deleted a-NUL-tail despite PowerShell -like a being False'}
}
Write-Host "Review fb3da3b: passed=$script:passed; failed=$script:failed"
if($script:failed -gt 0) {exit 1}
