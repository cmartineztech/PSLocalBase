# Independent regression evidence; existing runner unchanged.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed=0; $script:failed=0
function Check-Review([string]$Name,[scriptblock]$Body) {
    $db=New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
Check-Review 'Control: reads preserve filters; exists-delete excludes b' {
    param($db)
    $db.collection('items').doc('a').set(@{n=1}); $db.collection('items').doc('b').set(@{n=2})
    foreach($method in @('exists','distinct','sum','avg','min','max')) {
        $q=$db.collection('items').where('n','=',1)
        switch($method) {
            'exists' {$null=$q.exists()}; 'distinct' {$null=$q.distinct('n')}
            'sum' {$null=$q.sum('n')}; 'avg' {$null=$q.avg('n')}
            'min' {$null=$q.min('n')}; 'max' {$null=$q.max('n')}
        }
        if($q.count() -ne 1) { throw "$method erased filters" }
    }
    $q=$db.collection('items').where('n','=',1); $null=$q.exists(); $q.delete()
    if(-not $db.collection('items').doc('b').exists()) { throw 'Excluded key deleted' }
}
Check-Review 'Control: tiny numeric members remain distinct' {
    param($db)
    if([PSLocalBase]::_JsonValuesEqual([double]6e-29,[decimal]1e-28)) { throw 'Distinct numbers equal' }
    $db.collection('items').doc('a').set(@{values=@([double]6e-29)})
    $db.collection('items').doc('a').update(@{values=[PSLocalBase]::ArrayUnion([decimal]1e-28)})
    if(@($db.collection('items').doc('a').get().values).Count -ne 2) { throw 'Member omitted' }
}
Check-Review 'Control: distinct rejects union and group' {
    param($db)
    $db.collection('a').doc('a').set(@{n=1}); $db.collection('b').doc('b').set(@{n=2})
    foreach($kind in @('union','group')) {
        $q=if($kind -eq 'union') {$db.collection('a').union($db.collection('b'))}else{$db.collectionGroup('*')}
        $rejected=$false
        try {$null=$q.distinct('n')} catch [System.InvalidOperationException] {$rejected=$true}
        if(-not $rejected) {throw 'Composite distinct not rejected'}
    }
}
foreach($kind in @('filtered','point','missing')) {
    Check-Review "S1: repeated $kind deletion preserves excluded key" {
        param($db)
        if($kind -ne 'missing') {
            $db.collection('items').doc('a').set(@{n=1}); $db.collection('items').doc('b').set(@{n=2})
        }
        $q=if($kind -eq 'point') {$db.collection('items').doc('a')}else{$db.collection('items').where('n','=',1)}
        $q.delete()
        if($kind -eq 'missing') {
            $db.collection('items').doc('a').set(@{n=1}); $db.collection('items').doc('b').set(@{n=2})
        }
        $q.delete()
        if(-not $db.collection('items').doc('b').exists()) {throw 'Second delete removed excluded key b'}
    }
}
Check-Review 'S2: RHS reuse preserves original union get/count parity' {
    param($db)
    foreach($name in @('a','b','c')) {$db.collection($name).doc('one').set(@{tag=$name})}
    $right=$db.collection('b'); $first=$db.collection('a').union($right)
    if(@($first.get()).Count -ne 2) {throw 'Initial fixture incorrect'}
    $second=$right.union($db.collection('c'))
    if(@($second.get()).Count -ne 2) {throw 'Second union incorrect'}
    if(@($first.get()).Count -ne 2 -or $first.count() -ne 2) {throw 'Original snapshot invalidated'}
}
Check-Review 'S3: -like matches PowerShell for literal underscore and percent' {
    param($db)
    $names=@('a_b','aXb','a%b','ab')
    foreach($name in $names) {$null=$db.collection('items').add(@{name=$name})}
    $differences=@()
    foreach($pattern in @('a_b','a_*','a%b','a%*','a?b')) {
        $expected=@($names | Where-Object {$_ -like $pattern} | Sort-Object)
        $actual=@($db.collection('items').where('name','-like',$pattern).get() | ForEach-Object {$_.name} | Sort-Object)
        if(($actual -join '|') -cne ($expected -join '|')) {$differences += "$pattern expected=[$($expected -join ',')] actual=[$($actual -join ',')]"}
    }
    if($differences.Count -gt 0) {throw ($differences -join '; ')}
}
Check-Review 'S4: union preserves RHS limit zero or rejects unsupported scope' {
    param($db)
    $db.collection('a').doc('a').set(@{n=1})
    $db.collection('b').doc('b1').set(@{n=2}); $db.collection('b').doc('b2').set(@{n=3})
    $right=$db.collection('b').limit(0)
    if(@($right.get()).Count -ne 0) {throw 'RHS fixture not empty'}
    try {$result=@($db.collection('a').unionAll($right).get())}
    catch [System.InvalidOperationException] {return}
    catch [System.NotSupportedException] {return}
    if($result.Count -ne 1) {throw "RHS limit(0) discarded: expected1 actual=$($result.Count)"}
}
Write-Host "Review 158582f: passed=$script:passed; failed=$script:failed"
if($script:failed -gt 0) {exit 1}
