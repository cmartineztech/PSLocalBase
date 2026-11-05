# Sol Medium: Security and Functionality/Data Integrity

## Identity and scope

- Provider: **Codex**; model: **gpt-6.1-sol**; reasoning effort: **medium** (inherited from the coordinating agent).
- Baseline: working copy on `main`, HEAD `d6b5e537bf7b9aee83ee8fb092f0c5615e2b6b2a`, module **2.1.0**, including the pending documentation/help edits described by `baseline-sha256.csv`.
- Independently inspected the native bridge, SQL/JSON filter and write paths, transactions, collection/index/composition contracts, disposal, destructive cmdlets and pipeline identity. Read relevant core, contracts, second-review and preparation-isolation tests. No production files were changed; no subagents were used.
- The observations below are fresh review judgments. Historical scores were not used as evidence or a target.

## Findings

**No new confirmed critical, high, medium or low defect was established in this review.** The following are confirmed documented constraints or evidence gaps, not newly discovered vulnerabilities.

### SF-01 — Informational: per-document limits do not bound total read memory

- Evidence: `PSLocalBase.psm1:935` validates one JSON document; `PSLocalBase.psm1:1901` first obtains all selected SQL rows, then constructs the result collection at line 1903. `_ExecuteBoundQuery` at line 2594 materializes the rows.
- Trigger: read a large collection with `get()`/`Get-LocalBaseDocument` without a SQL-side limit; a downstream `Select-Object -First 1` does not reduce the already selected rows.
- Expected/observed: current documentation describes materialized reads and recommends bounded pages. Source confirms this behavior; no unbounded-memory failure was deliberately induced. `maxDocumentBytes`/`maxReadDepth` are not aggregate query budgets.
- Impact: callers handling large or untrusted datasets must bound the query; per-document checks alone do not provide denial-of-service isolation.
- Recommendation: retain the documented boundary and use `limit`/`skip` or `-First`/`-Skip`. A future cancellable cursor or aggregate resource budget would be an enhancement, not a prerequisite for closing this audit.

### SF-02 — Informational: conservative numeric domain and guarded-index tradeoff

- Evidence: `InitWinSqlite3Native.ps1:90` validates numeric JSON; `PSLocalBase.psm1:1417` and lines 1573–1580 guard JSON extraction; `PSLocalBase.psm1:2499` validates/binds parameters. The guard examines the whole stored JSON document.
- Trigger: a legacy/raw-SQL document containing integer `18446744073709551615`, then a guarded comparison or deletion; or compare against `[uint64]::MaxValue`.
- Expected/observed: numeric operations reject unsupported precision instead of producing rounded matches. Independent probes confirmed rejection and no partial deletion in both editions. Whole-document safety can reject a query even when the unsupported number is outside the queried field.
- Trigger for performance: compare `EXPLAIN QUERY PLAN` for `json_extract(doc,'$.v')=1` and `json_extract(pslocalbase_numeric(doc),'$.v')=1` after `createIndex('v')`.
- Expected/observed: compatible raw SQL used the expression index; guarded SQL used a table scan, while the fluent result remained correct. This matches the current documented tradeoff.
- Impact/recommendation: this is intentionally narrower than arbitrary decimal/UInt64 database arithmetic, and the current fluent filter does not gain the raw index's acceleration. Keep both limitations explicit; optimize only while preserving comparison safety and existing contracts.

### SF-03 — Informational: point-array `first()` returns its first element

- Evidence: `PSLocalBase.psm1:1925` applies a limit and then selects the first item from `get()`'s result.
- Reproduction: store `@(10,20)` at `.doc('a')`; `.get()` returns the two-element document, `.first()` returns `10`, while `.first(@{keys=$true}).data` preserves the full array.
- Expected/observed: the specification now explicitly documents this asymmetry, and probes reproduced it in both editions. It is an API ergonomics constraint rather than a contradiction with the reviewed documentation or a storage-loss defect.
- Recommendation: use point `get()` or key wrappers for array-valued documents; changing `first()` should be handled as an intentional API change with regression coverage.

### SF-04 — Informational: environment and filesystem evidence boundaries

- Evidence: System32-only native imports at `InitWinSqlite3Native.ps1:23`; platform preflight at line 9; network path/mapped-drive checks in `PSLocalBase.psm1:175`; removal preflight at `PSLocalBase.Cmdlets.ps1:242` releases exclusive handles before the later `Remove-Item` loop.
- Observed: native DLL isolation, parameterized SQL, path checks and removal guards are present. Removal is documented as non-atomic across files; this is not a demonstrated data-corruption defect.
- Limits: this review did not execute adversarial reparse-point/remote filesystem races, interrupted deletion, forced power loss, fuzzing, or a matrix of Windows SQLite builds. No claim of race-free deletion, universal native memory safety or support for every Windows build follows from these checks.
- Recommendation: retain local-disk guidance, close independent connections before deletion and validate target Windows environments. Use separate destructive fault-injection testing if those deployment risks become requirements.

