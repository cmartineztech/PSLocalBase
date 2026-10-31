# Regression checks for the 2.0.0 hardening release. Each check fails on 1.0.x (03ccf2f).
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0; $script:failed = 0
function Check([string]$Name, [scriptblock]$Body) {
    $db = New-LocalBase
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
    finally { $db.close() }
}
function Assert-Throws([scriptblock]$Body, [string]$Because) {
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw "Expected an exception: $Because" }
}
function New-TempPath([string]$Name) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("pslb-h2-" + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($dir)
    return (Join-Path $dir $Name)
}
function Remove-TempPath([string]$Path) {
    $dir = Split-Path $Path -Parent
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Data-loss risks -------------------------------------------------------
Check 'H1 filtered set(array) is rejected and keeps every document' {
    param($db)
    foreach ($n in 1..3) { $db.collection('c').doc("k$n").set(@{ n = $n }) }
    foreach ($query in @($db.collection('c').where('n', '=', 1), $db.collection('c').orderBy('n'), $db.collection('c').limit(1), $db.collection('c').skip(1))) {
        Assert-Throws { $query.set(@(@{ id = 'z'; n = 9 })) } 'bulk set on a filtered/paginated query'
        Assert-Throws { $query.replaceAll(@(@{ id = 'z'; n = 9 })) } 'replaceAll on a filtered/paginated query'
    }
    if ($db.collection('c').count() -ne 3) { throw 'Rejected bulk write still deleted documents' }
    $db.collection('c').replaceAll(@(@{ id = 'a'; n = 1 }, @{ id = 'b'; n = 2 }))
    if (($db.collection('c').orderBy('n').get().n -join ',') -ne '1,2') { throw 'replaceAll on the unfiltered collection failed' }
    $db.collection('c').set(@(@{ id = 'only'; n = 5 }))
    if ($db.collection('c').count() -ne 1) { throw 'Unfiltered set(array) alias changed' }
    Assert-Throws { $db.collection('c').doc('only').replaceAll(@(@{ n = 1 })) } 'replaceAll after doc()'
}

Check 'H2 writes leave the query they were called on unchanged' {
    param($db)
    foreach ($n in 1..4) { $db.collection('c').doc("k$n").set(@{ n = $n }) }
    $doc = $db.collection('c').doc('k1')
    $doc.set(@{ n = 10 })
    $after = $doc.get()
    if ($after -is [System.Array] -or $after.n -ne 10) { throw 'doc().set() reset the target key' }
    $doc.update(@{ extra = 1 })
    if ($doc.get().extra -ne 1) { throw 'doc().update() reset the target key' }
    $q = $db.collection('c').where('n', '<=', 3)
    [void]$q.add(@{ n = 99 })
    [void]$q.upsert(@{ id = 'u1'; n = 100 })
    if ($q.count() -ne 2) { throw "add()/upsert() cleared the filter: count=$($q.count())" }
    $doc.delete()
    if ($db.collection('c').count() -ne 5) { throw 'delete() after set() removed more than its document' }
    $c = $db.collection('dropme')
    [void]$c.add(@{ v = 1 })
    $c.drop()
    [void]$c.add(@{ v = 2 })
    if ($c.count() -ne 1) { throw 'Collection reference unusable after drop()' }
}

Check 'H3 collectionGroup cannot be combined with union' {
    param($db)
    $db.collection('logs_1').doc('a').set(@{ n = 1 })
    $db.collection('north').doc('b').set(@{ n = 2 })
    $group = $db.collectionGroup('logs_*')
    $plain = $db.collection('north')
    Assert-Throws { $group.union($plain) } 'group.union'
    Assert-Throws { $plain.union($group) } 'plain.union(group)'
    Assert-Throws { $group.unionAll($plain) } 'group.unionAll'
    Assert-Throws { $plain.unionAll($group) } 'plain.unionAll(group)'
}

# --- Query semantics -------------------------------------------------------
Check 'M1 in/not-in treat null list members as IS NULL' {
    param($db)
    $db.collection('c').doc('a').set(@{ s = 'admin' })
    $db.collection('c').doc('b').set(@{ s = 'user' })
    $db.collection('c').doc('c').set(@{ s = $null })
    $db.collection('c').doc('d').set(@{ other = 1 })
    $keys = { param($q) (@($q.get(@{ keys = $true })).key | Sort-Object) -join ',' }
    if ((& $keys $db.collection('c').where('s', 'not-in', @('user', $null))) -ne 'a') { throw 'not-in with null dropped every row' }
    if ((& $keys $db.collection('c').where('s', 'not-in', @($null))) -ne 'a,b') { throw 'not-in @($null) must keep only non-null values' }
    if ((& $keys $db.collection('c').where('s', 'in', @($null))) -ne 'c,d') { throw 'in @($null) must match null and missing values' }
    if ((& $keys $db.collection('c').where('s', 'in', @('admin', $null))) -ne 'a,c,d') { throw 'in with null must combine both matches' }
    if ((& $keys $db.collection('c').where('s', 'not-in', @('user'))) -ne 'a') { throw 'not-in without null changed' }
    if ((& $keys $db.collection('c').where('s', 'not-in', @())) -ne 'a,b') { throw 'empty not-in must keep only present values' }
    if ((& $keys $db.collection('c').where('s', 'in', @())) -ne '') { throw 'empty in must match nothing' }
}

Check 'M2 aggregates use JSON numbers only and keep value types' {
    param($db)
    $values = @(5, 100, '10', 'abc', $true, 2.5)
    for ($i = 0; $i -lt $values.Count; $i++) { $db.collection('c').doc("k$i").set(@{ v = $values[$i] }) }
    $avg = $db.collection('c').avg('v')
    if ([Math]::Abs($avg - (107.5 / 3)) -gt 1e-9) { throw "avg used non-numeric values: $avg" }
    if ($db.collection('c').sum('v') -ne 107.5) { throw 'sum used non-numeric values' }
    $max = $db.collection('c').max('v')
    if ($max -ne 100 -or $max -isnot [long]) { throw "max returned $max [$($max.GetType().Name)]" }
    $min = $db.collection('c').min('v')
    if ($min -ne 2.5 -or $min -isnot [double]) { throw "min returned $min" }
    $db.collection('t').doc('a').set(@{ v = '007' })
    $db.collection('t').doc('b').set(@{ v = '1,000' })
    $textMin = $db.collection('t').min('v')
    if ($textMin -isnot [string] -or $textMin -cne '007') { throw "text min converted to $textMin" }
    $distinct = @($db.collection('c').where('v', 'type', 'integer').distinct('v'))
    if ($distinct.Count -ne 2 -or $distinct[0] -isnot [long]) { throw 'distinct() returned strings for numbers' }
}

Check 'M3 dates are stored as ISO-8601 UTC and filter correctly in both editions' {
    param($db)
    $when = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
    $db.collection('c').doc('a').set(@{ d = $when; wrapped = (Get-Date -Date $when) })
    $db.collection('c').doc('b').set(@{ d = $when.AddYears(-10) })
    $raw = $db.query("SELECT doc FROM c WHERE key = 'a';")[0].doc
    if ($raw -notmatch '"d":"2026-01-02T03:04:05\.0000000Z"' -or $raw -notmatch '"wrapped":"2026-01-02T03:04:05\.0000000Z"') { throw "Unexpected date encoding: $raw" }
    if (@($db.collection('c').where('d', '>=', [datetime]'2030-01-01').get()).Count -ne 0) { throw 'Future date filter matched' }
    if (@($db.collection('c').where('d', '>=', $when.AddDays(-1)).get()).Count -ne 1) { throw 'Date range filter missed' }
    if (@($db.collection('c').where('d', 'in', @($when)).get()).Count -ne 1) { throw 'Date in-list did not match' }
    if (@($db.query('SELECT key FROM c WHERE json_extract(doc, ''$.d'') = ?;', @($when))).Count -ne 1) { throw 'Bound date parameter not normalized' }
    $db.collection('c').doc('o').set(@{ iso = '2026-01-01T10:00:00.1234567+02:00' })
    $db.collection('c').doc('o').update(@{ other = 2 })
    if ($db.collection('c').doc('o').get().iso -cne '2026-01-01T10:00:00.1234567+02:00') { throw 'update() rewrote an untouched date string' }
}

Check 'M4 beginTransaction takes the write lock immediately' {
    param($db)
    $path = New-TempPath 'tx.db'
    $first = $null; $second = $null
    try {
        $first = New-LocalBase -Path $path -Options @{ busyTimeout = 100 }
        $second = New-LocalBase -Path $path -Options @{ busyTimeout = 100 }
        $first.collection('c').doc('a').set(@{ n = 1 })
        $first.beginTransaction()
        Assert-Throws { $second.beginTransaction() } 'second writer must be blocked while the first holds an immediate transaction'
        $first.rollback()
        $second.beginTransaction('deferred')
        $second.rollback()
        Assert-Throws { $first.beginTransaction('bogus') } 'unknown transaction mode'
    } finally {
        if ($first) { $first.close() }
        if ($second) { $second.close() }
        Remove-TempPath $path
    }
}

Check 'M5 query helpers reject or honour previously ignored input' {
    param($db)
    $db.collection('c').doc('a').set(@{ tags = @(1, 2); flag = $true; ref = 'x'; n = [uint64]2 })
    $db.collection('c').doc('b').set(@{ tags = @(1); flag = 'yes' })
    Assert-Throws { $db.collection('c').whereLength('tags', 'bogus', 2) } 'unknown whereLength operator'
    if (@($db.collection('c').whereLength('tags', '==', 2).get()).Count -ne 1) { throw 'whereLength == failed' }
    if ($null -ne $db.collection('c').limit(0).first()) { throw 'first() ignored limit(0)' }
    if ($db.collection('c').skip(5).exists()) { throw 'exists() ignored skip()' }
    if ($db.collection('c').doc('a').limit(0).exists()) { throw 'exists() ignored limit(0) on a key lookup' }
    if (@($db.collection('c').whereType('flag', 'boolean').get()).Count -ne 1) { throw 'whereType boolean failed' }
    if (@($db.collection('c').whereType('flag', 'true').get()).Count -ne 1) { throw 'whereType true failed' }
    $populated = $db.collection('c').doc('a').populate('ref', 'missing_collection', 'refDoc').get()
    if ($null -eq $populated -or $null -ne $populated.refDoc) { throw 'populate() on a missing collection must resolve to null' }
    Assert-Throws { $db.collection('c').doc(@{ email = 'a@b' }) } 'criteria without key/id/_key'
    if (@($db.collection('c').where('n', '=', [uint64]2).get()).Count -ne 1) { throw 'uint64 parameter bound as text' }
}

Check 'M7 a single filter value of 0 or $false is still bound' {
    param($db)
    $db.collection('c').doc('zero').set(@{ n = 0; s = '0' })
    $db.collection('c').doc('one').set(@{ n = 1; s = '1' })
    $db.collection('logs_1').doc('zero').set(@{ n = 0 })
    foreach ($q in @($db.collection('c').where('n', '=', 0), $db.collection('c').where('n', 'in', @(0)), $db.collection('c').where('s', '=', '0'))) {
        if (@($q.get()).Count -ne 1 -or $q.count() -ne 1 -or -not $q.exists()) { throw 'Filter value 0 lost its parameter' }
        if ($q.sum('n') -ne 0 -or @($q.distinct('n')).Count -ne 1) { throw 'Aggregate with filter value 0 failed' }
    }
    if (@($db.collectionGroup('logs_*').where('n', '=', 0).get()).Count -ne 1) { throw 'collectionGroup filter value 0 failed' }
}

Check 'M6 collectionGroup resolves tables at query time and exposes _collection to filters' {
    param($db)
    $db.collection('logs_1').doc('a').set(@{ n = 1 })
    $db.collection('logs_2').doc('b').set(@{ n = 2 })
    $group = $db.collectionGroup('logs_*')
    $db.collection('logs_2').drop()
    $db.collection('logs_3').doc('c').set(@{ n = 3 })
    $keys = (@($group.get(@{ keys = $true })).key | Sort-Object) -join ','
    if ($keys -ne 'a,c' -or $group.count() -ne 2) { throw "Stale group tables: $keys" }
    if (@($group.where('_collection', '=', 'logs_3').get()).Count -ne 1) { throw '_collection filter never matched' }
    if (-not $group.where('_collection', '=', 'logs_1').exists()) { throw 'exists() disagrees with get() for _collection' }
}

# --- Security and robustness -----------------------------------------------
Check 'S1 children of a closed connection never reach a reused handle' {
    param($db)
    $root = New-LocalBase
    $stale = $root.collection('c')
    $root.close()
    Assert-Throws { $root.Init(':memory:', @{}) } 'reopening a closed instance'
    $others = @(for ($i = 0; $i -lt 10; $i++) { New-LocalBase })
    try {
        Assert-Throws { [void]$stale.add(@{ v = 'from-stale-child' }) } 'stale child write'
        foreach ($other in $others) {
            if ($other.collectionExists('c')) { throw 'Stale child wrote into an unrelated connection' }
        }
    } finally { foreach ($other in $others) { $other.close() } }
}

Check 'S2 untrusted schema names and stored code are contained' {
    param($db)
    [void]$db.query('CREATE TABLE "a]b" (key TEXT, doc TEXT);')
    [void]$db.query('CREATE TABLE "users]);" (x TEXT);')
    [void]$db.query('CREATE TABLE users (key TEXT PRIMARY KEY, doc TEXT);')
    $names = @($db.getCollections())
    if ($names -contains 'a]b' -or $names -contains 'users]);' -or -not ($names -contains 'users')) { throw "Unexpected collections: $($names -join ',')" }
    [void]$db.query("CREATE TRIGGER t AFTER INSERT ON users BEGIN SELECT pslocalbase_like(NEW.doc, '*'); END;")
    Assert-Throws { [void]$db.collection('users').add(@{ v = 1 }) } 'stored trigger invoking the native matcher'
    Assert-Throws { [void]$db.collection("evil`n") } 'collection name with trailing newline'
    if ($db.collectionExists("evil`n")) { throw 'Newline-suffixed table was created' }
}

Check 'S3 oversized or deeply nested documents fail without leaking content' {
    param($db)
    $deep = ('{"a":' * 150) + '"apiKey-SECRET"' + ('}' * 150)
    [void]$db.query('CREATE TABLE c (key TEXT PRIMARY KEY, doc TEXT NOT NULL CHECK (json_valid(doc)));')
    [void]$db.query('INSERT INTO c (key, doc) VALUES (?, ?);', @('deep', $deep))
    $db.collection('c').doc('ok').set(@{ v = 1 })
    $message = ''
    try { [void]$db.collection('c').get() } catch { $message = $_.Exception.Message }
    if ($message -notmatch 'deep' -or $message -match 'SECRET') { throw "Unexpected error: $message" }
    if ($db.collection('c').doc('ok').get().v -ne 1) { throw 'A healthy document became unreadable' }
    $small = New-LocalBase -Path ':memory:' -Options @{ maxDocumentBytes = 64 }
    try {
        $small.collection('c').doc('big').set(@{ v = ('x' * 200) })
        Assert-Throws { [void]$small.collection('c').doc('big').get() } 'maxDocumentBytes'
    } finally { $small.close() }
    $caseSensitive = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $caseSensitive['a'] = 1
    $caseSensitive['A'] = 2
    Assert-Throws { $db.collection('c').doc('dup').set($caseSensitive) } 'case-duplicated property names'
    if ($db.collection('c').doc('dup').exists()) { throw 'Unreadable document was written' }
    Assert-Throws { $db.collection('c').doc('empty').set(@{ '' = 1 }) } 'empty property name'
}

Check 'S4 query() runs one statement and errors hide SQL unless debugging' {
    param($db)
    $db.collection('c').doc('a').set(@{ v = 1 })
    Assert-Throws { [void]$db.query('SELECT 1; DROP TABLE c;') } 'second statement'
    if (-not $db.collectionExists('c')) { throw 'Trailing statement executed' }
    if (@($db.query('SELECT 1 AS one; -- trailing comment')).Count -ne 1) { throw 'Trailing comment rejected' }
    $message = ''
    try { [void]$db.query("SELECT 'S3cr3t!' FROM missing_table;") } catch { $message = $_.Exception.Message }
    if ($message -match 'S3cr3t') { throw 'SQL literal leaked into the error message' }
    $db.config['debug'] = $true
    try {
        $message = ''
        try { [void]$db.query("SELECT 'visible' FROM missing_table;") } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'visible') { throw 'Debug mode should include the SQL text' }
    } finally { $db.config['debug'] = $false }
}

