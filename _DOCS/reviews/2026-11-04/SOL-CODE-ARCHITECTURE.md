# Sol Medium: Code Quality and Architecture Review

## Identity and scope

- Provider: **Codex**; model: **gpt-6.1-sol**; reasoning effort: **medium**, as assigned and inherited from the coordinating run.
- Reviewed base: `main`, HEAD `d6b5e537bf7b9aee83ee8fb092f0c5615e2b6b2a`, module **2.1.0**, including the pending documentation/help edits identified by `baseline-sha256.csv`.
- Reviewed native interop and callbacks, initialization/configuration, SafeHandle ownership, parent/child lifecycle, query cloning/composition, serialization/merge, SQL execution/binding, transaction handling, adapter context/identity, and relevant regression tests. No production files were modified. No subagents were used.
- This is an independent fresh assessment; historical numerical scores were not used as a baseline.

## Findings

### C1 — Low: constructor options lack the range validation used by the adapter

**Classification:** confirmed input-validation weakness; no corruption or security exploit demonstrated.

**Evidence:** `PSLocalBase.psm1:232-234` casts `busyTimeout` to Int32 and applies it without checking its sign. `PSLocalBase.psm1:268-270` similarly accepts a signed `cacheSizeMB`, multiplies it by `-1024`, and passes the result to SQLite. By contrast, `Connect-LocalBase` validates its timeout at `PSLocalBase.Cmdlets.ps1:120`.

**Reproduction, observed in both editions:**

```powershell
$db = New-LocalBase -Options @{ cacheSizeMB = -1; busyTimeout = -1 }
try {
    $db.query('PRAGMA cache_size')
    $db.query('PRAGMA busy_timeout')
} finally {
    $db.close()
}
```

Observed: construction succeeds, `cache_size` is **1024**, and `busy_timeout` is **0**. A positive SQLite cache_size denotes a page-count setting rather than the intended negative KiB target. The negative timeout disables waiting. `Connect-LocalBase -Path ':memory:' -BusyTimeoutMs -1` instead rejects the value at parameter binding.

Expected/recommendation: normalize and validate these options at the shared constructor boundary, with an explicit supported range and consistent handling through both interfaces. At minimum, reject negative timeout and negative cache-size values; document whether zero cache size is supported. Impact is surprising configuration and lock failures under invalid input, not demonstrated damage to correctly configured databases.

### C2 — Low: concentrated implementation and repeated SQL assembly increase maintenance cost

**Classification:** maintainability observation, not a newly reproduced runtime defect.

`PSLocalBase.psm1` places connection ownership, schema/index management, query plans, serialization, merge/equality and execution in one class of roughly 2,900 lines. SQL projection construction is repeated in `_BuildBranchSelect` (`PSLocalBase.psm1:1302` onward) and `get` (`PSLocalBase.psm1:1722` onward); `union` and `unionAll` repeat their validation and plan-capture paths (`PSLocalBase.psm1:694`, `720`).

Trigger: future changes to projection, composition restrictions or numeric extraction require parallel changes across these paths. Current targeted tests passed; no divergence is alleged merely from duplication. Recommendation: gradually factor immutable plan/expression construction and a small connection/execution component, retaining the current regression tests and avoiding a wholesale rewrite.

### A1 — Informational: scalability and environment tradeoffs remain material

**Classification:** accepted, documented design tradeoffs; not new defects.

