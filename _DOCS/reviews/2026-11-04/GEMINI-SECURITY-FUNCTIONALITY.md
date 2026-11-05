# Gemini 3.8 Flash: Security and Functionality/Data Integrity Review

## Identity and scope

- Provider: **Google DeepMind / Antigravity**; model: **gemini-3.8-flash**; thinking level / effort: **medium** (as configured).
- Baseline: working copy on `main`, HEAD `d6b5e537bf7b9aee83ee8fb092f0c5615e2b6b2a`, module **2.1.0**, including pending documentation/help edits recorded in `baseline-sha256.csv`.
- Scope: Independent inspection of native SQLite bridge, parameterized query binding, SQL/JSON filter compilation, transaction/savepoint mechanics, collection/key validation, destructive cmdlets, pipeline identity safety, and numeric boundaries.
- No production runtime files were altered. Probes were executed independently across both PowerShell editions. Historical scores were treated as background context rather than target anchors.

## Findings

**No critical, high, or medium security vulnerability or unmitigated data loss defect was identified.** The observations below reflect documented design boundaries, operational tradeoffs, and testing boundaries.

### G-SF-01 — Informational: Total query memory is unmetered despite per-document limits

- **Evidence:** `PSLocalBase.psm1:935` enforces per-document size limits (`_ValidateDocumentJson`), but `PSLocalBase.psm1:1901-1903` and `_ExecuteBoundQuery` (`PSLocalBase.psm1:2594`) materialize all matching SQL rows into memory prior to returning a `[System.Collections.Generic.List[object]]`.
- **Trigger:** Calling `Get-LocalBaseDocument` or `.get()` against a collection with tens of thousands of documents without specifying a SQL-level `limit()` / `-First`.
- **Observed vs Expected:** Query execution materializes entire result sets into managed memory before returning. Pipelining with `Select-Object -First 1` downstream does not prevent full upstream SQL materialization. This behavior matches the documented design specification (`_DOCS/SPECIFICATION.md:467`).
- **Impact:** Memory exhaustion risk under massive unpaged queries in constrained environments.
- **Recommendation:** Retain documented guidance requiring explicit pagination (`limit`/`skip` or `-First`/`-Skip`) when querying large or untrusted collections.

### G-SF-02 — Informational: Conservative numeric precision domain and guarded expression-index tradeoff

- **Evidence:** `InitWinSqlite3Native.ps1:90` (`ValidateNumericJson`), `PSLocalBase.psm1:1417`, and `PSLocalBase.psm1:2499`.
- **Trigger:** Attempting comparisons with scalar parameters outside safe integer / IEEE 754 float ranges (e.g., `[uint64]::MaxValue`), or comparing `EXPLAIN QUERY PLAN` between raw SQL and guarded fluent queries.
- **Observed vs Expected:** Unsafe numeric values are rejected at binding time to prevent silent rounding/truncation anomalies. For expression indexes, fluent queries perform guarded extraction over whole documents to ensure precision safety, resulting in table scans rather than index seeks unless raw SQL is used.
- **Impact:** Correctness and safety are prioritized over raw numeric index acceleration.
- **Recommendation:** Maintain the safe numeric boundary. Document that callers needing high-throughput numeric range queries should consider key-based or raw indexed queries where supported.

### G-SF-03 — Informational: Point-array document `first()` vs `get()` contract asymmetry

- **Evidence:** `PSLocalBase.psm1:1722` (`get()`) returns the full array, while `PSLocalBase.psm1:1925` (`first()`) extracts the first element of the deserialized document array.
- **Reproduction:** Storing `@(10, 20, 30)` at `.doc('arr')`: `.doc('arr').get()` yields the three-element array, whereas `.doc('arr').first()` returns integer `10`. Using `.first(@{ keys = $true }).data` preserves the full array structure.
- **Observed vs Expected:** Consistent with updated specification (`_DOCS/SPECIFICATION.md`). It represents an API ergonomic asymmetry rather than data corruption.
- **Recommendation:** Users storing root JSON arrays should utilize `.get()` or key wrappers (`@{ keys = $true }`).

### G-SF-04 — Informational: Host environment and filesystem fault boundaries

