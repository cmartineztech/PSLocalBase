# ===========================================================================
# PSLocalBase Automated Test Suite
# Validates TC-01 through TC-05 and full Localbase feature parity
# ===========================================================================

param(
    [switch]$VerboseOutput = $false
)

$ErrorActionPreference = "Stop"
$testDir = $PSScriptRoot
$modulePath = Join-Path (Split-Path $testDir -Parent) "PSLocalBase.psd1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running PSLocalBase Automated Test Suite" -ForegroundColor Cyan
Write-Host " Module: $modulePath" -ForegroundColor DarkGray
Write-Host " PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )

    try {
        & $TestBlock
        Write-Host " [PASS] $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host " [FAIL] $Name" -ForegroundColor Red
        Write-Host "        Error: $($_.Exception.Message)" -ForegroundColor DarkRed
        if ($script:VerboseOutput) {
            Write-Host "        $($_.ScriptStackTrace)" -ForegroundColor DarkRed
        }
        $script:failed++
    }
}

# ---------------------------------------------------------------------------
# TC-01: Zero Dependencies & Import
# ---------------------------------------------------------------------------
Assert-Test "TC-01: Zero Dependencies - Clean Module Import" {
    Import-Module $modulePath -Force
    if (-not ('PSLocalBase' -as [type])) {
        throw "Type [PSLocalBase] was not loaded."
    }
    if (-not ('WinSqlite3' -as [type])) {
        throw "Type [WinSqlite3] was not loaded."
    }
}

