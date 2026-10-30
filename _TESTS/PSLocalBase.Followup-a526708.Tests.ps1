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
Check-Followup 'Right branch reuse preserves original union snapshot and true nested-union is rejected' {
    param($db)
    # Contract: Each union forms an independent immutable snapshot query.
    # Reusing a branch source ($right) in a subsequent union does NOT mutate or invalidate prior unions.
    $db.collection('a').doc('a').set(@{ n = 1 })
    $db.collection('b').doc('b').set(@{ n = 2 })
    $db.collection('c').doc('c').set(@{ n = 3 })
    $right = $db.collection('b')
    $query1 = $db.collection('a').union($right)
    $query2 = $right.union($db.collection('c'))

    # Both independent composite queries must return their respective 2 rows
    $rows1 = @($query1.get())
    $rows2 = @($query2.get())
    if ($rows1.Count -ne 2) { throw "First union snapshot corrupted: expected 2 rows, got $($rows1.Count)." }
    if ($rows2.Count -ne 2) { throw "Second union corrupted: expected 2 rows, got $($rows2.Count)." }

    # True nested union (calling union on an already composite query or passing a composite query) must be explicitly rejected
    $rejected1 = $false
    try { [void]$query1.union($db.collection('c')) }
    catch [System.InvalidOperationException] { $rejected1 = $true }
    if (-not $rejected1) { throw "Nested union on composite left branch must throw InvalidOperationException." }

    $rejected2 = $false
    try { [void]$db.collection('c').union($query1) }
    catch [System.InvalidOperationException] { $rejected2 = $true }
    if (-not $rejected2) { throw "Nested union passing composite right branch must throw InvalidOperationException." }
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
Check-Followup 'H01 - Subnormal floats must not equal Decimal zero' {
    param($db)
    if ([PSLocalBase]::_JsonValuesEqual([double]1e-35, [decimal]0)) { throw '1e-35 must not equal decimal 0' }
    if ([PSLocalBase]::_JsonValuesEqual([double]::Epsilon, [decimal]0)) { throw 'Epsilon must not equal decimal 0' }
    if ([PSLocalBase]::_JsonValuesEqual([double]-1e-35, [decimal]0)) { throw '-1e-35 must not equal decimal 0' }
    if (-not [PSLocalBase]::_JsonValuesEqual([double]0.0, [decimal]0)) { throw '0.0 must equal decimal 0' }
}
Check-Followup 'H02 - Deserialized JSON PSCustomObject array operations' {
    param($db)
    $col = $db.collection('h02_ops')
    $col.doc('d1').set(@{ tags = @('a', 'b') })
    $jsonU = '{"tags": {"$arrayUnion": ["c", "a"]}}'
    $col.doc('d1').update((ConvertFrom-Json $jsonU))
    $resU = $col.doc('d1').get()
    if (($resU.tags -join ',') -ne 'a,b,c') { throw "Expected a,b,c after PSCustomObject arrayUnion; got: $($resU.tags -join ',')" }
    $jsonR = '{"tags": {"$arrayRemove": ["b"]}}'
    $col.doc('d1').update((ConvertFrom-Json $jsonR))
    $resR = $col.doc('d1').get()
    if (($resR.tags -join ',') -ne 'a,c') { throw "Expected a,c after PSCustomObject arrayRemove; got: $($resR.tags -join ',')" }
}
Check-Followup 'H04 - collectionGroup drop must reject with InvalidOperationException' {
    param($db)
    $col = $db.collection('cg_drop_target')
    $col.add(@{ val = 42 })
    $cg = $db.collectionGroup('cg_drop_target')
    $threw = $false
    try {
        $cg.drop()
    } catch [System.InvalidOperationException] {
        if ($_.Exception.Message -match 'composite|collectionGroup|read-only') { $threw = $true }
    }
    if (-not $threw) { throw 'collectionGroup.drop() must throw InvalidOperationException' }
    if ($col.count() -ne 1) { throw 'collectionGroup.drop() must not have dropped the underlying collection' }
}
Write-Host "Followup a526708: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
