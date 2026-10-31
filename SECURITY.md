# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.0.x   | :white_check_mark: |
| 1.0.x   | :x: (upgrade to 2.0; see [CHANGELOG.md](CHANGELOG.md)) |

---

## Threat Model & Scope

**PSLocalBase** is an in-process, embedded document database engine designed for local PowerShell execution on Windows. 

- **Local Execution Boundary:** PSLocalBase runs entirely inside the caller's PowerShell process and communicates with Windows' native `C:\Windows\System32\winsqlite3.dll`. It does not expose network ports, sockets, or remote listening endpoints.
- **Operating System Access Control (ACL):** Physical file access security is governed by the host operating system's NTFS permissions and user Access Control Lists (ACLs). Documents are stored as plaintext JSON; there is no encryption at rest.
- **Trusted callers:** Any code running in the same PowerShell process can use the full API, including `query()`. PSLocalBase is not a security boundary between scripts in one process.
- **Untrusted database files:** Opening a `.db` file you did not create is supported with the defenses in section 16, but treat such files with care: they can still contain arbitrary data and schema.

---

## Defensive Security Architecture

### 1. Zero External Dependencies & System32 Search Path Isolation
- Relies exclusively on `winsqlite3.dll`, a trusted native Windows system binary maintained and patched directly by Microsoft via Windows Update.
- Eliminates software supply chain risks associated with third-party NuGet packages, external binaries, or unsigned dependencies.
- Enforces assembly-level `[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]` to completely eliminate DLL preloading and search-order hijacking vulnerabilities.

### 2. Complete Anti-SQL Injection & Strongly-Typed Parameter Defense
- **Strongly-Typed Parameter Binding:** Document writes (`.set()`, `.add()`, `.update()`), custom SQL operations (`.query()`), and filter values in `.where()` are bound as prepared statement parameters (`?`) with native SQLite type affinities. The only values written into SQL text are type-checked integers (`LIMIT`/`OFFSET`, array lengths) and the boolean literals `1`/`0`:
  - Integer numbers (`int32`, `int64`, `byte`, `sbyte`, `uint16`, `uint32`, `uint64` up to `Int64.MaxValue`, `bool`) are bound with `sqlite3_bind_int64`.
  - Floating point numbers (`single`, `double`, `decimal`, larger `uint64`) are bound with `sqlite3_bind_double`.
  - `DateTime`/`DateTimeOffset` values are bound as ISO-8601 UTC text.
  - Nulls are bound with `sqlite3_bind_null`.
  - Strings are bound with exact Unicode byte length via `sqlite3_bind_text16` using `SQLITE_TRANSIENT`.
- **Parameter Count Parity Enforcement:** Custom queries validate parameter count parity against native prepared statement placeholders using `sqlite3_bind_parameter_count`. Any mismatch throws `[System.InvalidOperationException]`, preventing omitted parameters from silently converting into `NULL`.
- **Strict Identifier Whitelisting:** All patterns are anchored with `\A` and `\z`, so a trailing newline cannot slip through.
  - Collection names: `\A[a-zA-Z0-9_]+\z`, validated when a collection is selected and again before every operation builds SQL (internal fields are `hidden`, but still reachable from PowerShell, so they are not trusted).
  - Field paths: `\A[a-zA-Z0-9_]+(\[\d+\])*(\.[a-zA-Z0-9_]+(\[\d+\])*)*\z` in `where()`/`orderBy()`, and the same without array indexes in `select()`, aggregates, `distinct()`, indexes and `populate()`.
  - Query operators: restricted to a whitelist; every alias is normalized before use: `=`, `==`, `-eq`, `!=`, `<>`, `-ne`, `>`, `-gt`, `<`, `-lt`, `>=`, `-ge`, `<=`, `-le`, `LIKE`, `NOT LIKE`, `-like`, `-notlike`, `IN`, `-in`, `not-in` (`not in`, `not_in`, `-notin`), `array-contains` (`-contains`), `array-contains-any`, `length`/`array-length`/`size` and their `>`, `>=`, `<`, `<=`, `!=` variants, `type`/`json-type`. `-like`/`-notlike` call the registered `pslocalbase_like` function; `LIKE`/`NOT LIKE` use SQLite's native operator.
  - Sorting directions: restricted strictly to `ASC` or `DESC`
  - Table names read back from `sqlite_master` (for `getCollections()` and `collectionGroup()`) are filtered with the same collection-name pattern and passed to `pragma_table_info(?)` as a bound parameter.
