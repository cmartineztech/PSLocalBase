# Targeted regression probes from the security/functionality review.
# Run in a fresh PowerShell process. All databases are in memory.
# These checks describe the desired behavior; failures are unresolved findings.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:failed = 0
$script:passed = 0

function Test-AuditCase([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try {
        & $Body $db
        $script:passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failed++
        Write-Host "[FAIL] ${Name}: $($_.Exception.Message)"
    } finally {
        $db.close()
    }
}

Test-AuditCase 'F01 - orderBy().delete() must reject accidental collection drop' {
    param($db)
    $db.collection('users').doc('u1').set(@{ name = 'Alice' })
    $rejected = $false
    try { $db.collection('users').orderBy('name').delete() } catch { $rejected = $true }
    if (-not $rejected -or -not $db.collectionExists('users')) {
        throw "Rejected=$rejected; collection survives=$($db.collectionExists('users'))"
    }
}

Test-AuditCase 'F02 - upsert without identity must generate distinct keys' {
    param($db)
    $first = $db.collection('users').upsert([pscustomobject][ordered]@{ role = 'reader'; name = 'Alice' })
    $second = $db.collection('users').upsert([pscustomobject][ordered]@{ role = 'reader'; name = 'Bob' })
    $count = $db.collection('users').count()
    if ($first -eq $second -or $count -ne 2) {
        throw "First key=$first; second key=$second; documents=$count (expected 2)"
    }
}

Test-AuditCase 'F03 - ArrayRemove must distinguish adjacent Int64 values above 2^53' {
    param($db)
    $a = [long]9007199254740992
    $b = [long]9007199254740993
    $db.collection('items').doc('one').set(@{ ids = @($a, $b) })
    $db.collection('items').doc('one').update(@{ ids = [PSLocalBase]::ArrayRemove($a) })
    $remaining = @($db.collection('items').doc('one').get().ids)
    if ($remaining.Count -ne 1 -or $remaining[0] -ne $b) {
        throw "Remaining=[$($remaining -join ',')]; expected [$b]"
    }
}

Test-AuditCase 'F04 - dropIndex must resolve collection casing like SQLite' {
    param($db)
    [void]$db.collection('users').createIndex('email', @{ unique = $true })
    [void]$db.collection('USERS').dropIndex('email')
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if ($indexes.Count -ne 0) {
        throw "Indexes still present: $($indexes.name -join ',')"
    }
}

Test-AuditCase 'F05 - union with a point lookup must agree between get and count' {
    param($db)
    $db.collection('a').doc('a1').set(@{ n = 1 })
    $db.collection('b').doc('b1').set(@{ n = 2 })
    $actual = @($db.collection('a').doc('a1').union($db.collection('b')).get())
    $count = $db.collection('a').doc('a1').union($db.collection('b')).count()
    if ($actual.Count -ne 2 -or $count -ne 2) {
        throw "get returned $($actual.Count); count returned $count; expected 2 for both"
    }
}

Test-AuditCase 'F06 - union must accept a filtered collection that does not exist' {
    param($db)
    $db.collection('b').doc('b1').set(@{ name = 'Bob' })
    $actual = @($db.collection('missing').where('name', '=', 'Alice').union($db.collection('b')).get())
    if ($actual.Count -ne 1 -or $actual[0].name -ne 'Bob') {
        throw "Expected the surviving branch containing Bob; got $($actual.Count) rows"
    }
}

Test-AuditCase 'F07 - array-contains must exclude scalar and object fields' {
    param($db)
    $db.collection('items').doc('array').set(@{ tags = @('admin') })
    $db.collection('items').doc('scalar').set(@{ tags = 'admin' })
    $db.collection('items').doc('object').set(@{ tags = @{ role = 'admin' } })
    $actual = $db.collection('items').where('tags', 'array-contains', 'admin').get(@{ keys = $true })
    if ($actual.Count -ne 1 -or $actual[0].key -ne 'array') {
        throw "Matched keys=[$($actual.key -join ',')]; expected [array]"
    }
}

Write-Host "Audit regressions: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