- **Evidence:** Strict System32 DLL loading (`InitWinSqlite3Native.ps1:23`), path preflight checking for network/UNC paths (`PSLocalBase.psm1:175`), and pre-removal handle closure (`PSLocalBase.Cmdlets.ps1:242`).
- **Observed vs Expected:** Local disk operations are strictly guarded. Deletion across multiple database files (e.g., `-wal` and `-shm`) is inherently multi-step on Windows filesystems.
- **Impact/Limits:** Automated verification was deterministic and in-memory; abrupt host power loss or adversarial filesystem symlink manipulation was not actively fuzzed.
- **Recommendation:** Retain documentation advising local SSD storage and graceful connection teardown before file manipulation.

## Scores

| Area | Fresh Score | Strengths and Explicit Deductions |
|---|---:|---|
| **Security** | **96/100** | Strict parameter binding (`PSLocalBase.psm1:2499`), rigid identifier whitelisting preventing SQL injection in tables/fields/collections (`SEC-01`), pre-prepare compound SQL statement rejection (`SEC-03`), embedded NUL rejection in keys (`SEC-02`), DIRECTONLY callback isolation preventing trigger-based privilege escalation (`InitWinSqlite3Native.ps1:137`), private pipeline identity protection against property tampering (`PSLocalBase.Cmdlets.ps1:18`, `SEC-05`), and empty filter deletion safeguards preventing accidental table wipes (`SEC-04`).<br>• Deductions: **-2** for unbounded aggregate query memory (G-SF-01), **-2** for lack of adversarial filesystem/power-loss fault injection testing (G-SF-04). |
| **Functionality / Data Integrity** | **95/100** | Strict AND conjunction between point document lookup and where filters (`FUNC-01`), defensive JSON schema validation and depth bounds (`PSLocalBase.psm1:935`), atomic savepoint rollback on duplicate key collision during bulk replace (`FUNC-04`), automated transaction rollback and tentative output withholding on error (`CODE-02`), and numeric precision overflow guards (`FUNC-02`).<br>• Deductions: **-2** for conservative numeric domain excluding full UInt64/Decimal range (G-SF-02), **-1** for guarded expression-index table scan tradeoff (G-SF-02), **-1** for point-array `first()` asymmetry (G-SF-03), **-1** for fully materialized query reads (G-SF-01). |

## Validation executed

Independent targeted probe script executed across both PowerShell engines:
- **PowerShell 7.6.9 (Core)**: 15/15 probes PASSED (evidence logged in `_DOCS/reviews/2026-11-04/evidence/PSLocalBase-rereview-gemini-core.log`).
- **Windows PowerShell 5.1.26100.9843 (Desktop)**: 15/15 probes PASSED (evidence logged in `_DOCS/reviews/2026-11-04/evidence/PSLocalBase-rereview-gemini-desktop.log`).

Key security and functionality validations verified:
1. `SEC-01`: Identifier injection rejection across collection names and field paths containing SQL control characters.
2. `SEC-02`: Bound SQL injection resistance round-tripping special characters, quotes, and embedded NUL bytes in document payloads, while rejecting NUL in keys.
3. `SEC-03`: Compound statement injection (`PRAGMA busy_timeout=9999; SELECT 1;`) rejected before execution without side effects.
4. `SEC-04`: `Remove-LocalBaseDocument -Filter @{}` without `-Id` or `-All` strictly rejected with terminating error, preventing table truncation.
5. `SEC-05`: Tampering with user-visible `id` or document properties does not overwrite target documents due to private pipeline note tracking.
6. `FUNC-01`: Combining `.doc('id')` with `.where(...)` evaluates as strict logical AND, correctly returning null on mismatched criteria.
7. `FUNC-02`: Numeric integrity verified across IEEE 754 safe bounds; UInt64 overflow queries safely rejected.
8. `FUNC-03`: Point-array `first()` vs `get()` contract validated.
9. `FUNC-04`: Bulk replacement savepoint rollback verified under duplicate key collision; outer transaction and existing records preserved.

## Limits and objections

- Full test runner (22 suites), playground automation, and packaging verification were performed by the coordinator; this review specifically targets independent exploratory and edge-case probes.
- Probes were executed against in-memory databases (`:memory:`); physical power-loss or hard disk corruption was not simulated.
- Documented design decisions (materialized reads, conservative numeric typing, Windows native DLL coupling) are evaluated as intentional architectural choices, not exploitable defects.