- **Payload Safety & NUL Preservation:** Arbitrary user strings (including SQL syntax like `' OR '1'='1` or `'; DROP TABLE; --`) are treated strictly as literal data. Embedded NUL bytes (`\0`) within string payloads are preserved losslessly using exact byte bounds (`ColumnBytes16 / 2`).
- **Lazy Schema Provisioning:** Referencing `.collection("name")` or `.doc("key")`, and every read, operates lazily and does not provision SQLite tables. Only writes (`.set()`, `.add()`, `.upsert()`, `.update()`, `.replaceAll()`) or `.create()` create tables, preventing unintended table pollution and resource exhaustion from arbitrary or mistyped collection names.
- **Single-Statement `query()` & Pre-Preparation Rejection:** `query()` validates statement completeness using `sqlite3_complete16` and rejects compound SQL before calling `sqlite3_prepare16_v2`. This prevents multi-statement queries from altering connection PRAGMAs (such as `ignore_check_constraints=ON` or `trusted_schema=ON`) during SQLite's preparation phase. Quoted semicolons inside strings, comments, and multi-statement trigger bodies remain fully supported. `query()` is a trusted-code interface: never concatenate untrusted input into its SQL; always pass values through the parameter array.

### 3. Source Code & Complex Payload Integrity
- Field values containing complex scripts, code snippets (PowerShell, Python, SQL), nested quotes, backslashes, dollar signs, and multiline strings are stored and retrieved byte-for-byte identical without interpretation or corruption.

### 4. Memory Safety & Handle Lifecycle
- **Native Unicode Marshaling:** Dynamic P/Invoke layer uses UTF-16 Unicode variants (`sqlite3_open16`, `sqlite3_prepare16_v2`, `sqlite3_bind_text16`, `sqlite3_column_text16`, `sqlite3_errmsg16`) matching Windows' and .NET's native string format to prevent encoding desynchronization or buffer overflows.
- **Leak Prevention:** All prepared SQLite statement pointers are scoped inside `try { ... } finally { [WinSqlite3]::Finalize($stmt) }` blocks to guarantee immediate destruction of unmanaged structures.
- **Connection Ownership:** Each root connection is owned by a `SafeHandle` (`PSLocalBaseConnectionHandle`). `close()`/`Dispose()` release it deterministically; if an instance is abandoned without being closed, the finalizer calls `sqlite3_close_v2`. The NativeStress suite verifies that 20 undisposed instances return SQLite memory to its baseline after garbage collection.
- **Fluent API State Isolation:** Query branches are independent copies. Writes preserve their document target and query scope, including after errors.
- **WAL Storage Boundary Validation:** Explicitly rejects UNC paths (`\\server\share`) and mapped network drives (`DriveType.Network`) to prevent SQLite shared-memory (`-shm`) corruption over SMB shares.
- **Safe Transaction Rollback Isolation:** Handlers wrap rollback calls in guarded blocks to ensure engine-level auto-rollbacks (e.g. `SQLITE_FULL`) do not mask root exceptions.
- **Concurrency & Lock Contention Mitigation:** Implements Write-Ahead Logging (`WAL`), configurable `synchronous` (`NORMAL` by default), and an automated 5,000 ms busy handler (`busy_timeout`). In WAL mode, readers never block writers and writers never block readers. Explicit transactions, bulk replacement and `update()` start with `BEGIN IMMEDIATE`, so concurrent writers wait for the busy timeout instead of failing on a lock upgrade; a clear error is thrown if the timeout is exceeded. The multi-process WAL suite verifies this with a Windows PowerShell 5.1 and a PowerShell 7 process writing to one file concurrently.

### 5. NUL Character Defense & Identifier Integrity
- Document keys passed to `.doc('key')`, `.add(data, 'key')`, `.insert(data)`, `.upsert()`, and bulk `.replaceAll($array)` / `.set($array)` are explicitly validated against embedded NUL bytes (`\0` / `U+0000`).
- Because native C APIs treat `\0` as a null-terminator, embedded nulls could cause premature truncation and unauthorized key overwrites/collisions. PSLocalBase rejects any keys containing null characters with `[System.ArgumentException]`.

