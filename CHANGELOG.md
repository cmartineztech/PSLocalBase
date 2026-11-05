# Changelog

All notable changes to PSLocalBase are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [2.1.0] - 2026-11-04

### Added
- Complete native PowerShell cmdlet layer (22 exported advanced functions, 7 aliases) with pipeline input/output and `-WhatIf`/`-Confirm` handling on supported operations. Reads materialize the selected query result before emitting pipeline objects; this is not a database cursor stream.
- Automated pipeline identity tracking decoupled from user payloads via `ConditionalWeakTable`.
- Transaction script block execution with automatic rollback via `Invoke-LocalBaseTransaction`.

### Fixed & Hardened
- Mandatory rejection of empty `-Filter @{}` without `-Id` in `Remove-LocalBaseDocument` to prevent accidental mass deletion.
- Logical AND conjunction for point lookup + filter in both Fluent queries and Cmdlet deletions (`-Id` with `-Filter`).
- Resolution of relative backup paths against PowerShell session location (`SessionState`) in `Backup-LocalBaseDatabase`.
- Auxiliary table filtering in `collectionGroup()` via `_IsDocumentTable` contract qualification.
- Native numeric guard in C# Bridge v5 (`pslocalbase_numeric`) preserving IEEE 754 precision and rejecting unsafe comparisons.

### Packaging
- Verified lightweight package distribution containing exclusively the 7 core engine, cmdlet, and metadata files (~55 KB).
- Automated pre-upload validation asserting zero extraneous files (excluding `.codegraph`, `_TESTS`, `_DOCS`, `Playground`, and CI).

## [2.0.5] - 2026-11-04

### Packaging
- Build the NuGet archive in a temporary local repository and inspect its actual entries before uploading.
- Block publication unless the archive contains exactly the seven runtime/metadata files, the generated nuspec and standard NuGet infrastructure metadata.
- Upload the inspected archive itself and verify its SHA256 immediately before sending, rather than rebuilding a package during Gallery publication.
- Keep `PSLocalBase.Cmdlets.ps1` separate. No database engine or cmdlet behavior changes.

## [2.0.4] - 2026-11-04

### Packaging
- Prepare Gallery publication from a validated staging directory containing only `PSLocalBase.psd1`, `PSLocalBase.psm1`, `PSLocalBase.Cmdlets.ps1`, `InitWinSqlite3Native.ps1`, `LICENSE`, `README.md` and `CHANGELOG.md`.
- Keep the cmdlet adapter separate, preserving the source layout and all 22 functions and 7 aliases.
- Exclude repository-only assets, including `.codegraph`, CI configuration, tests, Playground, extended documentation, local databases, logs and temporary benchmark outputs.
- Retain the 2.0.3 runtime behavior and native bridge version 5; this release corrects packaging only.

## [2.0.3] - 2026-11-04

The numeric guard requires native bridge version 5. Restart PowerShell after upgrading an already loaded module.

### Fixed
- Reject an empty `Remove-LocalBaseDocument -Filter` without a document ID before deleting any data; direct intentional collection-wide deletion to `Clear-LocalBaseCollection`.
- Apply logical AND when `Remove-LocalBaseDocument` receives both a document ID (explicitly or through pipeline identity) and a filter.
- Resolve relative `Backup-LocalBaseDatabase` destinations against the current PowerShell location before executing the backup.
- Exclude matching SQLite auxiliary tables without `key` and `doc` columns from `collectionGroup()` queries.
- Normalize `not-like` operator syntax in `where()` to accept hyphen, underscore, and space (`'not-like'`, `'not_like'`, `'not like'`, `'-notlike'`) for full syntax symmetry with `not-in`.
- Guard numeric SQL extraction against unsupported stored values as well as parameters; reject ambiguous comparisons atomically, including membership/deletion with legacy indexes. Preserve Int64 binding and document conservative binary64 limits and index-performance tradeoffs.
- Open/validate replacement ambient connections before closing the original; failed paths/options preserve pending transactions.
- Preserve top-level arrays, scalars and null across Get/Set/Add/Remove with trusted `.Value` envelopes; prevent ConvertFrom-Json array enumeration and explicitly serialize null on PS5.1.
- Reject distinct combined with limit/skip/orderBy instead of ignoring scope.
- Correct materialization/streaming claims and recommend bounded paging.
- Include Cmdlets in CI static analysis; implement ShouldProcess on New collection/index, Set and Start transaction without warning suppressions.
- Pipeline Set/Update/Remove now prioritize explicit arguments, then Get's object identity, then content fallback. Collection/id collisions cannot redirect mutations; adapter decorations are not persisted and colliding payload metadata is preserved.
- `doc()` and `where()` preserve each other's constraints. Reads and deletion combine key and filters with AND; filtered set/update/upsert now throw instead of ignoring filters.
- Transaction blocks use the selected database as their scoped ambient connection and treat ordinary non-terminating errors as failures. Context and error preference are restored on success/failure; same-connection nesting is rejected before entering the inner block.
- `Add-LocalBaseDocument -Id` inserts and rejects duplicates instead of overwriting them.
- Serialization enforces the same UTF-16 byte and JSON nesting limits as reads, preserving previous data on failed targeted or bulk writes.
- `Connect-LocalBase -JournalMode` accepts only the implemented WAL/DELETE modes; unsupported modes are rejected before changing the connection.
- Database removal reports filesystem failures, rejects active files and directories, and requires explicit disconnection. Force permits read-only removal while respecting WhatIf/Confirm.

