# Changelog

All notable changes to PSLocalBase are documented here. The project follows [Semantic Versioning](https://semver.org/).

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