### 6. Safe Deletion, Mutation & Identity Protection
- **Collection Deletion vs. Truncation:** Calling `.delete()` without criteria truncates records from a collection (`DELETE FROM [col]`), clearing document rows while keeping table definitions and secondary indexes intact. In contrast, completely dropping the collection table and its associated SQLite schema requires calling the explicit, dedicated `.drop()` method (`DROP TABLE IF EXISTS [col]`).
- **Accidental Bulk Deletion Defense:** Calling `.delete()` when chained with sorting or pagination (`.orderBy()`, `.limit()`, `.skip()`) is strictly rejected with `[System.InvalidOperationException]`, preventing unintended mass data loss and preserving all records and indexes. Point deletions must target a document key (`.doc('key').delete()`), filtered deletions must provide criteria (`.where(...).delete()`), and full table removal requires `.drop()`.
- **Filtered Replacement Defense:** `replaceAll()` and its alias `set(@(...))` delete every document before inserting. They are rejected on queries with `where()`, `orderBy()`, `limit()` or `skip()`, which in 1.0.x silently emptied the whole collection.
- **Write Immutability:** Writes do not reset the query they are called on. In 1.0.x, `$d.set(...)` cleared `$d`'s key, so a following `$d.delete()` truncated the collection.
- **Identity Auto-Provisioning:** `.upsert()` extracts explicit identity properties (`id`, `key`, `_key`). If none are present, a unique random GUID is generated, preventing arbitrary content properties from colliding or overwriting existing documents.
- **Array Mutation 64-Bit Precision:** `ArrayUnion` and `ArrayRemove` perform exact 64-bit integer comparisons, avoiding conversion to `double` and preserving full precision for values exceeding 2^53.
- **Array Type Gating:** `array-contains` and `array-contains-any` enforce `json_type = 'array'`, preventing false positive matches against scalar strings, numbers, or objects in polymorphic schemas, and protecting `.where(...).delete()` from deleting non-array records.
- **Collection State Isolation:** Collection reference variables operate on isolated instances: assigning `$u = $db.collection('users')` and `$o = $db.collection('orders')` produces independent context instances, eliminating shared-state mutation between collection variables.

### 7. Debug Output Sanitization & Credential Privacy
- **Redaction of Prepared Statement Parameters:** When `$db.config["debug"] = $true` is enabled, parameter values and document payloads bound via prepared statement placeholders (`?`) are redacted and summarized by parameter count rather than printed raw to `stdout`, preventing sensitive credentials, API tokens, and PII from leaking into terminal transcripts and CI logs.
- **SQL Text in Errors:** Error messages include the SQL statement only when `debug` is enabled, because SQL can contain literals copied from data. With debug enabled, raw literals inside custom `.query("SELECT ...")` strings appear in output and errors; always pass user-supplied values via the parameter array (e.g., `$db.query("SELECT * FROM users WHERE role = ?", @($userRole))`).
- **Document Content in Errors:** A document that cannot be read (too large, too deeply nested, or malformed) fails with an error that names only its key, never its content.

### 8. Interactive Playground Security & Execution Model
- The WPF Playground (`Playground.ps1`) runs within the local user context and executes code snippets directly using the caller's Windows permissions.
- It does not implement a restricted sandbox. It is intended strictly as a developer productivity and database exploration tool for authorized local environments. Never paste untrusted code into it.

### 9. Unmanaged Handle Lifecycle & Orphaned Collection Defense (Use-After-Free Prevention)
- **Parent-Child Lifecycle Guarding:** Child collection instances (`IsChildInstance = $true`) share the underlying SQLite native handle (`DbHandle`) with the root `PSLocalBase` instance without owning connection termination.
- **Immediate Closure Detection:** When the root database connection is closed (`.close()` or `.Dispose()`), child collections validate parent connection health on all operations via `_EnsureOpen()`. A child is rejected when the root handle is zero, differs from the child's handle, or the root's `HandleGeneration` (advanced on every open and close) differs from the generation the child was created with. The child then zeroes its local `DbHandle` and raises `[System.InvalidOperationException]: Database connection is closed.`.
- **No Reopen:** A closed instance cannot be reopened (`Init()` is `hidden` and refuses a second call). In 1.0.x, reopening let older children pass the closure check with a freed pointer that could belong to another connection.
- **Memory Safety Guarantee:** Stale or orphaned collection instances are blocked from calling unmanaged SQLite C APIs (`sqlite3_step`, `sqlite3_exec`, `sqlite3_get_autocommit`) even when the native address has been reused, preventing use-after-free.

### 10. Cross-Edition Serialization Depth Protection (Data Loss Prevention)
- **Pre-Flight Depth Inspection:** Windows PowerShell 5.1's built-in `ConvertTo-Json` silently truncates objects exceeding `-Depth` into .NET type name strings (such as `"System.Collections.Hashtable"`) without raising errors or warnings.
- **Deterministic Rejection:** PSLocalBase incorporates a recursive pre-flight depth analyzer (`_ExceedsDepth`) that traverses dictionaries, collections, and custom object properties. If the object exceeds configured `depth`, an `[System.InvalidOperationException]` is thrown prior to serialization across both Windows PowerShell 5.1 and PowerShell 7+, ensuring pre-existing documents are preserved intact without silent corruption.