- The conservative numeric guard scans stored JSON before guarded extraction (`InitWinSqlite3Native.ps1:90`, `PSLocalBase.psm1:1417`). That preserves the intended comparison domain but makes existing plain `json_extract` expression indexes generally unsuitable for fluent filtering/sorting. Key indexes remain useful. The tradeoff is explicitly documented in `_DOCS/SPECIFICATION.md:467`.
- Reads materialize native row text and then PowerShell objects (`PSLocalBase.psm1:2594`, `1903-1918`); `query()` likewise collects a list (`2212-2275`). Per-document limits do not bound total query memory. Bounded paging is the supported mitigation.
- The implementation deliberately relies on Windows' system SQLite, runtime C# compilation and PowerShell/.NET behavior (`InitWinSqlite3Native.ps1:9-23`). This reduces packaged dependencies but ties feature availability and patching to the host; the startup bridge-version guard does not substitute for validating every Windows/.NET/SQLite combination.
- The API is designed around one root connection shared by its child queries. Cross-process concurrency is tested through separate connections; that does not establish safe concurrent use/close of one PowerShell instance across runspaces. This review did not attempt such unsupported sharing.

## Scores

Scores are technical judgments, not coverage measurements or certification. The two categories overlap in evidence but evaluate different concerns; their deductions must not be added into a separate defect count.

| Area | Fresh score | Strengths and explicit deductions |
|---|---:|---|
| Code Quality | **93/100** | Strong typed binding and statement cleanup (`PSLocalBase.psm1:2499-2543`, `2271`, `2589`, `2630`), callback exception containment/static roots (`InitWinSqlite3Native.ps1:52-54`, `137-145`, `215-227`), and failure-preserving transaction cleanup. Deductions: **2** for confirmed constructor-range inconsistency (C1), **3** for concentrated/repeated implementation paths (C2), **2** for remaining assessment uncertainty: inspection and targeted success/error probes do not establish exhaustive cleanup under every native allocation failure or host combination. |
| Architecture | **92/100** | Clear bridge/core/adapter distribution; root SafeHandle ownership and generation validation (`InitWinSqlite3Native.ps1:26-29`, `PSLocalBase.psm1:2405-2449`); immutable query branch copies and composition snapshots (`657-744`); native transaction state and adapter ambient restoration (`2354-2400`, `PSLocalBase.Cmdlets.ps1:877-903`). Deductions for accepted limits/evidence gaps: **3** guarded-query/index performance, **2** fully materialized read design, **2** host-specific engine/runtime coupling, **1** absence of demonstrated shared-instance concurrency guarantees. These are A1 tradeoffs, not claims of newly discovered correctness failures. |

## Validation executed

Executed the same independent in-memory probe script in **PowerShell 7.6.9 (Core)** and **Windows PowerShell 5.1.26100.9843 (Desktop)**. Both processes exited successfully and reported all eight assertions passing:

1. Independent filtered branches and repeated reads leave the base query unchanged.
2. Closing a cloned child leaves the root connection usable.
3. Parameter-count mismatch throws and subsequent reads still work.
4. Compound `PRAGMA busy_timeout=7; SELECT 1;` is rejected before changing the effective timeout.
5. Raw `BEGIN IMMEDIATE` is reflected by the native-backed `InTransaction` property.
6. Rollback restores the document count and native transaction state.
7. Closing the root invalidates preexisting child clones.
8. Adapter parameter validation rejects the negative timeout.

The additional negative-options observation reproduced C1 in both editions. No files or user databases were used by these probes. Commands were `pwsh -NoProfile -File <temporary probe> -Repo <repository>` and `powershell -NoProfile -ExecutionPolicy Bypass -File <temporary probe> -Repo <repository>`; the substantive reproduction is included above.

Inspected native-stress tests covering statement enumeration/finalization and undisposed wrappers, prepare-isolation tests, branch/composition regressions, and adapter transaction cleanup. The coordinator owns full-suite, Playground, packaging and static-analysis results; those are not attributed here as independently executed checks.

## Limits and objections

No critical/high-severity code or architecture defect was confirmed in this review. This statement is scoped to the inspected paths and executed probes. No native allocator fault injection, cross-runspace same-instance race testing, exhaustive Windows-version matrix, or production workload benchmark was performed. Numeric restrictions, expression-index performance and materialized reads are documented accepted boundaries; they should remain visible in the consolidated table without being mislabeled as newly found data-integrity defects. C1 is still present in the frozen reviewed base and should not be reported as fixed by this review.