Check 'S5 deleteDatabase uses the real database path and removes the journal' {
    param($db)
    $path = New-TempPath 'del.db'
    $victim = Join-Path (Split-Path $path -Parent) 'victim.txt'
    try {
        Set-Content -Path $victim -Value 'keep'
        $file = New-LocalBase -Path $path -Options @{ wal = 'false' }
        if ($file.JournalMode -ne 'delete') { throw "wal='false' kept journal mode $($file.JournalMode)" }
        $file.collection('c').doc('a').set(@{ v = 1 })
        Set-Content -Path "$path-journal" -Value 'stale'
        $file.FilePath = $victim
        $file.deleteDatabase()
        if (-not (Test-Path $victim)) { throw 'deleteDatabase followed a modified FilePath' }
        if ((Test-Path $path) -or (Test-Path "$path-journal")) { throw 'Database or journal file left behind' }
    } finally { Remove-TempPath $path }
}

Check 'S6 reads never create tables and options are validated strictly' {
    param($db)
    [void]$db.collection('ghost').doc('k').get()
    [void]$db.collection('ghost').doc('k').exists()
    if ($db.collectionExists('ghost')) { throw 'A read created a table' }
    Assert-Throws { New-LocalBase -Path ':memory:' -Options @{ depth = 150 } } 'depth above 100'
    Assert-Throws { New-LocalBase -Path ':memory:' -Options @{ wal = 'maybe' } } 'non-boolean wal'
    $strict = New-LocalBase -Path ':memory:' -Options @{ debug = 'no' }
    try { if ($strict.config['debug'] -ne $false) { throw 'debug string not converted' } } finally { $strict.close() }
}

Check 'S7 module import leaves no helper variables in the session' {
    param($db)
    foreach ($name in @('csharpCode', 'isWin')) {
        if (Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue) { throw "Variable `$$name leaked into the global scope" }
    }
}

Write-Host "Hardening v2: passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
