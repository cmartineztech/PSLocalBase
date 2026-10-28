# PSLocalBase

[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue.svg)](https://microsoft.com/powershell)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)](#zero-dependencies-guarantee)
[![Tests: 26 Passed](https://img.shields.io/badge/Tests-26%20Passed-success.svg)](#test-suite--quality-verification)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **PSLocalBase** is a lightning-fast, zero-dependency embedded **NoSQL Document Database Engine** for PowerShell, inspired by [Localbase](https://github.com/samuk190/localbase) and Firebase Firestore.
>
> It combines the schema flexibility and fluent developer experience of a modern NoSQL Document Store with the rock-solid ACID durability, sub-millisecond query performance, and Write-Ahead Logging (WAL) of Windows' native, pre-installed SQLite engine (`winsqlite3.dll`) using built-in SQLite JSON capabilities.

---

## Highlights

- 🚀 **Embedded NoSQL on Native SQLite3:** Store arbitrary, schemaless JSON documents in collections without writing SQL, creating schemas, or running migrations.
- ⚡ **Zero Overhead & Sub-Millisecond Speed:** Direct in-memory P/Invoke bindings to `C:\Windows\System32\winsqlite3.dll` with pushdown filtering via SQLite's compiled C `json_extract()`. No CLI wrapper processes, no ODBC overhead, no external NuGet packages.
- 💎 **Pure PowerShell Objects (`[PSCustomObject]`):** Queries deserialize directly into native PowerShell objects. Access nested properties using standard dot syntax (`$doc.address.city`), and pipe seamlessly to `Where-Object`, `Select-Object`, `Format-Table`, or `Export-Csv`.
- 📦 **First-Class Array & JSONPath Support:** Store simple arrays (`@('powershell', 'cloud')`) or arrays of complex nested objects. Query by array index (`.where('tags[0]', '=', 'powershell')` or `.where('roles[1].title', '=', 'Architect')`) and perform bulk operations atomically.
- 🛡️ **Zero Dependencies Guarantee:** 100% self-contained. Pre-installed out of the box on Windows 10 (Build 1809+), Windows 11, and Windows Server 2019+.
- 🖥️ **Interactive WPF Playground (`PSLocalBase | Playground v1.0.0`):** Full dual-pane desktop GUI with Dark/Light mode, searchable Database Explorer, selectable RichTextBox console, and live code execution.

---

## Table of Contents

- [Zero Dependencies Guarantee](#zero-dependencies-guarantee)
- [How It Works: NoSQL on SQLite3 JSON](#how-it-works-nosql-on-sqlite3-json)
- [Interactive GUI Playground (WPF)](#interactive-gui-playground-wpf)
- [System Requirements & Compatibility](#system-requirements--compatibility)
- [Quick Start](#quick-start)
- [Core API Reference](#core-api-reference)
  - [Initialization](#initialization)
  - [Collections & Documents](#collections--documents)
  - [Writing Data (`set`, `add`, `update`)](#writing-data-set-add-update)
  - [Working with Arrays & Nested Objects](#working-with-arrays--nested-objects)
  - [Querying & Filtering (`get`, `where`, `orderBy`, `limit`, `skip`, `count`)](#querying--filtering-get-where-orderby-limit-skip-count)
  - [Cross-Collection SQL Queries (`query`)](#cross-collection-sql-queries-query)
  - [Deleting Data (`delete`, `deleteDatabase`)](#deleting-data-delete-deletedatabase)
  - [ACID Transactions](#acid-transactions)
  - [Resource Cleanup & Disposal](#resource-cleanup--disposal)
  - [Production Best Practices & Crash Resilience](#production-best-practices--crash-resilience)
- [Test Suite & Quality Verification](#test-suite--quality-verification)
- [Architecture & Performance](#architecture--performance)
- [Author & License](#author)

---

## How It Works: NoSQL on SQLite3 JSON

PSLocalBase applies the same high-performance architectural pattern found in engines like **PostgreSQL (`jsonb`)** and **Azure Cosmos DB**: a relational storage engine running in WAL mode with a document-oriented abstraction layer powered by native JSON functions.

### The Document Table
Each collection is an isolated table with an optimized primary key B-Tree index:

```sql
CREATE TABLE IF NOT EXISTS [collection_name] (
    key  TEXT PRIMARY KEY,
    doc  TEXT NOT NULL
);
```

### Transparent Pushdown Execution
When you call fluent NoSQL methods in PowerShell, PSLocalBase compiles them directly into parameterized SQLite statements utilizing native `json_extract()`:

| PowerShell Fluent API | Internal SQLite3 Pushdown Execution |
|---|---|
| `$db.collection('users').get()` | `SELECT doc FROM [users]` |
| `$db.collection('users').doc('u100').get()` | `SELECT doc FROM [users] WHERE key = @k` |
| `$db.collection('users').where('age', '>=', 30)` | `... WHERE json_extract(doc, '$.age') >= 30` |
| `$db.collection('users').where('address.city', '=', 'Madrid')` | `... WHERE json_extract(doc, '$.address.city') = 'Madrid'` |
| `$db.collection('users').where('tags[0]', '=', 'powershell')` | `... WHERE json_extract(doc, '$.tags[0]') = 'powershell'` |
| `$db.collection('users').orderBy('price', 'desc')` | `... ORDER BY json_extract(doc, '$.price') DESC` |

Because SQLite's `json_extract()` is written in compiled native C, filtering occurs inside the SQLite engine before rows are loaded into PowerShell memory, eliminating deserialization overhead for unneeded records.

---

## Interactive GUI Playground (WPF)

PSLocalBase includes a modern, enterprise desktop GUI (`Playground.ps1`) built with native PowerShell and WPF:

```powershell
# Launch in PowerShell 7+ (Core):
pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1

# Or in Windows PowerShell 5.1:
powershell.exe -ExecutionPolicy Bypass -File .\Playground\Playground.ps1

# Launch directly in Dark Mode:
pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1 -DarkMode
```

### Playground Features:
* 🎨 **`PSLocalBase | Playground v1.0.0` Design System:** Clean Windows enterprise design inspired by `LiteDeploy.DynamicDrivers`.
* 🌓 **Full Dark Mode & Light Mode:** Seamless live theme toggling with automatic Windows OS theme preference detection.
* 🔽 **DynamicDrivers ComboBoxes:** High-contrast custom dropdowns with crisp SVG chevrons and guaranteed text contrast.
* 📜 **Fully Selectable Console Output:** RichTextBox `FlowDocument` viewer allowing continuous multi-line mouse selection, drag highlighting, and native `Ctrl+C` copying.
* 🗄️ **Database Explorer Toolbar:** Two-row responsive toolbar with collection switching, 240px real-time search, refresh, document inspection on double-click, and record deletion.
* 🔗 **Multiline Method Chaining:** Code runner supports clean method chaining across lines and auto-normalizes leading dots (`.where().orderBy().get()`).
* 💾 **Session State Persistence:** Remembers your changes, deletions, and additions across sessions. Automatically checkpoints the WAL log on close (`PRAGMA wal_checkpoint(TRUNCATE)`) and avoids auto-reseeding over user data.

---

## Zero Dependencies Guarantee

- **No NuGet / PSGallery Dependencies:** Does not depend on `System.Data.SQLite`, `Microsoft.Data.Sqlite`, or external executables.
- **Native OS Engine:** Calls `C:\Windows\System32\winsqlite3.dll` via dynamic C# P/Invoke compiled in memory with `Add-Type`.
- **Pure Unicode UTF-16:** Guaranteed non-corrupt storage and retrieval of special characters, international accents, nested quotes, and multi-byte emojis (🚀🔥🌙).
- **System32 DLL Isolation:** Applies `[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]` to prevent DLL search-order hijacking.

---

## System Requirements & Compatibility

| Requirement | Supported Environments |
| :--- | :--- |
| **Operating System** | Windows 10 (Build 1809+), Windows 11 (all editions), Windows Server 2019+, Windows PE x64 (with `WinPE-NetFX` and native `winsqlite3.dll`) |
| **PowerShell Editions** | Windows PowerShell 5.1 (Desktop / .NET Framework 4.x), PowerShell 7.x+ (Core / .NET 6+) |
| **Processor Architectures** | x64 and ARM64 (utilizing the native OS bitness of `winsqlite3.dll`) |

---

## Quick Start

```powershell
# 1. Import the module
Import-Module .\PSLocalBase.psd1 -Force

# 2. Initialize database (disk file or in-memory)
$db = [PSLocalBase]::new(".\my_database.db")

# 3. Insert documents (schemaless objects or hashtables)
$db.collection("users").doc("usr-100").set(@{
    name   = "Carlos Martinez"
    role   = "Admin"
    active = $true
    skills = @("PowerShell", "SQLite", "Cloud")
})

# 4. Read back single document as [PSCustomObject]
$user = $db.collection("users").doc("usr-100").get()
Write-Host "Name: $($user.name) | Role: $($user.role) | Active: $($user.active)"
Write-Host "Primary skill: $($user.skills[0])"

# 5. Query collection with filtering and ordering
$admins = $db.collection("users").
    where("role", "=", "Admin").
    orderBy("name", "asc").
    get()

# Seamless pipeline integration:
$admins | Format-Table name, role, active

# 6. Clean close
$db.close()
```

---

## Core API Reference

### Initialization

#### Standard File-Based Database
```powershell
$db = [PSLocalBase]::new("C:\Data\app.db")
# Or with options hashtable:
$db = [PSLocalBase]::new("C:\Data\app.db", @{
    cacheSizeMB = 32
    wal         = $true
    depth       = 20
})
# Or using the helper cmdlet:
$db = New-LocalBase -Path "C:\Data\app.db"
```
* Configures Write-Ahead Logging (`WAL`) mode, `synchronous = NORMAL`, and a 5000ms `busy_timeout`.
* Rejects unsafe UNC network paths (`\\server\share`) to prevent SMB shared-memory corruption.

#### In-Memory Database
```powershell
$db = [PSLocalBase]::new(":memory:")
# Or:
$db = New-LocalBase
```

---

### Collections & Documents

#### `collection([string]$name)`
Navigates to a collection (SQLite table). Alphanumeric characters and underscores (`^[a-zA-Z0-9_]+$`) are supported. Automatically creates the collection table if it does not exist.
```powershell
$db.collection("orders")
```

#### `doc([object]$keyOrCriteria)`
Targets a specific document by its key or an object/hashtable criteria.
```powershell
# By string key
$db.collection("orders").doc("ord-001")

# By criteria hashtable
$db.collection("orders").doc(@{ id = "ord-001" })
```

#### `listCollections()` / `getCollections()`
Retrieves an array of all collection names present in the database.
```powershell
$collections = $db.listCollections()
# Returns: @("orders", "users", "products")
```

---

### Writing Data (`set`, `add`, `update`, `insert`)

#### `set([object]$data, [hashtable]$options)`
* **On a Document:** Overwrites or creates the targeted document.
  ```powershell
  $db.collection("products").doc("p1").set(@{
      name  = "Mechanical Keyboard"
      price = 120.00
      stock = 45
  })
  ```
* **On a Collection (Bulk Overwrite):** Replaces the entire collection atomically with an array of objects within an ACID transaction.
  ```powershell
  $items = @(
      @{ id = "1"; name = "Item One"; price = 19.99 },
      @{ id = "2"; name = "Item Two"; price = 29.99 }
  )
  $db.collection("products").set($items)
  ```

#### `add([object]$data, [string]$customKey = "")` / `insert([object]$data)`
Generates a unique 32-character GUID (or uses `$customKey` if supplied), saves the document, and returns the key.
```powershell
$genKey = $db.collection("audit_logs").add(@{
    action    = "UserLogin"
    timestamp = (Get-Date).ToString("o")
})
Write-Host "Generated audit record key: $genKey"
```

#### `update([object]$partialData)`
Performs a deep, recursive merge into the existing document. Unspecified fields remain untouched.
```powershell
$db.collection("users").doc("usr-100").update(@{
    profile = @{
        avatarUrl = "https://example.com/avatar.png"
    }
})
```

---

### Working with Arrays & Nested Objects

PSLocalBase provides first-class support for arrays and nested document structures:

```powershell
# Store complex nested data with arrays
$db.collection("developers").doc("dev-1").set(@{
    name  = "Carlos"
    tags  = @("powershell", "systems", "cloud")
    roles = @(
        @{ title = "Architect"; primary = $true },
        @{ title = "Auditor";   primary = $false }
    )
})

# 1. Filter by top-level array index:
$devs = $db.collection("developers").where("tags[0]", "=", "powershell").get()

# 2. Filter by nested property inside an array of objects:
$auditors = $db.collection("developers").where("roles[1].title", "=", "Auditor").get()

# 3. Access returned data natively via standard dot syntax:
Write-Host $auditors[0].roles[1].title  # "Auditor"
Write-Host $auditors[0].tags[2]         # "cloud"
```

---

### Querying & Filtering (`get`, `where`, `orderBy`, `limit`, `skip`, `count`)

#### `where([string]$field, [string]$operator, [object]$value)`
Filters documents using SQLite's native `json_extract`. Conditions can be chained together.

**Supported Operators:**
- **Equality:** `=`, `==`, `-eq`
- **Inequality:** `!=`, `<>`, `-ne`
- **Comparisons:** `>`, `<`, `>=`, `<=`, `-gt`, `-lt`, `-ge`, `-le`
- **Pattern Matching:** `LIKE`, `-like`, `NOT LIKE`, `-notlike`
- **Membership:** `IN`, `-in`

```powershell
# Boolean filter
$activeUsers = $db.collection("users").where("active", "=", $true).get()

# Numeric comparison
$expensive = $db.collection("products").where("price", ">=", 100).get()

# IN membership filter
$filtered = $db.collection("users").where("role", "IN", @("Admin", "Manager")).get()

# Multiple chained filters (AND) with multiline syntax
$result = $db.collection("products").
    where("category", "=", "Electronics").
    where("price", "<", 500).
    get()
```

#### `orderBy([string]$field, [string]$direction = "asc")`
Sorts results by any JSON property (ascending or descending) inside SQLite before returning.
```powershell
$sorted = $db.collection("products").orderBy("price", "desc").get()
```

#### `limit([int]$count)`
Restricts the maximum number of documents returned.
```powershell
$top3 = $db.collection("products").orderBy("price", "desc").limit(3).get()
```

#### `skip([int]$offset)`
Skips the specified number of records for offset-based pagination.
```powershell
# Page 2 (skip first 10, return next 10)
$page2 = $db.collection("products").orderBy("price", "asc").skip(10).limit(10).get()
```

#### `count()`
Returns the total document count directly in SQL without loading rows into PowerShell memory.
```powershell
# Total count in collection
$total = $db.collection("users").count()

# Filtered count
$activeAdmins = $db.collection("users").
    where("active", "=", $true).
    where("role", "=", "Admin").
    count()
```

#### `get([hashtable]$options)`
Executes the query and returns data deserialized as native `[PSCustomObject]` instances.
```powershell
# Standard retrieval (array of PSCustomObjects)
$docs = $db.collection("users").get()

# With document keys exposed ({ key, data })
$itemsWithKeys = $db.collection("users").get(@{ keys = $true })
foreach ($item in $itemsWithKeys) {
    Write-Host "Key: $($item.key) | User: $($item.data.name)"
}
```

---

### Cross-Collection SQL Queries (`query`)

Perform relational `JOIN`s, aggregations (`COUNT`, `SUM`), or complex multi-table queries across independent collections:

```powershell
$sql = @'
SELECT 
    json_extract(u.doc, '$.name') AS Customer,
    json_extract(u.doc, '$.department') AS Department,
    json_extract(o.doc, '$.item') AS ItemPurchased,
    CAST(json_extract(o.doc, '$.price') AS REAL) AS Amount
FROM orders o
INNER JOIN users u ON json_extract(o.doc, '$.userId') = u.key
ORDER BY Amount DESC;
'@

$report = $db.query($sql)
$report | Format-Table -AutoSize
```

---

### Deleting Data (`delete`, `deleteDatabase`)

#### Deleting a Document
```powershell
$db.collection("users").doc("usr-100").delete()
```

#### Deleting Filtered Documents
```powershell
$db.collection("logs").where("level", "=", "DEBUG").delete()
```

#### Deleting an Entire Collection
```powershell
$db.collection("temporary_data").delete()
```

#### Deleting the Entire Database File
Closes all connections and safely deletes the database file, along with any active `.db-wal` and `.db-shm` files:
```powershell
$db.deleteDatabase()
```

---

### ACID Transactions

Wrap multi-document operations in high-performance atomic transactions:

```powershell
$db.beginTransaction()
try {
    $db.collection("accounts").doc("acc-1").update(@{ balance = 400 })
    $db.collection("accounts").doc("acc-2").update(@{ balance = 600 })
    $db.commit()
} catch {
    $db.rollback()
    throw
}
```

---

### Resource Cleanup & Disposal

#### `close()`
Flushes pending WAL entries and releases native unmanaged handles immediately so disk files can be safely moved, backed up, or removed without file locking issues:
```powershell
$db.close()
```

#### `Dispose()`
Implements `System.IDisposable` for deterministic cleanup.

---

### Production Best Practices & Crash Resilience

#### Guaranteed Cleanup with `try / finally`

When writing production scripts or automation pipelines, encapsulate operations in a `try / finally` block. The `finally` block is guaranteed by PowerShell to execute even if an unhandled error aborts the script:

```powershell
$db = [PSLocalBase]::new(".\production.db")
try {
    $db.collection("sales").add(@{
        amount = 1500
        date   = (Get-Date).ToString("o")
    })
} finally {
    $db.close()
}
```

#### What Happens if a Script Crashes Without Calling `.close()`?
* **Data Integrity & Zero Corruption:** PSLocalBase operates in SQLite's Write-Ahead Logging (`WAL`) mode with full ACID compliance. If a script crashes mid-execution, any uncommitted transaction is safely discarded by the engine. The database file will **never** be corrupted.
* **Process Exit Cleanup:** When a PowerShell process terminates (e.g. running via `pwsh -File script.ps1`, GitHub Actions, or Windows Scheduled Tasks), the Windows kernel automatically reclaims all unmanaged handles and closes all file descriptors.
* **Interactive Sessions:** If a script fails inside an interactive session, the handle remains bound to that session's variable until closed. Simply invoke `$db.close()` or close the terminal window to release the file lock.

---

## Test Suite & Quality Verification

PSLocalBase includes a fully automated test suite (`_TESTS/PSLocalBase.Tests.ps1`) covering 26 comprehensive test cases:

```powershell
# Run in Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1

# Run in PowerShell 7+ (Core)
pwsh -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1

# Verify the interactive GUI Playground
pwsh -ExecutionPolicy Bypass -File .\Playground\verify-playground.ps1
```

### Verified Acceptance Criteria (26/26 Passed)

| Test ID | Test Category | Validation Criteria | Status |
| :--- | :--- | :--- | :---: |
| **TC-01** | **Zero Dependencies** | Imports cleanly in clean PS 5.1 & PS 7+ hosts without missing assembly errors | **PASSED** |
| **TC-02** | **PSCustomObject Typing** | All queries return `[PSCustomObject]` supporting nested dot navigation (`$obj.a.b`) | **PASSED** |
| **TC-03** | **Unicode Integrity** | Stores and retrieves accents, quotes, and multi-byte emojis (🚀🔥🌙) identically | **PASSED** |
| **TC-04** | **Concurrency** | Multiple concurrent connections read/write simultaneously via WAL + busy_timeout | **PASSED** |
| **TC-05** | **Pointer Release** | Calling `.close()` unbinds file handles so `Remove-Item` succeeds immediately | **PASSED** |
| **TC-06** | **Auto & Custom Keys** | Auto-generates GUIDs or accepts custom keys via `.add()` | **PASSED** |
| **TC-07** | **Deep Merge Update** | `.update()` recursively updates nested objects without clobbering existing keys | **PASSED** |
| **TC-08** | **Where Operators** | Filters booleans, numbers, strings, nulls, and `IN` lists | **PASSED** |
| **TC-09** | **Order & Limit** | Correctly sorts numeric and string fields ascending and descending with `limit` | **PASSED** |
| **TC-10** | **Get with Keys** | Supports `.get(@{ keys = $true })` returning structured `{ key, data }` items | **PASSED** |
| **TC-11** | **Collection Overwrite** | Supports `.set(@(...))` to atomically replace an entire collection | **PASSED** |
| **TC-12** | **Cascade Deletions** | Correctly deletes single docs, filtered docs, collections, and database files | **PASSED** |
| **TC-13** | **ACID Transactions** | Verifies rollback restores state and commit persists state | **PASSED** |
| **TC-14** | **Cross-Collection Queries** | Supports custom SQL queries, JOINs and aggregations across collections via `.query()` | **PASSED** |
| **TC-15** | **Code Payload Integrity** | Stores and retrieves complex scripts, quotes, regex, and newlines byte-for-byte identical | **PASSED** |
| **TC-16** | **Anti-Injection Hardening** | Parameterized query literals, identifier regex whitelisting, payload isolation | **PASSED** |
| **TC-17** | **Array Index JSONPath** | Supports JSONPath array indexing (`tags[0]`, `items[1].sku`) in `.where()` | **PASSED** |
| **TC-18** | **Native Count** | Direct SQL `.count()` on collections and filtered queries without memory load | **PASSED** |
| **TC-19** | **Pagination (Skip & Limit)**| Offset-based pagination with `.skip($n)` and `.limit($n)` | **PASSED** |
| **TC-20** | **Configurable Depth** | Deep serialization (> 10 levels) without stringification or truncation | **PASSED** |
| **TC-21** | **Native Memory Safety** | `sqlite3_free` memory reclamation on failed queries and UTF-8 error buffer marshalling | **PASSED** |
| **TC-22** | **Query Step Validation** | Checks return codes on `sqlite3_step` and surfaces `SQLITE_BUSY` or iteration errors | **PASSED** |
| **TC-23** | **Fluent State Isolation** | Resets `CurrentKey` across `.set()`, `.get()`, and `.update()` in `try/finally` | **PASSED** |
| **TC-24** | **WAL Path Validation** | Rejects UNC network paths (`\\server\share`) and mapped network drives | **PASSED** |
| **TC-25** | **Transaction Tracking** | Safe rollback on bulk set and error recovery without masking original exception | **PASSED** |
| **TC-26** | **Search Path & Scalar IN** | System32 DLL search path isolation, balanced field regex, and scalar/empty `IN` handling | **PASSED** |

---

## Architecture & Performance

```
+-------------------------------------------------------------+
|                      PowerShell Host                        |
|   (Windows PowerShell 5.1 Desktop  /  PowerShell 7+ Core)   |
+-------------------------------------------------------------+
                              |
                     [PSLocalBase] Class
       (Fluent API: collection, doc, set, add, update, get)
                              |
                   WinSqlite3 Interop Layer
          (P/Invoke C# with Unicode UTF-16 Bindings)
                              |
                C:\Windows\System32\winsqlite3.dll
             (Zero Dependencies Native Windows SQLite)
                              |
           +-------------------+-------------------+
           |                                       |
     [database.db]                     [database.db-wal]
   Standard SQLite DB                 Write-Ahead Logging
 (Key-Value JSON Store)              (Non-Blocking Read/Write)
```

### Native SQLite 3 & NoSQL Architecture Highlights

1. **Embedded NoSQL Document Model:**
   * **Isolated Collection Tables:** Every collection is an isolated table structured as `(key TEXT PRIMARY KEY, doc TEXT)`.
   * **Zero Schema Overhead:** Documents are stored as standard JSON payloads, allowing arbitrary schema evolution without migrations.
   * **Instant Key Access:** Single document queries (`.doc("id").get()`) leverage SQLite's B-Tree primary key index for $O(1)$ / $O(\log N)$ sub-millisecond retrieval.

2. **SQLite JSON Engine (`json_extract`):**
   * **Pushdown Query Execution:** Filters created with `.where()` evaluate properties inside the SQLite engine via `json_extract(doc, '$.field')`, completely bypassing the overhead of deserializing unneeded rows into PowerShell memory.
   * **Deep Path Resolution:** Full support for nested properties (e.g. `.where("billing.address.city", "=", "Miami")`).
   * **Direct JSON Sorting:** `.orderBy("price", "desc")` executes in native C via `ORDER BY json_extract(...)`.
   * **Array & Type-Aware Evaluations:** Translates PowerShell booleans (`$true`/`$false`) to SQLite JSON integer representations (`1`/`0`), supports SQL `IN` array operators, array indexing (`items[0]`), string `LIKE` wildcards, and `NULL` checks.

3. **Native Concurrency & PRAGMA Tuning:**
   * **`PRAGMA journal_mode = WAL;`** Activates Write-Ahead Logging. Readers never block writers, and writers never block readers across processes.
   * **`PRAGMA synchronous = NORMAL;`** Optimizes I/O throughput by eliminating redundant disk sync flushes while maintaining complete ACID crash-safety.
   * **`PRAGMA busy_timeout = 5000;`** Automatically waits up to 5,000 milliseconds when multiple threads or processes write concurrently, avoiding `SQLITE_BUSY` errors.
   * **`PRAGMA cache_size = -32000;`** Reserves a 32 MB in-memory page cache for high-throughput query execution.

4. **Low-Level C UTF-16 Interoperability:**
   * Interacts directly with `C:\Windows\System32\winsqlite3.dll` via UTF-16 APIs (`sqlite3_open16`, `sqlite3_prepare16_v2`, `sqlite3_bind_text16`, `sqlite3_column_text16`, `sqlite3_errmsg16`).
   * 100% immune to ANSI/UTF-8 conversion data corruption or multi-byte emoji truncation.
   * Fully parameterized SQL queries prevent SQL injection attacks.

---

## Author

Created and maintained by **Carlos Martinez** ([@cmartineztech](https://github.com/cmartineztech)).

---

## License

This project is licensed under the [MIT License](LICENSE) - see the [LICENSE](LICENSE) file for details.
