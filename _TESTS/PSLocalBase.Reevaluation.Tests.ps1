# Independent reevaluation probes. Run in a fresh PowerShell process.
# Only in-memory databases are used. Failing assertions are unresolved findings.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passes = 0
$script:failures = 0

function Test-Independent([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try {
        & $Body $db
        $script:passes++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failures++
        Write-Host "[FAIL] ${Name}: $($_.Exception.Message)"
    } finally { $db.close() }
}

Test-Independent 'R01a - composite point delete must preserve untargeted documents' {
    param($db)
    $db.collection('a').doc('a1').set(@{ n = 1 })
    $db.collection('a').doc('a2').set(@{ n = 2 })
    $db.collection('b').doc('b1').set(@{ n = 3 })
    try { $db.collection('a').doc('a1').union($db.collection('b')).delete() } catch [System.InvalidOperationException] { }
    if (-not $db.collectionExists('a') -or -not $db.collection('a').doc('a2').exists()) {
        throw 'Collection a / unrelated document a2 was lost.'
    }
}

Test-Independent 'R01b - composite point set must not become a bulk replacement' {
    param($db)
    $db.collection('a').doc('a1').set(@{ n = 1 })
    $db.collection('a').doc('a2').set(@{ n = 2 })
    [void]$db.collection('b').create()
    try { $db.collection('a').doc('a1').union($db.collection('b')).set(@(@{ n = 9 })) } catch [System.InvalidOperationException] { }
    if (-not $db.collection('a').doc('a2').exists()) {
        throw 'Unrelated document a2 was lost through bulk replacement.'
    }
}

Test-Independent 'R02 - dropping profile.code must retain UNIQUE profile_code' {
    param($db)
    [void]$db.collection('users').createIndex('profile.code')
    [void]$db.collection('users').createIndex('profile_code', @{ unique = $true })
    [void]$db.collection('users').add(@{ profile_code = 'same' }, 'u1')
    [void]$db.collection('USERS').dropIndex('profile.code')
    $rejected = $false
    try { [void]$db.collection('users').add(@{ profile_code = 'same' }, 'u2') } catch [System.InvalidOperationException] { $rejected = $true }
    if (-not $rejected) { throw 'Dropping a different field removed the UNIQUE constraint; duplicate accepted.' }
}

Test-Independent 'R03 - a stored index name must never execute additional SQL' {
    param($db)
    [void]$db.collection('users').create()
    $db.collection('victim').doc('v1').set(@{ value = 'keep' })
    # Simulates schema supplied by another SQLite producer. The attack is the
    # subsequent innocent dropIndex call, not this deliberate fixture creation.
    [void]$db.query('CREATE INDEX "idx_users__email_probe]; DROP TABLE victim; --" ON users (key);')
    try { [void]$db.collection('users').dropIndex('email') } catch [System.InvalidOperationException] { }
    if (-not $db.collectionExists('victim')) { throw 'Stored schema name executed DROP TABLE victim.' }
}

Test-Independent 'R04a - mixed Int64/double equality must not erase a distinct integer' {
    param($db)
    $db.collection('items').doc('one').set(@{ ids = @([long]9007199254740993) })
    $db.collection('items').doc('one').update(@{ ids = [PSLocalBase]::ArrayRemove([double]9007199254740992) })
    $actual = @($db.collection('items').doc('one').get().ids)
    if ($actual.Count -ne 1 -or $actual[0] -ne [long]9007199254740993) {
        throw "Distinct integer removed; remaining=[$($actual -join ',')]"
    }
}

Test-Independent 'R04b - unsigned 64-bit array union must preserve exact idempotence' {
    param($db)
    $value = [uint64]::MaxValue
    $db.collection('items').doc('one').set(@{ ids = @($value) })
    $db.collection('items').doc('one').update(@{ ids = [PSLocalBase]::ArrayUnion($value) })
    $actual = @($db.collection('items').doc('one').get().ids)
    if ($actual.Count -ne 1) { throw "UInt64 union duplicated its member: count=$($actual.Count); value=$($actual -join ',')" }
}

Test-Independent 'R05 - upgrading UNIQUE through different casing must replace old index' {
    param($db)
    [void]$db.collection('users').createIndex('email')
    [void]$db.collection('USERS').createIndex('email', @{ unique = $true })
    [void]$db.collection('users').createIndex('email', @{ unique = $false })
    [void]$db.collection('users').add(@{ email = 'same' }, 'a')
    [void]$db.collection('users').add(@{ email = 'same' }, 'b')
}

Test-Independent 'R06 - projection must preserve JSON boolean values' {
    param($db)
    $db.collection('users').doc('one').set(@{ enabled = $true; disabled = $false })
    $actual = $db.collection('users').doc('one').select('enabled', 'disabled').get()
    if ($actual.enabled -isnot [bool] -or $actual.disabled -isnot [bool]) {
        throw "Projection converted booleans to $($actual.enabled.GetType().Name)/$($actual.disabled.GetType().Name)."
    }
}

Test-Independent 'R07 - collectionGroup doc must scope reads or reject before creating schema' {
    param($db)
    $db.collection('audit_a').doc('wanted').set(@{ value = 1 })
    $db.collection('audit_a').doc('other').set(@{ value = 2 })
    $db.collection('audit_b').doc('wanted').set(@{ value = 3 })
    $rejected = $false
    $actual = @()
    try { $actual = @($db.collectionGroup('audit_*').doc('wanted').get(@{ keys = $true })) }
    catch [System.InvalidOperationException] { $rejected = $true }
    if ($db.collectionExists('audit_*')) { throw "Created literal wildcard table audit_*; point read returned $($actual.Count) rows, keys=[$($actual.key -join ',')]." }
    if (-not $rejected -and ($actual.Count -ne 2 -or @($actual | Where-Object { $_.key -cne 'wanted' }).Count -ne 0)) {
        throw "Point-scoped group returned $($actual.Count) rows instead of 2."
    }
}

Test-Independent 'R08 - point-scoped aggregation must honor key or reject unsupported scope' {
    param($db)
    $db.collection('items').doc('one').set(@{ amount = 10 })
    $db.collection('items').doc('two').set(@{ amount = 20 })
    try { $actual = $db.collection('items').doc('one').sum('amount') }
    catch [System.InvalidOperationException] { return }
    if ($actual -ne 10) { throw "Point-scoped sum returned $actual instead of 10." }
}

Test-Independent 'C07 - SQL aliasing in populate must preserve a field named doc' {
    param($db)
    $db.collection('users').doc('u1').set(@{ name = 'Alice' })
    $db.collection('posts').doc('p1').set(@{ user = 'u1'; doc = @{ status = 'ready' } })
    $actual = @($db.collection('posts').where('doc.status', '=', 'ready').populate('user', 'users').get())
    if ($actual.Count -ne 1) { throw "Expected 1 populated row, got $($actual.Count)." }
}

Test-Independent 'C01 - rejected ordered delete preserves documents and indexes' {
    param($db)
    [void]$db.collection('users').createIndex('name', @{ unique = $true })
    $db.collection('users').doc('u1').set(@{ name = 'Alice' })
    $before = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users' ORDER BY name;").name -join ','
    $rejected = $false
    try { $db.collection('users').where('name', '=', 'Alice').orderBy('name').delete() } catch [System.InvalidOperationException] { $rejected = $true }
    $after = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users' ORDER BY name;").name -join ','
    if (-not $rejected -or $before -cne $after -or $db.collection('users').count() -ne 1) { throw 'Ordered deletion changed storage or was accepted.' }
}

Test-Independent 'C02 - explicit identities, GUIDs, NUL validation and failed upserts' {
    param($db)
    $keys = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; $i -lt 100; $i++) {
        $key = $db.collection('users').upsert(@{ role = 'reader'; n = $i })
        if ($key -notmatch '^[0-9a-f]{32}$' -or -not $keys.Add($key)) { throw 'Invalid or repeated generated identity.' }
    }
    foreach ($field in @('id', 'key', '_key')) {
        $payload = @{ name = 'Alice' }; $payload[$field] = $field
        if ($db.collection('users').upsert($payload) -cne $field) { throw 'Explicit identity was not respected.' }
    }
    $rejected = $false
    try { [void]$db.collection('users').upsert(@{ id = "key`0evil" }) } catch [System.ArgumentException] { $rejected = $true }
    if (-not $rejected -or $db.collection('users').count() -ne 103) { throw 'NUL identity modified storage.' }
}

