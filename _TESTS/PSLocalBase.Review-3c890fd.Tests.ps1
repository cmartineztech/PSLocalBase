# Independent review evidence for dev 3c890fd. Does not change the existing runner.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0
$script:failed = 0
function Check-Review([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
Check-Review 'Issue22 distinct tiny numeric members' {
    param($db)
    if ([PSLocalBase]::_JsonValuesEqual([double]6e-29,[decimal]1e-28)) { throw 'Distinct numbers compare equal.' }
    $db.collection('items').doc('one').set(@{values=@([double]6e-29)})
    $db.collection('items').doc('one').update(@{values=[PSLocalBase]::ArrayRemove([decimal]1e-28)})
    if (@($db.collection('items').doc('one').get().values).Count -ne 1) { throw 'Distinct member removed.' }
    $db.collection('items').doc('one').update(@{values=[PSLocalBase]::ArrayUnion([decimal]1e-28)})
    if (@($db.collection('items').doc('one').get().values).Count -ne 2) { throw 'Distinct member omitted.' }
}
Check-Review 'Issue23 union copies both branch parameter lists' {
    param($db)
    foreach ($name in @('a','b')) {
        $db.collection($name).doc('one').set(@{n=1})
        $db.collection($name).doc('two').set(@{n=2})
    }
    $left=$db.collection('a').where('n','=',1)
    $right=$db.collection('b').where('n','=',2)
    $combined=$left.unionAll($right)
    $left.WhereParameters[0]=99
    $right.WhereParameters[0]=99
    if ($combined.count() -ne 2) { throw 'Snapshot changed with source state.' }
}
Check-Review 'Issue24 independent query branches and repeated reads' {
    param($db)
    $db.collection('users').doc('a').set(@{role='admin';active=$true})
    $db.collection('users').doc('b').set(@{role='admin';active=$false})
    $db.collection('users').doc('c').set(@{role='reader';active=$true})
    $base=$db.collection('users')
    $admins=$base.where('role','=','admin')
    $active=$base.where('active','=',$true)
    if ($base.count() -ne 3 -or $admins.count() -ne 2 -or $active.count() -ne 2) { throw 'Branches interfere.' }
    $null=$admins.get()
    if ($admins.count() -ne 2) { throw 'get changed filters.' }
}
Check-Review 'R1 every documented read terminal preserves filters' {
    param($db)
    $db.collection('items').doc('one').set(@{n=1})
    $db.collection('items').doc('two').set(@{n=2})
    $broken=@()
    foreach ($method in @('exists','distinct','sum','avg','min','max')) {
        $q=$db.collection('items').where('n','=',1)
        switch ($method) {
            'exists' {$null=$q.exists()}
            'distinct' {$null=$q.distinct('n')}
            'sum' {$null=$q.sum('n')}
            'avg' {$null=$q.avg('n')}
            'min' {$null=$q.min('n')}
            'max' {$null=$q.max('n')}
        }
        if ($q.count() -ne 1) { $broken += $method }
    }
    if ($broken.Count -gt 0) { throw "Filters erased by: $($broken -join ', ')" }
}
Check-Review 'R1 exists followed by delete preserves excluded document' {
    param($db)
    $db.collection('items').doc('one').set(@{n=1})
    $db.collection('items').doc('two').set(@{n=2})
    $q=$db.collection('items').where('n','=',1)
    if (-not $q.exists()) { throw 'Fixture missing.' }
    $q.delete()
    if ($db.collection('items').count() -ne 1 -or -not $db.collection('items').doc('two').exists()) { throw 'Delete removed excluded document.' }
}
Check-Review 'R2 simple RHS remains reusable in another union' {
    param($db)
    foreach ($name in @('a','b','c')) { $db.collection($name).doc('one').set(@{n=$name}) }
    $right=$db.collection('b')
    $first=$db.collection('a').union($right)
    $second=$right.union($db.collection('c'))
    if ($first.count() -ne 2 -or $second.count() -ne 2) { throw 'Independent union results incorrect.' }
}
Check-Review 'R4 distinct honors composite scope or rejects it explicitly' {
    param($db)
    $db.collection('part_a').doc('a').set(@{n=1})
    $db.collection('part_b').doc('b').set(@{n=2})
    foreach ($kind in @('union','group')) {
        $q=if ($kind -eq 'union') { $db.collection('part_a').union($db.collection('part_b')) } else { $db.collectionGroup('part_*') }
        try { $actual=@($q.distinct('n')) }
        catch [System.InvalidOperationException] { continue }
        catch [System.NotSupportedException] { continue }
        if ($actual.Count -ne 2 -or $actual -notcontains 1 -or $actual -notcontains 2) { throw "$kind distinct silently omitted branches; actual=$($actual -join ',')" }
    }
}
Check-Review 'R3 synchronous option honors FULL and NORMAL with readback verification' {
    param($ignored)
    $tmpDb = [System.IO.Path]::GetTempFileName() + '.db'
    try {
        $dbFull = New-LocalBase -Path $tmpDb -Options @{ wal = $true; synchronous = 'FULL' }
        $syncVal = $dbFull.query('PRAGMA synchronous;')[0].synchronous
        $dbFull.close()
        if ($syncVal -ne 2) { throw "Expected synchronous=2 (FULL), got $syncVal" }

        $dbNormal = New-LocalBase -Path $tmpDb -Options @{ wal = $true; synchronous = 'NORMAL' }
        $syncValNorm = $dbNormal.query('PRAGMA synchronous;')[0].synchronous
        $dbNormal.close()
        if ($syncValNorm -ne 1) { throw "Expected synchronous=1 (NORMAL), got $syncValNorm" }

        $rejected = $false
        try {
            $null = New-LocalBase -Path $tmpDb -Options @{ synchronous = 'INVALID_MODE' }
        } catch [System.ArgumentException] {
            $rejected = $true
        }
        if (-not $rejected) { throw 'Expected INVALID_MODE synchronous to throw ArgumentException' }
    } finally {
        Remove-Item -Force $tmpDb -ErrorAction SilentlyContinue
        Remove-Item -Force ($tmpDb + '-wal') -ErrorAction SilentlyContinue
        Remove-Item -Force ($tmpDb + '-shm') -ErrorAction SilentlyContinue
    }
}
Write-Host "Review 3c890fd: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