### Tests
- Add regression coverage for empty-filter rejection with document preservation, conditional ID-and-filter deletion, relative backup paths and collection groups containing auxiliary tables.
- Final review of `e93d1ac`: all 22 suites passed on both PowerShell 7.6.9 and Windows PowerShell 5.1; Playground verification passed on both editions, and PSScriptAnalyzer reported no errors or warnings.
- Added second-review regressions for numeric collisions and atomic failures, reconnects, all top-level JSON shapes, distinct scope and WhatIf.
- Added the contracts regression suite to the runner for identity collisions, query intersections, scoped transactions, duplicate inserts, write limits, real journal readback, and safe temporary-file removal.

### Documentation
- Correct service examples by serializing enum properties as strings and passing explicit collection/storage keys when updating fluent query results through cmdlets.
- Make the service-audit example clear its previous snapshot before ingesting another, and use a valid command to list module aliases.
- Synchronize current references to 22 functions, 7 aliases, 22 test suites and native bridge version 5; label the earlier audit scorecard as historical.

### Added
- **Native PowerShell Cmdlets & Pipeline Adapter (`PSLocalBase.Cmdlets.ps1`)**: Added 22 native cmdlets and 7 short interactive aliases (`gld`, `ald`, `sld`, `uld`, `rld`, `Open-LocalBase`, `Close-LocalBase`) providing pipeline integration (`|`), ambient session management (`Connect-LocalBase` / `Disconnect-LocalBase`), and `-WhatIf` / `-Confirm` safety over the native engine.
- **Dedicated Cmdlets Test Suite (`_TESTS/PSLocalBase.Cmdlets.Tests.ps1`)**: 18 comprehensive test cases (C01–C18) verifying connection lifecycles, pipeline streaming, deep recursive merging, array mutations, atomic transactions, multi-database routing, and cross-edition parity.
- **Comprehensive Documentation (`_DOCS/CMDLETS.md`)**: Complete reference guide covering pipeline architecture, property binding, safety mechanics, cmdlet syntax, parity matrices, and operational automation scripts.

## [2.0.2] - 2026-10-31

### Packaging & Distribution
- **Pure Engine Packaging for PowerShell Gallery**: Restored automated staging pipeline (`Publish-PSLocalBase.ps1`) and declared explicit `FileList` in module manifest (`PSLocalBase.psd1`) to guarantee that `Install-Module PSLocalBase` distributes exclusively the 6 core runtime engine files (`PSLocalBase.psd1`, `PSLocalBase.psm1`, `InitWinSqlite3Native.ps1`, `LICENSE`, `README.md`, `CHANGELOG.md`). Excludes repository companion tools (`Playground/`), test suites (`_TESTS/`), extended documentation (`_DOCS/`), and CI workflows (`.github/`).
- **Automatic Documentation Link Normalization**: Staging pipeline converts relative repository markdown links and image embeds to absolute GitHub raw/blob URLs to prevent broken links on the PowerShell Gallery package view.

## [2.0.1] - 2026-10-31

