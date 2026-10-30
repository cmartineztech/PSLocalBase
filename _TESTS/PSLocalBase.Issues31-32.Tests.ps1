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
    foreach($n in 1..3) {$db.collection('a').doc("a$n").set(@{n=$n;profile=@{name="a$n"};flag=$true;items=@($n)})}
    foreach($n in 4..5) {$db.collection('b').doc("b$n").set(@{n=$n;profile=@{name="b$n"};flag=$false;items=@($n)})}
}
Check '#31 global pagination on both union operators' {
    param($db); Seed $db
    foreach($kind in @('union','unionAll')) {
        $q=if($kind -eq 'union') {$db.collection('a').union($db.collection('b'))}else{$db.collection('a').unionAll($db.collection('b'))}
        $page=$q.orderBy('n').skip(2).limit(2)
        if((@($page.get()).n -join ',') -ne '3,4' -or $page.count() -ne 2) {throw "$kind paged incorrect rows"}
        $projection=@($q.select('profile.name').get() | ForEach-Object {$_.'profile.name'} | Sort-Object)
        if(($projection -join ',') -ne 'a1,a2,a3,b4,b5') {throw "$kind lost nested values"}
    }
}
Check '#31 branch-local limits remain separate from global limits and clones' {
    param($db); Seed $db
    $left=$db.collection('a').orderBy('n','desc').skip(1).limit(1)
    $right=$db.collection('b').orderBy('n','desc').limit(1)
    $q=$left.unionAll($right)
    if((@($q.orderBy('n').get()).n -join ',') -ne '2,5' -or $q.count() -ne 2) {throw 'Branch-local paging lost or applied globally'}
    $page=$q.clone().orderBy('n','desc').skip(1).limit(1)
    if(@($page.get())[0].n -ne 2 -or $page.count() -ne 1 -or $q.count() -ne 2) {throw 'Global page changed branch plan or source'}
    $leftEmpty=$db.collection('a').limit(0).unionAll($db.collection('b'))
    if($leftEmpty.count() -ne 2) {throw 'LHS limit(0) became a global limit'}
}
Check '#31 branch projection preserves bool and array types' {
    param($db); Seed $db
    $q=$db.collection('a').select('n','flag','items').unionAll($db.collection('b').select('n','flag','items'))
    $rows=@($q.orderBy('n').get())
    if($rows.Count -ne 5 -or $rows[0].flag -isnot [bool] -or $rows[4].flag -isnot [bool] -or @($rows[0].items).Count -ne 1) {throw 'Branch projection changed JSON types'}
}
Check '#31 filters after union target the complete result' {
    param($db); Seed $db
    $q=$db.collection('a').where('n','>',1).unionAll($db.collection('b')).where('n','>',4)
    if((@($q.get()).n -join ',') -ne '5' -or $q.count() -ne 1) {throw 'Composite filter did not cover both branches'}
}
Check '#32 complete NUL strings and Unicode match the PowerShell oracle' {
    param($db)
    $names=@('a',"a`0tail","`0a","a`0",'',"`0",'a_b','a%b','a*b','a?b','a\b',([string][char]233),([string][char]201))
    for($i=0;$i -lt $names.Count;$i++) {$db.collection('patterns').doc("p$i").set(@{name=$names[$i]})}
    foreach($pattern in @('a',"a`0tail","*`0*","?`0*",'*','?',"`0",'a_b','a%*','a`*b','a\b',([string][char]201))) {
        foreach($op in @('-like','-notlike')) {
            $expected=@(for($i=0;$i -lt $names.Count;$i++) {if(($op -eq '-like' -and $names[$i] -like $pattern) -or ($op -eq '-notlike' -and $names[$i] -notlike $pattern)) {"p$i"}}) | Sort-Object
            $actual=@($db.collection('patterns').where('name',$op,$pattern).get(@{keys=$true})).key | Sort-Object
            if(($expected -join ',') -cne ($actual -join ',')) {throw "$op differed from PowerShell for pattern length=$($pattern.Length)"}
        }
    }
}
Check '#32 deletion preserves nonmatching NUL documents and exact equality' {
    param($db)
    $tail="a`0tail"
    $db.collection('items').doc('a').set(@{name='a'})
    $db.collection('items').doc('tail').set(@{name=$tail})
    if(@($db.collection('items').where('name','=',$tail).get()).Count -ne 1) {throw 'NUL equality fixture invalid'}
    $db.collection('items').where('name','-like','a').delete()
    if($db.collection('items').doc('tail').get().name -cne $tail -or $db.collection('items').count() -ne 1) {throw 'NUL document deleted or altered'}
    $db.collection('items').where('name','-notlike','a').delete()
    if($db.collection('items').count() -ne 0) {throw 'Negated match did not delete the intended NUL document'}
    $db.collection('numeric').doc('one').set(@{name='1';flag=$true})
    $db.collection('numeric').doc('tail').set(@{name="1`0tail";flag=$false})
    foreach($pattern in @(1,$true)) {
        if(@($db.collection('numeric').where('name','-like',$pattern).get()).Count -ne 1) {throw 'Typed pattern bypassed full-string matching'}
    }
    if(@($db.collection('numeric').where('flag','-like',$true).get()).Count -ne 1) {throw 'JSON boolean pattern normalization changed'}
}
Check '#32 SQL LIKE stays distinct and matcher survives GC on multiple connections' {
    param($db)
    $db.collection('items').doc('a').set(@{name='a_b'})
    $db.collection('items').doc('b').set(@{name='aXb'})
    if(@($db.collection('items').where('name','LIKE','a_b').get()).Count -ne 2) {throw 'SQL LIKE contract changed'}
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    for($i=0;$i -lt 20;$i++) {if(@($db.collection('items').where('name','-like','a_b').get()).Count -ne 1) {throw 'Matcher changed after GC'} }
    $other=New-LocalBase
    try {$other.collection('items').doc('one').set(@{name="a`0b"}); if(@($other.collection('items').where('name','-like',"a`0b").get()).Count -ne 1) {throw 'Matcher missing on second connection'}} finally {$other.close()}
}
Write-Host "Issues31-32: passed=$script:passed; failed=$script:failed"
if($script:failed -gt 0) {exit 1}
