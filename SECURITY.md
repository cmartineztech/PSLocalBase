# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

---

## Threat Model & Scope

**PSLocalBase** is an in-process, embedded document database engine designed for local PowerShell execution on Windows. 

- **Local Execution Boundary:** PSLocalBase runs entirely inside the caller's PowerShell process and communicates with Windows' native `C:\Windows\System32\winsqlite3.dll`. It does not expose network ports, sockets, or remote listening endpoints.
- **Operating System Access Control (ACL):** Physical file access security is governed by the host operating system's NTFS permissions and user Access Control Lists (ACLs).

---

## Defensive Security Architecture

### 1. Zero External Dependencies & System32 Search Path Isolation
- Relies exclusively on `winsqlite3.dll`, a trusted native Windows system binary maintained and patched directly by Microsoft via Windows Update.
- Eliminates software supply chain risks associated with third-party NuGet packages, external binaries, or unsigned dependencies.
- Enforces assembly-level `[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]` to completely eliminate DLL preloading and search-order hijacking vulnerabilities.

### 2. Complete Anti-SQL Injection & Strongly-Typed Parameter Defense
- **Strongly-Typed Parameter & Literal Binding:** Document writes (`.set()`, `.add()`, `.update()`), custom SQL operations (`.query()`), and string filter queries (`.where()`) bind values using prepared statement parameters (`?`) with native SQLite type affinities:
  - Integer numbers (`int32`, `int64`, `byte`, `sbyte`, `uint16`, `uint32`, `bool`) are bound with `sqlite3_bind_int64` (in `.where()` clauses, scalar numeric values are injected as validated invariant numeric literals).
  - Floating point numbers (`single`, `double`, `decimal`) are bound with `sqlite3_bind_double`.
  - Nulls are bound with `sqlite3_bind_null`.
  - Strings are bound with exact Unicode byte length via `sqlite3_bind_text16` using `SQLITE_TRANSIENT`.