### Added
- **Field Existence Filtering (`whereExists`, `whereMissing`)**: Added fluent query builder methods and operator support for `exists`, `-exists`, `missing`, and `-missing`. Evaluated natively in SQLite via `json_type(doc, '$.field') IS NOT NULL` / `IS NULL` without PowerShell deserialization overhead (resolves #36).

### Documentation
- **Formalized SQLite JSON Null Contract**: Explicitly documented scalar null comparison semantics: `.where("field", "=", $null)` matches both explicit JSON nulls and missing fields via `json_extract(...) IS NULL`; `.where("field", "!=", $null)` matches only present, non-null values; and `.whereType("field", "null")` matches strictly explicit JSON nulls via `json_type(...) = 'null'` (resolves #35).
- **Synchronized Verification Matrices**: Updated acceptance criteria matrices across `_DOCS/SPECIFICATION.md` and `_TESTS/README.md` to 84/84 passing.
- **Scorecard Update**: Elevated independent audit quality scorecard to 96.7/100 (Enterprise Ready) in `README.md` and `_DOCS/FINAL-VERIFICATION-REPORT-v2.md`.

### Tests
- **TC-84**: Added comprehensive test suite for `whereExists`, `whereMissing`, `exists`, and `missing` covering scalar fields, deep dot-paths, array indexing, CLR boolean type validation, and query builder immutability.

## 2.0.0

A hardening release driven by an independent security, code, functionality and documentation audit of 1.0.x. It fixes defects that could delete or alter data without an error, and it changes several behaviors on purpose. Read **Breaking changes** before upgrading.

After upgrading, start a new PowerShell session: the native bridge (`BridgeVersion` 4) cannot replace an older one already loaded, and opening a connection in such a session fails with a request to restart.

### Added

- **Interactive Playground GUI (`Playground.ps1`)**: Modern Windows desktop GUI explorer with auto-detection of Windows OS dark/light theme (`AppsUseLightTheme`), manual `-Theme Light|Dark` and `-DarkMode` parameters, in-app theme toggle, native DWM dark title bar styling, direct documentation shortcut, and clean collection management (`.drop()`). Validated across both editions with automated headless runner `Playground/verify-playground.ps1`.
- **Explicit `.drop()` method**: Fully supported collection drop lifecycle that safely purges the table and schema metadata while preserving the fluent collection instance.

### Breaking changes

- **Replacing a filtered collection is rejected.** `set(@(...))` on a query with `where()`, `orderBy()`, `limit()` or `skip()` now throws `InvalidOperationException`. In 1.0.x it ignored the filter and deleted every document. The new `replaceAll()` is the explicit name for replacing an unfiltered collection; `set(@(...))` remains an alias.
- **Writes no longer reset the query they are called on.** After `$d = $c.doc('k'); $d.set(...)`, `$d` still targets `k`; after `$q.add(...)`, `$q` keeps its filters; after `$c.drop()`, `$c` still names its collection. In 1.0.x the query was cleared, so a following `$d.delete()` truncated the whole collection.
- **`.doc()` no longer creates the collection table.** Tables are created by the first write (`set`, `add`, `upsert`, `update`, `replaceAll`) or by `create()`. Reads never create tables.
- **`doc()` criteria must name the key.** A hashtable or object without `key`, `id` or `_key` now throws instead of silently using its first value.
- **`collectionGroup()` cannot be combined with `union()`/`unionAll()`.** In 1.0.x one side was silently dropped.
- **`not-in` with an empty list** returns the documents where the field is present and not null, consistent with non-empty lists (1.0.x returned every document).
- **`in`/`not-in` with `$null` members.** `in` now also matches null or missing fields; `not-in` ignores `$null` members. In 1.0.x a `$null` member made `not-in` return nothing.
- **Aggregates use JSON numbers only.** `sum()`/`avg()` ignore text, booleans and nulls (1.0.x counted them as `0`/`1`). `min()`/`max()` compare numbers numerically and return `[long]`/`[double]`; they compare text only when a field has no numbers. `distinct()` returns typed values instead of strings.
- **Dates are stored as ISO-8601 UTC.** `DateTime`/`DateTimeOffset` values are written as `2026-01-02T03:04:05.0000000Z` in both editions (1.0.x wrote `\/Date(...)\/` objects in Windows PowerShell 5.1 and local-time strings in PowerShell 7) and are converted the same way in `where()`, `IN` lists and `query()` parameters. On PowerShell 7.5+, reads return stored date text unchanged instead of converting it to `DateTime`, matching 5.1.
- **`beginTransaction()` uses `BEGIN IMMEDIATE`.** Use `beginTransaction('deferred')` for the old behavior. `update()` and bulk replacement also start immediate transactions.
- **`query()` runs exactly one statement.** Any further executable statement after the first `;` throws (1.0.x ignored it silently).
- **Error messages omit SQL unless `debug` is enabled**, and documents that cannot be read report only their key.
- **Stricter options.** `wal` and `debug` must be booleans or `true`/`false`/`1`/`0`/`yes`/`no` (in 1.0.x `wal = 'false'` enabled WAL). `depth` must be 1-100 and is validated at construction.
- **Internal fields are `hidden`** (`DbHandle`, `FilePath`, `CurrentCollection`, `CurrentKey`, `WhereClauses`, `LimitValue`, `SkipValue`, `UnionQuery`, ...). They are no longer part of the public API; `LimitValue`/`SkipValue` are `Nullable[int]`.
- **A closed instance cannot be reopened.** `Init()` is `hidden` and refuses a second call; create a new instance instead.
- **`whereLength()` rejects unknown operators** instead of treating them as equality.
- **Property names that are empty or differ only in case are rejected on write**, because they made the whole collection unreadable.
- **Removed the `Update-TypeData` method fallbacks**, which never ran in supported sessions and diverged from the class implementation.

### Fixed

- Compound SQL is rejected before preparing any statement, preventing preparation-time PRAGMA changes after rejection. Quoted semicolons, comments and multi-statement trigger bodies remain supported.

- Point `get()` now applies the same pagination as `count()`/`exists()`; an empty point lookup returns `$null`, including `limit(0)` and nonzero `skip()`.
- Connections require native bridge version 4 or newer. Sessions with an older bridge must restart; rejected initialization releases its connection.

- A single filter value of `0` (for example `where('n', '=', 0)`) dropped its bound parameter and failed with "Parameter count mismatch" in `get()`, aggregates, `distinct()` and `collectionGroup()` queries. Found by the new property test.
- Children of a closed root could reach a reused native handle after `Init()` reopened the root (use-after-free). Children now also check a handle generation.
- Undisposed instances kept native connections open for the life of the process; a `SafeHandle` finalizer now releases them.
- `getCollections()` failed on table names such as `a]b` and could list incompatible tables; names are filtered and bound.
- `collectionGroup()` used the tables that existed when it was created, failing after a drop and missing new tables; it now resolves them at query time, and `_collection` can be used in `where()`.
- `exists()` ignored `skip()`/`limit()`; `first()` ignored `limit(0)`; `whereType()` could not select booleans; `populate()` on a missing foreign collection threw `no such table`.
- In PowerShell 7, `update()` rewrote untouched date strings in the local time zone.
- Documents nested more than about 100 levels made a collection unreadable in Windows PowerShell 5.1 and leaked the document text in the error.
- `deleteDatabase()` trusted the modifiable `FilePath` field and left `-journal` files behind.
- A failed `COMMIT` reported `InTransaction = $false` while the transaction was still open.
- Importing the module left `$csharpCode` and `$isWin` in the caller's session.

### Security

- `PRAGMA trusted_schema = OFF` on every connection, and `pslocalbase_like` registered with `SQLITE_DIRECTONLY`, so triggers and views in an untrusted database file cannot call it.
- Collection names are re-validated before every SQL statement, and all identifier patterns are anchored with `\A...\z`.
- Reads are bounded by `maxDocumentBytes` (default 16 MB) and `maxReadDepth` (default 100).
- CI declares `permissions: contents: read`, pins actions to commit SHAs and does not persist checkout credentials.

### Tests and CI

- New suites: `Hardening-v2` (17 regression checks that fail on 1.0.x), `Property` (seeded randomized comparison against a PowerShell model), `WalMultiProcess` (Windows PowerShell 5.1 and PowerShell 7 writing to one WAL file concurrently), `Review-v2-de8801d`, `PointBridge` (39 checks) and `PrepareIsolation` (17 checks). The full runner executes 19 suites.
- The runner starts every suite in its own process, continues after failures and prints a summary.
- NativeStress N03 is now an assertion: undisposed instances must return native memory to baseline.
- TC-04, TC-38 and TC-72 were renamed to describe what they actually verify; TC-27 and TC-28 assert the new lazy `.doc()` behavior.
- CI now validates the manifest, runs PSScriptAnalyzer (no errors or warnings in the module), verifies the Playground in both editions, and uploads test logs.

### Documentation

- Corrected `createIndex()`/`dropIndex()`, `validate()`, `where()` and `whereType()` examples, which did not match the API.
- Documented `New-LocalBase -Options` and every configuration option.
- Removed references to missing Playground screenshots and to the nonexistent `Open-LocalBaseFromSmb`.
- Made test counts and platform support (Windows only; ARM64 unverified) consistent across documents; `QUICKSTART.md` is now a short guide.

## 1.0.0

Initial release.
