# Sol Medium review: Documentation and Test Adequacy

## Identity and scope

- Provider/model/effort: **Codex / GPT-6.1 Sol / Medium** (native agent assignment).
- Date: November 4, 2026, America/New_York.
- Baseline: `main` HEAD `d6b5e537bf7b9aee83ee8fb092f0c5615e2b6b2a`, module 2.1.0, plus the frozen pending documentation/help changes recorded in `baseline-sha256.csv`.
- Independently inspected the 12 current non-review Markdown files, exported cmdlet help/contracts, representative fluent implementations, all suite purposes, the fixed-seed property model, concurrency/second-review tests, CI, Playground verification and the publishing path. No production/documentation/test source was changed by this reviewer.
- Assigned scores cover Documentation and Test Adequacy only. Historical scores and reported past PASS results were not adopted as current evidence.

## Findings

No critical, high or medium defect was confirmed in the assigned areas. The remaining documentation issues below are low severity; evidence gaps are identified separately from implementation defects.

### D1 — Point-read and first-result shape descriptions remain inconsistent (low, confirmed documentation defect)

**Evidence:** `_DOCS/README.md:391` describes a point result as a native PSCustomObject or absent null. `_DOCS/README.md:403` describes `first()` as retrieving the first matching document. `PSLocalBase.psm1:1722` returns the deserialized point value, while `PSLocalBase.psm1:1925` indexes an array result. `_DOCS/SPECIFICATION.md` now describes these special cases correctly.

**Reproduction in both editions:** Store `@(7,8)` at `shape/array`; `.doc('array').get()` is a two-element array, but `.doc('array').first()` returns integer `7`. Store JSON null at `shape/null`; its point `get()` is null while `exists()` is true and `get(@{keys=$true}).key` identifies the present document.

**Observed versus expected:** Runtime is consistent with the newer specification, but the guide's general point/first wording implies an object/document result for these inputs. Readers should receive the same contract in the main guide and specification. This can cause an array-valued document to be mistaken for a single element, or stored null to be mistaken for absence.

**Recommendation:** Qualify the point paragraph as object-document behavior, document other JSON shapes and null wrappers, and explicitly cross-link the point-array `first()` rule. This is a guide correction, not a requested behavior change.

### D2 — Group metadata is described as unconditional (low, confirmed documentation defect)

**Evidence:** `_DOCS/README.md:623` says each group result includes `_collection`. The root README and specification already explain that projection may omit it and that the returned view replaces a stored property of that name.

**Reproduction in both editions:** Store `{v=1; _collection='stored'}` in `logs_a/x`. `collectionGroup('logs_*').get()[0]._collection` is `logs_a`; `collectionGroup('logs_*').select('v').get()[0]` has no `_collection` property.

**Observed versus expected/impact:** The guide omits these documented view/projection conditions. Consumers relying on metadata after projection can receive null. Repeat the root/spec qualification in the guide.

### D3 — Existence-query execution description is broader than the implementation (low, confirmed documentation defect)

**Evidence:** `_DOCS/README.md:409` presents existence checks as `SELECT 1 ... LIMIT 1`. `PSLocalBase.psm1:1938` uses count for point/paged queries and `limit(1).get()` for unions. The specification accurately distinguishes these paths.

**Trigger/impact:** Reading the guide to estimate the cost or deserialization behavior of point, paged or union `exists()` calls gives an inaccurate execution model. The expected guide description should qualify the ordinary unpaged collection path and refer to the specification for the others. This is not a newly discovered performance regression.

### D4 — Benchmark diagram retains an inconsistent serialization depth (low, confirmed documentation defect)

**Evidence:** `_DOCS/BENCHMARKS.md:159` labels the flat-JSON serialization diagram `ConvertTo-Json -Depth 20`, whereas the corrected methodology and actual benchmark scripts use Depth 10.

**Trigger/impact:** Comparing the diagram with the methodology produces two different settings for the represented benchmark. Change the diagram to Depth 10 or label it as a separate conceptual example. Historical timings should remain historical.

### T1 — Abrupt-crash/fault recovery is not independently exercised by the automated suites (informational, evidence gap)

**Evidence:** `_TESTS/PSLocalBase.WalMultiProcess.Tests.ps1:23` coordinates two normal writers and checks final counts/integrity. Its process kills at lines 74 and 100 are timeout/cleanup actions, not intentional crash-recovery scenarios. Inspection of the suite set found no forced writer-termination/reopen recovery test, disk-full fault injection, or power-loss simulator.

**Trigger/impact:** A release claim about recovery during abrupt interruption is supported principally by SQLite's design and normal rollback/integrity tests, rather than a project-level fault campaign. This does not prove a recovery defect. Add a bounded disposable-process crash/reopen test and explicitly separate filesystem/power-loss assumptions from tested process recovery.

### T2 — Native/platform variation has limited automated evidence (informational, evidence gap)

