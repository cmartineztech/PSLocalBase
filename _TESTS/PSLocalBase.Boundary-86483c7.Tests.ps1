# Independent finite numeric boundary checks for commit 86483c7.
# In-memory databases only; existing engine and suites remain unchanged.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0
$script:failed = 0
function Check-Boundary([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
Check-Boundary 'Control - nonzero tiny Double is not Decimal zero' {
    param($db)
    foreach ($value in @([double]::Epsilon, [double]1e-35, [double]-1e-35, [double]1e-29)) {
        if ([PSLocalBase]::_JsonValuesEqual($value, [decimal]0) -or [PSLocalBase]::_JsonValuesEqual([decimal]0, $value)) { throw 'Nonzero value equals zero.' }
    }
    if (-not [PSLocalBase]::_JsonValuesEqual([double]0, [decimal]0)) { throw 'Exact zero equality failed.' }
}
foreach ($operation in @('remove', 'union')) {
    Check-Boundary "Nonzero Decimal quantization must preserve distinct values: $operation" {
        param($db)
        $small = [double]::Parse('6e-29', [Globalization.CultureInfo]::InvariantCulture)
        $different = [decimal]::Parse('1e-28', [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
        $db.collection('numbers').doc('one').set(@{ values = @($small) })
        $before = @($db.collection('numbers').doc('one').get().values)
        if ($before.Count -ne 1 -or [double]$before[0] -ne $small) { throw 'Fixture did not preserve the original Double before mutation.' }
        $mutation = if ($operation -eq 'remove') { [PSLocalBase]::ArrayRemove($different) } else { [PSLocalBase]::ArrayUnion($different) }
        $db.collection('numbers').doc('one').update(@{ values = $mutation })
        $actual = @($db.collection('numbers').doc('one').get().values)
        $expectedCount = if ($operation -eq 'remove') { 1 } else { 2 }
        if ($actual.Count -ne $expectedCount) { throw "Expected $expectedCount distinct members; actual=$($actual.Count)." }
        if ([double]$actual[0] -ne $small) { throw 'Original member was changed.' }
        if ($operation -eq 'union' -and -not [PSLocalBase]::_JsonValuesEqual($actual[1], $different)) { throw 'New distinct member was not preserved.' }
    }
}
Write-Host "Boundary 86483c7: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