## Scores

| Area | Fresh score | Strengths and explicit deductions |
|---|---:|---|
| Security | **96/100** | Strong parameter binding, identifier restrictions, pre-prepare compound-statement rejection, UTF-16 length handling, callback exception containment and DIRECTONLY isolation (`InitWinSqlite3Native.ps1:78`, `:137`, `:200`, `:272`); private identity and guarded deletion (`PSLocalBase.Cmdlets.ps1:18`, `:33`, `:748`); stale-handle generation checks (`PSLocalBase.psm1:2431`). Deductions: **2** for aggregate resource-budget limitations (accepted boundary, SF-01), **2** for adversarial native/environment/filesystem testing gaps (evidence gap, SF-04). No confirmed exploitable vulnerability is asserted. |
| Functionality/Data Integrity | **94/100** | Defensive write validation (`PSLocalBase.psm1:935`, `:964`), atomic bulk/savepoint handling (`:1050`), transactional read/merge/write (`:1205`), filter/key conjunction and reusable query state, native transaction-state checks (`:2354`), buffered transaction output and rollback (`PSLocalBase.Cmdlets.ps1:855`). Deductions: **2** for the supported numeric domain (accepted design scope, SF-02), **1** for the fluent expression-index tradeoff (accepted performance limitation, SF-02), **1** for point-array `first()` asymmetry (accepted documented behavior, SF-03), **1** for materialized reads (accepted scalability limitation, SF-01), **1** for incomplete fault/composition/environment evidence (evidence gap). |

The numbers are subjective technical assessments, not coverage percentages, probabilities of correctness, certification or a requirement to fix accepted limitations.

## Validation executed

An independent temporary probe script was run with both:

```text
pwsh -NoProfile -File $env:TEMP/PSLocalBase-sol-security-function-probe-20261104.ps1 -Root .
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP/PSLocalBase-sol-security-function-probe-20261104.ps1 -Root .
```

Both completed with exit **0**, **16/16 independent cases passed**, in PowerShell **7.6.9** (Core) and Windows PowerShell **5.1.26100.9843** (Desktop):

1. Invalid collection identifiers, embedded-newline field names and NUL keys rejected without creating tables.
2. Injection-like keys and values, including Unicode and embedded NUL in values, round-trip through bound SQL.
3. Compound PRAGMA SQL rejected before changing `trusted_schema`; NUL SQL rejected; comment tails accepted.
4. Parameter-count mismatch and BLOB result rejected; subsequent bound query remains usable.
5. Empty deletion filters rejected; pipeline `-WhatIf` preserves documents.
6. Forged visible metadata and `id` do not override a tracked object's private storage identity.
7. Nested-array and JSON-null envelopes survive Get-to-Set round trips.
8. Null equality, explicit JSON null and missing-field filters retain distinct contracts.
9. Unsafe stored numeric values and UInt64 parameters are rejected; failed guarded deletion leaves every row intact.
10. Duplicate-key bulk replacement rolls back its savepoint without destroying the outer transaction or earlier write.
11. Transaction wrapper converts an unhandled nonterminating error into rollback, withholds tentative output and restores ambient state.
12. A trigger cannot invoke the managed `pslocalbase_like` callback during a write; rejected write persists no row.
13. Closing a child rejects later operations on that child and leaves the root usable.
14. Point-array `get`/`first`/key-wrapper behavior matches SF-03.
15. Raw expression-index use versus guarded table scan matches SF-02 while fluent matching remains correct.
16. `PRAGMA integrity_check` returns `ok` after successful and rejected operations.

The initial draft probe incorrectly expected a trailing newline in a field argument to be rejected; `where()` deliberately trims field arguments (`PSLocalBase.psm1:1344`). The probe was corrected to test an embedded newline. This was a test-assumption correction, not a product defect. Final results above refer to the corrected 16-case script.

## Limits and objections

- The coordinator, rather than this specialist, runs the complete suites, GUI automation, static analysis and packaging. Those outcomes must be attributed to the coordinator and joined to this report separately.
- Tests were in-memory, deterministic and targeted. This specialist did not rerun physical backups, remote shares, crash/power-loss tests, arbitrary malicious native inputs, or exhaustive compositions of every fluent operator.
- Windows-only System32 SQLite, limited numeric arithmetic, materialized reads and current expression-index behavior are explicit design boundaries. They should not be relabeled as newly found vulnerabilities or silently removed to improve scores.
- No production source changes are requested by the findings established here.