**Evidence:** `.github/workflows/ci.yml:15` uses one `windows-latest` image, with two PowerShell editions. `winsqlite3.dll` comes from that OS image, so these runs do not exercise a matrix of native SQLite/Windows versions, ARM64 or the separately listed deployment environments.

**Impact/recommendation:** The Windows-only/native-DLL assumption is documented correctly; it is not itself a defect. Add representative explicitly supported OS/native-version jobs or publish a narrow verified-environment table rather than inferring parity from a single image.

### T3 — Documentation/package checks are manual review evidence, not CI regression gates (informational, evidence gap)

**Evidence:** `.github/workflows/ci.yml:23-59` validates the manifest, four module files with PSScriptAnalyzer, both full runners and both Playground automation runs. It does not parse Markdown examples, compare documented exports/parameters, check local links, or run the publisher's local DryRun allowlist check.

**Impact/recommendation:** This audit's clean examples and package verification can regress without CI detecting them. Promote bounded, offline documentation checks and local package construction/inspection to explicit test jobs. Do not interpret current manual validation as an existing CI gate.

### T4 — Property exploration is deliberately narrow and fixed (informational, evidence gap)

**Evidence:** `_TESTS/PSLocalBase.Property.Tests.ps1:5` hardcodes seed 20261029, uses simple integer/null/missing fields and eight scalar operators at line 65, with 80+40+40 rounds at lines 68, 84 and 101. Dedicated example tests cover additional features, but the randomized model does not generate the full document/query domain.

**Impact/recommendation:** Reproducibility is a strength; repeated green runs explore the same generated sample. Retain the fixed regression seed and add an optional bounded seed list and richer independent nested/array/type generators. This is an adequacy improvement, not evidence of an observed mismatch.

## Scores

| Area | Fresh score / 100 | Strengths and explicit deductions |
|---|---:|---|
| Documentation | **94** | Broad usable guide, all 22 exports documented, correct release/main status and clear contracts for pipeline materialization, numeric limits, index tradeoff and historical provenance. Deduct 3 for D1's cross-guide point/first shape inconsistency, 1 for D2 group metadata, 1 for D3 execution-path overstatement, and 1 for D4 benchmark setting inconsistency. All are confirmed low-severity documentation defects on the frozen baseline. |
| Test Adequacy | **91** | Strong 22-suite regression inventory, isolated edition-aware runner, model comparison, native resource probes, complete-string wildcard oracles, destructive-operation/identity guards, two-process WAL and real integrity checks. Deduct 4 for T1 fault-recovery evidence gap, 2 for T2 platform/native-version evidence gap, 2 for T3 absent documentation/package CI gates, and 1 for T4 fixed/narrow randomized exploration. These deductions are evidence gaps, not measured uncovered-line percentages. |

The documented numeric comparison domain, guard-driven expression-index performance limitation, materialized reads and Windows-only/native DLL requirement were reviewed as accepted design tradeoffs, not scored again as new defects. Their presence in the root guide/specification improves clarity.

## Validation executed

Ran a reviewer-authored isolated in-memory probe using:

```text
pwsh -NoProfile -File %TEMP%/PSLocalBase-sol-docs-independent.ps1 -Root .
powershell -NoProfile -File %TEMP%/PSLocalBase-sol-docs-independent.ps1 -Root .
```

Both runs completed successfully: **Core 7.6.9** and **Desktop 5.1.26100.9843**. Checks confirmed:

1. Array-valued point `get()` retains both elements, while point `first()` returns element 7.
2. Stored null returns null with positive existence; a keys wrapper distinguishes its identity.
3. Group views replace stored `_collection`; projecting only `v` omits the metadata.
4. Dotted projection produces a literal `profile.city` property rather than a nested profile object.
5. Created index names use a 16-hex-character suffix (64-bit prefix of SHA-256), matching the current implementation.
6. All **117 PowerShell fences** in the **12 non-review Markdown documents** parse with no errors in both editions.
7. Each of the **22 actual exported functions** is named in the cmdlet guide.

Also inspected the suite runner's missing-file/nonzero-exit handling, the 22-suite inventory and representative assertions, property oracle, concurrent-worker lifecycle/integrity assertions, second-review regressions, publisher archive allowlist, CI action pins/permissions and Playground verification structure. `git diff --check` completed successfully. No complete functional runner, GUI visual session, publishing operation or live service workflow was executed by this specialist; the coordinator owns those shared validation results.

## Limits and objections

Scores concern this frozen working copy and assigned areas only. Syntax parsing does not execute all examples or establish semantic correctness of every composition. No measured line/branch coverage, mutation test campaign, broad fuzzer, external penetration test or OS/native-version matrix was performed. No external URLs or Gallery availability were checked. Parent-coordinated results must be recorded separately with their own outcomes; historical PASS tables are not substitutes.

The main objection to an unconditional documentation-alignment claim is that a few duplicated guide paragraphs still lag the more precise specification. The main objection to a perfect testing score is limited fault/environment exploration and missing regression gates for the documentation/package checks now being performed manually. No runtime defect was demonstrated by this specialist's targeted probes.