Test-Independent 'C03 - missing composite branches across union and unionAll' {
    param($db)
    $db.collection('present').doc('k').set(@{ value = 'safe' })
    foreach ($method in @('union', 'unionAll')) {
        foreach ($terminal in @('get', 'count', 'exists', 'first')) {
            $left = $db.collection('present').where('value', '=', 'safe')
            $right = $db.collection('missing').where('value', '=', 'absent')
            $query = $left.$method($right)
            $actual = $query.$terminal()
            if ($null -eq $actual -or ($terminal -eq 'count' -and $actual -ne 1) -or ($terminal -eq 'exists' -and -not $actual)) { throw "Bad result from $method/$terminal" }
        }
    }
}

Test-Independent 'C04 - array-contains-any deletion retains all non-array field types' {
    param($db)
    $db.collection('items').doc('array').set(@{ tags = @('admin') })
    $db.collection('items').doc('scalar').set(@{ tags = 'admin' })
    $db.collection('items').doc('object').set(@{ tags = @{ x = 'admin' } })
    $db.collection('items').doc('null').set(@{ tags = $null })
    $db.collection('items').doc('missing').set(@{ name = 'missing' })
    $db.collection('items').where('tags', 'array-contains-any', @('admin')).delete()
    $keys = @($db.collection('items').get(@{ keys = $true }).key)
    if ($keys.Count -ne 4 -or $keys -contains 'array') { throw "Incorrect survivors: $($keys -join ',')" }
}