# ---------------------------------------------------------------------------
# TC-02: PSCustomObject Typing & Dot Syntax Access
# ---------------------------------------------------------------------------
Assert-Test "TC-02: PSCustomObject Typing & Nested Dot Syntax" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("users").doc("u-1").set(@{
            name    = "Carlos Martinez"
            role    = "Architect"
            profile = @{
                department = "Engineering"
                contact    = @{ email = "carlos@example.com" }
            }
            tags    = @("powershell", "sqlite", "nosql")
        })

        # Single document retrieval
        $user = $db.collection("users").doc("u-1").get()
        if ($null -eq $user) { throw "User document was not retrieved." }
        if ($user -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Retrieved object is not [PSCustomObject]. Actual type: $($user.GetType().FullName)"
        }
        if ($user.name -ne "Carlos Martinez") { throw "Incorrect property 'name': $($user.name)" }
        if ($user.profile.department -ne "Engineering") { throw "Nested property 'profile.department' mismatch" }
        if ($user.profile.contact.email -ne "carlos@example.com") { throw "Deeply nested property 'contact.email' mismatch" }

        # Collection-level retrieval
        $users = $db.collection("users").get()
        if ($users -isnot [array] -or $users.Length -ne 1) { throw "Collection get did not return array of 1 element" }
        if ($users[0] -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Array element is not [PSCustomObject]"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-03: Unicode, Tildes, Nested Quotes & Emojis
# ---------------------------------------------------------------------------
Assert-Test "TC-03: Unicode Integrity (Accents, Quotes, Emojis)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $testString = "München Übergrößen & Niña con 'comillas simples', `"dobles`", saltos `n y emojis: 🚀🔥👍🎉"
        $db.collection("unicode_test").doc("doc-utf").set(@{
            rawText = $testString
            spanish = "ÁÉÍÓÚáéíóúñÑ¿?¡!"
            japanese = "こんにちは世界"
        })

        $retrieved = $db.collection("unicode_test").doc("doc-utf").get()
        if ($null -eq $retrieved) { throw "Failed to retrieve unicode document" }
        if ($retrieved.rawText -cne $testString) {
            throw "Unicode string mismatch! Expected '$testString', but got '$($retrieved.rawText)'"
        }
        if ($retrieved.spanish -cne "ÁÉÍÓÚáéíóúñÑ¿?¡!") {
            throw "Spanish accents mismatch!"
        }
        if ($retrieved.japanese -cne "こんにちは世界") {
            throw "Japanese characters mismatch!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-04: Concurrency (WAL + Busy Handler)
# ---------------------------------------------------------------------------
Assert-Test "TC-04: Concurrency (WAL Mode & Busy Timeout)" {
    $tempDbPath = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_concurrency_$([Guid]::NewGuid().ToString('N')).db"
    try {
        # Initialize database
        $db1 = [PSLocalBase]::new($tempDbPath)
        $db1.collection("concurrent").doc("init").set(@{ ready = $true })

        # Open secondary connection to same file
        $db2 = [PSLocalBase]::new($tempDbPath)

        # Simultaneous reads and writes across both connections
        $db1.collection("concurrent").doc("key-db1").set(@{ writer = "db1"; counter = 100 })
        $docFromDb2 = $db2.collection("concurrent").doc("key-db1").get()
        if ($null -eq $docFromDb2 -or $docFromDb2.counter -ne 100) {
            throw "Connection 2 could not read Connection 1's commit"
        }

        $db2.collection("concurrent").doc("key-db2").set(@{ writer = "db2"; counter = 200 })
        $docFromDb1 = $db1.collection("concurrent").doc("key-db2").get()
        if ($null -eq $docFromDb1 -or $docFromDb1.counter -ne 200) {
            throw "Connection 1 could not read Connection 2's commit"
        }

        $db1.close()
        $db2.close()
    } finally {
        if (Test-Path $tempDbPath) { Remove-Item -Path $tempDbPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path "$tempDbPath-wal") { Remove-Item -Path "$tempDbPath-wal" -Force -ErrorAction SilentlyContinue }
        if (Test-Path "$tempDbPath-shm") { Remove-Item -Path "$tempDbPath-shm" -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# TC-05: Pointer Release & File Lock Release
# ---------------------------------------------------------------------------
Assert-Test "TC-05: Pointer Release (Lock released on disk upon close)" {
    $tempDbPath = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_locktest_$([Guid]::NewGuid().ToString('N')).db"
    $db = [PSLocalBase]::new($tempDbPath)
    $db.collection("locktest").doc("item1").set(@{ status = "active" })
    $readBack = $db.collection("locktest").doc("item1").get()
    if ($null -eq $readBack) { throw "Failed to read item1 before close." }

    # Close database handle
    $db.close()

    # Verify that file lock is released and file can be removed immediately
    Remove-Item -Path $tempDbPath -Force
    if (Test-Path $tempDbPath) {
        throw "Database file still exists after Remove-Item; file lock was not released."
    }

    # Clean up wal/shm if any
    if (Test-Path "$tempDbPath-wal") { Remove-Item -Path "$tempDbPath-wal" -Force -ErrorAction SilentlyContinue }
    if (Test-Path "$tempDbPath-shm") { Remove-Item -Path "$tempDbPath-shm" -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Core Operations: add() with generated GUID and custom key
# ---------------------------------------------------------------------------
Assert-Test "Core Operations: add() with Auto GUID and Custom Key" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $genKey = $db.collection("logs").add(@{ level = "INFO"; msg = "Auto key" })
        if ([string]::IsNullOrWhiteSpace($genKey)) { throw "add() did not return a generated key" }
        if ($genKey.Length -ne 32) { throw "Generated key length is unexpected: $genKey" }

        $customKey = $db.collection("logs").add(@{ level = "WARN"; msg = "Custom key" }, "custom-log-99")
        if ($customKey -ne "custom-log-99") { throw "add() did not return the custom key: $customKey" }

        $retrieved = $db.collection("logs").doc("custom-log-99").get()
        if ($null -eq $retrieved -or $retrieved.level -ne "WARN") { throw "Failed to retrieve doc with custom key" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Update Operations: update() Deep Merge
# ---------------------------------------------------------------------------
Assert-Test "Update Operations: update() Deep Recursive Merge" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("customers").doc("c1").set(@{
            name    = "Danny"
            age     = 30
            address = @{
                city    = "London"
                country = "UK"
            }
        })

        # Partial update
        $db.collection("customers").doc("c1").update(@{
            age     = 31
            address = @{
                city = "Manchester"
            }
        })

        $updated = $db.collection("customers").doc("c1").get()
        if ($updated.age -ne 31) { throw "Age was not updated to 31" }
        if ($updated.address.city -ne "Manchester") { throw "City was not updated to Manchester" }
        if ($updated.address.country -ne "UK") { throw "Country was lost during partial update! (Expected: UK, Got: $($updated.address.country))" }
        if ($updated.name -ne "Danny") { throw "Name was overwritten!" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Query Filtering: where() Operators (String, Bool, Number, Null, IN)
# ---------------------------------------------------------------------------
Assert-Test "Query Filtering: where() with Various Data Types" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("products").doc("p1").set(@{ name = "Laptop"; price = 1200; inStock = $true; category = "Tech" })
        $db.collection("products").doc("p2").set(@{ name = "Mouse"; price = 25; inStock = $true; category = "Tech" })
        $db.collection("products").doc("p3").set(@{ name = "Notebook"; price = 5; inStock = $false; category = "Office" })
        $db.collection("products").doc("p4").set(@{ name = "Desk"; price = 300; inStock = $true; category = "Furniture" })

        # Boolean where filter
        $inStockItems = $db.collection("products").where("inStock", "=", $true).get()
        if ($inStockItems.Count -ne 3) { throw "Expected 3 inStock items, got $($inStockItems.Count)" }

        # Numeric where filter
        $cheapItems = $db.collection("products").where("price", "<", 50).get()
        if ($cheapItems.Count -ne 2) { throw "Expected 2 cheap items (< 50), got $($cheapItems.Count)" }

        # String inequality where filter
        $nonTech = $db.collection("products").where("category", "!=", "Tech").get()
        if ($nonTech.Count -ne 2) { throw "Expected 2 non-tech items, got $($nonTech.Count)" }

        # IN operator
        $selected = $db.collection("products").where("category", "IN", @("Office", "Furniture")).get()
        if ($selected.Count -ne 2) { throw "Expected 2 items in IN filter, got $($selected.Count)" }

        # LIKE operator
        $laptops = $db.collection("products").where("name", "LIKE", "%top%").get()
        if ($laptops.Count -ne 1 -or $laptops[0].name -ne "Laptop") { throw "LIKE filter failed" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Query Sorting & Pagination: orderBy() and limit()
# ---------------------------------------------------------------------------
Assert-Test "Query Sorting & Pagination: orderBy() and limit()" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("students").doc("s1").set(@{ name = "Alice"; score = 95 })
        $db.collection("students").doc("s2").set(@{ name = "Bob"; score = 82 })
        $db.collection("students").doc("s3").set(@{ name = "Charlie"; score = 98 })
        $db.collection("students").doc("s4").set(@{ name = "David"; score = 70 })

        # Order by score descending with limit 2
        $top2 = $db.collection("students").orderBy("score", "desc").limit(2).get()
        if ($top2.Count -ne 2) { throw "Expected 2 students, got $($top2.Count)" }
        if ($top2[0].name -ne "Charlie" -or $top2[0].score -ne 98) { throw "Rank 1 is not Charlie (98)" }
        if ($top2[1].name -ne "Alice" -or $top2[1].score -ne 95) { throw "Rank 2 is not Alice (95)" }

        # Order by score ascending
        $asc = $db.collection("students").orderBy("score", "asc").get()
        if ($asc[0].name -ne "David" -or $asc[3].name -ne "Charlie") { throw "Ascending order mismatch" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Metadata: get({ keys: true })
# ---------------------------------------------------------------------------
Assert-Test "Metadata: get({ keys = $true })" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("items").doc("k-alpha").set(@{ name = "Alpha" })
        $db.collection("items").doc("k-beta").set(@{ name = "Beta" })

        # Point get with keys
        $singleWithKey = $db.collection("items").doc("k-alpha").get(@{ keys = $true })
        if ($null -eq $singleWithKey.key -or $singleWithKey.key -ne "k-alpha") {
            throw "Single get with keys did not return correct key property"
        }
        if ($singleWithKey.data.name -ne "Alpha") {
            throw "Single get with keys did not return nested data property"
        }

        # Collection get with keys
        $listWithKeys = $db.collection("items").orderBy("name", "asc").get(@{ keys = $true })
        if ($listWithKeys.Count -ne 2) { throw "Expected 2 items with keys" }
        if ($listWithKeys[0].key -ne "k-alpha" -or $listWithKeys[1].key -ne "k-beta") {
            throw "Collection get with keys mismatch in keys"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Bulk Operations: set() entire collection
# ---------------------------------------------------------------------------
Assert-Test "Bulk Operations: set() entire collection with array" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $initialData = @(
            @{ id = "1"; title = "Book 1"; author = "Author A" },
            @{ id = "2"; title = "Book 2"; author = "Author B" }
        )
        $db.collection("books").set($initialData)

        $books = $db.collection("books").get()
        if ($books.Count -ne 2) { throw "Expected 2 books after collection set, got $($books.Count)" }

        # Overwrite collection with new array
        $replacement = @(
            @{ id = "99"; title = "Replaced Book"; author = "Author Z" }
        )
        $db.collection("books").set($replacement)

        $newBooks = $db.collection("books").get()
        if ($newBooks.Count -ne 1 -or $newBooks[0].title -ne "Replaced Book") {
            throw "Collection overwrite failed"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Deletion: doc vs collection, deleteDatabase()
# ---------------------------------------------------------------------------
Assert-Test "Deletion: Document, Collection and deleteDatabase()" {
    $tempDbPath = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_deltest_$([Guid]::NewGuid().ToString('N')).db"
    $db = [PSLocalBase]::new($tempDbPath)

    # 1. Delete single doc
    $db.collection("del_test").doc("doc1").set(@{ val = 1 })
    $db.collection("del_test").doc("doc2").set(@{ val = 2 })
    $db.collection("del_test").doc("doc1").delete()
    if ($null -ne ($db.collection("del_test").doc("doc1").get())) {
        throw "Doc1 was not deleted"
    }
    if ($null -eq ($db.collection("del_test").doc("doc2").get())) {
        throw "Doc2 was unexpectedly deleted"
    }

    # 2. Delete collection
    $db.collection("del_test").delete()
    $recreated = $db.collection("del_test").get()
    if ($recreated.Count -ne 0) { throw "Collection was not empty after collection delete" }

    # 3. deleteDatabase()
    $db.deleteDatabase()
    if (Test-Path $tempDbPath) {
        throw "Database file still exists after deleteDatabase()"
    }
}

# ---------------------------------------------------------------------------
# Transactions: beginTransaction, commit, rollback
# ---------------------------------------------------------------------------
Assert-Test "Transactions: Rollback and Commit Verification" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("accounts").doc("acc1").set(@{ balance = 1000 })

        # Rollback test
        $db.beginTransaction()
        $db.collection("accounts").doc("acc1").set(@{ balance = 500 })
        $db.rollback()

        $afterRollback = $db.collection("accounts").doc("acc1").get()
        if ($afterRollback.balance -ne 1000) {
            throw "Rollback failed! Balance was changed to $($afterRollback.balance)"
        }

        # Commit test
        $db.beginTransaction()
        $db.collection("accounts").doc("acc1").set(@{ balance = 750 })
        $db.commit()

        $afterCommit = $db.collection("accounts").doc("acc1").get()
        if ($afterCommit.balance -ne 750) {
            throw "Commit failed! Balance is $($afterCommit.balance)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Cross-Collection Queries: SQL JOIN across collections via .query()
# ---------------------------------------------------------------------------
Assert-Test "Cross-Collection Queries: SQL JOIN and Aggregations" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("users").doc("u1").set(@{ name = "Alice"; dept = "IT" })
        $db.collection("users").doc("u2").set(@{ name = "Bob"; dept = "HR" })

        $db.collection("tickets").doc("t1").set(@{ userId = "u1"; title = "VPN Issue"; points = 5 })
        $db.collection("tickets").doc("t2").set(@{ userId = "u1"; title = "Password Reset"; points = 2 })
        $db.collection("tickets").doc("t3").set(@{ userId = "u2"; title = "Onboarding"; points = 8 })

        $sql = @'
SELECT 
    json_extract(u.doc, '$.name') AS Agent,
    json_extract(t.doc, '$.title') AS TicketTitle,
    CAST(json_extract(t.doc, '$.points') AS INT) AS Points
FROM tickets t
INNER JOIN users u ON json_extract(t.doc, '$.userId') = u.key
ORDER BY Points DESC;
'@

        $results = $db.query($sql)
        if ($results.Count -ne 3) { throw "Expected 3 joined records, got $($results.Count)" }
        if ($results[0].Agent -ne "Bob" -or $results[0].Points -ne 8) { throw "Top joined ticket mismatch" }
        if ($results[1].Agent -ne "Alice" -or $results[1].Points -ne 5) { throw "Second joined ticket mismatch" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Code Storage Integrity: Scripts with Quotes, Backslashes, Newlines & Variables
# ---------------------------------------------------------------------------
Assert-Test "Code Storage Integrity: Raw Script Payload Storage" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $sourceScript = @'
Get-Process | Where-Object { $_.Name -like "*sql*" -and $_.CPU -gt 5.5 } | ForEach-Object {
    $path = "C:\Windows\System32\drivers\"
    Write-Output "PID: $($_.Id) | Path: '$path'"
}
'@
        $db.collection("code_snippets").doc("ps-check").set(@{
            name     = "CheckProcess.ps1"
            language = "powershell"
            source   = $sourceScript
        })

        $retrieved = $db.collection("code_snippets").doc("ps-check").get()
        if ($null -eq $retrieved) { throw "Failed to retrieve code snippet" }
        if ($retrieved.source -cne $sourceScript) {
            throw "Source code payload was altered during storage or retrieval!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# Anti-Injection: Parameterized Queries with Malicious Payloads
# ---------------------------------------------------------------------------
Assert-Test "Anti-Injection: Parameterized Literals and Malicious Payloads" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("accounts").doc("acc1").set(@{ username = "admin"; balance = 5000 })
        $db.collection("accounts").doc("acc2").set(@{ username = "user1"; balance = 100 })
        $db.collection("accounts").doc("acc3").set(@{ username = "' OR '1'='1"; balance = 999 })

        # 1. Searching for SQL injection payload must match ONLY the literal payload
        $injectedSearch = $db.collection("accounts").where("username", "=", "' OR '1'='1").get()
        if ($injectedSearch.Count -ne 1 -or $injectedSearch[0].balance -ne 999) {
            throw "SQL injection payload was evaluated as logic instead of literal text!"
        }

        # 2. Injection payload attempting to drop table must return 0 records and NOT drop table
        $dropSearch = $db.collection("accounts").where("username", "=", "admin'; DROP TABLE accounts; --").get()
        if ($dropSearch.Count -ne 0) {
            throw "Unexpected match for DROP TABLE payload"
        }

        # Verify table accounts still exists and has all 3 documents
        $allAccounts = $db.collection("accounts").get()
        if ($allAccounts.Count -ne 3) {
            throw "Accounts table was affected by injection payload!"
        }

        # 3. Invalid field name must be rejected by whitelist regex
        $invalidFieldThrown = $false
        try {
            [void]$db.collection("accounts").where("username') = 1 OR 1=1 --", "=", "test").get()
        } catch {
            $invalidFieldThrown = $true
        }
        if (-not $invalidFieldThrown) {
            throw "Invalid field name was not rejected by whitelist regex!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-17: JSONPath Array Indexing (e.g. tags[0], items[1].sku)
# ---------------------------------------------------------------------------
Assert-Test "TC-17: JSONPath Array Indexing" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("developers").doc("dev1").set(@{
            name  = "Carlos"
            tags  = @("powershell", "systems", "cloud")
            roles = @(
                @{ title = "Architect"; primary = $true },
                @{ title = "Auditor";   primary = $false }
            )
        })
        $db.collection("developers").doc("dev2").set(@{
            name  = "Ana"
            tags  = @("python", "machine-learning")
            roles = @(
                @{ title = "DataScientist"; primary = $true }
            )
        })

        # 1. Filter by top-level array index: tags[0]
        $psDevs = $db.collection("developers").where("tags[0]", "=", "powershell").get()
        if ($psDevs.Count -ne 1 -or $psDevs[0].name -ne "Carlos") {
            throw "Failed to match array index tags[0] = 'powershell'"
        }

        # 2. Filter by nested array object property: roles[1].title
        $auditors = $db.collection("developers").where("roles[1].title", "=", "Auditor").get()
        if ($auditors.Count -ne 1 -or $auditors[0].name -ne "Carlos") {
            throw "Failed to match nested array object property roles[1].title"
        }

        # 3. Non-matching array index
        $nomatch = $db.collection("developers").where("tags[0]", "=", "golang").get()
        if ($nomatch.Count -ne 0) {
            throw "Unexpected match for non-existent tag"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-18: Native count() Method
# ---------------------------------------------------------------------------
Assert-Test "TC-18: Native count() Method" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("orders").doc("o1").set(@{ item = "Keyboard"; status = "shipped"; total = 120 })
        $db.collection("orders").doc("o2").set(@{ item = "Mouse";    status = "pending"; total = 30 })
        $db.collection("orders").doc("o3").set(@{ item = "Monitor";  status = "shipped"; total = 350 })
        $db.collection("orders").doc("o4").set(@{ item = "Cable";    status = "pending"; total = 10 })

        # 1. Total collection count
        $totalOrders = $db.collection("orders").count()
        if ($totalOrders -ne 4) {
            throw "Expected total count 4, got $totalOrders"
        }

        # 2. Filtered count
        $shippedCount = $db.collection("orders").where("status", "=", "shipped").count()
        if ($shippedCount -ne 2) {
            throw "Expected shipped count 2, got $shippedCount"
        }

        # 3. Point lookup count
        $o1Count = $db.collection("orders").doc("o1").count()
        if ($o1Count -ne 1) {
            throw "Expected point lookup count 1, got $o1Count"
        }

        # 4. Non-existent point lookup count
        $missingCount = $db.collection("orders").doc("o999").count()
        if ($missingCount -ne 0) {
            throw "Expected missing doc count 0, got $missingCount"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-19: Pagination with skip() and limit()
# ---------------------------------------------------------------------------
Assert-Test "TC-19: Pagination with skip() and limit()" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        for ($i = 1; $i -le 10; $i++) {
            $db.collection("pages").doc("p$i").set(@{ seq = $i; label = "Item $i" })
        }

        # Page 1: skip 0, limit 3 -> items 1, 2, 3
        $page1 = $db.collection("pages").orderBy("seq", "asc").limit(3).get()
        if ($page1.Count -ne 3 -or $page1[0].seq -ne 1 -or $page1[2].seq -ne 3) {
            throw "Page 1 pagination failed"
        }

        # Page 2: skip 3, limit 3 -> items 4, 5, 6
        $page2 = $db.collection("pages").orderBy("seq", "asc").skip(3).limit(3).get()
        if ($page2.Count -ne 3 -or $page2[0].seq -ne 4 -or $page2[2].seq -ne 6) {
            throw "Page 2 pagination failed (expected seq 4..6, got $($page2[0].seq)..$($page2[2].seq))"
        }

        # Page 4: skip 9, limit 3 -> item 10 (last remaining item)
        $page4 = $db.collection("pages").orderBy("seq", "asc").skip(9).limit(3).get()
        if ($page4.Count -ne 1 -or $page4[0].seq -ne 10) {
            throw "Page 4 pagination failed"
        }

        # Skip only without explicit limit -> items 8, 9, 10
        $skipOnly = $db.collection("pages").orderBy("seq", "asc").skip(7).get()
        if ($skipOnly.Count -ne 3 -or $skipOnly[0].seq -ne 8 -or $skipOnly[2].seq -ne 10) {
            throw "Skip-only pagination failed"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-20: Configurable JSON Serialization Depth
# ---------------------------------------------------------------------------
Assert-Test "TC-20: Configurable Serialization Depth" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Construct a 15-level deeply nested dictionary
        $deep = @{ leaf = "success_depth_15" }
        for ($lvl = 14; $lvl -ge 1; $lvl--) {
            $deep = @{ "level_$lvl" = $deep }
        }

        # Default depth is now 20 (accommodating > 10 levels)
        $db.collection("deep_docs").doc("dd1").set($deep)
        $retrieved = $db.collection("deep_docs").doc("dd1").get()

        # Traverse 15 levels down to verify no stringification occurred
        $cur = $retrieved
        for ($lvl = 1; $lvl -le 14; $lvl++) {
            $propName = "level_$lvl"
            if ($null -eq $cur.$propName) {
                throw "Level $lvl truncated during serialization!"
            }
            $cur = $cur.$propName
        }
        if ($cur.leaf -ne "success_depth_15") {
            throw "Deep leaf value mismatch, got: $($cur.leaf)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-21: Native Memory Reclamation & UTF-8 Error Marshalling
# ---------------------------------------------------------------------------
Assert-Test "TC-21: Native Memory Reclamation & UTF-8 Error Marshalling" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Verify [WinSqlite3]::Free([IntPtr]::Zero) and GetUtf8String([IntPtr]::Zero) are safe
        [WinSqlite3]::Free([IntPtr]::Zero)
        if ($null -ne [WinSqlite3]::GetUtf8String([IntPtr]::Zero)) {
            throw "Expected GetUtf8String(IntPtr.Zero) to return null."
        }

        # Trigger a direct SQL error and verify UTF-8 error text is decoded cleanly (not garbled UTF-16)
        $errorThrown = $false
        try {
            $db._ExecuteDirectSql("CREATE SYNTAX ERROR TABLE ;")
        } catch {
            $errorThrown = $true
            if ($_.Exception.Message -notmatch "SQLite execution error" -or $_.Exception.Message -notmatch "syntax error") {
                throw "Expected readable UTF-8 SQLite syntax error message, got: $($_.Exception.Message)"
            }
        }
        if (-not $errorThrown) {
            throw "Expected malformed SQL to throw exception!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-22: Custom Query Step & Parameter Binding Validation
# ---------------------------------------------------------------------------
Assert-Test "TC-22: Custom Query Step & Parameter Binding Validation" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("events").doc("e1").set(@{ type = "login"; user = "alice" })
        $db.collection("events").doc("e2").set(@{ type = "logout"; user = "bob" })

        # Parameterized custom query
        $rows = $db.query("SELECT key, json_extract(doc, '$.user') AS usr FROM [events] WHERE json_extract(doc, '$.type') = ?;", @("login"))
        if ($rows.Count -ne 1 -or $rows[0].usr -ne "alice") {
            throw "Parameterized query() failed to return expected row."
        }

        # Excess bound parameters beyond placeholders must throw InvalidOperationException (SQLITE_RANGE = 25)
        $bindErrThrown = $false
        try {
            [void]$db.query("SELECT key FROM [events];", @("unexpected_param"))
        } catch [System.InvalidOperationException] {
            $bindErrThrown = $true
        }
        if (-not $bindErrThrown) {
            throw "Expected BindText out-of-range parameter to throw InvalidOperationException."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-23: Fluent State Isolation & CurrentKey Reset
# ---------------------------------------------------------------------------
Assert-Test "TC-23: Fluent State Isolation & CurrentKey Reset" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("tasks")
        $col.doc("t1").set(@{ title = "Task 1"; done = $false })
        $col.doc("t2").set(@{ title = "Task 2"; done = $true })
        $col.doc("t3").set(@{ title = "Task 3"; done = $true })

        if (-not [string]::IsNullOrEmpty($col.CurrentKey)) {
            throw "CurrentKey was not cleared after .set()!"
        }

        # Point get followed by collection get on the same reference must return all documents
        $single = $col.doc("t1").get()
        if ($null -eq $single -or $single.title -ne "Task 1") {
            throw "Point lookup for t1 failed."
        }
        if (-not [string]::IsNullOrEmpty($col.CurrentKey)) {
            throw "CurrentKey was not cleared after .get()!"
        }

        $allAfterGet = $col.get()
        if ($allAfterGet.Count -ne 3) {
            throw "Collection .get() after .doc().get() returned $($allAfterGet.Count) items instead of 3."
        }

        # Point update followed by filtered delete must not delete the updated key
        $col.doc("t1").update(@{ title = "Task 1 Updated" })
        if (-not [string]::IsNullOrEmpty($col.CurrentKey)) {
            throw "CurrentKey was not cleared after .update()!"
        }

        # Even if .doc() is called before .where(), .where() must clear CurrentKey
        $col.doc("t1").where("done", "=", $true).delete()
        $remaining = $col.get()
        if ($remaining.Count -ne 1 -or $remaining[0].title -ne "Task 1 Updated") {
            throw "Filtered delete polluted by CurrentKey! Remaining count: $($remaining.Count)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-24: Reject UNC & Network Paths for WAL Mode
# ---------------------------------------------------------------------------
Assert-Test "TC-24: Reject UNC & Network Paths for WAL Mode" {
    $uncThrown = $false
    try {
        [void][PSLocalBase]::new("\\server\share\pslocalbase.db")
    } catch [System.InvalidOperationException] {
        $uncThrown = $true
    }
    if (-not $uncThrown) {
        throw "Expected UNC path '\\server\share\pslocalbase.db' to be rejected with InvalidOperationException."
    }

    $fwdUncThrown = $false
    try {
        [void][PSLocalBase]::new("//server/share/pslocalbase.db")
    } catch [System.InvalidOperationException] {
        $fwdUncThrown = $true
    }
    if (-not $fwdUncThrown) {
        throw "Expected forward-slash UNC path '//server/share/pslocalbase.db' to be rejected with InvalidOperationException."
    }
}

# ---------------------------------------------------------------------------
# TC-25: Transaction Tracking & Safe Rollback on Bulk Set
# ---------------------------------------------------------------------------
Assert-Test "TC-25: Transaction Tracking & Safe Rollback on Bulk Set" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Bulk .set() within an existing caller-managed transaction must not fail on nested BEGIN
        $db.beginTransaction()
        if (-not $db.InTransaction) {
            throw "Expected InTransaction to be true after beginTransaction()."
        }
        $db.collection("batch").set(@(
            @{ id = "b1"; name = "Item 1" },
            @{ id = "b2"; name = "Item 2" }
        ))
        if (-not $db.InTransaction) {
            throw "Expected InTransaction to remain true before caller commit()."
        }
        $db.commit()
        if ($db.InTransaction) {
            throw "Expected InTransaction to be false after commit()."
        }

        if ($db.collection("batch").count() -ne 2) {
            throw "Expected 2 items committed in batch collection."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-26: System32 DLL Search Path, Balanced Field Regex & Scalar/Empty IN
# ---------------------------------------------------------------------------
Assert-Test "TC-26: System32 DLL Search Path, Balanced Field Regex & Scalar/Empty IN" {
    # 1. Verify DefaultDllImportSearchPaths(DllImportSearchPath.System32) attribute on WinSqlite3 assembly
    $attr = [WinSqlite3].Assembly.GetCustomAttributes([System.Runtime.InteropServices.DefaultDllImportSearchPathsAttribute], $false)
    if ($null -eq $attr -or $attr.Count -eq 0) {
        throw "WinSqlite3 assembly is missing [DefaultDllImportSearchPaths] attribute."
    }
    if ($attr[0].Paths -ne [System.Runtime.InteropServices.DllImportSearchPath]::System32) {
        throw "WinSqlite3 DefaultDllImportSearchPaths is not set to System32. Actual: $($attr[0].Paths)"
    }

    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("items").doc("i1").set(@{ category = "Tech"; rank = 2 })
        $db.collection("items").doc("i2").set(@{ category = "Office"; rank = 1 })

        # 2. Trimmed field name in where() and orderBy() + scalar IN clause
        $scalarIn = $db.collection("items").where("  category  ", "IN", "Tech").orderBy("  rank  ", "asc").get()
        if ($scalarIn.Count -ne 1 -or $scalarIn[0].category -ne "Tech") {
            throw "Trimmed field or scalar IN clause failed."
        }

        # 3. Empty array IN clause returns 0 matches cleanly
        $emptyIn = $db.collection("items").where("category", "IN", @()).get()
        if ($emptyIn.Count -ne 0) {
            throw "Empty array IN clause should return 0 items."
        }

        # 4. Null IN value throws ArgumentException
        $nullInThrown = $false
        try {
            [void]$db.collection("items").where("category", "IN", $null)
        } catch [System.ArgumentException] {
            $nullInThrown = $true
        }
        if (-not $nullInThrown) {
            throw "Expected null value with IN operator to throw ArgumentException."
        }

        # 5. Unbalanced array brackets in where() and orderBy() are rejected
        foreach ($badField in @("tags[[0]", "tags[0]]", "tags[]", ".leading", "trailing.", "a..b")) {
            $whereRejected = $false
            try {
                [void]$db.collection("items").where($badField, "=", "x")
            } catch [System.ArgumentException] {
                $whereRejected = $true
            }
            if (-not $whereRejected) {
                throw "Malformed field '$badField' was not rejected in where()."
            }

            $orderRejected = $false
            try {
                [void]$db.collection("items").orderBy($badField, "asc")
            } catch [System.ArgumentException] {
                $orderRejected = $true
            }
            if (-not $orderRejected) {
                throw "Malformed field '$badField' was not rejected in orderBy()."
            }
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-27: Explicit Collection Lifecycle (.create() & Lazy Navigation)
# ---------------------------------------------------------------------------
Assert-Test "TC-27: Explicit Collection Lifecycle (.create() and Lazy Navigation)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # 1. Navigation does not create collection in SQLite
        [void]$db.collection("uncreated_collection")
        $colls = @($db.listCollections())
        if ($colls.Count -ne 0) {
            throw "Collection was created simply by navigating to it."
        }

        # 2. Reading non-existent collection returns empty without creating table
        $res = $db.collection("uncreated_collection").get()
        if ($res.Count -ne 0) {
            throw "Expected empty array from uncreated collection."
        }
        $cnt = $db.collection("uncreated_collection").count()
        if ($cnt -ne 0) {
            throw "Expected 0 count from uncreated collection."
        }
        if (@($db.listCollections()).Count -ne 0) {
            throw "Collection table was created during read/count."
        }

        # 3. Explicit .create() provisions table
        [void]$db.collection("my_custom_coll").create()
        $collsAfterCreate = @($db.listCollections())
        if ($collsAfterCreate.Count -ne 1 -or $collsAfterCreate[0] -ne "my_custom_coll") {
            throw "Explicit .create() failed to create collection table."
        }

        # 4. Explicit .delete() drops table
        $db.collection("my_custom_coll").delete()
        if (@($db.listCollections()).Count -ne 0) {
            throw "Collection table still exists after .delete()."
        }

        # 5. Writing data creates table automatically
        $null = $db.collection("auto_on_write").add(@{ ok = $true })
        $collsAfterWrite = @($db.listCollections())
        if ($collsAfterWrite.Count -ne 1 -or $collsAfterWrite[0] -ne "auto_on_write") {
            throw "Write operation failed to auto-create collection table."
        }

        # 6. Explicit .doc() targeting provisions table automatically
        [void]$db.collection("auto_on_doc").doc("doc1")
        $collsAfterDoc = @($db.listCollections())
        if ($collsAfterDoc.Count -ne 2 -or -not ($collsAfterDoc -contains "auto_on_doc")) {
            throw "Explicit .doc() failed to auto-create collection table."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-28: Target Document Auto-Provisioning & Criteria Key Resolution
# ---------------------------------------------------------------------------
Assert-Test "TC-28: Target Document Auto-Provisioning & Criteria Key Resolution" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # 1. Calling .doc() on uncreated collection provisions table in SQLite
        if ($db.collectionExists("orders_auto")) {
            throw "Collection orders_auto should not exist prior to .doc()"
        }
        [void]$db.collection("orders_auto").doc("ord-001")
        if (-not $db.collectionExists("orders_auto")) {
            throw "Calling .doc('ord-001') failed to auto-provision table 'orders_auto'."
        }

        # 2. Reading targeted document that hasn't been set returns $null
        $read = $db.collection("orders_auto").doc("ord-001").get()
        if ($null -ne $read) {
            throw "Expected null for unpopulated document."
        }

        # 3. Setting document by hashtable criteria @{ id = 'ord-100' }
        $db.collection("orders_auto").doc(@{ id = "ord-100" }).set(@{ total = 450; status = "Completed" })
        $fromCriteria = $db.collection("orders_auto").doc("ord-100").get()
        if ($null -eq $fromCriteria -or $fromCriteria.total -ne 450) {
            throw "Failed to set/get document targeted via criteria hashtable."
        }

        # 4. Setting document by PSCustomObject criteria [PSCustomObject]@{ key = 'ord-200' }
        $critObj = [PSCustomObject]@{ key = "ord-200"; description = "Search criteria" }
        $db.collection("orders_auto").doc($critObj).set(@{ total = 890; status = "Pending" })
        $fromObj = $db.collection("orders_auto").doc("ord-200").get()
        if ($null -eq $fromObj -or $fromObj.total -ne 890) {
            throw "Failed to set/get document targeted via PSCustomObject criteria."
        }

        # 5. Verify total count in collection is 2
        $cnt = $db.collection("orders_auto").count()
        if ($cnt -ne 2) {
            throw "Expected 2 documents in orders_auto, got $cnt"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-29: Collection Schema Lifecycle (createCollection, Exists, Drop & Re-create)
# ---------------------------------------------------------------------------
Assert-Test "TC-29: Collection Schema Lifecycle (createCollection, Exists, Drop & Re-create)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # 1. Verify collectionExists is false for non-existent collection
        if ($db.collectionExists("audit_trail")) {
            throw "audit_trail should not exist initially."
        }

        # 2. Direct createCollection method
        [void]$db.createCollection("audit_trail")
        if (-not $db.collectionExists("audit_trail")) {
            throw "audit_trail should exist after createCollection."
        }

        # 3. Insert and verify document
        $db.collection("audit_trail").doc("entry-1").set(@{ action = "Login"; timestamp = "2026-10-28" })
        if ($db.collection("audit_trail").count() -ne 1) {
            throw "Failed document write in audit_trail."
        }

        # 4. Drop collection table completely
        $db.collection("audit_trail").delete()
        if ($db.collectionExists("audit_trail")) {
            throw "audit_trail should not exist after .delete()."
        }
        $colls = @($db.listCollections())
        if ($colls -contains "audit_trail") {
            throw "listCollections should not contain audit_trail after drop."
        }

        # 5. Immediate re-creation of the same collection name
        [void]$db.collection("audit_trail").create()
        if (-not $db.collectionExists("audit_trail")) {
            throw "audit_trail should exist after immediate re-creation."
        }
        if ($db.collection("audit_trail").count() -ne 0) {
            throw "Re-created collection should be completely empty (0 documents)."
        }

        # 6. Re-insert data to verify schema is functional
        $db.collection("audit_trail").doc("entry-2").set(@{ action = "Logout" })
        $doc = $db.collection("audit_trail").doc("entry-2").get()
        if ($null -eq $doc -or $doc.action -ne "Logout") {
            throw "Failed write on re-created collection."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-30: Multiple Collection Isolation & Relational Integrity
# ---------------------------------------------------------------------------
Assert-Test "TC-30: Multiple Collection Isolation & Relational Integrity" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # 1. Provision 3 independent collections
        [void]$db.createCollection("users")
        [void]$db.createCollection("products")
        [void]$db.createCollection("orders")

        $colls = @($db.getCollections())
        if ($colls.Count -ne 3) {
            throw "Expected exactly 3 collections, got $($colls.Count)"
        }

        # 2. Populate collections with interconnected data
        $db.collection("users").doc("u-1").set(@{ name = "Alice"; dept = "Sales" })
        $db.collection("users").doc("u-2").set(@{ name = "Bob"; dept = "Engineering" })

        $db.collection("products").doc("p-1").set(@{ title = "Server"; price = 2500 })
        $db.collection("products").doc("p-2").set(@{ title = "Switch"; price = 400 })

        $db.collection("orders").doc("o-1").set(@{ userId = "u-1"; prodId = "p-1"; qty = 2 })
        $db.collection("orders").doc("o-2").set(@{ userId = "u-2"; prodId = "p-2"; qty = 5 })

        # 3. Bulk overwrite collection 'users' using .set(@(...))
        $newUsers = @(
            @{ id = "u-3"; name = "Charlie"; dept = "HR" },
            @{ id = "u-4"; name = "Dana"; dept = "Finance" }
        )
        $db.collection("users").set($newUsers)

        # 4. Verify 'products' and 'orders' were untouched by 'users' bulk overwrite
        if ($db.collection("products").count() -ne 2) {
            throw "products collection was mutated by users overwrite."
        }
        if ($db.collection("orders").count() -ne 2) {
            throw "orders collection was mutated by users overwrite."
        }
        $serverDoc = $db.collection("products").doc("p-1").get()
        if ($null -eq $serverDoc -or $serverDoc.price -ne 2500) {
            throw "products p-1 document corrupted."
        }

        # 5. Drop 'orders' collection
        $db.collection("orders").delete()
        if ($db.collectionExists("orders")) {
            throw "orders collection should be deleted."
        }
        if (-not $db.collectionExists("users") -or -not $db.collectionExists("products")) {
            throw "users or products collection accidentally deleted."
        }

        # 6. Verify cross-collection query between surviving collections
        $sql = "SELECT json_extract(u.doc, '$.name') AS User, json_extract(p.doc, '$.title') AS Product FROM users u CROSS JOIN products p ORDER BY User, Product;"
        $crossRes = $db.query($sql)
        # 2 users * 2 products = 4 cross-join rows
        if ($crossRes.Count -ne 4) {
            throw "Expected 4 rows from CROSS JOIN, got $($crossRes.Count)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-31: Isolated Collection State Reference Independence
# ---------------------------------------------------------------------------
Assert-Test "TC-31: Isolated Collection State Reference Independence" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $users = $db.collection("users")
        $orders = $db.collection("orders")

        $users.doc("u-1").set(@{ name = "Ana"; role = "Developer" })
        $orders.doc("o-1").set(@{ orderId = "ORD-99"; total = 150 })

        if ($users.count() -ne 1) {
            throw "Expected 1 document in 'users', got $($users.count())"
        }
        if ($orders.count() -ne 1) {
            throw "Expected 1 document in 'orders', got $($orders.count())"
        }

        $userDoc = $users.doc("u-1").get()
        if ($null -eq $userDoc -or $userDoc.name -ne "Ana") {
            throw "Document u-1 not found in 'users' collection."
        }
        $orderDoc = $orders.doc("o-1").get()
        if ($null -eq $orderDoc -or $orderDoc.orderId -ne "ORD-99") {
            throw "Document o-1 not found in 'orders' collection."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-32: Accidental Drop Protection & Explicit .drop()
# ---------------------------------------------------------------------------
Assert-Test "TC-32: Accidental Drop Protection & Explicit .drop()" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("critical_data")
        $col.doc("doc-1").set(@{ val = "important" })
        $col.doc("doc-2").set(@{ val = "vital" })

        # Calling .delete() with limit() must be rejected with InvalidOperationException
        $exceptionThrown = $false
        try {
            $col.doc("doc-1").limit(1).delete()
        } catch [System.InvalidOperationException] {
            $exceptionThrown = $true
        }

        if (-not $exceptionThrown) {
            throw "Expected .limit().delete() to throw InvalidOperationException!"
        }

        # Verify collection and both documents were NOT dropped or deleted
        if (-not $db.collectionExists("critical_data")) {
            throw "critical_data table was accidentally dropped!"
        }
        if ($db.collection("critical_data").count() -ne 2) {
            throw "Documents were corrupted or deleted during rejected delete!"
        }

        # Explicit .drop() must cleanly remove the collection
        $db.collection("critical_data").drop()
        if ($db.collectionExists("critical_data")) {
            throw "Collection should have been dropped by explicit .drop()."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-33: Case-Insensitive Collection Schema Resolution
# ---------------------------------------------------------------------------
Assert-Test "TC-33: Case-Insensitive Collection Schema Resolution" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Create with uppercase
        $db.collection("Customers").doc("c-1").set(@{ name = "Carlos"; role = "Architect"; active = $true })

        # Update using lowercase collection reference
        $db.collection("customers").doc("c-1").update(@{ age = 35 })

        # Retrieve and verify deep merge preserved original fields
        $doc = $db.collection("Customers").doc("c-1").get()
        if ($null -eq $doc) {
            throw "Document c-1 not found after case-insensitive update."
        }
        if ($doc.name -ne "Carlos" -or $doc.role -ne "Architect" -or $doc.active -ne $true -or $doc.age -ne 35) {
            throw "Fields were lost during case-insensitive update! Retrieved: $(ConvertTo-Json -InputObject $doc -Compress)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-34: NUL Byte Key Defense
# ---------------------------------------------------------------------------
Assert-Test "TC-34: NUL Byte Key Defense" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        [void]$db.collection("null_defense").create()

        # Reject NUL character in .doc()
        $nulDocRejected = $false
        try {
            $db.collection("null_defense").doc("alice`0admin").set(@{ role = "attacker" })
        } catch [System.ArgumentException] {
            $nulDocRejected = $true
        }
        if (-not $nulDocRejected) {
            throw "Expected key with embedded null character to be rejected in .doc()!"
        }

        # Reject NUL character in .add()
        $nulAddRejected = $false
        try {
            [void]$db.collection("null_defense").add(@{ val = 1 }, "bob`0attacker")
        } catch [System.ArgumentException] {
            $nulAddRejected = $true
        }
        if (-not $nulAddRejected) {
            throw "Expected key with embedded null character to be rejected in .add()!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-35: Bulk Set SAVEPOINT Isolation in External Transactions
# ---------------------------------------------------------------------------
Assert-Test "TC-35: Bulk Set SAVEPOINT Isolation in External Transactions" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("inventory").doc("item-1").set(@{ name = "Initial Item"; qty = 10 })

        # Start outer transaction
        $db.beginTransaction()
        $bulkFailed = $false
        try {
            # Provide batch with duplicate keys
            $db.collection("inventory").set(@(
                @{ id = "dup-key"; name = "First Valid" },
                @{ id = "dup-key"; name = "Second Collision" }
            ))
        } catch {
            $bulkFailed = $true
        }

        if (-not $bulkFailed) {
            throw "Expected duplicate key in bulk set to throw constraint error!"
        }

        # Commit outer transaction - savepoint should have rolled back the failed bulk set
        $db.commit()

        $items = @($db.collection("inventory").get())
        if ($items.Count -ne 1 -or $items[0].name -ne "Initial Item") {
            throw "Initial record was lost or partial bulk inserts leaked into outer transaction!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-36: Safe Handle Release on Constructor PRAGMA Failure
# ---------------------------------------------------------------------------
Assert-Test "TC-36: Safe Handle Release on Constructor PRAGMA Failure" {
    $tempCorruptFile = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_corrupt_$([Guid]::NewGuid().ToString('N')).bin"
    [System.IO.File]::WriteAllText($tempCorruptFile, "THIS IS AN INVALID DATABASE FILE HEADER")
    try {
        $constructorFailed = $false
        try {
            [void][PSLocalBase]::new($tempCorruptFile)
        } catch {
            $constructorFailed = $true
        }

        if (-not $constructorFailed) {
            throw "Expected corrupt file opening to fail during constructor!"
        }

        # Attempt to delete file immediately - if handle leaked, IOException will occur
        [System.IO.File]::Delete($tempCorruptFile)
        if (Test-Path $tempCorruptFile) {
            throw "Corrupt file still exists after deletion attempt!"
        }
    } finally {
        if (Test-Path $tempCorruptFile) {
            Remove-Item $tempCorruptFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# TC-37: Constructor Options Enforcement
# ---------------------------------------------------------------------------
Assert-Test "TC-37: Constructor Options Enforcement" {
    $tempDb = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_cfg_$([Guid]::NewGuid().ToString('N')).db"
    try {
        $db = [PSLocalBase]::new($tempDb, @{
            wal         = $false
            cacheSizeMB = 32
            busyTimeout = 8000
        })

        $jm = ($db.query("PRAGMA journal_mode;"))[0].journal_mode
        $cs = ($db.query("PRAGMA cache_size;"))[0].cache_size
        $bt = ($db.query("PRAGMA busy_timeout;"))[0].timeout

        # journal_mode should be delete (non-WAL)
        if ($jm.ToString().ToLowerInvariant() -ne "delete") {
            throw "Expected journal_mode 'delete', got '$jm'"
        }
        # 32 MB = 32 * 1024 = 32768 KiB (-32768)
        if ([int]$cs -ne -32768) {
            throw "Expected cache_size -32768, got '$cs'"
        }
        if ([int]$bt -ne 8000) {
            throw "Expected busy_timeout 8000, got '$bt'"
        }

        $db.close()
    } finally {
        if (Test-Path $tempDb) { Remove-Item $tempDb -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# TC-38: Atomic update() Isolation
# ---------------------------------------------------------------------------
Assert-Test "TC-38: Atomic update() Isolation" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("accounts").doc("acc-1").set(@{ balance = 1000; status = "active"; tier = "silver" })

        # Atomic partial update
        $db.collection("accounts").doc("acc-1").update(@{ tier = "gold"; points = 500 })

        $acc = $db.collection("accounts").doc("acc-1").get()
        if ($acc.balance -ne 1000 -or $acc.status -ne "active" -or $acc.tier -ne "gold" -or $acc.points -ne 500) {
            throw "Update did not preserve unmutated fields or failed to merge new fields!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-39: Real-time InTransaction Ground Truth via sqlite3_get_autocommit
# ---------------------------------------------------------------------------
Assert-Test "TC-39: Real-time InTransaction Ground Truth" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        if ($db.InTransaction) {
            throw "InTransaction should be false initially."
        }

        $db.beginTransaction()
        if (-not $db.InTransaction) {
            throw "InTransaction should be true after beginTransaction()."
        }

        $db.commit()
        if ($db.InTransaction) {
            throw "InTransaction should be false after commit()."
        }

        # Raw SQL BEGIN check
        $db._ExecuteDirectSql("BEGIN;")
        if (-not $db.InTransaction) {
            throw "InTransaction should detect raw SQL BEGIN via sqlite3_get_autocommit."
        }

        $db._ExecuteDirectSql("ROLLBACK;")
        if ($db.InTransaction) {
            throw "InTransaction should detect raw SQL ROLLBACK."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-40: Strongly-Typed Query Results & Clean Wrapper Unwrapping
# ---------------------------------------------------------------------------
Assert-Test "TC-40: Strongly-Typed Query Results & Clean Wrapper Unwrapping" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # 1. Strongly typed SQL query
        $res = $db.query("SELECT 42 as num, 3.14 as flt, 'hello' as str, NULL as nil;")
        if ($res.Count -ne 1) { throw "Expected 1 row from query." }
        if ($res[0].num -ne 42 -or ($res[0].num -isnot [long] -and $res[0].num -isnot [int])) {
            throw "num column is not a strongly-typed integer."
        }
        if ($res[0].flt -ne 3.14 -or $res[0].flt -isnot [double]) {
            throw "flt column is not a strongly-typed double."
        }
        if ($res[0].str -ne "hello" -or $res[0].str -isnot [string]) {
            throw "str column is not a string."
        }
        if ($null -ne $res[0].nil) {
            throw "nil column should be null."
        }

        # 2. Clean export and re-import with keys (no wrapper nesting)
        $db.collection("source_col").doc("doc-a").set(@{ title = "Article A"; views = 100 })
        $exported = $db.collection("source_col").get(@{ keys = $true })

        # Re-import into target_col using keys option
        $db.collection("target_col").set($exported, @{ keys = $true })

        $importedDoc = $db.collection("target_col").doc("doc-a").get()
        if ($null -eq $importedDoc) {
            throw "Imported document doc-a not found in target_col."
        }
        if ($importedDoc.title -ne "Article A" -or $importedDoc.views -ne 100) {
            throw "Imported document corrupted or wrapped: $(ConvertTo-Json -InputObject $importedDoc -Compress)"
        }
        # Verify it was not wrapped in .data
        if ($importedDoc.PSObject.Properties["data"]) {
            throw "Document data was improperly nested in a 'data' wrapper property!"
        }
    } finally {
        $db.close()
    }
}


# ---------------------------------------------------------------------------
# TC-41: Orphaned Collection Handle Defense
# ---------------------------------------------------------------------------
Assert-Test "TC-41: Orphaned Collection Handle Defense" {
    $db = [PSLocalBase]::new(":memory:")
    $users = $db.collection("users")
    $db.close()

    $threwTx = $false
    try {
        $null = $users._GetInTransaction()
    } catch [System.InvalidOperationException] {
        $threwTx = $true
    }
    if (-not $threwTx) { throw "Expected _GetInTransaction on orphaned collection to throw InvalidOperationException." }

    $threwBegin = $false
    try {
        $users.beginTransaction()
    } catch [System.InvalidOperationException] {
        $threwBegin = $true
    }
    if (-not $threwBegin) { throw "Expected beginTransaction on orphaned collection to throw InvalidOperationException." }
}

# ---------------------------------------------------------------------------
# TC-42: Cross-Edition Serialization Depth Protection
# ---------------------------------------------------------------------------
Assert-Test "TC-42: Cross-Edition Serialization Depth Protection" {
    $db = [PSLocalBase]::new(":memory:", @{ depth = 2 })
    try {
        $db.collection("users").doc("u1").set(@{ name = "Alice"; age = 30 })
        $threwDepth = $false
        try {
            $deepObj = @{ a = @{ b = @{ c = @{ d = 1 } } } }
            $db.collection("users").doc("u1").set($deepObj)
        } catch [System.InvalidOperationException] {
            $threwDepth = $true
        }
        if (-not $threwDepth) { throw "Expected serialization exceeding depth to throw InvalidOperationException." }
        $prev = $db.collection("users").doc("u1").get()
        if ($prev.name -ne "Alice" -or $prev.age -ne 30) { throw "Previous document was not preserved after rejected set." }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-43: Paged Count with Skip/Offset Subquery
# ---------------------------------------------------------------------------
Assert-Test "TC-43: Paged Count with Skip/Offset Subquery" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("paged_count")
        $col.add(@{ v = 1 }) | Out-Null
        $col.add(@{ v = 2 }) | Out-Null
        $col.add(@{ v = 3 }) | Out-Null

        $cTotal = $col.count()
        $cSkip1 = $col.skip(1).count()
        $cSkip2 = $col.skip(2).count()
        $cSkip3 = $col.skip(3).count()
        $cSkip1Lim1 = $col.skip(1).limit(1).count()

        if ($cTotal -ne 3) { throw "count() expected 3, got $cTotal" }
        if ($cSkip1 -ne 2) { throw "skip(1).count() expected 2, got $cSkip1" }
        if ($cSkip2 -ne 1) { throw "skip(2).count() expected 1, got $cSkip2" }
        if ($cSkip3 -ne 0) { throw "skip(3).count() expected 0, got $cSkip3" }
        if ($cSkip1Lim1 -ne 1) { throw "skip(1).limit(1).count() expected 1, got $cSkip1Lim1" }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-44: Strongly-Typed Query Parameter Binding and Count Parity
# ---------------------------------------------------------------------------
Assert-Test "TC-44: Strongly-Typed Query Parameter Binding and Count Parity" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Numeric parameter comparison: 1 > 10 should be 0 (False), typeof should be integer
        $rows = $db.query("SELECT ? > 10 AS cmp, typeof(?) AS t;", @(1, 1))
        if ($rows[0].cmp -ne 0 -or $rows[0].t -ne "integer") {
            throw "Numeric parameter binding affinity failed (cmp=$($rows[0].cmp), t=$($rows[0].t))"
        }

        # Parameter count mismatch validation
        $threwMismatch = $false
        try {
            $null = $db.query("SELECT ? AS a, ? AS b;", @("only_one"))
        } catch [System.InvalidOperationException] {
            $threwMismatch = $true
        }
        if (-not $threwMismatch) { throw "Parameter count mismatch did not throw InvalidOperationException." }

        # String parameter with NUL byte preservation
        $nulString = "hello" + [char]0 + "world"
        $nulRows = $db.query("SELECT ? AS s;", @($nulString))
        if ($nulRows[0].s.Length -ne 11) {
            throw "NUL byte string parameter was truncated (length=$($nulRows[0].s.Length))."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-45: Collection-level deleteDatabase() Rejection
# ---------------------------------------------------------------------------
Assert-Test "TC-45: Collection-level deleteDatabase() Rejection" {
    $tempDb = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test_tc45_$([Guid]::NewGuid().ToString('N')).db")
    $db = [PSLocalBase]::new($tempDb)
    try {
        $col = $db.collection("test")
        $col.doc("1").set(@{ a = 1 })
        $threwChildDel = $false
        try {
            $col.deleteDatabase()
        } catch [System.InvalidOperationException] {
            $threwChildDel = $true
        }
        if (-not $threwChildDel) { throw "Child deleteDatabase did not throw InvalidOperationException." }
        if ($db.DbHandle -eq [IntPtr]::Zero) { throw "Root DB handle was unexpectedly closed." }
    } finally {
        $db.close()
        Remove-Item $tempDb* -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# TC-46: Expression Indexing & Unique Constraints
# ---------------------------------------------------------------------------
Assert-Test "TC-46: Expression Indexing & Unique Constraints" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("users")
        [void]$col.add(@{ email = "alice@example.com"; name = "Alice" })

        # Create unique expression index on $.email
        [void]$col.createIndex("email", @{ unique = $true })

        # Verify index exists in sqlite_master
        $idxRows = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users' AND name LIKE 'idx_users__email_%';")
        if ($idxRows.Count -ne 1) { throw "Expected idx_users__email_* in sqlite_master." }

        # Attempt to insert duplicate email; must throw unique constraint exception
        $duplicateFailed = $false
        try {
            [void]$col.add(@{ email = "alice@example.com"; name = "Alice Duplicate" })
        } catch {
            $duplicateFailed = $true
        }
        if (-not $duplicateFailed) {
            throw "Inserting duplicate unique index value should have thrown an exception."
        }

        # Drop index
        [void]$col.dropIndex("email")
        $idxDropped = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='users' AND name LIKE 'idx_users__email_%';")
        if ($idxDropped.Count -ne 0) { throw "Index idx_users__email_* was not dropped." }

        # Insertion should now succeed without unique index
        [void]$col.add(@{ email = "alice@example.com"; name = "Alice 2" })
        $count = $col.where("email", "==", "alice@example.com").count()
        if ($count -ne 2) { throw "Expected 2 records with alice@example.com after index drop, got $count." }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-47: Array Operator 'array-contains'
# ---------------------------------------------------------------------------
Assert-Test "TC-47: Array Operator 'array-contains'" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("articles")
        [void]$col.add(@{ title = "Article 1"; tags = @("powershell", "sqlite", "nosql") })
        [void]$col.add(@{ title = "Article 2"; tags = @("powershell", "devops") })
        [void]$col.add(@{ title = "Article 3"; tags = @("python", "ai") })
        [void]$col.add(@{ title = "Article 4"; scores = @(10, 20, 30) })

        # array-contains string
        $sqliteArticles = $col.where("tags", "array-contains", "sqlite").get()
        if ($sqliteArticles.Count -ne 1 -or $sqliteArticles[0].title -ne "Article 1") {
            throw "Expected 1 article containing 'sqlite'."
        }

        # -contains alias
        $psArticles = $col.where("tags", "-contains", "powershell").get()
        if ($psArticles.Count -ne 2) {
            throw "Expected 2 articles containing 'powershell', got $($psArticles.Count)."
        }

        # array-contains number
        $scoreArticles = $col.where("scores", "array-contains", 20).get()
        if ($scoreArticles.Count -ne 1 -or $scoreArticles[0].title -ne "Article 4") {
            throw "Expected Article 4 to match numeric array-contains 20."
        }

        # non-existent
        $empty = $col.where("tags", "array-contains", "rust").get()
        if ($empty.Count -ne 0) {
            throw "Expected 0 results for non-existent tag."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-48: Array Operator 'array-contains-any'
# ---------------------------------------------------------------------------
Assert-Test "TC-48: Array Operator 'array-contains-any'" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("posts")
        [void]$col.add(@{ id = 1; tags = @("tech", "windows") })
        [void]$col.add(@{ id = 2; tags = @("linux", "bash") })
        [void]$col.add(@{ id = 3; tags = @("cooking", "recipes") })

        # Match either windows or linux
        $res = $col.where("tags", "array-contains-any", @("windows", "linux")).get()
        if ($res.Count -ne 2) {
            throw "Expected 2 posts matching windows or linux, got $($res.Count)."
        }

        # Match single element passed as scalar
        $resScalar = $col.where("tags", "array-contains-any", "cooking").get()
        if ($resScalar.Count -ne 1 -or $resScalar[0].id -ne 3) {
            throw "Expected post 3 for scalar cooking match."
        }

        # Match none
        $none = $col.where("tags", "array-contains-any", @("gaming", "sports")).get()
        if ($none.Count -ne 0) {
            throw "Expected 0 posts matching gaming/sports."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-49: 'not-in' Operator & Null Safety
# ---------------------------------------------------------------------------
Assert-Test "TC-49: 'not-in' Operator & Null Safety" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("products")
        [void]$col.add(@{ name = "Apple"; category = "fruit" })
        [void]$col.add(@{ name = "Carrot"; category = "vegetable" })
        [void]$col.add(@{ name = "Cheese"; category = "dairy" })
        [void]$col.add(@{ name = "Mystery Item" }) # category is null/missing

        # not-in array
        $res = $col.where("category", "not-in", @("fruit", "dairy")).get()
        if ($res.Count -ne 1 -or $res[0].name -ne "Carrot") {
            throw "Expected only 'Carrot' for not-in (fruit, dairy). Got count=$($res.Count)."
        }

        # -notin alias with scalar
        $resScalar = $col.where("category", "-notin", "fruit").get()
        if ($resScalar.Count -ne 2) {
            throw "Expected 2 items for -notin fruit (Carrot, Cheese), got $($resScalar.Count)."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-50: Atomic Array Mutations (ArrayUnion & ArrayRemove)
# ---------------------------------------------------------------------------
Assert-Test "TC-50: Atomic Array Mutations (ArrayUnion & ArrayRemove)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("users")
        $col.doc("u1").set(@{ name = "Bob"; roles = @("User", "Editor") })

        # ArrayUnion: add existing ('Editor') and new ('Admin')
        $col.doc("u1").update(@{ roles = [PSLocalBase]::ArrayUnion("Editor", "Admin") })
        $u1 = $col.doc("u1").get()
        if ($u1.roles.Count -ne 3 -or -not ($u1.roles -contains "Admin")) {
            throw "ArrayUnion failed to add Admin without duplicating Editor: $(ConvertTo-Json $u1.roles -Compress)"
        }

        # ArrayRemove: remove 'Editor'
        $col.doc("u1").update(@{ roles = [PSLocalBase]::ArrayRemove("Editor") })
        $u1AfterRemove = $col.doc("u1").get()
        if ($u1AfterRemove.roles.Count -ne 2 -or ($u1AfterRemove.roles -contains "Editor")) {
            throw "ArrayRemove failed to remove Editor: $(ConvertTo-Json $u1AfterRemove.roles -Compress)"
        }

        # Hashtable descriptor syntax @{ '$arrayUnion' = @(...) }
        $col.doc("u1").update(@{ roles = @{ '$arrayUnion' = @("Auditor", "SuperUser") } })
        $u1Descriptor = $col.doc("u1").get()
        if ($u1Descriptor.roles.Count -ne 4 -or -not ($u1Descriptor.roles -contains "Auditor")) {
            throw "Hashtable '$arrayUnion' failed: $(ConvertTo-Json $u1Descriptor.roles -Compress)"
        }

        # Hashtable descriptor syntax @{ '$arrayRemove' = @(...) }
        $col.doc("u1").update(@{ roles = @{ '$arrayRemove' = @("Auditor", "User") } })
        $u1Final = $col.doc("u1").get()
        if ($u1Final.roles.Count -ne 2 -or ($u1Final.roles -contains "Auditor") -or ($u1Final.roles -contains "User")) {
            throw "Hashtable '$arrayRemove' failed: $(ConvertTo-Json $u1Final.roles -Compress)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-51: Relational .populate() Joins
# ---------------------------------------------------------------------------
Assert-Test "TC-51: Relational .populate() Joins" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $users = $db.collection("users")
        $orders = $db.collection("orders")

        $users.doc("usr_101").set(@{ name = "Sarah Connor"; tier = "VIP" })
        $users.doc("usr_102").set(@{ name = "John Connor"; tier = "Standard" })

        $orders.doc("ord_001").set(@{ customerId = "usr_101"; amount = 250.00 })
        $orders.doc("ord_002").set(@{ customerId = "usr_102"; amount = 45.50 })
        $orders.doc("ord_003").set(@{ customerId = "usr_missing"; amount = 10.00 })

        # Point lookup populate
        $popSingle = $orders.doc("ord_001").populate("customerId", "users", "customer").get()
        if ($null -eq $popSingle.customer -or $popSingle.customer.name -ne "Sarah Connor") {
            throw "Point lookup populate failed: $(ConvertTo-Json $popSingle -Compress)"
        }

        # Collection query populate with options hashtable
        $allPop = $orders.populate("customerId", @{ from = "users"; as = "customer" }).orderBy("amount", "desc").get()
        if ($allPop.Count -ne 3) {
            throw "Expected 3 populated orders, got $($allPop.Count)."
        }
        if ($allPop[0].customer.name -ne "Sarah Connor") {
            throw "First order customer should be Sarah Connor."
        }
        if ($null -ne $allPop[2].customer) {
            throw "Missing foreign key should resolve customer to null, got: $($allPop[2].customer)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-52: Compound Queries (.union() & .unionAll())
# ---------------------------------------------------------------------------
Assert-Test "TC-52: Compound Queries (.union() & .unionAll())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $cNorth = $db.collection("users_north")
        $cSouth = $db.collection("users_south")

        $cNorth.doc("1").set(@{ name = "Alice"; region = "North" })
        $cNorth.doc("2").set(@{ name = "Bob"; region = "Shared" })

        $cSouth.doc("2").set(@{ name = "Bob"; region = "Shared" })
        $cSouth.doc("3").set(@{ name = "Charlie"; region = "South" })

        # UNION (deduplicates identical key+doc)
        $qNorth = $cNorth
        $qSouth = $cSouth
        $unionRes = $qNorth.union($qSouth).get()
        if ($unionRes.Count -ne 3) {
            throw "Expected 3 distinct records from union, got $($unionRes.Count)."
        }

        # UNION ALL (preserves duplicates)
        $unionAllRes = $cNorth.unionAll($cSouth).get()
        if ($unionAllRes.Count -ne 4) {
            throw "Expected 4 records from unionAll, got $($unionAllRes.Count)."
        }

        # union count()
        $uCount = $cNorth.union($cSouth).count()
        if ($uCount -ne 3) {
            throw "Expected count() of union to be 3, got $uCount."
        }

        $uAllCount = $cNorth.unionAll($cSouth).count()
        if ($uAllCount -ne 4) {
            throw "Expected count() of unionAll to be 4, got $uAllCount."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-53: Sharded Querying via collectionGroup()
# ---------------------------------------------------------------------------
Assert-Test "TC-53: Sharded Querying via collectionGroup()" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        [void]$db.collection("audit_2026_01").add(@{ level = "WARN"; msg = "Disk warning" })
        [void]$db.collection("audit_2026_01").add(@{ level = "ERROR"; msg = "Network down" })
        [void]$db.collection("audit_2026_02").add(@{ level = "ERROR"; msg = "Database unreachable" })
        [void]$db.collection("audit_2026_02").add(@{ level = "INFO"; msg = "Service started" })
        [void]$db.collection("unrelated_table").add(@{ level = "ERROR"; msg = "Ignored" })

        $cg = $db.collectionGroup("audit_*")

        # Total count across matching collections
        $totalCount = $cg.count()
        if ($totalCount -ne 4) {
            throw "Expected 4 total records across audit_* tables, got $totalCount."
        }

        # Filtered query
        $errors = $cg.where("level", "==", "ERROR").get()
        if ($errors.Count -ne 2) {
            throw "Expected 2 ERROR records across group, got $($errors.Count)."
        }

        # Verify _collection metadata tag
        $collectionsFound = $errors | ForEach-Object { $_._collection }
        if (-not ($collectionsFound -contains "audit_2026_01") -or -not ($collectionsFound -contains "audit_2026_02")) {
            throw "Missing _collection origin property in results: $($collectionsFound -join ', ')"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-54: Atomic Upsert (.upsert())
# ---------------------------------------------------------------------------
Assert-Test "TC-54: Atomic Upsert (.upsert())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("devices")
        # 1. Insert new record via upsert
        $key1 = $col.upsert(@{ serial = "SN-1001"; status = "active"; firmware = "1.0.0" }, "dev-1")
        if ($key1 -ne "dev-1") { throw "Upsert did not return expected key." }
        $d1 = $col.doc("dev-1").get()
        if ($d1.firmware -ne "1.0.0") { throw "Upsert failed to insert document." }

        # 2. Update existing record via upsert with same key
        $key2 = $col.upsert(@{ serial = "SN-1001"; status = "maintenance"; firmware = "1.0.1" }, "dev-1")
        if ($key2 -ne "dev-1") { throw "Upsert update did not preserve key." }
        $d2 = $col.doc("dev-1").get()
        if ($d2.firmware -ne "1.0.1" -or $d2.status -ne "maintenance") {
            throw "Upsert failed to update existing document: $(ConvertTo-Json $d2 -Compress)"
        }
        if ($col.count() -ne 1) { throw "Upsert created duplicate record instead of updating." }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-55: Selective Field Projection (.select())
# ---------------------------------------------------------------------------
Assert-Test "TC-55: Selective Field Projection (.select())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("accounts")
        [void]$col.doc("acc-1").set(@{
            username = "carlos"
            email    = "carlos@example.com"
            password = "hashed_secret_password"
            profile  = @{ bio = "PowerShell Engineer"; age = 35 }
            roles    = @("Admin", "Owner")
        })

        # Select specific fields in point lookup
        $proj = $col.doc("acc-1").select("username", "email").get()
        if ($proj.username -ne "carlos" -or $proj.email -ne "carlos@example.com") {
            throw "select() failed to retrieve requested fields."
        }
        if ($null -ne $proj.password) {
            throw "select() leaked unselected 'password' field!"
        }
        if ($null -ne $proj.profile) {
            throw "select() leaked unselected 'profile' field!"
        }

        # Select in collection query
        [void]$col.doc("acc-2").set(@{ username = "ana"; email = "ana@example.com"; password = "secret" })
        $allProj = $col.select("username").orderBy("username", "asc").get()
        if ($allProj.Count -ne 2) { throw "Expected 2 projected accounts." }
        if ($allProj[0].username -ne "ana" -or $null -ne $allProj[0].password) {
            throw "Collection select() leaked unselected fields: $(ConvertTo-Json $allProj[0] -Compress)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-56: First Result Retrieval (.first())
# ---------------------------------------------------------------------------
Assert-Test "TC-56: First Result Retrieval (.first())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("logs")
        [void]$col.add(@{ level = "WARN"; msg = "Slow disk" })
        [void]$col.add(@{ level = "ERROR"; msg = "Database down"; prio = 10 })
        [void]$col.add(@{ level = "ERROR"; msg = "Out of memory"; prio = 20 })

        # first() with orderBy
        $firstErr = $col.where("level", "==", "ERROR").orderBy("prio", "desc").first()
        if ($null -eq $firstErr -or $firstErr.msg -ne "Out of memory") {
            throw "first() failed to return top matching record: $(ConvertTo-Json $firstErr -Compress)"
        }

        # first() with keys option
        $firstWithKey = $col.where("level", "==", "WARN").first(@{ keys = $true })
        if ($null -eq $firstWithKey.key -or $firstWithKey.data.msg -ne "Slow disk") {
            throw "first({ keys = true }) failed: $(ConvertTo-Json $firstWithKey -Compress)"
        }

        # first() on empty result must return $null
        $empty = $col.where("level", "==", "FATAL").first()
        if ($null -ne $empty) {
            throw "first() on empty result should return null, got: $empty"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-57: O(1) Existence Verification (.exists())
# ---------------------------------------------------------------------------
Assert-Test "TC-57: O(1) Existence Verification (.exists())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("customers")
        [void]$col.doc("c-100").set(@{ name = "Acme Corp"; active = $true; credits = 500 })

        # Point lookup exists
        if (-not $col.doc("c-100").exists()) { throw "exists() returned false for existing key c-100." }
        if ($col.doc("c-missing").exists()) { throw "exists() returned true for non-existent key." }

        # Filtered query exists
        if (-not $col.where("credits", ">", 100).exists()) { throw "exists() failed on matching filter." }
        if ($col.where("credits", ">", 1000).exists()) { throw "exists() returned true for non-matching filter." }

        # Non-existent collection returns false
        if ($db.collection("uncreated_collection").exists()) { throw "exists() on uncreated collection returned true." }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-58: Unique Values Extraction (.distinct())
# ---------------------------------------------------------------------------
Assert-Test "TC-58: Unique Values Extraction (.distinct())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("inventory")
        [void]$col.add(@{ sku = "SKU-1"; category = "Audio"; brand = "Sony" })
        [void]$col.add(@{ sku = "SKU-2"; category = "Audio"; brand = "Bose" })
        [void]$col.add(@{ sku = "SKU-3"; category = "Video"; brand = "Sony" })
        [void]$col.add(@{ sku = "SKU-4"; category = "Video"; brand = "LG" })
        [void]$col.add(@{ sku = "SKU-5"; brand = "Generic" }) # category is null

        # Distinct categories
        $cats = $col.distinct("category")
        if ($cats.Count -ne 2) { throw "Expected 2 distinct categories, got $($cats.Count)." }
        if (-not ($cats -contains "Audio") -or -not ($cats -contains "Video")) {
            throw "Distinct categories mismatch: $($cats -join ', ')"
        }

        # Distinct with filter
        $sonyCats = $col.where("brand", "==", "Sony").distinct("category")
        if ($sonyCats.Count -ne 2) { throw "Expected 2 distinct categories for Sony." }

        # Distinct brands for Audio only
        $audioBrands = $col.where("category", "==", "Audio").distinct("brand")
        if ($audioBrands.Count -ne 2 -or ($audioBrands -contains "LG")) {
            throw "Distinct brands for Audio mismatch: $($audioBrands -join ', ')"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-59: Native Mathematical Aggregations (.sum(), .avg(), .min(), .max())
# ---------------------------------------------------------------------------
Assert-Test "TC-59: Native Mathematical Aggregations (.sum(), .avg(), .min(), .max())" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("orders")
        [void]$col.add(@{ status = "paid"; amount = 100.00 })
        [void]$col.add(@{ status = "paid"; amount = 200.00 })
        [void]$col.add(@{ status = "paid"; amount = 300.00 })
        [void]$col.add(@{ status = "pending"; amount = 50.00 })

        # Aggregate on filtered query
        $paidSum = $col.where("status", "==", "paid").sum("amount")
        if ($paidSum -ne 600.0) { throw "Expected paid sum 600, got $paidSum." }

        $paidAvg = $col.where("status", "==", "paid").avg("amount")
        if ($paidAvg -ne 200.0) { throw "Expected paid avg 200, got $paidAvg." }

        # Total aggregates
        $allMin = $col.min("amount")
        $allMax = $col.max("amount")
        if ($allMin -ne 50.0) { throw "Expected min 50, got $allMin." }
        if ($allMax -ne 300.0) { throw "Expected max 300, got $allMax." }

        # Empty collection aggregations
        $emptySum = $col.where("status", "==", "cancelled").sum("amount")
        if ($emptySum -ne 0.0) { throw "Expected empty sum to be 0.0, got $emptySum." }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-60: Array Length Filtering (whereLength & length operators)
# ---------------------------------------------------------------------------
Assert-Test "TC-60: Array Length Filtering (whereLength & length operators)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("teams")
        [void]$col.add(@{ team = "Alpha"; members = @("Alice", "Bob", "Charlie") }) # len 3
        [void]$col.add(@{ team = "Beta";  members = @("Dave") })                    # len 1
        [void]$col.add(@{ team = "Gamma"; members = @("Eve", "Frank") })            # len 2
        [void]$col.add(@{ team = "Empty"; members = @() })                          # len 0

        # Exact length match
        $len2 = $col.where("members", "length", 2).get()
        if ($len2.Count -ne 1 -or $len2[0].team -ne "Gamma") {
            throw "Expected team Gamma for length 2, got: $(ConvertTo-Json $len2 -Compress)"
        }

        # whereLength helper with operator
        $largeTeams = $col.whereLength("members", ">=", 2).get()
        if ($largeTeams.Count -ne 2) {
            throw "Expected 2 large teams (>=2), got $($largeTeams.Count)."
        }

        # Empty array check (length == 0)
        $emptyTeams = $col.where("members", "length", 0).get()
        if ($emptyTeams.Count -ne 1 -or $emptyTeams[0].team -ne "Empty") {
            throw "Expected Empty team for length 0, got $($emptyTeams.Count)."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-61: Polymorphic Type Filtering (whereType & type operators)
# ---------------------------------------------------------------------------
Assert-Test "TC-61: Polymorphic Type Filtering (whereType & type operators)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("schema_test")
        [void]$col.add(@{ id = 1; config = @{ mode = "strict"; timeout = 30 } }) # object
        [void]$col.add(@{ id = 2; config = "default-string-mode" })              # text
        [void]$col.add(@{ id = 3; config = @("legacy", "compat") })             # array
        [void]$col.add(@{ id = 4; config = 42 })                                 # integer (number)

        # whereType object
        $objs = $col.whereType("config", "object").get()
        if ($objs.Count -ne 1 -or $objs[0].id -ne 1) {
            throw "Expected id 1 for object type, got $($objs.Count)."
        }

        # whereType text
        $texts = $col.where("config", "type", "text").get()
        if ($texts.Count -ne 1 -or $texts[0].id -ne 2) {
            throw "Expected id 2 for text type, got $($texts.Count)."
        }

        # whereType array
        $arrays = $col.whereType("config", "array").get()
        if ($arrays.Count -ne 1 -or $arrays[0].id -ne 3) {
            throw "Expected id 3 for array type, got $($arrays.Count)."
        }

        # whereType number
        $nums = $col.whereType("config", "number").get()
        if ($nums.Count -ne 1 -or $nums[0].id -ne 4) {
            throw "Expected id 4 for number type, got $($nums.Count)."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-62: CHECK(json_valid(doc)) Storage Constraint & .validate()
# ---------------------------------------------------------------------------
Assert-Test "TC-62: CHECK(json_valid(doc)) Storage Constraint & .validate()" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("integrity_test")
        [void]$col.create()

        # Insert healthy records
        [void]$col.doc("doc-ok").set(@{ title = "Clean Data"; count = 1 })
        if (-not $col.validate()) {
            throw "validate() should return true on clean collection."
        }

        # Attempt to insert malformed JSON string directly via SQL
        $threwCheck = $false
        try {
            $db._ExecuteDirectSql("INSERT INTO integrity_test (key, doc) VALUES ('bad-doc', '{malformed json');")
        } catch {
            $threwCheck = $true
        }
        if (-not $threwCheck) {
            throw "SQLite CHECK(json_valid(doc)) failed to block malformed JSON payload!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-63: Hardened Type Validation & SQL Injection Defense
# ---------------------------------------------------------------------------
Assert-Test "TC-63: Hardened Type Validation & SQL Injection Defense" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("sec_hardening")
        [void]$col.create()

        # 1. Invalid / Malicious types in whereType must throw ArgumentException
        $threwInjection = $false
        try {
            [void]$col.whereType("field", "text' OR 1=1 --").get()
        } catch [System.ArgumentException] {
            $threwInjection = $true
        }
        if (-not $threwInjection) {
            throw "whereType failed to reject malicious SQL injection type payload!"
        }

        # 2. Null type parameter must throw ArgumentException
        $threwNull = $false
        try {
            [void]$col.whereType("field", $null).get()
        } catch [System.ArgumentException] {
            $threwNull = $true
        }
        if (-not $threwNull) {
            throw "whereType failed to reject null type parameter!"
        }

        # 3. Direct NULL insertion into doc must violate NOT NULL constraint
        $threwNotNull = $false
        try {
            $db._ExecuteDirectSql("INSERT INTO sec_hardening (key, doc) VALUES ('null-doc', NULL);")
        } catch {
            $threwNotNull = $true
        }
        if (-not $threwNotNull) {
            throw "NOT NULL constraint on doc failed to block NULL insertion!"
        }

        # 4. _ExecuteAggregate with unauthorized function name must throw ArgumentException
        $threwAgg = $false
        try {
            [void]$col._ExecuteAggregate("DROP TABLE users; --", "price")
        } catch [System.ArgumentException] {
            $threwAgg = $true
        }
        if (-not $threwAgg) {
            throw "_ExecuteAggregate failed to reject invalid aggregate function!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-64: Criteria Resolution in Upsert & Fluent Terminal State Isolation
# ---------------------------------------------------------------------------
Assert-Test "TC-64: Criteria Resolution in Upsert & Fluent Terminal State Isolation" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("state_isolation_test")

        # 1. Upsert with hashtable criteria @{ id = 'usr-crit-1' }
        $k1 = $col.upsert(@{ id = "usr-crit-1"; name = "Alice"; tier = "Gold" })
        if ($k1 -ne "usr-crit-1") {
            throw "upsert failed to resolve key from criteria hashtable: $k1"
        }

        # 2. Upsert with PSCustomObject criteria
        $k2 = $col.upsert([PSCustomObject]@{ key = "usr-crit-2"; name = "Bob"; tier = "Silver" })
        if ($k2 -ne "usr-crit-2") {
            throw "upsert failed to resolve key from PSCustomObject criteria: $k2"
        }

        # Add 3 more items
        [void]$col.add(@{ name = "Charlie"; tier = "Bronze" })
        [void]$col.add(@{ name = "Dana"; tier = "Platinum" })
        [void]$col.add(@{ name = "Evan"; tier = "VIP" })

        # 3. Verify total count is 5
        if ($col.count() -ne 5) {
            throw "Expected 5 documents, got $($col.count())"
        }

        # 4. first() with chained limit(2) must NOT leave dangling limit on collection
        $f = $col.limit(2).first()
        if ($null -eq $f) {
            throw "first() returned null"
        }
        if ($null -ne $col.LimitValue) {
            throw "first() leaked dangling LimitValue: $($col.LimitValue)"
        }

        # 5. Subsequent get() must return all 5 items, not 2
        $allDocs = $col.get()
        if ($allDocs.Count -ne 5) {
            throw "Subsequent get() was constrained by leaked limit! Expected 5, got $($allDocs.Count)"
        }
    } finally {
        $db.close()
    }
}
# ---------------------------------------------------------------------------
# TC-65: Secondary Unique Index Abort & No Silent Deletion on Conflict (Issue #3)
# ---------------------------------------------------------------------------
Assert-Test "TC-65: Secondary Unique Index Abort & Data Loss Prevention" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("users")
        # Create a unique index on email
        $null = $col.createIndex("email", @{ unique = $true })

        # Insert first document
        $col.doc("u1").set(@{ email = "same@example.test"; name = "Alice" })
        if (-not $col.doc("u1").exists()) {
            throw "u1 was not created"
        }

        # Attempt to insert second document with identical email - must fail
        $conflictCaught = $false
        try {
            $col.doc("u2").set(@{ email = "same@example.test"; name = "Bob" })
        } catch {
            $conflictCaught = $true
            if ($_.Exception.Message -notmatch "UNIQUE constraint failed") {
                throw "Expected UNIQUE constraint failure message, got: $($_.Exception.Message)"
            }
        }
        if (-not $conflictCaught) {
            throw "Secondary UNIQUE index conflict did not throw an exception!"
        }

        # u1 must NOT have been silently deleted
        if (-not $col.doc("u1").exists()) {
            throw "u1 was silently deleted by secondary UNIQUE conflict!"
        }
        $u1 = $col.doc("u1").get()
        if ($u1.name -ne "Alice") {
            throw "u1 data was modified! Expected 'Alice', got '$($u1.name)'"
        }
        if ($col.count() -ne 1) {
            throw "Expected collection count 1, got $($col.count())"
        }

        # Valid same-key replacement must still succeed
        $col.doc("u1").set(@{ email = "same@example.test"; name = "Alice Updated" })
        $u1Updated = $col.doc("u1").get()
        if ($u1Updated.name -ne "Alice Updated") {
            throw "Same-key replacement failed! Expected 'Alice Updated', got '$($u1Updated.name)'"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-66: Strict DropIndex Field Sanitization & Anti-Injection (Issue #4)
# ---------------------------------------------------------------------------
Assert-Test "TC-66: DropIndex Field Sanitization & SQL Injection Defense" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("customers")
        $col.doc("c1").set(@{ email = "c1@test.com"; status = "active" })
        [void]$col.createIndex("email")

        # Invalid bracket injection must be rejected before reaching SQLite
        $caught = $false
        try {
            $col.dropIndex("invalid]field")
        } catch [System.ArgumentException] {
            $caught = $true
        }
        if (-not $caught) {
            throw "dropIndex failed to reject invalid bracket character in field name"
        }

        # Malicious statement termination attempt must be rejected
        $caughtPayload = $false
        try {
            $col.dropIndex("email]; DROP TABLE customers; --")
        } catch [System.ArgumentException] {
            $caughtPayload = $true
        }
        if (-not $caughtPayload) {
            throw "dropIndex failed to reject SQL injection payload"
        }

        # Customer table must remain completely intact
        if (-not $col.doc("c1").exists()) {
            throw "Customer collection was corrupted or dropped by injection attempt!"
        }

        # Valid dropIndex on existing index must succeed cleanly
        [void]$col.dropIndex("email")
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-67: View Isolation in Update (Select/Populate Decorator Immunity) (Issue #5)
# ---------------------------------------------------------------------------
Assert-Test "TC-67: View Isolation in Update (Decorator Immunity)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $users = $db.collection("users")
        $users.doc("u1").set(@{ name = "Ana"; secret = "keep_me"; n = 42 })

        # 1. Update chained with select() must NOT wipe unselected fields
        $users.doc("u1").select("name").update(@{ name = "Ana Updated" })
        $u1 = $users.doc("u1").get()
        if ($u1.name -ne "Ana Updated") {
            throw "name was not updated! Got: $($u1.name)"
        }
        if ($u1.secret -ne "keep_me") {
            throw "secret was wiped by select() update! Got: $($u1.secret)"
        }
        if ($u1.n -ne 42) {
            throw "n was wiped by select() update! Got: $($u1.n)"
        }

        # 2. Update chained with populate() must NOT overwrite foreign key with joined object
        $orders = $db.collection("orders")
        $orders.doc("o1").set(@{ userId = "u1"; amount = 100 })
        $orders.doc("o1").populate("userId", "users", "user").update(@{ amount = 250 })

        $o1 = $orders.doc("o1").get()
        if ($o1.amount -ne 250) {
            throw "amount was not updated! Got: $($o1.amount)"
        }
        if ($o1.userId -ne "u1" -or $o1.userId -isnot [string]) {
            throw "userId was overwritten with joined object! Got type: $($o1.userId.GetType().FullName)"
        }
    } finally {
        $db.close()
    }
}
# ---------------------------------------------------------------------------
# TC-68: Collision-Free Index Naming & Dynamic Uniqueness Upgrade (Issue #6)
# ---------------------------------------------------------------------------
Assert-Test "TC-68: Collision-Free Index Naming & Dynamic Uniqueness Upgrade" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("items")

        # Create index on dot notation vs underscore notation
        $null = $col.createIndex("profile.code")
        $null = $col.createIndex("profile_code", @{ unique = $true })

        # Verify both indexes exist with distinct names
        $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='items';")
        if ($indexes.Count -lt 2) {
            throw "Expected at least 2 distinct indexes on items, got $($indexes.Count)."
        }

        # Unique constraint on profile_code must reject duplicates
        $null = $col.add(@{ profile_code = "same"; profile = @{ code = "a" } }, "id1")
        $dupThrew = $false
        try {
            $col.add(@{ profile_code = "same"; profile = @{ code = "b" } }, "id2")
        } catch {
            $dupThrew = $true
        }
        if (-not $dupThrew) {
            throw "Inserting duplicate profile_code should have thrown unique constraint violation."
        }

        # Non-unique profile.code must allow duplicate values
        $col.add(@{ profile_code = "diff1"; profile = @{ code = "shared" } }, "id3")
        $col.add(@{ profile_code = "diff2"; profile = @{ code = "shared" } }, "id4")

        # Test index uniqueness upgrade on the same field
        $users = $db.collection("users")
        $null = $users.createIndex("nickname") # non-unique initially
        $null = $users.add(@{ nickname = "bob" })

        # Upgrade to UNIQUE
        $null = $users.createIndex("nickname", @{ unique = $true })
        $nickDupThrew = $false
        try {
            $null = $users.add(@{ nickname = "bob" })
        } catch {
            $nickDupThrew = $true
        }
        if (-not $nickDupThrew) {
            throw "Upgraded unique index on nickname failed to enforce uniqueness constraint."
        }

        # Cross-collection collision check: foo_bar / baz vs foo / bar_baz
        $c1 = $db.collection("foo_bar")
        $c2 = $db.collection("foo")
        $null = $c1.createIndex("baz", @{ unique = $true })
        $null = $c2.createIndex("bar_baz", @{ unique = $true })
        $allIdx = $db.query("SELECT tbl_name, name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%' AND tbl_name IN ('foo_bar', 'foo');")
        if ($allIdx.Count -ne 2) {
            throw "Cross-collection indexes collided or failed to create."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-69: ArrayUnion / ArrayRemove Structural JSON Equality (Issue #7)
# ---------------------------------------------------------------------------
Assert-Test "TC-69: ArrayUnion / ArrayRemove Structural JSON Equality" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("arrays")

        # 1. Distinct objects in ArrayUnion must both be preserved
        $col.doc("a").set(@{ items = @() })
        $col.doc("a").update(@{ items = [PSLocalBase]::ArrayUnion(@{ id = 1 }, @{ id = 2 }) })
        $docA = $col.doc("a").get()
        if ($docA.items.Count -ne 2) {
            throw "Expected 2 objects in items array, got $($docA.items.Count)."
        }

        # 2. Number 1 vs String '1' scalar type distinction
        $col.doc("b").set(@{ items = @(1, "1") })
        $col.doc("b").update(@{ items = [PSLocalBase]::ArrayRemove("1") })
        $docB = $col.doc("b").get()
        if ($docB.items.Count -ne 1) {
            throw "Expected 1 item after removing string '1', got $($docB.items.Count)."
        }
        if ($docB.items[0] -ne 1) {
            throw "Expected numeric 1 to be retained, got $($docB.items[0])."
        }

        # 3. Object removal with reordered keys
        $col.doc("c").set(@{ items = @(@{ id = 1; name = "target" }, @{ id = 2; name = "keep" }) })
        $col.doc("c").update(@{ items = [PSLocalBase]::ArrayRemove(@{ name = "target"; id = 1 }) })
        $docC = $col.doc("c").get()
        if ($docC.items.Count -ne 1 -or $docC.items[0].id -ne 2) {
            throw "Object removal with reordered keys failed. Items: $(ConvertTo-Json -InputObject $docC.items -Compress)"
        }

        # 4. Hashtable descriptor forms ($arrayUnion and $arrayRemove)
        $col.doc("d").set(@{ items = @("x") })
        $col.doc("d").update(@{ items = @{ '$arrayUnion' = @("y", "z") } })
        $docD = $col.doc("d").get()
        if ($docD.items.Count -ne 3) {
            throw "Hashtable `$arrayUnion descriptor failed to append items."
        }
        $col.doc("d").update(@{ items = @{ '$arrayRemove' = @("y") } })
        $docD2 = $col.doc("d").get()
        if ($docD2.items.Count -ne 2 -or ($docD2.items -contains "y")) {
            throw "Hashtable `$arrayRemove descriptor failed to remove item."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-70: Atomic update() on Non-Existent Document with Array Mutations (Issue #8)
# ---------------------------------------------------------------------------
Assert-Test "TC-70: Atomic update() on Non-Existent Document with Array Mutations" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $col = $db.collection("items")

        # 1. Update missing doc with ArrayUnion sentinel
        $col.doc("missing1").update(@{ tags = [PSLocalBase]::ArrayUnion("alpha", "beta") })
        $doc1 = $col.doc("missing1").get()
        if ($null -eq $doc1) { throw "Document was not created on update()." }
        if ($doc1.tags -isnot [System.Collections.IEnumerable]) {
            throw "tags is not an array! Got: $($doc1.tags)"
        }
        if ($doc1.tags.Count -ne 2) {
            throw "Expected 2 tags, got $($doc1.tags.Count)."
        }
        if ($doc1.PSObject.Properties["OpType"] -or ($doc1.tags -contains "OpType")) {
            throw "Internal sentinel leaked into persisted document."
        }

        # 2. Update missing doc with $arrayUnion descriptor
        $col.doc("missing2").update(@{ categories = @{ '$arrayUnion' = @("gadgets") } })
        $doc2 = $col.doc("missing2").get()
        if ($null -eq $doc2) { throw "Document was not created on update()." }
        if ($doc2.categories -isnot [System.Collections.IEnumerable]) {
            throw "categories is not an array! Got: $($doc2.categories)"
        }
        if ($doc2.categories.Count -ne 1 -or $doc2.categories[0] -ne "gadgets") {
            throw "Expected array ['gadgets'], got: $(ConvertTo-Json -InputObject $doc2.categories -Compress)"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-71: Composite Query Scoping, Projection, Exists and Connection Isolation (Issue #9)
# ---------------------------------------------------------------------------
Assert-Test "TC-71: Composite Query Scoping, Projection, Exists and Connection Isolation" {
    $db1 = [PSLocalBase]::new(":memory:")
    $db2 = [PSLocalBase]::new(":memory:")
    try {
        # 1. Cross-connection union rejection
        $connThrew = $false
        try {
            $null = $db1.collection("colA").unionAll($db2.collection("colB")).get()
        } catch [System.InvalidOperationException] {
            $connThrew = $true
        }
        if (-not $connThrew) {
            throw "Cross-database connection union must throw InvalidOperationException."
        }

        # 2. RHS document scoping in unionAll
        $db1.collection("a").set(@(
            @{ id = "one"; n = 1; secret = "s1" },
            @{ id = "two"; n = 2; secret = "s2" }
        ))
        $db1.collection("b").doc("three").set(@{ id = "three"; n = 3; secret = "s3" })

        $res = $db1.collection("b").unionAll($db1.collection("a").doc("one")).get()
        if ($res.Count -ne 2) {
            throw "Expected exactly 2 documents (one and three), got $($res.Count)."
        }
        $ids = @($res | ForEach-Object { $_.id })
        if ($ids -contains "two") {
            throw "RHS doc scope was ignored: document 'two' was unexpectedly returned in union."
        }

        # 3. collectionGroup projection
        $db1.collection("shard_east").add(@{ n = 10; secret = "s_east" }, "k1")
        $db1.collection("shard_west").add(@{ n = 20; secret = "s_west" }, "k2")

        $projectedShards = $db1.collectionGroup("shard_*").select("n").get()
        if ($projectedShards.Count -ne 2) {
            throw "Expected 2 shard documents, got $($projectedShards.Count)."
        }
        foreach ($item in $projectedShards) {
            if ($null -ne $item.secret) {
                throw "select('n') projection was ignored on collectionGroup! secret leaked: $($item.secret)"
            }
            if ($null -eq $item.n) {
                throw "select('n') projection did not include projected field n."
            }
        }

        # 4. union count with limit
        $pagedCount = $db1.collection("a").unionAll($db1.collection("b")).limit(1).count()
        if ($pagedCount -ne 1) {
            throw "Expected paged count of 1, got $pagedCount."
        }

        # 5. exists() on collectionGroup and union
        $groupExists = $db1.collectionGroup("shard_*").exists()
        if (-not $groupExists) {
            throw "exists() returned false on populated collectionGroup."
        }
        $unionExists = $db1.collection("a").unionAll($db1.collection("b")).exists()
        if (-not $unionExists) {
            throw "exists() returned false on populated union."
        }
    } finally {
        $db1.close()
        $db2.close()
    }
}

# ---------------------------------------------------------------------------
# TC-72: VACUUM INTO Consistent Snapshot for Concurrent WAL Mode (Issue #10)
# ---------------------------------------------------------------------------
Assert-Test "TC-72: VACUUM INTO Consistent Snapshot for Concurrent WAL Mode" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pslocalbase_snap_" + [System.Guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Path $tempDir -Force
    $srcDbPath = Join-Path $tempDir "source.db"
    $snapDbPath = Join-Path $tempDir "snapshot.db"

    try {
        $db = [PSLocalBase]::new($srcDbPath)
        $db.collection("records").add(@{ title = "Record 1"; status = "active" })
        $db.collection("records").add(@{ title = "Record 2"; status = "active" })

        # Export consistent completed snapshot
        $db.query("VACUUM INTO '$snapDbPath';")

        # Open snapshot in separate connection
        $snapDb = [PSLocalBase]::new($snapDbPath)
        try {
            $count = $snapDb.collection("records").count()
            if ($count -ne 2) {
                throw "Expected 2 records in completed snapshot, got $count."
            }
        } finally {
            $snapDb.close()
        }
        $db.close()
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# TC-73: Native Lexical & ISO Timestamp Ordering for MIN / MAX (Issue #11)
# ---------------------------------------------------------------------------
Assert-Test "TC-73: Native Lexical & ISO Timestamp Ordering for MIN / MAX" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $logs = $db.collection("audit_logs")
        $logs.doc("a").set(@{ timestamp = "2026-01-01T01:00:00Z"; code = "bravo"; score = 10 })
        $logs.doc("b").set(@{ timestamp = "2026-12-31T23:00:00Z"; code = "alpha"; score = 20 })
        $logs.doc("c").set(@{ timestamp = "2026-06-15T12:00:00Z"; code = "zeta"; score = 5 })

        # 1. max(timestamp) must return full ISO string, not numeric year
        $maxTime = $logs.max("timestamp")
        if ($maxTime -ne "2026-12-31T23:00:00Z") {
            throw "Expected '2026-12-31T23:00:00Z', got: $maxTime"
        }

        # 2. min(timestamp)
        $minTime = $logs.min("timestamp")
        if ($minTime -ne "2026-01-01T01:00:00Z") {
            throw "Expected '2026-01-01T01:00:00Z', got: $minTime"
        }

        # 3. Lexical min/max on string field
        $minCode = $logs.min("code")
        if ($minCode -ne "alpha") {
            throw "Expected lexical min 'alpha', got: $minCode"
        }
        $maxCode = $logs.max("code")
        if ($maxCode -ne "zeta") {
            throw "Expected lexical max 'zeta', got: $maxCode"
        }

        # 4. Numeric aggregation maintains numeric return
        $sumScore = $logs.sum("score")
        if ($sumScore -ne 35.0) {
            throw "Expected numeric sum 35.0, got: $sumScore"
        }
    } finally {
        $db.close()
    }
}
# ---------------------------------------------------------------------------
# TC-74: Accidental Collection Drop Defense on Ordered Mutation (Audit F01)
# ---------------------------------------------------------------------------
Assert-Test "TC-74: Accidental Collection Drop Defense on Ordered Mutation" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("users").doc("u1").set(@{ name = "Alice" })
        $rejected = $false
        try {
            $db.collection("users").orderBy("name").delete()
        } catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "delete() with orderBy() was not rejected with an exception."
        }
        if (-not $db.collectionExists("users")) {
            throw "Collection was dropped despite orderBy().delete() rejection!"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-75: Upsert Identity Auto-Provisioning & GUID Generation (Audit F02)
# ---------------------------------------------------------------------------
Assert-Test "TC-75: Upsert Identity Auto-Provisioning & GUID Generation" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $first = $db.collection("users").upsert([pscustomobject][ordered]@{ role = "reader"; name = "Alice" })
        $second = $db.collection("users").upsert([pscustomobject][ordered]@{ role = "reader"; name = "Bob" })
        $count = $db.collection("users").count()
        if ($first -eq $second) {
            throw "Two upserts without identity generated identical keys: $first"
        }
        if ($count -ne 2) {
            throw "Expected 2 documents after upserting distinct objects, got $count."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-76: Array Mutation Precision on Adjacent 64-Bit Integers (Audit F03)
# ---------------------------------------------------------------------------
Assert-Test "TC-76: Array Mutation Precision on Adjacent 64-Bit Integers" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $a = [long]9007199254740992
        $b = [long]9007199254740993
        $db.collection("items").doc("one").set(@{ ids = @($a, $b) })
        $db.collection("items").doc("one").update(@{ ids = [PSLocalBase]::ArrayRemove($a) })
        $remaining = @($db.collection("items").doc("one").get().ids)
        if ($remaining.Count -ne 1 -or $remaining[0] -ne $b) {
            throw "Expected remaining [$b], got [$($remaining -join ',')]."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-77: Case-Insensitive Collection Schema Index Resolution (Audit F04)
# ---------------------------------------------------------------------------
Assert-Test "TC-77: Case-Insensitive Collection Schema Index Resolution" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        [void]$db.collection("users").createIndex("email", @{ unique = $true })
        [void]$db.collection("USERS").dropIndex("email")
        $indexes = $db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
        if ($indexes.Count -ne 0) {
            throw "Indexes still present after dropIndex from USERS: $($indexes.name -join ',')"
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-78: Point-Lookup Scope Preservation in Composite Queries (Audit F05)
# ---------------------------------------------------------------------------
Assert-Test "TC-78: Point-Lookup Scope Preservation in Composite Queries" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("a").doc("a1").set(@{ n = 1 })
        $db.collection("b").doc("b1").set(@{ n = 2 })
        $actual = @($db.collection("a").doc("a1").union($db.collection("b")).get())
        $count = $db.collection("a").doc("a1").union($db.collection("b")).count()
        if ($actual.Count -ne 2 -or $count -ne 2) {
            throw "get returned $($actual.Count); count returned $count; expected 2 for both."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-79: Missing Branch Parameter Isolation in Composite Queries (Audit F06)
# ---------------------------------------------------------------------------
Assert-Test "TC-79: Missing Branch Parameter Isolation in Composite Queries" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("b").doc("b1").set(@{ name = "Bob" })
        $actual = @($db.collection("missing").where("name", "=", "Alice").union($db.collection("b")).get())
        if ($actual.Count -ne 1 -or $actual[0].name -ne "Bob") {
            throw "Expected surviving branch containing Bob; got $($actual.Count) rows."
        }
    } finally {
        $db.close()
    }
}

# ---------------------------------------------------------------------------
# TC-80: Array Type Enforcement for Array Operators (Audit F07)
# ---------------------------------------------------------------------------
Assert-Test "TC-80: Array Type Enforcement for Array Operators" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        $db.collection("items").doc("array").set(@{ tags = @("admin") })
        $db.collection("items").doc("scalar").set(@{ tags = "admin" })
        $db.collection("items").doc("object").set(@{ tags = @{ role = "admin" } })
        $actual = $db.collection("items").where("tags", "array-contains", "admin").get(@{ keys = $true })
        if ($actual.Count -ne 1 -or $actual[0].key -ne "array") {
            throw "Matched keys=[$($actual.key -join ',')]; expected [array]."
        }
    } finally {
        $db.close()
    }
}
# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Test Suite Completed" -ForegroundColor Cyan
Write-Host " Total Passed: $passed" -ForegroundColor Green
Write-Host " Total Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}