### 11. Query Composition & Branch Snapshot Isolation (Issues #23 & #25)
- **Defensive Snapshotting:** Calling `.union()` or `.unionAll()` creates a defensive deep clone of both the invoking query and target query instance.
- **Post-Composition Mutation Immunity:** Subsequent filter mutations on source branches (e.g., `$b.where(...)` after `$a.union($b)`) do not affect the composed query tree.
- **Connection Identity Validation:** Composed queries must belong to the exact same native SQLite database handle (`$otherQuery.DbHandle -eq $this.DbHandle`). Cross-database unions are rejected with `[System.InvalidOperationException]`.
- **Nested Composition Defense:** Re-composing a query that is already part of a composite branch (`IsComposedInUnion`) is explicitly rejected to prevent unbounded recursive SQL generation and semantic ambiguity.

### 12. Immutable Query State & Forking (Issues #24 & #26)
- **Immutable Query Builder:** Methods that modify query criteria (`where()`, `whereLength()`, `whereType()`, `orderBy()`, `limit()`, `skip()`, `select()`, `populate()`) return a new child cloned instance via `.clone()`. Root collection instances and parent queries remain unmodified and reusable.
- **Explicit Branch Forking:** The public `.clone()` and `.fork()` methods allow developers to safely fork query pipelines into multiple branches without shared filter interference.
- **Idempotent Terminal Reads:** Methods like `.get()`, `.count()`, `.exists()`, `.distinct()`, and aggregations do not wipe the query filters upon completion. Once defined, a query instance can be read multiple times without needing re-definition.

### 13. Numeric Precision & Decimal Quantization Boundaries (Issue #22)
- **Double/Decimal Boundary Scale:** In .NET, `System.Decimal` operates with a maximum precision scale of 28 decimal places. Any floating-point number whose absolute magnitude is strictly less than $10^{-28}$ (such as $6 \times 10^{-29}$, a normal Double below Decimal scale) cannot be represented by a non-zero Decimal.
- **Quantization Protection in Array Operations:** In `_JsonValuesEqual`, floating-point values whose magnitude is smaller than the Decimal resolution ($|Double| < 10^{-28}$) are guarded so they are never falsely equated with non-zero Decimals. This preserves distinct element integrity in `ArrayUnion` and `ArrayRemove`.
- **Lossless Roundtrip Verification:** Both IEEE 754 `"R"` and `"G17"` double representations are verified via roundtrip parsing (`Double.Parse`), preventing false inequality between serializations.

### 14. Collection Group Deletion Defense
- Calling `.drop()` on a sharded `collectionGroup()` instance is strictly rejected with `[System.InvalidOperationException]`.
- Because `collectionGroup` targets multiple tables via wildcards, dropping is prohibited to prevent accidental mass deletion of sharded schemas across the database.

### 15. Secondary Index Collision Immunity & Field Sanitization
- Secondary expression index names incorporate deterministic 64-bit hash isolation.
- Dropping an index (`dropIndex()`) inspects the underlying index definition in `sqlite_master` to ensure that an index deletion for one JSON path never inadvertently drops a `UNIQUE` constraint belonging to an unrelated path due to partial prefix or hash collisions.

### 16. Untrusted Database Files
- **`PRAGMA trusted_schema = OFF`** is set on every connection. Triggers, views, CHECK constraints and index expressions stored in the file can only call functions SQLite marks as innocuous.
- **`pslocalbase_like` is registered with `SQLITE_DIRECTONLY`**, so stored triggers and views cannot invoke the managed callback.
- **Schema names are not trusted:** table names from `sqlite_master` are filtered and bound as parameters (section 2), so names such as `a]b` cannot break `getCollections()`.
- **Bounded deserialization:** documents larger than `maxDocumentBytes` (16 MB by default) or nested deeper than `maxReadDepth` (100 by default) are rejected before `ConvertFrom-Json` runs, keeping memory use bounded and both PowerShell editions consistent.
- **`deleteDatabase()` path:** the files to delete are derived from `sqlite3_db_filename`, not from the instance's `FilePath` field, and include the `-journal` file.

### 17. Session Hygiene
- The native bridge script runs inside a script block, so importing the module leaves no helper variables (such as `$csharpCode`) in the caller's session.
- The bridge exposes `BridgeVersion`; version 4 or newer is required. If an older bridge is already loaded in the session, opening a connection fails with a request to restart PowerShell instead of running against mismatched native code. The failed initialization closes its connection.

---

## Reporting a Vulnerability

If you discover a security vulnerability or unexpected behavior in PSLocalBase, please report it responsibly:

1. **Do not create a public issue** on GitHub.
2. Please submit a private vulnerability report via **GitHub Security Advisories** or contact the author **[@cmartineztech](https://github.com/cmartineztech)** directly.
3. Include a description of the issue, minimal reproduction steps, and your PowerShell environment details.
4. The maintainer will review, verify, and release a patch in a timely manner.