- **Parameter Count Parity Enforcement:** Custom queries validate parameter count parity against native prepared statement placeholders using `sqlite3_bind_parameter_count`. Any mismatch throws `[System.InvalidOperationException]`, preventing omitted parameters from silently converting into `NULL`.
- **Strict Identifier Whitelisting:**
  - Collection names: enforced via regex `^[a-zA-Z0-9_]+$`
  - Field paths: enforced via regex `^[a-zA-Z0-9_.\[\]]+$` with balanced bracket validation
  - Query operators: restricted to a strict whitelist (`=`, `==`, `!=`, `<>`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IN`, `not-in`, `array-contains`, `array-contains-any`, `length`, `length>`, `length>=`, `length<`, `length<=`, `length!=`, `type`, `json-type`)
  - Sorting directions: restricted strictly to `ASC` or `DESC`
- **Payload Safety & NUL Preservation:** Arbitrary user strings (including SQL syntax like `' OR '1'='1` or `'; DROP TABLE; --`) are treated strictly as literal data. Embedded NUL bytes (`\0`) within string payloads are preserved losslessly using exact byte bounds (`ColumnBytes16 / 2`).
- **Lazy Schema Provisioning:** Referencing `.collection("name")` operates lazily and does not provision SQLite tables until explicit writes (`.set()`, `.add()`, `.update()`) or `.create()` are called, preventing unintended database table pollution and resource exhaustion from arbitrary or mistyped collection names.

### 3. Source Code & Complex Payload Integrity
- Field values containing complex scripts, code snippets (PowerShell, Python, SQL), nested quotes, backslashes, dollar signs, and multiline strings are stored and retrieved byte-for-byte identical without interpretation or corruption.

### 4. Memory Safety & Handle Lifecycle
- **Native Unicode Marshaling:** Dynamic P/Invoke layer uses UTF-16 Unicode variants (`sqlite3_open16`, `sqlite3_prepare16_v2`, `sqlite3_bind_text16`, `sqlite3_column_text16`, `sqlite3_errmsg16`) matching Windows' and .NET's native string format to prevent encoding desynchronization or buffer overflows.
- **Leak Prevention:** All prepared SQLite statement pointers are scoped inside `try { ... } finally { [WinSqlite3]::Finalize($stmt) }` blocks to guarantee immediate destruction of unmanaged structures.
- **Fluent API State Isolation:** Document targets (`CurrentKey`) are cleared across query executions in `try/finally` blocks and reset when chaining filters, preventing accidental cross-query state leakage.
- **WAL Storage Boundary Validation:** Explicitly rejects UNC paths (`\\server\share`) and mapped network drives (`DriveType.Network`) to prevent SQLite shared-memory (`-shm`) corruption over SMB shares.
- **Safe Transaction Rollback Isolation:** Handlers wrap rollback calls in guarded blocks to ensure engine-level auto-rollbacks (e.g. `SQLITE_FULL`) do not mask root exceptions.
- **Non-blocking Concurrency:** Implements Write-Ahead Logging (`WAL`), `synchronous = NORMAL`, and a 5,000 ms busy handler to eliminate locking deadlocks across concurrent scripts.

### 5. NUL Character Defense & Identifier Integrity
- Document keys passed to `.doc('key')`, `.add(data, 'key')`, `.insert(data)`, and bulk `.set($array)` are explicitly validated against embedded NUL bytes (`\0` / `U+0000`).
- Because native C APIs treat `\0` as a null-terminator, embedded nulls could cause premature truncation and unauthorized key overwrites/collisions. PSLocalBase rejects any keys containing null characters with `[System.ArgumentException]`.

### 6. Safe Deletion, Mutation & Identity Protection
- **Collection Deletion vs. Truncation:** Calling `.delete()` without criteria truncates records from a collection (`DELETE FROM [col]`), clearing document rows while keeping table definitions and secondary indexes intact. In contrast, completely dropping the collection table and its associated SQLite schema requires calling the explicit, dedicated `.drop()` method (`DROP TABLE IF EXISTS [col]`).
- **Accidental Bulk Deletion Defense:** Calling `.delete()` when chained with sorting or pagination (`.orderBy()`, `.limit()`, `.skip()`) is strictly rejected with `[System.InvalidOperationException]`, preventing unintended mass data loss and preserving all records and indexes. Point deletions must target a document key (`.doc('key').delete()`), filtered deletions must provide criteria (`.where(...).delete()`), and full table removal requires `.drop()`.
- **Identity Auto-Provisioning:** `.upsert()` extracts explicit identity properties (`id`, `key`, `_key`). If none are present, a unique random GUID is generated, preventing arbitrary content properties from colliding or overwriting existing documents.
- **Array Mutation 64-Bit Precision:** `ArrayUnion` and `ArrayRemove` perform exact 64-bit integer comparisons, avoiding conversion to `double` and preserving full precision for values exceeding 2^53.
- **Array Type Gating:** `array-contains` and `array-contains-any` enforce `json_type = 'array'`, preventing false positive matches against scalar strings, numbers, or objects in polymorphic schemas, and protecting `.where(...).delete()` from deleting non-array records.
- **Collection State Isolation:** Collection reference variables operate on isolated instances: assigning `$u = $db.collection('users')` and `$o = $db.collection('orders')` produces independent context instances, eliminating shared-state mutation between collection variables.

### 7. Debug Output Sanitization & Credential Privacy
- **Redaction of Prepared Statement Parameters:** When `$db.config["debug"] = $true` is enabled, parameter values and document payloads bound via prepared statement placeholders (`?`) are redacted and summarized by parameter count rather than printed raw to `stdout`, preventing sensitive credentials, API tokens, and PII from leaking into terminal transcripts and CI logs.
- **Raw SQL Literals in Custom Queries:** While prepared statement parameter bindings (`?`) are strictly protected from logging, any raw SQL literals passed directly inside custom `.query("SELECT ...")` strings will appear in error messages and debug outputs. It is a critical best practice to always pass user-supplied values via the parameter array (e.g., `$db.query("SELECT * FROM users WHERE role = ?", @($userRole))`) rather than concatenating or embedding raw literals in the query string.

### 8. Interactive Playground Security & Execution Model
- The WPF Playground (`Playground.ps1`) runs within the local user context and executes code snippets directly using the caller's Windows permissions.
- It does not implement a restricted sandbox. It is intended strictly as a developer productivity and database exploration tool for authorized local environments.

### 9. Unmanaged Handle Lifecycle & Orphaned Collection Defense (Use-After-Free Prevention)
- **Parent-Child Lifecycle Guarding:** Child collection instances (`IsChildInstance = $true`) share the underlying SQLite native handle (`DbHandle`) with the root `PSLocalBase` instance without owning connection termination.
- **Immediate Closure Detection:** When the root database connection is closed (`.close()` or `.Dispose()`), child collections validate parent connection health on all operations via `_EnsureOpen()`. If the parent handle has been released, the child zeroes out its local `DbHandle` and immediately raises `[System.InvalidOperationException]: Database connection is closed.`.
- **Memory Safety Guarantee:** Stale or orphaned collection instances are completely blocked from calling unmanaged SQLite C APIs (`sqlite3_step`, `sqlite3_exec`, `sqlite3_get_autocommit`), eliminating Use-After-Free vulnerabilities and unmanaged memory corruption.

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

### 13. Numeric Precision & Subnormal Quantization Boundaries (Issue #22)
- **Double/Decimal Boundary Theorem:** In .NET, `System.Decimal` operates with a maximum precision scale of 28 decimal places. Any floating-point number whose absolute magnitude is strictly less than $10^{-28}$ cannot be represented by a non-zero Decimal.
- **Quantization Protection in Array Operations:** In `_JsonValuesEqual`, subnormal floating-point values ($|Double| < 10^{-28}$) are guarded so they are never falsely equated with non-zero Decimals. This preserves distinct element integrity in `ArrayUnion` and `ArrayRemove`.
- **Lossless Roundtrip Verification:** Both IEEE 754 `"R"` and `"G17"` double representations are verified via roundtrip parsing (`Double.Parse`), preventing false inequality between serializations.

### 14. Collection Group Deletion Defense
- Calling `.drop()` on a sharded `collectionGroup()` instance is strictly rejected with `[System.InvalidOperationException]`.
- Because `collectionGroup` targets multiple tables via wildcards, dropping is prohibited to prevent accidental mass deletion of sharded schemas across the database.

### 15. Secondary Index Collision Immunity & Field Sanitization
- Secondary expression index names incorporate deterministic 64-bit hash isolation.
- Dropping an index (`dropIndex()`) inspects the underlying index definition in `sqlite_master` to ensure that an index deletion for one JSON path never inadvertently drops a `UNIQUE` constraint belonging to an unrelated path due to partial prefix or hash collisions.

---

## Reporting a Vulnerability

If you discover a security vulnerability or unexpected behavior in PSLocalBase, please report it responsibly:

1. **Do not create a public issue** on GitHub.
2. Please submit a private vulnerability report via **GitHub Security Advisories** or contact the author **[@cmartineztech](https://github.com/cmartineztech)** directly.
3. Include a description of the issue, minimal reproduction steps, and your PowerShell environment details.
4. The maintainer will review, verify, and release a patch in a timely manner.
