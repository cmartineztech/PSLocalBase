# PSLocalBase Test Suite

Automated regression and acceptance test suite for **PSLocalBase**, verifying zero-dependency imports, P/Invoke memory safety, ACID transactions, WAL concurrency, Unicode preservation, and fluent query isolation across all supported PowerShell editions.

---

## Running the Tests

You can execute the automated test runner in either Windows PowerShell 5.1 or PowerShell 7+ (Core):

```powershell
# In Windows PowerShell 5.1 (Desktop):
powershell.exe -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1

# In PowerShell 7+ (Core / Cross-Platform):
pwsh -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
```

To run individual test files directly:
```powershell
pwsh -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Tests.ps1
```

### Complete Multi-Suite Runner Overview (13 Suites / 186 Enumerated Checks + NativeStress)

The automated test runner (`_TESTS/run-tests.ps1`) executes 13 focused test suites:
1. `PSLocalBase.Tests.ps1` - Core acceptance criteria & functional tests (83 test cases).
2. `PSLocalBase.Audit.Tests.ps1` - Corner cases, boundary values, and corruption defenses (7 checks).
3. `PSLocalBase.Reevaluation.Tests.ps1` - Query builder state isolation and transaction rollbacks (17 checks).
4. `PSLocalBase.NativeStress.Tests.ps1` - P/Invoke statement cleanup and high-concurrency lock contention (stress cycles and observations).
5. `PSLocalBase.Independent-c57b52c.Tests.ps1` - Dotted/underscore field independence and numeric privacy (7 checks).
6. `PSLocalBase.Revalidation-3ecc2c1.Tests.ps1` - JSON path casing, legacy hash verification, and aggregation scoping (11 checks).
7. `PSLocalBase.Review-83ed742.Tests.ps1` - Index expression migration and roundtrip mutations (7 checks).
8. `PSLocalBase.Followup-a526708.Tests.ps1` - Cross-edition numeric roundtrip and collectionGroup drop rejection (21 checks).
9. `PSLocalBase.Boundary-86483c7.Tests.ps1` - Floating-point decimal quantization boundaries (3 checks).
10. `PSLocalBase.Review-3c890fd.Tests.ps1` - Read terminal filter preservation, RHS union reuse, and synchronous options (8 checks).
11. `PSLocalBase.Review-158582f.Tests.ps1` - Deletion query state preservation, RHS independent union snapshot, PowerShell -like wildcard matching, and RHS union query plan preservation (9 checks).
12. `PSLocalBase.Review-fb3da3b.Tests.ps1` - Global composite pagination/projection and complete-string pattern deletion (6 checks).
13. `PSLocalBase.Issues31-32.Tests.ps1` - Independent branch/global plans, projected JSON types, NUL/Unicode wildcard oracles, callback lifetime and SQL LIKE compatibility (7 checks).

*(Note: The 186 enumerated checks represent distinct functional verification scenarios and regression groups across the 12 enumerated suites, not raw line/branch code coverage percentages. NativeStress also exercises complete-string pattern callbacks in its 500 statement-cleanup cycles. The interactive WPF GUI playground verification script `Playground/verify-playground.ps1` executes GUI/WPF checks separately).*

---

## Verified Acceptance Criteria (83/83 Passed)

