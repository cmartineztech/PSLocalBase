# Additional independent cases from the review of 83ed742.
# No engine modifications; all databases are in memory.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0
$script:failed = 0
function Check-Remaining([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
Check-Remaining 'N01 - dropping the migrated path preserves a different legacy UNIQUE' {
    param($db)
    $p1 = 'a.a_a_a_a_a_a_a_a.a.a.a.a.a_a.a_a_a.a'
    $p2 = 'a_a.a.a.a_a.a_a.a.a.a_a_a.a.a.a_a.a_a'
    $clean = $p1.Replace('.', '_')
    $oldName = "idx_users__${clean}_43CEB4E2"
    [void]$db.collection('users').create()
    [void]$db.query("CREATE UNIQUE INDEX ""$oldName"" ON users(json_extract(doc,'`$.$p1'));")
    [void]$db.collection('users').createIndex($p2, @{ unique = $true })
    [void]$db.collection('users').dropIndex($p2)
    $insert = 'INSERT INTO users(key,doc) VALUES(?,json_set(''{}'',?,?,?,?));'
    [void]$db.query($insert, @('u1', "`$.$p1", 'same', "`$.$p2", 'one'))
    $blocked = $false
    try { [void]$db.query($insert, @('u2', "`$.$p1", 'same', "`$.$p2", 'two')) }
    catch [System.InvalidOperationException] { $blocked = $true }
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if (-not $blocked -or $indexes.Count -ne 1) { throw "Legacy UNIQUE lost: blocked=$blocked indexes=$($indexes.Count)" }
}
Check-Remaining 'N02 - nested union retains all branches or explicitly rejects nesting' {
    param($db)
    $db.collection('a').doc('a').set(@{ n = 1 })
    $db.collection('b').doc('b').set(@{ n = 2 })
    $db.collection('c').doc('c').set(@{ n = 3 })
    try { $rows = @($db.collection('a').union($db.collection('b').union($db.collection('c'))).get()) }
    catch [System.InvalidOperationException] { if ($_.Exception.Message -match 'composite|union|nested') { return }; throw }
    if ($rows.Count -ne 3) { throw "Nested union returned $($rows.Count) instead of 3" }
}
Check-Remaining 'N03 - group create rejects before changing schema' {
    param($db)
    $db.collection('audit_a').doc('a').set(@{ n = 1 })
    $blocked = $false
    try { [void]$db.collectionGroup('audit_*').create() }
    catch [System.InvalidOperationException] { $blocked = $_.Exception.Message -match 'group|composite|read.only' }
    if (-not $blocked -or $db.collectionExists('audit_*')) { throw "Rejected=$blocked literal wildcard table=$($db.collectionExists('audit_*'))" }
}
foreach ($kind in @('Double', 'Decimal')) {
    foreach ($operation in @('remove', 'union')) {
        Check-Remaining "N04 - same $kind $operation after JSON roundtrip" {
            param($db)
            $text = '1.0000000000000002'
            $value = if ($kind -eq 'Double') { [double]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) } else { [decimal]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) }
            $db.collection('items').doc('one').set(@{ values = @($value) })
            $stored = @($db.collection('items').doc('one').get().values)
            $storedType = $stored[0].GetType().Name
            $mutation = if ($operation -eq 'remove') { [PSLocalBase]::ArrayRemove($value) } else { [PSLocalBase]::ArrayUnion($value) }
            $db.collection('items').doc('one').update(@{ values = $mutation })
            $actual = @($db.collection('items').doc('one').get().values)
            $expectedCount = if ($operation -eq 'remove') { 0 } else { 1 }
            if ($actual.Count -ne $expectedCount) { throw "Stored type=$storedType; expected=$expectedCount actual=$($actual.Count)" }
        }
    }
}
Write-Host "Review 83ed742 additional cases: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
