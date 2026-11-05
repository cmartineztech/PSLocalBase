# PSLocalBase vs Flat JSON Benchmark Results

This document provides a comprehensive empirical performance and architectural evaluation comparing **PSLocalBase** (embedded SQLite NoSQL engine via Windows native `winsqlite3.dll`) against **Native PowerShell Flat JSON file persistence** (`ConvertTo-Json`, `ConvertFrom-Json`, `Get-Content`, `Set-Content`).

**Historical measurements:** The tables retain the results reported on October 30, 2026. They have not been rerun for 2.1.0 and do not establish current performance guarantees. In particular, the current numeric guard changes JSON extraction and expression-index use; rerun the scripts on the intended host and version before using these ratios for capacity planning.

Tests were conducted across both **5,000 records** and **10,000 records** across two distinct operational paradigms:
1. **Persistent Disk Storage:** Direct on-disk operations (`.db` with WAL mode vs `.json` file on disk).
2. **In-Memory Engine & Local Disk Sync:** Working purely in RAM (`:memory:` vs in-memory object arrays) and synchronizing dirty state back to persistent disk storage (`VACUUM INTO` vs full JSON serialization).

---

## Benchmark Environment

| Specification | Details |
| :--- | :--- |
| **Operating System & Architecture** | Microsoft Windows 10.0.26340 (x64) |
| **Hardware Profile** | High-performance x64 host with NVMe Solid-State Storage (PCIe NVMe SSD) |
| **PowerShell Version** | PowerShell 7.6.9 Core (tested also on Windows PowerShell 5.1.26100) |
| **Native Engine** | Windows native `C:\Windows\System32\winsqlite3.dll` (Zero External Dependencies) |
| **Storage Modes** | Persistent WAL Disk (`.db`) & High-Performance In-Memory (`:memory:`) |
| **Disk Sync Strategy** | SQLite `VACUUM INTO` snapshot vs PowerShell `ConvertTo-Json -Compress -Depth 10` and `WriteAllText` |
| **Test Suites** | `_TESTS/benchmark-comparison.ps1` (5k) & `_TESTS/benchmark-10k.ps1` (10k) |
| **Measurement Date** | Updated 2026-10-30 |

### Benchmark Methodology & Scope

- **Hardware & OS Profile:** Benchmarks were captured on a modern 64-bit Windows workstation (Windows 10/11 x64) backed by a high-throughput NVMe SSD storage subsystem and the operating system's native `winsqlite3.dll` library.
- **Execution Measurement:**
  - Measurements utilize high-resolution `[System.Diagnostics.Stopwatch]` timing windows with pre-run memory stabilization via `[System.GC]::Collect()` and `[System.GC]::WaitForPendingFinalizers()`.
  - Module import occurs before timing, but the scripts do not perform explicit per-operation warm-ups or repeated statistical samples. First-use JIT and cache effects can therefore remain in timed operations.
  - Figures below are reported single-run totals from `_TESTS/benchmark-comparison.ps1` and `_TESTS/benchmark-10k.ps1` on local NVMe disk, not medians or confidence intervals. Individual operation blocks can include loops; compare their actual workloads in the scripts.
- **Scope of Comparison:**
  - This benchmark evaluates the embedded SQLite NoSQL document model (`PSLocalBase`) against PowerShell's standard flat JSON document persistence paradigm (`Get-Content`, `ConvertFrom-Json`, `ConvertTo-Json`, `Set-Content`).
  - The persistent disk comparison focuses on the architectural cost of individual record mutations: PSLocalBase performs $O(\log N)$ in-place B-Tree page modifications appended to a WAL log, whereas naive flat JSON persistence requires reading, deserializing, modifying, re-serializing, and overwriting the entire multi-megabyte JSON array to update or delete a single document.
  - The in-memory comparison contrasts SQLite's in-memory database (`:memory:`) and binary snapshot (`VACUUM INTO`) against managed .NET heap object scans and full string serialization.

---

## Executive Summary: Key Highlights (10,000 Records)

At 10,000 records, the fundamental architectural differences between an indexed B-Tree database engine and flat file serialization become stark:

### 🌟 Part 1: Persistent Disk Comparison (10,000 Records)
* 🚀 **Individual Deletions on Disk:** PSLocalBase is **553.62x faster** (16.42 ms vs 9,090.44 ms).
* ⚡ **Atomic Document Upsert on Disk:** PSLocalBase is **419.05x faster** (21.30 ms vs 8,925.83 ms) via native `INSERT ... ON CONFLICT DO UPDATE`.
* ⚡ **Partial Document Updates on Disk:** PSLocalBase is **133.86x faster** (68.44 ms vs 9,161.33 ms).
* 🎯 **Instant Existence Verification (`exists()`):** PSLocalBase is **23.45x faster** (11.51 ms vs 269.96 ms) with SQL `SELECT 1 ... LIMIT 1`.
* 🔍 **Sorting & Top-N Pagination:** PSLocalBase is **14.14x faster** (27.47 ms vs 388.45 ms).
* 📑 **Selective Field Projection (`select()`):** PSLocalBase is **10.70x faster** (24.52 ms vs 262.31 ms) using native `json_object` filtering in C.
* 📊 **Aggregate Count (`count()`):** PSLocalBase is **9.64x faster** (31.04 ms vs 299.10 ms).
* ➕ **Mathematical Aggregations (`sum()`):** PSLocalBase is **7.45x faster** (39.80 ms vs 296.65 ms).
* 🏷️ **Array Length Filtering (`whereLength()`):** PSLocalBase is **7.03x faster** (34.74 ms vs 244.21 ms) evaluating SQLite `json_array_length`.
* 🔗 **Relational Cross-Collection JOIN:** PSLocalBase is **4.35x faster** (35.37 ms vs 153.98 ms).
* 🎯 **Point Lookups by Key:** PSLocalBase is **3.91x faster** (122.32 ms vs 478.12 ms).
* 🔎 **Multi-filter Query (`active` AND `score >= 80`):** PSLocalBase is **2.39x faster** (126.71 ms vs 302.94 ms).

### ⚡ Part 2: In-Memory Engine & Disk Sync (10,000 Records)
* 💾 **Disk Snapshot Export:** PSLocalBase's `VACUUM INTO` was **16.66x faster** in the reported run than serializing and writing flat JSON to disk (24.34 ms vs 405.54 ms).
* 🎯 **In-Memory Point Lookups (100 random IDs):** PSLocalBase is **8.07x faster** (25.53 ms vs 206.00 ms) due to primary key B-Tree index lookup vs PowerShell collection scans.
* 📑 **In-Memory Sorting & Pagination:** PSLocalBase is **4.82x faster** (13.36 ms vs 64.38 ms).
* ✏️ **In-Memory Document Updates (100 docs):** PSLocalBase is **2.65x faster** (102.75 ms vs 272.69 ms).

---

## Part 1: Persistent Disk Benchmark (10,000 Records)

Direct persistence to disk (`PSLocalBase` SQLite `.db` in WAL mode vs flat `.json` file).

| Operation | PSLocalBase (ms) | Flat JSON File (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **Individual Deletions (10 records on disk)** | **16.42 ms** | 9,090.44 ms | **553.62x** | **PSLocalBase** 🏆 |
| **Atomic Upsert (10 records on disk)** | **21.30 ms** | 8,925.83 ms | **419.05x** | **PSLocalBase** 🏆 |
| **Partial Updates (10 records on disk)** | **68.44 ms** | 9,161.33 ms | **133.86x** | **PSLocalBase** 🏆 |
| **Instant Existence Check (`exists()`)** | **11.51 ms** | 269.96 ms | **23.45x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10 DESC)** | **27.47 ms** | 388.45 ms | **14.14x** | **PSLocalBase** 🏆 |
| **Selective Field Projection (`select()` 100 docs)** | **24.52 ms** | 262.31 ms | **10.70x** | **PSLocalBase** 🏆 |
| **Scalar Aggregate Count (`count()`)** | **31.04 ms** | 299.10 ms | **9.64x** | **PSLocalBase** 🏆 |
| **In-Engine Mathematical Sum (`sum()`)** | **39.80 ms** | 296.65 ms | **7.45x** | **PSLocalBase** 🏆 |
| **Array Length Filtering (`whereLength`)** | **34.74 ms** | 244.21 ms | **7.03x** | **PSLocalBase** 🏆 |
| **Dual Collection Relational JOIN (5k x 5k)** | **35.37 ms** | 153.98 ms | **4.35x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **122.32 ms** | 478.12 ms | **3.91x** | **PSLocalBase** 🏆 |
| **Multi-filter Query (`active` AND `score >= 80`)** | **126.71 ms** | 302.94 ms | **2.39x** | **PSLocalBase** 🏆 |
| **Bulk Ingestion (10,000 records to disk)** | 3,938.03 ms | 304.21 ms | 0.08x | Flat JSON *(raw string dump)* |