| Test ID | Test Category | Validation Criteria | Status |
| :--- | :--- | :--- | :--- |
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
| **TC-21** | **Native Memory Safety** | `sqlite3_free` memory reclamation on failed queries and platform gating | **PASSED** |
| **TC-22** | **Query Step Validation** | Checks return codes on `sqlite3_step` and surfaces `SQLITE_BUSY` or iteration errors | **PASSED** |
| **TC-23** | **Fluent State Isolation** | Resets `CurrentKey` across `.set()`, `.get()`, and `.update()` in `try/finally` | **PASSED** |
| **TC-24** | **WAL Path Validation** | Rejects UNC network paths (`\\server\share`) and mapped network drives | **PASSED** |
| **TC-25** | **Transaction Tracking** | Safe rollback on bulk set and error recovery without masking original exception | **PASSED** |
| **TC-26** | **Search Path & Scalar IN** | System32 DLL search path isolation, balanced field regex, and scalar/empty `IN` handling | **PASSED** |
| **TC-27** | **Explicit Collection Lifecycle** | Lazy collection navigation without ghost tables; explicit `.create()`, `.createCollection()`, and `.collectionExists()` | **PASSED** |
| **TC-28** | **Target Document Auto-Provisioning** | Calling `.doc()` auto-provisions collection table; criteria key resolution via hashtable & PSCustomObject | **PASSED** |
| **TC-29** | **Collection Schema Lifecycle** | Schema introspection via `collectionExists()`, explicit `createCollection()`, drop & immediate re-creation | **PASSED** |
| **TC-30** | **Multiple Collection Isolation** | Data and index isolation across multiple collections; bulk overwrite and relational integrity | **PASSED** |
| **TC-31** | **Isolated Collection Reference State** | Independent `$users` and `$orders` instances without shared state or cross-talk | **PASSED** |
| **TC-32** | **Accidental Drop Protection & .drop()** | Rejects `.limit().delete()` and verifies explicit `.drop()` prevents accidental data loss | **PASSED** |
| **TC-33** | **Case-Insensitive Schema Resolution** | Resolves `Users` vs `users` preserving fields via deep-merge without schema mismatch | **PASSED** |
| **TC-34** | **NUL Byte Key Defense** | Rejects `\0` in document keys to prevent truncations and unauthorized collisions | **PASSED** |
| **TC-35** | **SAVEPOINT Bulk Isolation** | Outer transaction rollback safety during partial bulk set failures via SQLite savepoints | **PASSED** |
| **TC-36** | **Safe Handle Release on Open Failure** | Prevents unmanaged handle leaks on invalid/corrupt files during constructor PRAGMAs | **PASSED** |
| **TC-37** | **Constructor Options Enforcement** | Enforces `cacheSizeMB`, `wal`, and `busyTimeout` PRAGMA settings upon database initialization | **PASSED** |
| **TC-38** | **Atomic update() Isolation** | Immediate transaction isolation preventing lost updates during concurrent writes | **PASSED** |
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
| **TC-68** | **Collision-Free Index Naming & Dynamic Upgrade** | Hash-isolated index names preventing collisions between dots/underscores and table prefixes, dynamic uniqueness upgrade | **PASSED** |
| **TC-69** | **Array Mutation Structural JSON Equality** | Recursive structural equality for array elements preserving scalar types (numbers vs strings, booleans) and normalizing object key order | **PASSED** |
| **TC-70** | **Atomic update() on Non-Existent Document** | Evaluates partialData via _DeepMerge against empty document, resolving array sentinels and descriptors into arrays | **PASSED** |
| **TC-71** | **Composite Query Scoping & Connection Isolation** | Enforces connection isolation across union queries, RHS document key scoping, and projection on collectionGroup and union | **PASSED** |
| **TC-72** | **VACUUM INTO Consistent Snapshot for WAL Mode** | Exports complete, committed database snapshot directly from live WAL writer without uncheckpointed data loss | **PASSED** |
| **TC-73** | **Native Lexical & ISO Timestamp MIN / MAX** | Operates directly on json_extract without casting to REAL, preserving ISO 8601 dates and lexical text ordering | **PASSED** |
| **TC-74** | **Accidental Collection Drop Defense on Ordered Mutation** | Rejects delete() chained with orderBy() preserving collection tables and indexes | **PASSED** |
| **TC-75** | **Upsert Identity Auto-Provisioning & GUID Generation** | Extracts explicit document identity (key, id, _key) or generates a unique GUID, preventing arbitrary field key derivation | **PASSED** |
| **TC-76** | **Array Mutation Precision on Adjacent 64-Bit Integers** | Direct 64-bit integer comparison in _JsonValuesEqual preserving precision for values past 2^53 | **PASSED** |
| **TC-77** | **Case-Insensitive Collection Schema Index Resolution** | Resolves collection casing via sqlite_master COLLATE NOCASE in dropIndex() | **PASSED** |
| **TC-78** | **Point-Lookup Scope Preservation in Composite Queries** | Prevents early single-document return in get() when chained with union() or collectionGroup() | **PASSED** |
| **TC-79** | **Missing Branch Parameter Isolation in Composite Queries** | Isolates query parameter bindings so non-existent collections in union queries do not cause parameter count mismatches | **PASSED** |
| **TC-80** | **Array Type Enforcement for Array Operators** | Enforces json_type = 'array' for array-contains and array-contains-any, excluding scalar and object matches | **PASSED** |
| **TC-81** | **Double/Decimal Boundary Quantization & Array Mutation Isolation** | Enforces IEEE underflow threshold (< 1e-28) preventing collision between Double and Decimal in ArrayUnion/ArrayRemove | **PASSED** |
| **TC-82** | **Composite Query Defensive Copy & Snapshot Isolation** | union() and unionAll() capture defensive clone snapshots; subsequent source branch mutations do not alter composed query | **PASSED** |
| **TC-83** | **Query Builder Immutability, Bifurcation & Explicit Fork** | where() and query modifiers return cloned child queries; terminal methods are non-destructive and queries are reusable | **PASSED** |
