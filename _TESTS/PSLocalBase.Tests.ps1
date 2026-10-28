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
# TC-21: Native Memory Reclamation (sqlite3_free)
# ---------------------------------------------------------------------------
Assert-Test "TC-21: Native Memory Reclamation (sqlite3_free)" {
    $db = [PSLocalBase]::new(":memory:")
    try {
        # Verify [WinSqlite3]::Free([IntPtr]::Zero) is a safe no-op
        [WinSqlite3]::Free([IntPtr]::Zero)

        # Trigger a direct SQL error to ensure sqlite3_free correctly executes
        $errorThrown = $false
        try {
            # Deliberately malformed SQL DDL
            $db._ExecuteDirectSql("CREATE SYNTAX ERROR TABLE ;")
        } catch {
            $errorThrown = $true
            if ($_.Exception.Message -notmatch "SQLite execution error") {
                throw "Expected SQLite execution error message, got: $($_.Exception.Message)"
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
