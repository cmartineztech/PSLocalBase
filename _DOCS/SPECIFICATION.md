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
* **Processor Architectures:** x64 is verified in CI and local suites. ARM64 is supported by design (the native `winsqlite3.dll` of matching bitness is resolved from System32) but is not verified in CI.
* **Not supported:** Linux and macOS. Importing on a non-Windows PowerShell 7 host throws `PlatformNotSupportedException`.

---

## 3. P/Invoke Interoperability Layer (`WinSqlite3`)

A static C# class is dynamically compiled using `Add-Type` utilizing Unicode UTF-16 (`CharSet.Unicode` and `*16` variants) to guarantee lossless round-trip handling of special characters, diacritics, and multi-byte emojis without memory corruption. `InitWinSqlite3Native.ps1` compiles it as `ScriptsToProcess` because PowerShell classes need the type at parse time; the script body runs inside a script block so it leaves no variables in the caller's session.

The excerpt below shows the core binding surface. The full bridge in `InitWinSqlite3Native.ps1` additionally provides:
* `BridgeVersion` (currently `2`). `Init()` refuses to open a connection when an older bridge is already loaded in the session and asks for a PowerShell restart.
* `PSLocalBaseConnectionHandle`, a `SafeHandle` that owns each root connection and calls `sqlite3_close_v2` from its finalizer if the instance is never disposed.
* `RegisterPsLike`, which registers the `pslocalbase_like` scalar function with `SQLITE_DIRECTONLY`, so triggers and views cannot call it.
* `PrepareSingle`, which prepares the first statement of a `query()` call and reports whether another executable statement follows.
* `DbFilename` (`sqlite3_db_filename`) and `JsonNestingDepth`, used by `deleteDatabase()` and by bounded deserialization.

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

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_int64")]
    public static extern int BindInt64(IntPtr stmt, int index, long val);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_double")]
    public static extern int BindDouble(IntPtr stmt, int index, double val);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_parameter_count")]
    public static extern int BindParameterCount(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes16")]
    public static extern int ColumnBytes16(IntPtr stmt, int colIndex);

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
  PRAGMA trusted_schema = OFF;
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA busy_timeout = 5000;
  PRAGMA temp_store = MEMORY;
  PRAGMA cache_size = -16000;
  ```
  - **trusted_schema = OFF:** Triggers, views, CHECK constraints and index expressions stored in a database file may only call functions SQLite marks as innocuous, which limits what an untrusted `.db` file can execute.
  - **WAL (Write-Ahead Logging):** Eliminates reader/writer concurrency lock contention. Note: WAL requires shared-memory (`-shm`) locking; therefore, UNC network paths (`\\server\share`) and mapped network drives are strictly rejected to prevent silent data corruption over SMB.
  - **synchronous = NORMAL:** Configurable via constructor $options.synchronous (EXTRA, FULL, NORMAL, OFF), defaulting to NORMAL. Maximizes throughput while retaining crash resilience against process crashes. (Note: in WAL mode, fsync to physical platter/flash occurs primarily during checkpoints, providing complete crash-safety from application termination while optimizing disk I/O).
  - **busy_timeout = 5000:** Automatically sleeps and retries up to 5,000 ms on write collisions.
  - **temp_store = MEMORY:** Performs sorting and temporary indices directly in RAM.
  - **cache_size = -16000 / configurable:** Allocates warm page cache memory (configurable via `cacheSizeMB` option).

### 4.2. Collection Schema
Each collection referenced via `.collection("name")` maps to an independent SQLite table:

```sql
CREATE TABLE IF NOT EXISTS [collection_name] (
    key TEXT PRIMARY KEY,
    doc TEXT NOT NULL CHECK (json_valid(doc))
);
```
* `key`: Unique document identifier (custom string or 32-character GUID).
* `doc`: Compacted JSON string representation of the serialized document. `DateTime`/`DateTimeOffset` values are written as ISO-8601 UTC text; empty or case-insensitively duplicated property names are rejected before writing.
* Tables are created by the first write (`set`, `add`, `upsert`, `update`, `replaceAll`) or by `create()`. Navigation (`collection()`, `doc()`) and reads never create tables.

### 4.3. SQLite JSON1 Engine Integration
All NoSQL query filtering and ordering is pushed down directly into SQLite's native JSON1 engine:
* **Pushdown JSON Extraction (`json_extract`):** Powers `.where()` and `.orderBy()` clauses to evaluate properties in native C without deserializing unneeded rows into PowerShell memory.
* **Deep Path Notation:** Translates dot-separated properties (e.g. `user.address.city`) into valid JSONPath expressions (`$.user.address.city`).
* **Type Affinity Handling:** Maps PowerShell booleans (`$true`/`$false`) to SQLite JSON integer representation (`1`/`0`), supports SQL `IN` array operators, `LIKE` wildcards, and `NULL` / `NOT NULL` checks.
* **Point Lookups:** Lookups by key (`.doc('id')`) target the primary key index directly: `SELECT doc FROM [table] WHERE key = ?;`.

---

## 5. Class Architecture: `PSLocalBase`

### 5.1. Internal State Properties
Public surface: `[hashtable]$config`, `[string]$JournalMode` and the `InTransaction` script property (computed from `sqlite3_get_autocommit`). Everything else is `hidden`: it does not appear in `Get-Member` or default formatting and is not part of the supported API.
* `hidden [IntPtr]$DbHandle`: Memory pointer to the open SQLite connection.
* `hidden [SafeHandle]$ConnectionOwner`: Owner of the root connection; releases it on `close()` or finalization.
* `hidden [long]$HandleGeneration`: Incremented when the root opens or closes. Child instances copy it and are rejected when it no longer matches, so a stale child can never use a reused native address.
* `hidden [string]$FilePath`: Normalized absolute path to the database file (or `:memory:`). Informational only; `deleteDatabase()` asks SQLite for the real path.
* `hidden [string]$CurrentCollection`: Currently active collection name, re-validated against `\A[a-zA-Z0-9_]+\z` on every operation.
* `hidden [string]$CurrentKey`: Currently targeted document key.
* `hidden [List[string]]$WhereClauses` / `hidden [List[object]]$WhereParameters`: Accumulated SQL conditions and bound values.
* `hidden [string]$OrderByClause`: Active SQL sorting statement.
* `hidden [Nullable[int]]$LimitValue` / `hidden [Nullable[int]]$SkipValue`: Pagination constraints.
* `[hashtable]$config`: Configuration (`wal`, `synchronous`, `busyTimeout`, `cacheSizeMB`, `depth`, `maxDocumentBytes`, `maxReadDepth`, `debug`), normalized and validated in the constructor.
* `hidden [bool]$IsChildInstance` / `hidden [PSLocalBase]$ParentDb`: Collection instances attached to the root database.
* `hidden [bool]$IsComposedInUnion`: Tracks composite query membership to reject invalid nesting.

---

### 5.2. Core Method Signatures

#### Lifecycle & Navigation
* **`PSLocalBase([string]$filePath, [hashtable]$options)` / `PSLocalBase([string]$filePath)` / `PSLocalBase()`**
  * Initializes connection, verifies directories, sets busy handlers, checks network storage boundaries, and runs startup PRAGMAs. Accepts the configuration options listed in 5.1; booleans are parsed strictly and `depth` must be 1-100. An instance cannot be reopened after `close()`.
* **`New-LocalBase [-Path <string>] [-Options <hashtable>]`**
  * Exported cmdlet equivalent to `[PSLocalBase]::new($Path, $Options)`; `-Path` defaults to `:memory:`.
* **`[void] close()` & `[void] Dispose()`**
  * Releases the root connection through its `SafeHandle` (`sqlite3_close_v2`), sets `$DbHandle = [IntPtr]::Zero`, and advances `HandleGeneration` so existing child instances throw `Database connection is closed.`.
* **`[string[]] listCollections()` / `[string[]] getCollections()`**
  * Returns an array of all active collection names found in the database.
* **`[bool] collectionExists([string]$name)`**
  * Checks whether a collection table currently exists in SQLite `sqlite_master`.
* **`[PSLocalBase] collection([string]$name)`**
  * Validates `\A[a-zA-Z0-9_]+\z` (a trailing newline is rejected), sets active collection, and returns a fresh collection instance. Navigation is lazy: does not create empty/ghost tables in SQLite.
* **`[PSLocalBase] collectionGroup([string]$pattern)`**
  * Creates a sharded query across the tables matching `$pattern`, resolved each time the query runs. Rejects `.drop()`, writes, and `union()`/`unionAll()`.
* **`[PSLocalBase] create()` / `[PSLocalBase] createCollection([string]$name)`**
  * Explicitly provisions the collection table in SQLite immediately.
* **`[PSLocalBase] doc([object]$keyOrCriteria)`**
  * Resolves the key from a string or number, or from the `key`, `id` or `_key` property of a hashtable or object (other criteria throw `ArgumentException`). Creates no table.

#### Writing & Mutations
Writes never modify the query instance they are called on.
* **`[void] set([object]$data, [hashtable]$options)`**
  * On a targeted document: performs an atomic `INSERT INTO ... ON CONFLICT(key) DO UPDATE SET doc = excluded.doc;` using parameterized `?` bindings.
  * On a collection with an array: alias of `replaceAll()`.
* **`[void] replaceAll([object]$items)` / `replaceAll([object]$items, [hashtable]$options)`**
  * Atomically deletes every document and inserts `$items` inside a transaction (or a savepoint within an outer transaction). Rejected with `InvalidOperationException` when the query has `where()`, `orderBy()`, `limit()`, `skip()` or a `doc()` target.
* **`[string] add([object]$data, [string]$customKey = "")`**
  * Assigns `$customKey` or generates a unique 32-character GUID (`[Guid]::NewGuid().ToString("N")`), executes `.set()`, and returns the key.
* **`[void] update([object]$partialData)`**
  * Retrieves existing document, executes deep recursive merge (`_DeepMerge`), and persists the merged object. Supports atomic `ArrayUnion` and `ArrayRemove` with structural equality and tiny floating-point preservation below Decimal scale ($|Double| < 10^{-28}$). Upserts if document does not exist.
* **`[string] upsert([object]$data, [string]$customKey = "")`**
  * Performs an atomic single-step `INSERT INTO [collection] (key, doc) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET doc = excluded.doc;` without read-modify-write overhead. Supports auto-generated GUID or explicit custom keys.

#### Querying, Forking & Filtering
* **`[PSLocalBase] clone()` / `[PSLocalBase] fork()`**
  * Performs an isolated deep clone of the active query pipeline (where clauses, bound parameters, order by, limit, skip, projections, and populates). Enables branching queries safely without cross-query mutation.
* **`[PSLocalBase] where([string]$field, [string]$operator, [object]$value)`**
  * Returns an isolated child query instance (`clone()`) with the added condition, preserving the caller unmodified.
  * Sanitizes the (trimmed) field path via `\A[a-zA-Z0-9_]+(\[\d+\])*(\.[a-zA-Z0-9_]+(\[\d+\])*)*\z`, supporting dot navigation and array indexing (`tags[0]`, `roles[1].title`).
  * Accepts the operators `=`, `==`, `-eq`, `!=`, `<>`, `-ne`, `>`, `-gt`, `<`, `-lt`, `>=`, `-ge`, `<=`, `-le`, `LIKE`, `NOT LIKE`, `-like`, `-notlike`, `IN`, `-in`, `not-in`/`not in`/`not_in`/`-notin`, `array-contains`/`-contains`, `array-contains-any`, `length`/`array-length`/`size` (and `length>`, `length>=`, `length<`, `length<=`, `length!=` with `size` aliases), `type`/`json-type`. Anything else throws `ArgumentException`.
  * Binds every value as a parameter (`?`); `DateTime`/`DateTimeOffset` values are converted to ISO-8601 UTC text first. `IN` with a `$null` member adds `IS NULL`; `not-in` requires the field to be present and not null.
  * Extracts JSON fields using SQLite's native `json_extract(doc, '$.field')`.
* **`[PSLocalBase] whereLength([string]$field, [string]$op, [int]$expected)` / `whereLength([string]$field, [int]$count)`**
  * Returns a cloned query instance filtering documents by array size directly in SQLite C engine via `json_array_length(doc, '$.field')`. Operators: `=`, `==`, `-eq`, `!=`, `-ne`, `>`, `-gt`, `>=`, `-ge`, `<`, `-lt`, `<=`, `-le`; others throw.
* **`[PSLocalBase] whereType([string]$field, [string]$expectedType)`**
  * Returns a cloned query instance filtering documents by dynamic data type (`null`, `integer`, `real`, `text`, `array`, `object`, `true`, `false`, plus the groups `number` and `boolean`) via SQLite's `json_type(doc, '$.field')`.
* **`[PSLocalBase] select([string[]]$fields)`**
  * Returns a cloned query instance projecting only requested fields directly in SQLite using `json_object('field', json_extract(doc, '$.field'))`, drastically reducing PowerShell deserialization overhead and memory allocation.
* **`[PSLocalBase] orderBy([string]$field, [string]$direction = "asc")`**
  * Returns a cloned query instance with validated sorting direction (`ASC`/`DESC`).
* **`[PSLocalBase] limit([int]$count)`**
  * Returns a cloned query instance with constrained result set size.
* **`[PSLocalBase] skip([int]$offset)`**
  * Returns a cloned query instance skipping `$offset` records for offset-based query pagination (`OFFSET`).
* **`[PSLocalBase] populate([string]$foreignField)` / `populate([string]$foreignField, [string]$foreignCollection)` / `populate([string]$foreignField, [string]$foreignCollection, [string]$asProperty)` / `populate([string]$foreignField, [hashtable]$options)`**
  * Returns a cloned query instance that `LEFT JOIN`s `$foreignCollection` on `key = json_extract(doc, '$.<foreignField>')` and embeds the matched document as `$asProperty` (default: the field name). `$options` accepts `from` and `as`. A missing foreign collection resolves every reference to `$null`.
* **`[PSLocalBase] union([PSLocalBase]$otherQuery)` / `unionAll([PSLocalBase]$otherQuery)`**
  * Returns a new composite query instance capturing defensive clones of both branches. Mutations to either source branch after calling `union()` do not affect the composite query. Rejects nested unions, cross-connection queries and `collectionGroup()` on either side.
  * `UnionLeftQuery` and `UnionQuery` capture branch-local plans. The outer query starts with empty modifiers; subsequent filters/projection/order/pagination affect the combined result once. Projected branches preserve JSON boolean, array and object types.
  * `-like` and `-notlike` invoke a connection-local SQLite scalar function backed by the host `WildcardPattern` matcher. Arguments use explicit UTF-16 lengths, including embedded NUL. Statement auxiliary data owns the cached pattern; finalization releases its GCHandle. SQL LIKE and SQL NULL behavior are unchanged; bracket classes remain rejected.
* **`[int] count()`**
  * Returns the count of matching documents executed directly in SQL (`SELECT COUNT(*)`) with zero row deserialization in memory. Non-destructive: preserves query filter clauses for reuse.
* **`[bool] exists()`**
  * High-performance boolean check executing `SELECT 1 ... LIMIT 1` directly in SQL ($O(1)$ on indexed lookups) without loading or deserializing documents. With `skip()`/`limit()` it returns `count() -gt 0`. Non-destructive.
* **`[object] first([hashtable]$options)`**
  * Retrieves the first matching document with a `LIMIT 1` cursor on a cloned instance, returning `[PSCustomObject]` or `$null` (always `$null` after `limit(0)`). Does not mutate caller limits.
* **`[object[]] distinct([string]$field)`**
  * Extracts unique values directly from SQLite via `SELECT DISTINCT json_extract(doc, '$.field')`, returned with their SQLite types (`[long]`, `[double]`, `[string]`). Non-destructive. Explicitly rejected on composite queries (`union`/`unionAll`) and collection groups.
* **`[double] sum([string]$field)` / `[double] avg([string]$field)` / `[object] min([string]$field)` / `[object] max([string]$field)`**
  * Executes aggregate functions inside SQLite. `sum`/`avg` use only values whose `json_type` is `integer` or `real`. `min`/`max` compare those numbers and return `[long]`/`[double]`; when there are none they compare `text` values and return a string; otherwise `$null`. Non-destructive.
* **`[object] get([hashtable]$options)`**
  * Executes the query with bound parameters and returns single `[PSCustomObject]` (for `.doc()`) or strongly-typed array `[PSCustomObject[]]` (for `.collection()`). Non-destructive: leaves query state intact.
  * If `$options.keys = $true`, returns objects structured as `@{ key = $k; data = $v }`.
* **`[bool] validate()`**
  * Returns `$true` when no document in the collection is NULL or fails `json_valid(doc)` (and when the collection does not exist), `$false` otherwise.
* **`[PSCustomObject[]] query([string]$sql, [object[]]$parameters)`**
  * Executes exactly one custom SQL statement (including cross-collection `JOIN`s and aggregations) with strongly-typed parameter binding (`int64`, `double`, `string`, `null`, ISO-8601 dates) and parameter count parity enforcement. A further executable statement after the first throws.
* **`[PSLocalBase] createIndex([string]$field)` / `createIndex([string]$field, [object]$options)`**
  * Creates `CREATE [UNIQUE] INDEX idx_<collection>__<field>_<hash> ON [col] ((json_extract(doc, '$.<field>')) ASC|DESC)`. `$options` is `[bool]` (unique) or a hashtable with `unique` and `order`. Changing uniqueness replaces the index inside a savepoint.
* **`[PSLocalBase] dropIndex([string]$field)`**
  * Drops the index(es) whose definition extracts exactly `$.<field>`; the argument is a field path, not an index name.

#### Deletion & Transactions
* **`[void] delete()`**
  * Deletes a targeted document or a filtered document set. If called without target or criteria, truncates all document rows while keeping table schema and secondary indexes intact. Chained deletions with `orderBy()`, `limit()`, or `skip()` are rejected with `[System.InvalidOperationException]`.
* **`[void] drop()`**
  * Explicitly drops the collection table from SQLite (`DROP TABLE IF EXISTS [col]`). Rejected on `collectionGroup()`.
* **`[void] deleteDatabase()`**
  * Reads the real path with `sqlite3_db_filename`, closes the root connection, and removes the database file and its `-wal`, `-shm` and `-journal` files. Must be called on root instance (rejected on child collections).
* **`[void] beginTransaction()` / `beginTransaction([string]$mode)`**, **`[void] commit()`**, **`[void] rollback()`**
  * `beginTransaction()` issues `BEGIN IMMEDIATE`; `$mode` selects `immediate`, `deferred` or `exclusive`. A failed `COMMIT` leaves `InTransaction` reflecting the still-open transaction. State is tracked via `sqlite3_get_autocommit`.

---

## 6. Acceptance Criteria Verification Matrix

The core acceptance criteria below are verified by [_TESTS/PSLocalBase.Tests.ps1](../_TESTS/PSLocalBase.Tests.ps1) (83 of 83 passing on both PowerShell 5.1 and PowerShell 7+). The full runner adds 15 more suites, including the 2.0 hardening regressions, a seeded property test and a multi-process WAL test; see [_TESTS/README.md](../_TESTS/README.md).

| ID | Test Category | Specification & Verification Criteria | Status |
| :--- | :--- | :--- | :---: |
| **TC-01** | **Zero Dependencies** | Imports cleanly without NuGet, external assemblies, or network access | **PASSED** |
| **TC-02** | **PSCustomObject Typing** | All queries return `[PSCustomObject]` with deep dot-notation navigation | **PASSED** |
| **TC-03** | **Unicode Integrity** | Diacritics, nested quotes, and multi-byte emojis (🚀🔥🌙) stored and retrieved losslessly | **PASSED** |
| **TC-04** | **Cross-Connection Visibility** | Two connections to one WAL file see each other's commits (sequential; multi-process concurrency is verified by `PSLocalBase.WalMultiProcess.Tests.ps1`) | **PASSED** |
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
| **TC-28** | **Lazy Document Targeting** | Calling `.doc()` creates no table until a write; criteria key resolution via hashtable & PSCustomObject | **PASSED** |
| **TC-29** | **Collection Schema Lifecycle** | Schema introspection via `collectionExists()`, explicit `createCollection()`, drop & immediate re-creation | **PASSED** |
| **TC-30** | **Multiple Collection Isolation** | Data and index isolation across multiple collections; bulk overwrite and relational integrity | **PASSED** |
| **TC-31** | **Isolated Collection State** | Independent `$users` and `$orders` instances without shared state or cross-talk | **PASSED** |
| **TC-32** | **Accidental Drop Protection & .drop()** | Rejects `.limit().delete()` and verifies explicit `.drop()` prevents accidental data loss | **PASSED** |
| **TC-33** | **Case-Insensitive Schema Resolution** | Resolves `Users` vs `users` preserving fields via deep-merge without schema mismatch | **PASSED** |
| **TC-34** | **NUL Byte Key Defense** | Rejects `\0` in document keys to prevent truncations and unauthorized collisions | **PASSED** |
| **TC-35** | **SAVEPOINT Bulk Isolation** | Outer transaction rollback safety during partial bulk set failures via SQLite savepoints | **PASSED** |
| **TC-36** | **Safe Handle Release on Open Failure** | Prevents unmanaged handle leaks on invalid/corrupt files during constructor PRAGMAs | **PASSED** |
| **TC-37** | **Constructor Options Enforcement** | Enforces `cacheSizeMB`, `wal`, and `busyTimeout` PRAGMA settings upon database initialization | **PASSED** |
| **TC-38** | **update() Partial Merge** | A partial `update()` preserves unmodified fields and merges new ones (single connection) | **PASSED** |
| **TC-39** | **Real-Time InTransaction Ground Truth**| Direct engine synchronization via `sqlite3_get_autocommit` reflecting raw SQL BEGIN/COMMIT | **PASSED** |
| **TC-40** | **Typed Query & Clean Re-Import** | Strongly-typed columns and clean unwrapping on `set(get({keys}))` without wrapper nesting | **PASSED** |
| **TC-41** | **Orphaned Collection Defense** | Guarantees orphaned child collections throw on unmanaged handle usage after owner closure | **PASSED** |
| **TC-42** | **Cross-Edition Depth Protection** | Enforces consistent depth limit rejection across both PowerShell 5.1 and 7+ | **PASSED** |
| **TC-43** | **Paged Count Offset Subquery** | Wraps `skip()` without `limit()` into source document subquery returning accurate counts | **PASSED** |
| **TC-44** | **Typed Parameter Binding & Parity**| Strongly-typed parameter affinities (`int64`, `double`), parameter count parity, NUL preservation | **PASSED** |
| **TC-45** | **Collection-level deleteDatabase()**| Explicitly rejects global database file deletion from child collection instances | **PASSED** |
| **TC-46** | **Expression Indexing & Unique Constraints** | B-Tree expression indexes on JSON fields, unique constraint enforcement, and index dropping | **PASSED** |
| **TC-47** | **Array Operator 'array-contains'** | Native array membership testing using SQLite `json_each` for strings and numbers | **PASSED** |
| **TC-48** | **Array Operator 'array-contains-any'** | Set intersection between document arrays and query value sets via `json_each` subqueries | **PASSED** |
| **TC-49** | **'not-in' Operator & Null Safety** | Set exclusion with strict null-safety exclusion directly in SQLite SQL | **PASSED** |
| **TC-50** | **Atomic Array Mutations** | In-place atomic and idempotent `ArrayUnion` and `ArrayRemove` via static sentinels and descriptors | **PASSED** |
| **TC-51** | **Relational .populate() Joins** | Dynamic `LEFT JOIN` and `json_set` compilation resolving foreign keys without N+1 overhead | **PASSED** |
| **TC-52** | **Compound Queries (.union() / .unionAll())** | Pure SQL `UNION` (deduplication) and `UNION ALL` across collections with ordering and count | **PASSED** |
| **TC-53** | **Sharded collectionGroup()** | Wildcard multi-collection querying (`audit_*`) with automated `._collection` origin metadata | **PASSED** |
| **TC-54** | **Atomic Upsert** | Single-step atomic `INSERT ... ON CONFLICT(key) DO UPDATE` inserting or updating records | **PASSED** |
| **TC-55** | **Selective Field Projection** | Native `json_object` and `json_extract` field filtering in SQL, eliminating unselected field memory overhead | **PASSED** |
| **TC-56** | **First Result Retrieval** | Single document cursor retrieval with `LIMIT 1` returning PSCustomObject or null | **PASSED** |
| **TC-57** | **O(1) Existence Verification** | Instant boolean verification (`SELECT 1 ... LIMIT 1`) on point lookups and filtered queries | **PASSED** |
| **TC-58** | **Unique Values Extraction** | Native `SELECT DISTINCT json_extract()` leveraging B-Tree index scans for unique sets | **PASSED** |
| **TC-59** | **Mathematical Aggregations** | Direct in-engine `SUM`, `AVG`, `MIN`, and `MAX` calculations without PowerShell memory deserialization | **PASSED** |
| **TC-60** | **Array Length Filtering** | Evaluates array cardinality directly in C via SQLite's `json_array_length()` (`length`, `whereLength`) | **PASSED** |
| **TC-61** | **Polymorphic Type Filtering** | Inspects dynamic NoSQL document schemas using SQLite's `json_type()` (`type`, `whereType`) | **PASSED** |
| **TC-62** | **CHECK(json_valid(doc)) Storage Constraint**| Enforces native SQLite table-level JSON schema integrity and exposes collection `.validate()` | **PASSED** |
| **TC-63** | **Hardened Type Validation & SQL Injection Defense** | Validates allowlist types for `whereType` with parameter binding `?`, rejects malicious payloads, enforces `NOT NULL` on doc | **PASSED** |
| **TC-64** | **Criteria Resolution in Upsert & Fluent State Isolation** | Resolves keys from criteria objects in `upsert()`, prevents `first()` from leaking limits to subsequent queries | **PASSED** |
| **TC-65** | **Secondary Unique Index Abort & Data Loss Prevention** | Precludes silent deletion of unrelated documents on secondary unique conflict, targeted `ON CONFLICT(key)` | **PASSED** |
| **TC-66** | **DropIndex Field Sanitization & Anti-Injection** | Strict validation of field names in `dropIndex` preventing SQL injection and bracket escaping | **PASSED** |
| **TC-67** | **View Isolation in Update (Decorator Immunity)** | Raw document retrieval in `update()` preventing view decorators (`select`, `populate`) from corrupting stored state | **PASSED** |
| **TC-68** | **Collision-Free Index Naming & Dynamic Uniqueness Upgrade** | Deterministic 64-bit hash isolated index names and dynamic UNIQUE upgrading | **PASSED** |
| **TC-69** | **Array Mutation Structural JSON Equality** | Recursive structural equality for array elements preserving scalar types (numbers vs strings, booleans) | **PASSED** |
| **TC-70** | **Atomic update() on Non-Existent Document** | Evaluates partialData via _DeepMerge against empty document, resolving array sentinels and descriptors into arrays | **PASSED** |
| **TC-71** | **Composite Query Scoping, Projection & Connection Isolation** | Enforces connection isolation across union queries, RHS document key scoping, and projection on collectionGroup and union | **PASSED** |
| **TC-72** | **VACUUM INTO Snapshot from a Live WAL Connection** | Exports a complete, committed snapshot from an open WAL connection without losing uncheckpointed data | **PASSED** |
| **TC-73** | **Native Lexical & ISO Timestamp Ordering for MIN / MAX** | Operates directly on json_extract without casting to REAL, preserving ISO 8601 dates and lexical text ordering | **PASSED** |
| **TC-74** | **Accidental Collection Drop Defense on Ordered Mutation** | Rejects delete() chained with orderBy() preserving collection tables and indexes | **PASSED** |
| **TC-75** | **Upsert Identity Auto-Provisioning & GUID Generation** | Extracts explicit document identity (key, id, _key) or generates a unique GUID, preventing arbitrary field key derivation | **PASSED** |
| **TC-76** | **Array Mutation Precision on Adjacent 64-Bit Integers** | Direct 64-bit integer comparison in _JsonValuesEqual preserving precision for values past 2^53 | **PASSED** |
| **TC-77** | **Case-Insensitive Collection Schema Index Resolution** | Resolves collection casing via sqlite_master COLLATE NOCASE in dropIndex() | **PASSED** |
| **TC-78** | **Point-Lookup Scope Preservation in Composite Queries** | Prevents early single-document return in get() when chained with union() or collectionGroup() | **PASSED** |
| **TC-79** | **Missing Branch Parameter Isolation in Composite Queries** | Isolates query parameter bindings so non-existent collections in union queries do not cause parameter count mismatches | **PASSED** |
| **TC-80** | **Array Type Enforcement for Array Operators** | Enforces json_type = 'array' for array-contains and array-contains-any, excluding scalar and object matches | **PASSED** |
| **TC-81** | **Double/Decimal Boundary Quantization & Array Mutation Isolation** | Enforces Decimal scale resolution boundary ($|Double| < 10^{-28}$) preventing collision between Double and Decimal in ArrayUnion/ArrayRemove | **PASSED** |
| **TC-82** | **Composite Query Defensive Copy & Snapshot Isolation** | union() and unionAll() capture defensive clone snapshots; subsequent source branch mutations do not alter composed query | **PASSED** |
| **TC-83** | **Query Builder Immutability, Bifurcation & Explicit Fork** | where() and query modifiers return cloned child queries; terminal methods are non-destructive and queries are reusable | **PASSED** |

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

# Query with JSON filtering (immutable chaining)
$activeQuery = $db.collection("users").where("active", "=", $true)
$activeLeads = $activeQuery.where("role", "LIKE", "%Architect%").get()
$activeLeads | Format-Table name, role, active

# Query branching via explicit fork / clone
$activeUsers = $activeQuery.get() # Reusable! Filters were not wiped by .get()

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

### Multi-Client Reading over SMB Network Shares

SQLite's WAL mode relies on kernel shared memory (`.db-shm`), which cannot be coordinated across separate machines over SMB/CIFS. For distributed environments where multiple clients query a central database, refer to [Section 11 in the Full Documentation](README.md#11-reading-over-smb--network-shares) for the snapshot pattern: the writer exports with `VACUUM INTO`, and each reader copies the published snapshot to a local temporary path before opening it.
