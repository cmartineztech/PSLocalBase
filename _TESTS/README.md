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

---

## Verified Acceptance Criteria (30/30 Passed)

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
