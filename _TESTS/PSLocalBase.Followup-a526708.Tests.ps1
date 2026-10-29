# Additional independent evidence for a526708, outside its original green runner.
# All databases are in memory. No changes to the engine or previous assertions.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0
$script:failed = 0
function Check-Followup([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
foreach ($text in @('0.1', '0.2', '0.01', '1.0000000000000002')) {
    foreach ($kind in @('Double', 'Decimal')) {
        foreach ($operation in @('remove', 'union')) {
            Check-Followup "Numeric roundtrip: value=$text input=$kind operation=$operation" {
                param($db)
                $value = if ($kind -eq 'Double') { [double]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) } else { [decimal]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) }
                $db.collection('items').doc('one').set(@{ values = @($value) })
                $stored = @($db.collection('items').doc('one').get().values)
                $storedType = $stored[0].GetType().Name
                $mutation = if ($operation -eq 'remove') { [PSLocalBase]::ArrayRemove($value) } else { [PSLocalBase]::ArrayUnion($value) }
                $db.collection('items').doc('one').update(@{ values = $mutation })
                $actual = @($db.collection('items').doc('one').get().values)
                $expected = if ($operation -eq 'remove') { 0 } else { 1 }
                if ($actual.Count -ne $expected) { throw "stored=$storedType expected=$expected actual=$($actual.Count)" }
            }
        }
    }
}
Check-Followup 'Mutable right branch must not silently bypass nested-union rejection' {
    param($db)
    $db.collection('a').doc('a').set(@{ n = 1 })
    $db.collection('b').doc('b').set(@{ n = 2 })
    $db.collection('c').doc('c').set(@{ n = 3 })
    $right = $db.collection('b')
    $query = $db.collection('a').union($right)
    try {
        [void]$right.union($db.collection('c'))
        $rows = @($query.get())
    } catch [System.InvalidOperationException] {
        if ($_.Exception.Message -match 'nested|union|composite') { return }
        throw
    }
    if ($rows.Count -ne 3) { throw "Right branch changed after composition; returned $($rows.Count) instead of 3 without explicit rejection." }
}
Check-Followup 'Imported legacy index with quoted doc must preserve its unrelated UNIQUE' {
    param($db)
    # This fixture requires an external/custom SQLite index definition. It is
    # not the unquoted definition emitted by the usual historical helper.
    $p1 = 'a.a_a_a_a_a_a_a_a.a.a.a.a.a_a.a_a_a.a'
    $p2 = 'a_a.a.a.a_a.a_a.a.a.a_a_a.a.a.a_a.a_a'
    $clean = $p1.Replace('.', '_')
    $oldName = "idx_users__${clean}_43CEB4E2"
    [void]$db.collection('users').create()
    [void]$db.query("CREATE UNIQUE INDEX ""$oldName"" ON users(json_extract(""doc"",'`$.$p1'));")
    [void]$db.collection('users').createIndex($p2, @{ unique = $true })
    [void]$db.collection('users').dropIndex($p2)
    $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
    if ($indexes.Count -ne 1 -or $indexes[0].name -cne $oldName) { throw "Expected original imported index; remaining=$($indexes.Count)." }
    $insert = 'INSERT INTO users(key,doc) VALUES(?,json_set(''{}'',?,?,?,?));'
    [void]$db.query($insert, @('u1', "`$.$p1", 'same', "`$.$p2", 'one'))
    $blocked = $false
    try { [void]$db.query($insert, @('u2', "`$.$p1", 'same', "`$.$p2", 'two')) }
    catch [System.InvalidOperationException] { $blocked = $true }
    if (-not $blocked) { throw 'Imported first-path UNIQUE no longer enforced.' }
}
Write-Host "Followup a526708: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
