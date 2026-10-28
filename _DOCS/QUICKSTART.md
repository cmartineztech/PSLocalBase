# PSLocalBase — Quick Start Guide

Welcome to the **PSLocalBase** Quick Start Guide! This document provides clear, copy-pasteable examples to get you up and running with embedded NoSQL document persistence in PowerShell in under two minutes.

---

## Table of Contents

- [Visual Explorer: Interactive GUI Playground](#visual-explorer-interactive-gui-playground)
- [1. Installation & Import](#1-installation--import)
- [2. Database Initialization](#2-database-initialization)
  - [File-Based Persistence](#file-based-persistence)
  - [In-Memory Ephemeral Database](#in-memory-ephemeral-database)
- [3. Working with Collections & Documents](#3-working-with-collections--documents)
  - [Explicit Collection Creation (`create`)](#explicit-collection-creation-create)
  - [Insert with Custom Key (`set`)](#insert-with-custom-key-set)
  - [Insert with Auto-Generated GUID (`add`)](#insert-with-auto-generated-guid-add)
  - [Bulk Insert Entire Collection](#bulk-insert-entire-collection)
  - [Partial Update / Deep Merge (`update`)](#partial-update--deep-merge-update)
- [4. Querying & Filtering](#4-querying--filtering)
  - [Point Lookups](#point-lookups)
  - [Collection-Wide Retrieval](#collection-wide-retrieval)
  - [Filtering with `where()`](#filtering-with-where)
  - [Array Index Filtering](#array-index-filtering)
  - [Counting Records (`count`)](#counting-records-count)
  - [Sorting & Pagination (`orderBy`, `skip`, `limit`)](#sorting--pagination-orderby-skip-limit)
  - [Exposing Primary Keys (`keys = $true`)](#exposing-primary-keys-keys--true)
- [5. Cross-Collection Queries (`query`)](#5-cross-collection-queries-query)
- [6. Atomic ACID Transactions](#6-atomic-acid-transactions)
- [7. Production Best Practice: `try / finally`](#7-production-best-practice-try--finally)
- [8. PowerShell Pipeline Integration](#8-powershell-pipeline-integration)

---

## Visual Explorer: Interactive GUI Playground

Prefer a visual tool to explore documents, test queries, and generate PowerShell code with one click? Launch the built-in **WPF Playground**:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1
# or
powershell.exe -ExecutionPolicy Bypass -File .\Playground\Playground.ps1
```

* **Interactive Query Builder:** Build and execute `.where()`, `.orderBy()`, `.limit()`, and `.count()` with immediate feedback.
* **Live PowerShell Code Snippets:** Copy generated PowerShell syntax directly to your clipboard.
* **Seed Demo Data:** 1-click loading of realistic users, products, and orders datasets.
* **Theme Switching:** Sleek dark and light themes with automatic Windows OS theme detection.

---

## 1. Installation & Import

PSLocalBase requires **zero external dependencies**, no NuGet packages, and no binary downloads. It uses Windows' native, pre-installed SQLite engine (`winsqlite3.dll`).

```powershell
# Import the module manifest
Import-Module .\PSLocalBase.psd1 -Force
```

Compatible with:
* **Windows PowerShell 5.1** (Desktop Edition / .NET Framework 4.x)
* **PowerShell 7.x+** (Core Edition / .NET 6+) on Windows 10, Windows 11, Windows Server 2019+, and WinPE x64.

---

## 2. Database Initialization

### File-Based Persistence
Creates or opens a SQLite database file on disk. Parent directories are created automatically if they do not exist.

```powershell
# Method A: Using the standard class constructor
$db = [PSLocalBase]::new(".\app_data.db")

# Method B: With performance & serialization tuning options
$db = [PSLocalBase]::new(".\app_data.db", @{
    cacheSizeMB = 32      # 32 MB warm page cache
    wal         = $true   # Write-Ahead Logging (default: true)
    depth       = 20      # JSON serialization depth limit
})

# Method C: Using the helper cmdlet
$db = New-LocalBase -Path ".\app_data.db"
```

### In-Memory Ephemeral Database
Lives exclusively in RAM with zero disk footprints. Ideal for testing, temporary caching, and CI/CD pipelines.

```powershell
$db = [PSLocalBase]::new(":memory:")
# Or simply:
$db = New-LocalBase
```

---

## 3. Working with Collections & Documents

Collections are created automatically upon explicitly targeting a document (`.doc()`, `.add()`), writing data, or explicitly calling `.create()`. Mere navigation via `$db.collection("name")` or read queries (`.get()`, `.count()`) are lazy and will not create empty/ghost tables in SQLite.

### Explicit Collection Creation (`create`)
If you want to pre-provision an empty collection table before inserting records:
```powershell
# Fluent chaining:
$db.collection("audit_logs").create()

# Direct method:
$db.createCollection("audit_logs")

# Check existence:
$exists = $db.collectionExists("audit_logs") # $true
```

### Insert with Custom Key (`set`)
```powershell
$db.collection("users").doc("usr-100").set(@{
    name       = "Carlos Martinez"
    role       = "Lead Architect"
    active     = $true
    department = "Engineering"
    skills     = @("PowerShell", "SQLite", "Security")
})
```

### Insert with Auto-Generated GUID (`add`)
Generates a unique 32-character GUID key and returns it.
```powershell
$logId = $db.collection("audit_logs").add(@{
    action    = "UserLogin"
    userId    = "usr-100"
    timestamp = (Get-Date).ToString("o")
})
Write-Host "Created audit record with ID: $logId"
```

### Bulk Insert Entire Collection
Atomically replaces the entire collection with an array of objects.
```powershell
$products = @(
    @{ id = "prod-1"; name = "Mechanical Keyboard"; price = 120.00; stock = 45 },
    @{ id = "prod-2"; name = "Wireless Mouse";     price = 45.50;  stock = 120 },
    @{ id = "prod-3"; name = "USB-C Hub";           price = 35.00;  stock = 80 }
)
$db.collection("products").set($products)
```

### Partial Update / Deep Merge (`update`)
Performs a deep recursive merge into the targeted document. Existing properties are preserved.
```powershell
$db.collection("users").doc("usr-100").update(@{
    role   = "Principal Architect"
    avatar = @{
        url    = "https://example.com/avatar.png"
        format = "PNG"
    }
})
```

---

## 4. Querying & Filtering

All queries return strongly-typed `[PSCustomObject]` instances supporting native dot-notation property traversal.

### Point Lookups
```powershell
$user = $db.collection("users").doc("usr-100").get()
Write-Host "Name: $($user.name) | Role: $($user.role)"
```

### Collection-Wide Retrieval
```powershell
$allUsers = $db.collection("users").get()
```

### Filtering with `where()`
Supported operators: `=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IN`.

```powershell
# 1. Filter by Boolean
$activeUsers = $db.collection("users").where("active", "=", $true).get()

# 2. Filter by Numeric Comparison
$expensive = $db.collection("products").where("price", ">=", 50.00).get()

# 3. Filter with LIKE wildcard
$keyboards = $db.collection("products").where("name", "LIKE", "%Keyboard%").get()

# 4. Filter with IN operator
$staff = $db.collection("users").where("department", "IN", @("Engineering", "DevOps")).get()

# 5. Multiple Chained Filters (AND logic)
$filtered = $db.collection("products") `
    .where("stock", ">", 50) `
    .where("price", "<", 100) `
    .get()
```

### Array Index Filtering
Target specific array elements directly using JSONPath brackets:
```powershell
# Matches users whose first skill (index 0) is "PowerShell"
$psExperts = $db.collection("users").where("skills[0]", "=", "PowerShell").get()
```

### Counting Records (`count`)
Executes directly inside SQLite using `SELECT COUNT(*)` with zero document deserialization in memory.
```powershell
# Count all records in a collection
$totalProducts = $db.collection("products").count()

# Count records matching a filter
$inStockCount = $db.collection("products").where("stock", ">", 0).count()
```

### Sorting & Pagination (`orderBy`, `skip`, `limit`)
```powershell
# Page 1: Top 2 most expensive products
$page1 = $db.collection("products").orderBy("price", "desc").limit(2).get()

# Page 2: Skip first 2, return next 2
$page2 = $db.collection("products").orderBy("price", "desc").skip(2).limit(2).get()
```

### Exposing Primary Keys (`keys = $true`)
```powershell
$itemsWithKeys = $db.collection("users").get(@{ keys = $true })
foreach ($item in $itemsWithKeys) {
    Write-Host "Primary Key: $($item.key) | Document Name: $($item.data.name)"
}
```

---

## 5. Cross-Collection Queries (`query`)

Perform relational `JOIN`s, aggregations, or group-by operations across independent collections using raw SQLite SQL:

```powershell
$sql = @"
SELECT 
    json_extract(u.doc, '$.name') AS Customer,
    json_extract(u.doc, '$.department') AS Department,
    json_extract(o.doc, '$.item') AS Product,
    CAST(json_extract(o.doc, '$.total') AS REAL) AS TotalSpent
FROM orders o
INNER JOIN users u ON json_extract(o.doc, '$.userId') = u.key
ORDER BY TotalSpent DESC;
"@

$report = $db.query($sql)
$report | Format-Table -AutoSize
```

---

## 6. Atomic ACID Transactions

Wrap multi-document mutations in atomic transactions that automatically rollback on error:

```powershell
$db.beginTransaction()
try {
    $db.collection("accounts").doc("acc-1").update(@{ balance = 400 })
    $db.collection("accounts").doc("acc-2").update(@{ balance = 600 })
    $db.commit()
    Write-Host "Transaction committed successfully!"
} catch {
    $db.rollback()
    Write-Warning "Transaction rolled back due to error: $_"
}
```

---

## 7. Production Best Practice: `try / finally`

Always encapsulate database operations in a `try / finally` block to guarantee immediate connection closure and file handle release:

```powershell
$db = [PSLocalBase]::new(".\production.db")
try {
    # Business logic here
    $db.collection("metrics").add(@{
        cpu = (Get-CimInstance Win32_Processor).LoadPercentage
        date = (Get-Date).ToString("o")
    })
} finally {
    # Guaranteed cleanup: ensures file lock release even on unhandled exceptions
    $db.close()
}
```

---

## 8. PowerShell Pipeline Integration

Because query results are native `[PSCustomObject]` arrays, you can pipe them directly into standard PowerShell cmdlets:

```powershell
# Filter and export directly to CSV
$db.collection("products").where("stock", ">", 0).get() |
    Select-Object name, price, stock |
    Export-Csv -Path ".\inventory.csv" -NoTypeInformation

# Format as an interactive GridView
$db.collection("users").get() | Out-GridView -Title "Active Users Directory"
```

---

## Need More Details?

* [Technical Architecture Specification](SPECIFICATION.md)
* [Security Policy & Threat Model](../SECURITY.md)
* [Main Project README](../README.md)
