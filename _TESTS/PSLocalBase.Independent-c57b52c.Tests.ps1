# Independent evidence for the review of commit c57b52c.
# Does not modify the engine or the existing test suites. In-memory databases only.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0
$script:failed = 0
function Check([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try {
        & $Body $db
        $script:passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failed++
        Write-Host "[FAIL] ${Name}: $($_.Exception.Message)"
    } finally { $db.close() }
}

Check 'A01 - removing 1.0 must preserve its distinct adjacent Double' {
    param($db)
    $next = [double]::Parse('1.0000000000000002', [Globalization.CultureInfo]::InvariantCulture)
    $db.collection('numbers').doc('n').set(@{ values = @([double]1.0, $next) })
    $before = $db.collection('numbers').doc('n').get()
    if (@($before.values).Count -ne 2 -or $before.values[0] -eq $before.values[1]) { throw 'Fixture did not preserve distinct doubles.' }
    $db.collection('numbers').doc('n').update(@{ values = [PSLocalBase]::ArrayRemove([double]1.0) })
    $after = @($db.collection('numbers').doc('n').get().values)
    # PS 5.1 may deserialize the fractional JSON number as Decimal. Normalize
    # the assertion to Double instead of invoking asymmetric PS -eq coercion.
    if ($after.Count -ne 1 -or [double]$after[0] -ne $next) { throw "Expected one adjacent Double; remaining count=$($after.Count)." }
}

Check 'A02 - equality of exactly equal Int64 and Double at 2^53' {
    param($db)
    $db.collection('numbers').doc('n').set(@{ values = @([long]9007199254740992) })
    $db.collection('numbers').doc('n').update(@{ values = [PSLocalBase]::ArrayRemove([double]9007199254740992) })
    $after = @($db.collection('numbers').doc('n').get().values)
    if ($after.Count -ne 0) { throw "Equal numeric member was retained: $($after -join ',')." }
}

Check 'A03 - literal dotted and underscore legacy fields must remain independent' {
    param($db)
    [void]$db.collection('users').create()
    [void]$db.query('CREATE UNIQUE INDEX idx_users_profile_code ON users(json_extract(doc, ''$.profile_code''));')
    $db.collection('users').doc('u1').set(@{ profile_code = 'unique'; profile = @{ code = 'x' } })
    [void]$db.collection('users').dropIndex('profile.code')
    $blocked = $false
    try { [void]$db.collection('users').add(@{ profile_code = 'unique' }, 'u2') } catch [System.InvalidOperationException] { $blocked = $true }
    if (-not $blocked) { throw 'An index for another JSON path was dropped; duplicate accepted.' }
}

Check 'A04 - numeric filter data must obey the documented debug privacy guarantee' {
    param($db)
    $db.collection('users').doc('u1').set(@{ pin = 735291 })
    $db.config['debug'] = $true
    try { $captured = & { [void]$db.collection('users').where('pin', '=', 735291).get() } 6>&1 }
    finally { $db.config['debug'] = $false }
    if (($captured | Out-String) -match '735291') { throw 'Numeric filter value appeared in diagnostic output.' }
}

Check 'A05 - unsupported composite insert must reject before schema changes' {
    param($db)
    $db.collection('audit_a').doc('a').set(@{ value = 1 })
    $rejected = $false
    try { [void]$db.collectionGroup('audit_*').add(@{ value = 2 }, 'new') } catch [System.InvalidOperationException] { $rejected = $true }
    if (-not $rejected -or $db.collectionExists('audit_*')) { throw "Rejected=$rejected; literal wildcard table exists=$($db.collectionExists('audit_*'))." }
}

Check 'C01 - matched unusual index name is dropped without interpreting its contents' {
    param($db)
    [void]$db.collection('users').create()
    $db.collection('victim').doc('v1').set(@{ value = 'keep' })
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes('users:email'))).Replace('-', '').Substring(0, 8) }
    finally { $hasher.Dispose() }
    # The suffix deliberately matches the current selector, unlike the old R03 fixture.
    $indexName = 'fixture"__email_probe]; DROP TABLE victim; --__email_' + $hash
    $quotedName = $indexName.Replace('"', '""')
    [void]$db.query("CREATE INDEX ""$quotedName"" ON users(key);")
    [void]$db.collection('users').dropIndex('email')
    $remaining = $db.query('SELECT name FROM sqlite_master WHERE type=''index'' AND name=?;', @($indexName))
    if ($remaining.Count -ne 0) { throw 'Fixture was not selected: identifier quoting was not exercised.' }
    if (-not $db.collectionExists('victim') -or $db.collection('victim').doc('v1').get().value -cne 'keep') { throw 'Schema identifier was interpreted as SQL.' }
}

Check 'C02 - rejected composite writes must actually throw and retain all source documents' {
    param($db)
    $db.collection('a').doc('one').set(@{ value = 1 })
    $db.collection('a').doc('two').set(@{ value = 2 })
    [void]$db.collection('b').create()
    foreach ($operation in @('set', 'delete')) {
        $rejected = $false
        $query = $db.collection('a').doc('one').union($db.collection('b'))
        try {
            if ($operation -eq 'set') { $query.set(@(@{ value = 3 })) } else { $query.delete() }
        } catch [System.InvalidOperationException] { $rejected = $true }
        if (-not $rejected -or $db.collection('a').count() -ne 2 -or $db.collection('a').doc('one').get().value -ne 1) { throw "$operation was not rejected before mutation." }
    }
}

Write-Host "Independent c57b52c checks: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