Test-Independent 'C05 - SQL and identifier injection corpus cannot destroy data' {
    param($db)
    $db.collection('safe').doc('one').set(@{ value = 'safe' })
    $payloads = @("' OR 1=1 --", "x']; DROP TABLE safe; --", "value`0suffix")
    foreach ($payload in $payloads) {
        $db.collection('payloads').doc([Guid]::NewGuid().ToString('N')).set(@{ value = $payload })
        if ($db.collection('payloads').where('value', '=', $payload).count() -ne 1) { throw 'Literal did not round-trip.' }
        $rejected = $false
        try { [void]$db.collection($payload) } catch [System.ArgumentException] { $rejected = $true }
        if (-not $rejected) { throw 'Malicious collection name accepted.' }
        $rejected = $false
        try { [void]$db.collection('safe').where($payload, '=', 'x') } catch [System.ArgumentException] { $rejected = $true }
        if (-not $rejected) { throw 'Malicious JSON path accepted.' }
    }
    if ($db.collection('safe').count() -ne 1) { throw 'Protected document lost.' }
}

Test-Independent 'C06 - failed unique write preserves an outer transaction' {
    param($db)
    [void]$db.collection('users').createIndex('name', @{ unique = $true })
    $db.collection('users').doc('u1').set(@{ name = 'Alice' })
    $db.beginTransaction()
    $db.collection('users').doc('u2').set(@{ name = 'Bob' })
    $rejected = $false
    try { $db.collection('users').doc('u2').update(@{ name = 'Alice' }) } catch [System.InvalidOperationException] { $rejected = $true }
    if (-not $rejected -or -not $db.InTransaction -or $db.collection('users').doc('u2').get().name -cne 'Bob') { throw 'Failed update corrupted outer transaction.' }
    $db.rollback()
    if ($db.collection('users').count() -ne 1) { throw 'Outer rollback did not restore storage.' }
}

Write-Host "Independent probes: passed=$script:passes; failed=$script:failures"
if ($script:failures -gt 0) { exit 1 }