---

## Part 2: In-Memory Engine & Local Disk Sync (10,000 Records)

Both systems operate with the entire dataset pre-loaded in memory. Modifications happen in RAM, followed by a timed export to persist the dataset. The JSON write is not an atomic replacement, and neither export is a crash-durability benchmark.

* **PSLocalBase Strategy:** `[PSLocalBase]::new(":memory:")` uses SQLite's in-memory database and calls `VACUUM INTO 'disk.db'` to create a consistent, compacted snapshot at a new destination. Wrapper serialization and deep merges still run in managed PowerShell/.NET code.
* **Flat JSON Strategy:** An in-memory object list mutated in RAM, then serialized using `ConvertTo-Json -Compress -Depth 10` and written using `[System.IO.File]::WriteAllText()`.

| Operation | PSLocalBase In-Memory (ms) | Flat JSON In-Memory (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **SYNC IN-MEMORY STATE TO DISK** | **24.34 ms** | 405.54 ms | **16.66x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **25.53 ms** | 206.00 ms | **8.07x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10)** | **13.36 ms** | 64.38 ms | **4.82x** | **PSLocalBase** 🏆 |
| **In-Memory 100 Document Updates** | **102.75 ms** | 272.69 ms | **2.65x** | **PSLocalBase** 🏆 |
| **Loading 10,000 Records into RAM** | 1,696.14 ms | 101.91 ms | 0.06x | Flat JSON |
| **Aggregate Count (Filter + Count)** | 11.26 ms | 3.54 ms | 0.31x | Flat JSON *(direct object property)* |
| **Multi-filter Query (`active` AND `score >= 80`)** | 61.86 ms | 7.15 ms | 0.12x | Flat JSON *(direct object property)* |

> **Analysis of In-Memory Filtering:** Flat object lists were faster for the measured in-memory scans and ingestion, while PSLocalBase was faster for the reported lookup, sort, update and snapshot workloads. These ratios apply to these implementations, datasets and historical runs; indexed .NET dictionaries or another persistence strategy could produce different results.

---

## 5,000 Records Baseline Comparison

Empirical results from `_TESTS/benchmark-comparison.ps1`:

| Operation | PSLocalBase (ms) | Flat JSON File (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **Individual Deletions (10 docs)** | **18.13 ms** | 4,487.39 ms | **247.51x** | **PSLocalBase** 🏆 |
| **Partial Updates (10 docs)** | **94.58 ms** | 5,652.73 ms | **59.77x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10 DESC)** | **25.65 ms** | 277.30 ms | **10.81x** | **PSLocalBase** 🏆 |
| **Scalar Aggregate Count (`count()`)** | **26.84 ms** | 178.10 ms | **6.64x** | **PSLocalBase** 🏆 |
| **Relational JOIN (`orders` JOIN `users`)** | **34.97 ms** | 90.72 ms | **2.59x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **150.11 ms** | 301.22 ms | **2.01x** | **PSLocalBase** 🏆 |
| **Multi-filter Query (`active` + `score >= 80`)** | **109.62 ms** | 143.39 ms | **1.31x** | **PSLocalBase** 🏆 |
| **Bulk Ingestion (5,000 docs)** | 2,546.68 ms | 163.61 ms | 0.06x | Flat JSON |

---

## Storage Footprint Analysis

| Metric | PSLocalBase (`.db`) | Flat JSON File (`.json`) | Ratio |
| :--- | :---: | :---: | :---: |
| **10,000 Records on Disk (Part 1)** | **4,728 KB** (4.62 MB) | **2,018 KB** (1.97 MB) | 2.34x |
| **10,000 Records Synced Disk (Part 2)** | **4,708 KB** (4.60 MB) | **2,026 KB** (1.98 MB) | 2.32x |
| **5,000 Records on Disk (Baseline)** | **2,372 KB** (2.32 MB) | **1,005 KB** (0.98 MB) | 2.36x |

