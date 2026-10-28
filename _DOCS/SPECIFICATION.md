# Technical Specification: PSLocalBase

## 1. Executive Summary & Scope

`PSLocalBase` is an embedded NoSQL document (Key-Value) database engine for PowerShell, inspired by the fluent API of [Localbase](https://github.com/samuk190/localbase). It provides lightweight, high-performance, and resilient structured JSON document persistence backed by an industry-standard SQLite database file (`.db`).

### Fundamental Constraint: Zero External Dependencies
* **No Third-Party Packages:** Prohibited from using NuGet packages, PowerShell Gallery modules (`System.Data.SQLite`, `Microsoft.Data.Sqlite`), or external binaries not bundled with the base operating system.
* **Native Operating System Engine:** All SQLite database interactions are executed via dynamic C# and Platform Invocation Services (P/Invoke) targeting the Windows native system library `C:\Windows\System32\winsqlite3.dll`.

---

## 2. Environment & Compatibility Requirements

* **Supported Operating Systems:**
  * Windows 10 (Build 1809+).
  * Windows 11 (all editions).
  * Windows Server 2019, 2022, 2025+.
  * Windows Preinstallation Environment (WinPE x64 with `WinPE-NetFX` and native `winsqlite3.dll` in `X:\Windows\System32`).
* **Supported PowerShell Editions:**
  * Windows PowerShell 5.1 (Desktop Edition / .NET Framework 4.x).
  * PowerShell 7.x+ (Core Edition / .NET 6+).
* **Processor Architectures:** x64 and ARM64 (resolving `winsqlite3.dll` with matching native bitness).

---

## 3. P/Invoke Interoperability Layer (`WinSqlite3`)

A static C# class is dynamically compiled using `Add-Type` utilizing Unicode UTF-16 (`CharSet.Unicode` and `*16` variants) to guarantee lossless round-trip handling of special characters, diacritics, and multi-byte emojis without memory corruption:

```csharp
using System;
using System.Runtime.InteropServices;

public class WinSqlite3 {
    public const int SQLITE_OK = 0;
    public const int SQLITE_BUSY = 5;
    public const int SQLITE_ROW = 100;
    public const int SQLITE_DONE = 101;

    public static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    // Connection lifecycle
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode)]
    public static extern int Open(string filename, out IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close")]
    public static extern int Close(IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")]
    public static extern int CloseV2(IntPtr db);

    // Command preparation and execution
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CharSet = CharSet.Unicode)]
    public static extern int Prepare(IntPtr db, string sql, int numBytes, out IntPtr stmt, IntPtr pzTail);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")]
    public static extern int Step(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")]
    public static extern int Finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_reset")]
    public static extern int Reset(IntPtr stmt);

    // Parameter binding
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_text16", CharSet = CharSet.Unicode)]
    public static extern int BindText(IntPtr stmt, int index, string val, int nLength, IntPtr destructor);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_null")]
    public static extern int BindNull(IntPtr stmt, int index);

    // Column extraction
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text16", CharSet = CharSet.Unicode)]
    public static extern IntPtr ColumnText(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_name16", CharSet = CharSet.Unicode)]
    public static extern IntPtr ColumnName(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_count")]
    public static extern int ColumnCount(IntPtr stmt);

    // Error logging and timeouts
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_errmsg16", CharSet = CharSet.Unicode)]
    public static extern IntPtr Errmsg(IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")]
    public static extern int BusyTimeout(IntPtr db, int ms);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_exec")]
    public static extern int Exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);

    // Unmanaged memory helpers
    public static string GetString(IntPtr ptr) {
        if (ptr == IntPtr.Zero) return null;
        return Marshal.PtrToStringUni(ptr);
    }

    public static string GetErrorMessage(IntPtr db) {
        if (db == IntPtr.Zero) return "Invalid SQLite database pointer (IntPtr.Zero)";
        return GetString(Errmsg(db));
    }
}
```

---

## 4. Storage Engine & Database Schema

### 4.1. Storage Configurations & PRAGMAs
* **Database Format:** Standard SQLite `.db` file on disk or `:memory:` for ephemeral in-RAM instances.
* **Mandatory Runtime PRAGMAs:**
  ```sql
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA busy_timeout = 5000;
  PRAGMA temp_store = MEMORY;
  PRAGMA cache_size = -16000;
  ```
  - **WAL (Write-Ahead Logging):** Eliminates reader/writer concurrency lock contention. Note: WAL requires shared-memory (`-shm`) locking; therefore, UNC network paths (`\\server\share`) and mapped network drives are strictly rejected to prevent silent data corruption over SMB.
  - **synchronous = NORMAL:** Maximizes throughput while retaining crash resilience.
  - **busy_timeout = 5000:** Automatically sleeps and retries up to 5,000 ms on write collisions.
  - **temp_store = MEMORY:** Performs sorting and temporary indices directly in RAM.
  - **cache_size = -16000 / configurable:** Allocates warm page cache memory (configurable via `cacheSizeMB` option).

### 4.2. Collection Schema
Each collection referenced via `.collection("name")` maps to an independent SQLite table:

```sql
CREATE TABLE IF NOT EXISTS [collection_name] (
    key TEXT PRIMARY KEY,
    doc TEXT
);
```
* `key`: Unique document identifier (custom string or 32-character GUID).
* `doc`: Compacted JSON string representation of the serialized document.

### 4.3. SQLite JSON1 Engine Integration
All NoSQL query filtering and ordering is pushed down directly into SQLite's native JSON1 engine:
* **Pushdown JSON Extraction (`json_extract`):** Powers `.where()` and `.orderBy()` clauses to evaluate properties in native C without deserializing unneeded rows into PowerShell memory.
* **Deep Path Notation:** Translates dot-separated properties (e.g. `user.address.city`) into valid JSONPath expressions (`$.user.address.city`).
* **Type Affinity Handling:** Maps PowerShell booleans (`$true`/`$false`) to SQLite JSON integer representation (`1`/`0`), supports SQL `IN` array operators, `LIKE` wildcards, and `NULL` / `NOT NULL` checks.
* **Point Lookups:** Lookups by key (`.doc('id')`) target the primary key index directly: `SELECT doc FROM [table] WHERE key = ?;`.

---

## 5. Class Architecture: `PSLocalBase`

### 5.1. Internal State Properties
* `[IntPtr]$DbHandle`: Memory pointer to the open SQLite connection.
* `[string]$FilePath`: Normalized absolute path to the database file (or `:memory:`).
* `[string]$CurrentCollection`: Currently active collection name.
* `[string]$CurrentKey`: Currently targeted document key.
* `[System.Collections.Generic.List[string]]$WhereClauses`: Accumulated SQL where filter conditions.
* `[System.Collections.Generic.List[string]]$WhereParameters`: Accumulated parameter values for binding.
* `[string]$OrderByClause`: Active SQL sorting statement.
* `[object]$LimitValue`: Maximum document count constraint.
* `[hashtable]$config`: Configuration settings (`@{ debug = $false }`).

---

### 5.2. Core Method Signatures

#### Lifecycle & Navigation
* **`PSLocalBase([string]$filePath, [hashtable]$options)` / `PSLocalBase([string]$filePath)` / `PSLocalBase()`**
  * Initializes connection, verifies directories, sets busy handlers, checks network storage boundaries, and runs startup PRAGMAs. Accepts configuration options (`cacheSizeMB`, `wal`, `depth`).
* **`[void] close()` & `[void] Dispose()`**
  * Finalizes pending statements, invokes `sqlite3_close` (with `sqlite3_close_v2` fallback), and sets `$DbHandle = [IntPtr]::Zero`.
* **`[string[]] listCollections()` / `[string[]] getCollections()`**
  * Returns an array of all active collection names found in the database.
* **`[bool] collectionExists([string]$name)`**
  * Checks whether a collection table currently exists in SQLite `sqlite_master`.
* **`[PSLocalBase] collection([string]$name)`**
  * Validates alphanumeric regex `^[a-zA-Z0-9_]+$`, sets active collection, and resets query state. Navigation is lazy: does not create empty/ghost tables in SQLite.
* **`[PSLocalBase] create()` / `[PSLocalBase] createCollection([string]$name)`**
  * Explicitly provisions the collection table in SQLite immediately, matching the counterpart `.delete()` method.
* **`[PSLocalBase] doc([object]$keyOrCriteria)`**
  * Resolves key from string, number, hashtable, or criteria object, and automatically provisions the collection table in SQLite if it does not already exist.

#### Writing
* **`[void] set([object]$data, [hashtable]$options)`**
  * On a targeted document: performs an atomic `INSERT OR REPLACE` using parameterized `?` bindings.
  * On a collection: atomically drops existing data and repopulates all records inside an ACID transaction.
* **`[string] add([object]$data, [string]$customKey = "")`**
  * Assigns `$customKey` or generates a unique 32-character GUID (`[Guid]::NewGuid().ToString("N")`), executes `.set()`, and returns the key.
* **`[void] update([object]$partialData)`**
  * Retrieves existing document, executes deep recursive merge (`_DeepMerge`), and persists the merged object. Upserts if document does not exist.

#### Querying & Filtering
* **`[PSLocalBase] where([string]$field, [string]$operator, [object]$value)`**
  * Sanitizes field path via whitelist regex `^[a-zA-Z0-9_.\[\]]+$` supporting dot navigation and array indexing (`tags[0]`, `roles[1].title`).
  * Sanitizes operators (`=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IN`).
  * Enforces parameterized query binding (`?`) for string values and dynamic placeholders for `IN`.
  * Extracts JSON fields using SQLite's native `json_extract(doc, '$.field')`.
* **`[PSLocalBase] orderBy([string]$field, [string]$direction = "asc")`**
  * Validates field whitelist and directions (`ASC`/`DESC`).
* **`[PSLocalBase] limit([int]$count)`**
  * Constrains the result set size.
* **`[PSLocalBase] skip([int]$offset)`**
  * Skips `$offset` records for offset-based query pagination (`OFFSET`).
* **`[int] count()`**
  * Returns the count of matching documents executed directly in SQL (`SELECT COUNT(*)`) with zero row deserialization in memory.
* **`[object] get([hashtable]$options)`**
  * Executes the query with bound parameters and returns single `[PSCustomObject]` (for `.doc()`) or strongly-typed array `[PSCustomObject[]]` (for `.collection()`).
  * If `$options.keys = $true`, returns objects structured as `@{ key = $k; data = $v }`.
* **`[PSCustomObject[]] query([string]$sql, [string[]]$parameters)`**
  * Executes arbitrary custom SQL (including cross-collection `JOIN`s and aggregations) with parameter binding support.

#### Deletion & Transactions
* **`[void] delete()`**
  * Deletes a targeted document, a filtered document set, or drops the entire collection table.
* **`[void] deleteDatabase()`**
  * Closes connection and physically removes `.db`, `.db-wal`, and `.db-shm` files.
* **`[void] beginTransaction()`**, **`[void] commit()`**, **`[void] rollback()`**
  * Manages native ACID transactions.

---

## 6. Acceptance Criteria Verification Matrix

The implementation is verified by an automated test suite ([_TESTS/PSLocalBase.Tests.ps1](../_TESTS/PSLocalBase.Tests.ps1)) passing 27 out of 27 tests on both PowerShell 5.1 and PowerShell 7+:

| ID | Test Category | Specification & Verification Criteria | Status |
| :--- | :--- | :--- | :---: |
| **TC-01** | **Zero Dependencies** | Imports cleanly without NuGet, external assemblies, or network access | **PASSED** |
| **TC-02** | **PSCustomObject Typing** | All queries return `[PSCustomObject]` with deep dot-notation navigation | **PASSED** |
| **TC-03** | **Unicode Integrity** | Diacritics, nested quotes, and multi-byte emojis (🚀🔥🌙) stored and retrieved losslessly | **PASSED** |
| **TC-04** | **Concurrency** | Concurrent multi-process reads and writes operate without `SQLITE_BUSY` contention | **PASSED** |
| **TC-05** | **Pointer Release** | Calling `.close()` unbinds file handles so `Remove-Item` succeeds immediately | **PASSED** |
| **TC-06** | **Auto & Custom Keys** | Generates GUIDs or accepts custom keys via `.add()` | **PASSED** |
| **TC-07** | **Deep Merge Update** | `.update()` recursively updates nested objects without clobbering existing keys | **PASSED** |
| **TC-08** | **Where Operators** | Filters booleans, numbers, strings, nulls, and `IN` lists | **PASSED** |
| **TC-09** | **Order & Limit** | Correctly sorts numeric and string fields ascending and descending with `limit` | **PASSED** |
| **TC-10** | **Get with Keys** | Supports `.get(@{ keys = $true })` returning structured `{ key, data }` items | **PASSED** |
| **TC-11** | **Collection Overwrite** | Supports `.set(@(...))` to atomically replace an entire collection | **PASSED** |
| **TC-12** | **Cascade Deletions** | Correctly deletes single docs, filtered docs, collections, and database files | **PASSED** |
| **TC-13** | **ACID Transactions** | Verifies rollback restores state and commit persists state | **PASSED** |
| **TC-14** | **Cross-Collection Queries**| Supports custom SQL queries, JOINs and aggregations across collections via `.query()` | **PASSED** |
| **TC-15** | **Code Payload Integrity** | Stores and retrieves complex scripts, quotes, regex, and newlines byte-for-byte identical | **PASSED** |
| **TC-16** | **Anti-Injection Hardening**| Parameterized query literals, identifier regex whitelisting, payload isolation | **PASSED** |
| **TC-17** | **Array Index JSONPath** | Supports JSONPath array indexing (`tags[0]`, `items[1].sku`) in `.where()` | **PASSED** |
| **TC-18** | **Native Count** | Direct SQL `.count()` on collections and filtered queries without memory load | **PASSED** |
| **TC-19** | **Pagination (Skip & Limit)**| Offset-based pagination with `.skip($n)` and `.limit($n)` | **PASSED** |
| **TC-20** | **Configurable Depth** | Deep serialization (> 10 levels) without stringification or truncation | **PASSED** |
| **TC-21** | **Native Memory Safety** | `sqlite3_free` memory reclamation on failed queries and platform gating | **PASSED** |
| **TC-22** | **Query Step Validation** | Checks return codes on `sqlite3_step` and surfaces `SQLITE_BUSY` or iteration errors | **PASSED** |
| **TC-23** | **Fluent State Isolation** | Resets `CurrentKey` across `.set()`, `.get()`, and `.update()` in `try/finally` | **PASSED** |
| **TC-24** | **WAL Path Validation** | Rejects UNC network paths (`\\server\share`) and mapped network drives | **PASSED** |
| **TC-25** | **Transaction Tracking** | Safe rollback on bulk set and error recovery without masking original exception | **PASSED** |
| **TC-26** | **Search Path & Scalar IN** | System32 DLL search path isolation, balanced field regex, and scalar/empty `IN` handling | **PASSED** |
| **TC-27** | **Explicit Collection Lifecycle** | Lazy collection navigation without ghost tables; explicit `.create()`, `.createCollection()`, and `.collectionExists()` | **PASSED** |

---

## 7. Canonical Consumption Pattern

```powershell
# Import the module
Import-Module .\PSLocalBase.psd1 -Force

# Initialize database
$db = [PSLocalBase]::new(".\enterprise.db")

# Insert explicit key document
$db.collection("users").doc("usr-100").set(@{
    name   = "Carlos Martinez"
    role   = "Lead Architect"
    active = $true
    skills = @("PowerShell", "SQLite", "Security")
})

# Insert auto-generated key document
$auditId = $db.collection("audit_events").add(@{
    action    = "DeploymentInitialized"
    user      = "usr-100"
    timestamp = (Get-Date).ToString("o")
})

# Point lookup returning PSCustomObject
$user = $db.collection("users").doc("usr-100").get()
Write-Host "User: $($user.name) | Role: $($user.role)"

# Query with JSON filtering
$activeLeads = $db.collection("users").where("active", "=", $true).where("role", "LIKE", "%Architect%").get()
$activeLeads | Format-Table name, role, active

# Orderly shutdown and handle release
$db.close()
```

### Production Resiliency Pattern

For unattended scripts or production services, encapsulation with `try / finally` guarantees immediate lock release on failure:

```powershell
$db = [PSLocalBase]::new(".\enterprise.db")
try {
    # Perform database operations
    $db.collection("jobs").add(@{ status = "Processing"; started = (Get-Date).ToString("o") })
} finally {
    # Always executed even on unhandled exceptions
    $db.close()
}
```
