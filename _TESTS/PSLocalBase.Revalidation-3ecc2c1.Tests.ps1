# Restored independent review regressions for commit 3ecc2c1.
# In-memory databases only. Failures describe unresolved review findings.
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
Check-Review 'V01 - dropIndex respects JSON field casing' {
    param($db)
    [void]$db.collection('users').createIndex('email')
    [void]$db.collection('users').createIndex('Email', @{ unique = $true })
    [void]$db.collection('users').add(@{ Email = 'same' }, 'u1')
    [void]$db.collection('users').dropIndex('email')
    $blocked = $false
    try { [void]$db.collection('users').add(@{ Email = 'same' }, 'u2') } catch [System.InvalidOperationException] { $blocked = $true }
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if (-not $blocked -or $indexes.Count -ne 1) { throw "Email UNIQUE lost: blocked=$blocked indexes=$($indexes.Count)" }
}
Check-Review 'V02 - old hash32 compatibility verifies the indexed expression' {
    param($db)
    $p1 = 'a.a_a_a_a_a_a_a_a.a.a.a.a.a_a.a_a_a.a'
    $p2 = 'a_a.a.a.a_a.a_a.a.a.a_a_a.a.a.a_a.a_a'
    $clean = $p1.Replace('.', '_')
    $oldName = "idx_users__${clean}_43CEB4E2"
    [void]$db.collection('users').create()
    [void]$db.query("CREATE UNIQUE INDEX ""$oldName"" ON users(json_extract(doc,'`$.$p1'));")
    [void]$db.collection('users').createIndex($p2, @{ unique = $true })
    $insert = 'INSERT INTO users(key,doc) VALUES(?,json_set(''{}'',?,?,?,?));'
    [void]$db.query($insert, @('u1', "`$.$p1", 'one', "`$.$p2", 'same'))
    $blocked = $false
    try { [void]$db.query($insert, @('u2', "`$.$p1", 'two', "`$.$p2", 'same')) } catch [System.InvalidOperationException] { $blocked = $true }
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if (-not $blocked -or $indexes.Count -ne 2) { throw "Second UNIQUE missing: blocked=$blocked indexes=$($indexes.Count)" }
}
Check-Review 'V03 - Decimal 1 preserves a distinct adjacent Double' {
    param($db)
    $next = [double]::Parse('1.0000000000000002', [Globalization.CultureInfo]::InvariantCulture)
    $db.collection('items').doc('one').set(@{ values = @($next) })
    $db.collection('items').doc('one').update(@{ values = [PSLocalBase]::ArrayRemove([decimal]1) })
    $actual = @($db.collection('items').doc('one').get().values)
    if ($actual.Count -ne 1 -or [double]$actual[0] -ne $next) { throw "Distinct value removed: count=$($actual.Count)" }
}
Check-Review 'V04 - sum honors union or explicitly rejects it' {
    param($db)
    $db.collection('a').doc('one').set(@{ n = 10 })
    $db.collection('b').doc('two').set(@{ n = 20 })
    try { $actual = $db.collection('a').union($db.collection('b')).sum('n') }
    catch [System.InvalidOperationException] { if ($_.Exception.Message -match 'composite|union|aggregate') { return }; throw }
    if ($actual -ne 30) { throw "Union sum=$actual instead of 30" }
}
Check-Review 'V05 - sum honors pagination or explicitly rejects it' {
    param($db)
    $db.collection('a').doc('one').set(@{ n = 10 })
    $db.collection('a').doc('two').set(@{ n = 20 })
    try { $actual = $db.collection('a').orderBy('n').limit(1).sum('n') }
    catch [System.InvalidOperationException] { if ($_.Exception.Message -match 'limit|pagination|aggregate') { return }; throw }
    if ($actual -ne 10) { throw "Paged sum=$actual instead of 10" }
}
Check-Review 'V06 - composite createIndex rejects before schema mutation' {
    param($db)
    $db.collection('a').doc('one').set(@{ n = 10 })
    [void]$db.collection('b').create()
    $blocked = $false
    try { [void]$db.collection('a').union($db.collection('b')).createIndex('n') }
    catch [System.InvalidOperationException] { $blocked = $_.Exception.Message -match 'composite|union' }
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if (-not $blocked -or $indexes.Count -ne 0) { throw "Rejected=$blocked indexes=$($indexes.Count)" }
}
Check-Review 'V07 - group upsert rejects before creating wildcard schema' {
    param($db)
    $db.collection('audit_a').doc('one').set(@{ n = 1 })
    $blocked = $false
    try { [void]$db.collectionGroup('audit_*').upsert(@{ n = 2 }, 'new') }
    catch [System.InvalidOperationException] { $blocked = $_.Exception.Message -match 'composite|collectionGroup' }
    if (-not $blocked -or $db.collectionExists('audit_*')) { throw "Rejected=$blocked wildcard table=$($db.collectionExists('audit_*'))" }
}
Check-Review 'V08 - populated right branch is preserved or rejected' {
    param($db)
    $db.collection('customers').doc('c').set(@{ name = 'Alice' })
    $db.collection('orders').doc('o').set(@{ customer = 'c' })
    $db.collection('archive').doc('a').set(@{ customer = 'c' })
    foreach ($method in @('union', 'unionAll')) {
        $blocked = $false
        try { $rows = @($db.collection('orders').$method($db.collection('archive').populate('customer', 'customers')).get()) }
        catch [System.InvalidOperationException] { $blocked = $_.Exception.Message -match 'populate.*not supported' }
        if (-not $blocked) {
            $populated = @($rows | Where-Object { $_.customer -isnot [string] -and $_.customer.name -eq 'Alice' })
            if ($populated.Count -ne 1) { throw "$method discarded right-branch population" }
        }
    }
}
Check-Review 'V09 - documented bare delete retains table and indexes' {
    param($db)
    [void]$db.collection('users').createIndex('name', @{ unique = $true })
    $db.collection('users').doc('u1').set(@{ name = 'Alice' })
    $before = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users';").name -join ','
    $db.collection('users').delete()
    $after = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users';").name -join ','
    if (-not $db.collectionExists('users') -or $before -cne $after) { throw 'Bare delete dropped table/indexes despite SECURITY truncate claim' }
}
Check-Review 'C01 - failed UNIQUE upgrade preserves schema and outer transaction' {
    param($db)
    [void]$db.collection('users').createIndex('email')
    [void]$db.collection('users').add(@{ email = 'same' }, 'u1')
    [void]$db.collection('users').add(@{ email = 'same' }, 'u2')
    $before = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';").name -join ','
    $db.beginTransaction()
    $db.collection('other').doc('one').set(@{ n = 1 })
    $blocked = $false
    try { [void]$db.collection('users').createIndex('email', @{ unique = $true }) } catch [System.InvalidOperationException] { $blocked = $true }
    $after = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';").name -join ','
    if (-not $blocked -or $before -cne $after -or -not $db.InTransaction) { throw 'Schema/transaction changed after failed upgrade' }
    $db.rollback()
    if ($db.collectionExists('other')) { throw 'Outer rollback failed' }
}
Check-Review 'C02 - explicit BLOB rejection leaves connection usable' {
    param($db)
    foreach ($sql in @("SELECT X'0041FF80' AS value;", "SELECT X'' AS value;")) {
        $blocked = $false
        try { [void]$db.query($sql) } catch [System.NotSupportedException] { $blocked = $true }
        if (-not $blocked -or $db.query('SELECT 1 AS n;')[0].n -ne 1) { throw 'BLOB or later query contract failed' }
    }
}
Write-Host "Revalidation 3ecc2c1: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