### Why SQLite uses ~2.3x the disk space of flat JSON:
1. **B-Tree Page Allocation:** SQLite structures data into fixed-size 4KB pages containing cell pointers, interior nodes, and leaf records for $O(\log N)$ access.
2. **Primary Key Indexes:** Pre-computed index trees for fast point lookups and uniqueness validation.
3. **WAL Sidecars:** The scripts measure the main `.db` file, not a combined `.db` + `-wal` + `-shm` footprint. WAL mode can consume additional temporary space, so these ratios do not represent peak storage use.
4. **Observed Tradeoff:** The reported dataset used more SQLite storage while its measured mutation and snapshot workloads were faster. Transactions protect against partial logical updates, but do not eliminate all corruption risks.

---

## Architectural Deep Dive: The Flat JSON Scalability Wall

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       FLAT JSON PERSISTENCE BOTTLENECK                          │
│                                                                                 │
│  [Disk JSON File (2.0 MB / 10,000 records)]                                     │
│           │                                                                     │
│           ▼ (ReadAllText: Full File Read)                                       │
│  [Raw JSON String in RAM]                                                       │
│           │                                                                     │
│           ▼ (ConvertFrom-Json: Deserializes ALL 10,000 Objects into .NET Heap)   │
│  [10,000 PSCustomObjects in Managed Heap]                                       │
│           │                                                                     │
│           ▼ (O(N) linear search through 10,000 items to mutate 1 document)      │
│  [Modified In-Memory Object Tree]                                               │
│           │                                                                     │
│           ▼ (ConvertTo-Json -Depth 10: Serializes ALL 10,000 Objects to JSON)   │
│  [2.0 MB JSON String in Managed Heap]                                           │
│           │                                                                     │
│           ▼ (WriteAllText: Replaces Entire File on Disk)                        │
│  [Disk JSON File]                                                               │
│                                                                                 │
│  ⚠️ MULTIPLIED BY N OPERATIONS: 10 UPDATES = ~9.1 SECONDS!                      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     PSLOCALBASE IN-PLACE B-TREE ARCHITECTURE                    │
│                                                                                 │
│  [Incoming Mutation: .doc("usr-429").update(@{ score = 99 })]                  │
│           │                                                                     │
│           ▼                                                                     │
│  [SQLite B-Tree Index: O(log N) lookup directly to 4KB page]                    │
│           │                                                                     │
│           ▼                                                                     │
│  [Native WAL In-Place Page Write (~4KB appended to WAL journal)]                │
│           │                                                                     │
│           ▼                                                                     │
│  ⚡ COMPLETED IN ~6.8 MILLISECONDS PER UPDATE (133x FASTER)                      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key Architectural Advantages of PSLocalBase:
1. **Indexed Point Mutations:** A keyed update avoids rewriting the whole database. `update()` reads, merges and serializes the entire selected document; SQLite may modify multiple data/index pages, with page size and WAL volume depending on configuration and document size.
2. **Pushdown Filtering:** Query clauses execute inside SQLite, reducing managed document deserialization for rows discarded there. The current managed numeric guard still inspects JSON text and can allocate memory; filtering does not eliminate GC pressure.
3. **`VACUUM INTO` Snapshots:** A snapshot avoids reserializing every document through PowerShell. It requires no active transaction and a destination that does not already contain data; a snapshot interrupted before completion must not be published.
4. **Transactional Writes:** SQLite transactions protect logical atomicity; power-loss durability depends on synchronous mode, filesystem and hardware. Directly overwriting a flat JSON file can leave a partial file after interruption.
5. **WAL Concurrency:** Readers and one writer can operate concurrently. Writers serialize, readers can delay checkpoints, and busy/lock errors remain possible.

---

## Reproduction Instructions

To reproduce these benchmarks on your local machine:

Run from a repository checkout in a fresh PowerShell session on Windows. The scripts recreate `_TESTS/temp_bench_data` (5k) and `_TESTS/temp_bench_10k` (10k); keep user data outside these benchmark scratch directories. Record the commit, host, native SQLite version and repeated runs when comparing current results.

```powershell
# Run the 10,000 Records Benchmark Suite (Part 1 Disk + Part 2 In-Memory & Sync):
pwsh -ExecutionPolicy Bypass -File .\_TESTS\benchmark-10k.ps1

# Run the 5,000 Records Baseline Benchmark Suite:
pwsh -ExecutionPolicy Bypass -File .\_TESTS\benchmark-comparison.ps1
```
