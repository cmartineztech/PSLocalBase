# PSLocalBase vs Flat JSON Benchmark Results

This document provides a comprehensive empirical performance and architectural evaluation comparing **PSLocalBase** (embedded SQLite NoSQL engine via Windows native `winsqlite3.dll`) against **Native PowerShell Flat JSON file persistence** (`ConvertTo-Json`, `ConvertFrom-Json`, `Get-Content`, `Set-Content`).

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
| **Disk Sync Strategy** | SQLite atomic `VACUUM INTO` vs PowerShell `ConvertTo-Json -Depth 20` |
| **Test Suites** | `_TESTS/benchmark-comparison.ps1` (5k) & `_TESTS/benchmark-10k.ps1` (10k) |
| **Measurement Date** | Updated 2026-10-29 |

### Benchmark Methodology & Scope

- **Hardware & OS Profile:** Benchmarks were captured on a modern 64-bit Windows workstation (Windows 10/11 x64) backed by a high-throughput NVMe SSD storage subsystem and the operating system's native `winsqlite3.dll` library.
- **Warm-Up Iterations & Execution Measurement:**
  - Measurements utilize high-resolution `[System.Diagnostics.Stopwatch]` timing windows with pre-run memory stabilization via `[System.GC]::Collect()` and `[System.GC]::WaitForPendingFinalizers()`.
  - Initial pipeline warm-ups ensure that dynamic P/Invoke compilation (via `Add-Type`) and .NET JIT optimization overhead are excluded from timing measurements.
  - Figures reported in the tables below represent reproducible benchmark executions recorded via `_TESTS/benchmark-comparison.ps1` and `_TESTS/benchmark-10k.ps1` on local NVMe disk.
- **Scope of Comparison:**
  - This benchmark evaluates the embedded SQLite NoSQL document model (`PSLocalBase`) against PowerShell's standard flat JSON document persistence paradigm (`Get-Content`, `ConvertFrom-Json`, `ConvertTo-Json`, `Set-Content`).
  - The persistent disk comparison focuses on the architectural cost of individual record mutations: PSLocalBase performs $O(\log N)$ in-place B-Tree page modifications appended to a WAL log, whereas naive flat JSON persistence requires reading, deserializing, modifying, re-serializing, and overwriting the entire multi-megabyte JSON array to update or delete a single document.
  - The in-memory comparison contrasts SQLite's unmanaged C memory engine (`:memory:`) and atomic binary page dump (`VACUUM INTO`) against managed .NET heap object scans and full string serialization.

---

## Executive Summary: Key Highlights (10,000 Records)

At 10,000 records, the fundamental architectural differences between an indexed B-Tree database engine and flat file serialization become stark:

### 🌟 Part 1: Persistent Disk Comparison (10,000 Records)
* 🚀 **Individual Deletions on Disk:** PSLocalBase is **482.26x faster** (70.24 ms vs 33,874.14 ms).
* ⚡ **Atomic Document Upsert on Disk:** PSLocalBase is **412.80x faster** (58.59 ms vs 24,185.80 ms) via native `INSERT ... ON CONFLICT DO UPDATE`.
* ⚡ **Partial Document Updates on Disk:** PSLocalBase is **148.02x faster** (119.25 ms vs 17,651.23 ms).
* 📑 **Selective Field Projection (`select()`):** PSLocalBase is **14.06x faster** (55.06 ms vs 774.11 ms) using native `json_object` filtering in C.
* 🔍 **Sorting & Top-N Pagination:** PSLocalBase is **13.93x faster** (46.94 ms vs 653.98 ms).
* 🎯 **Instant Existence Verification (`exists()`):** PSLocalBase is **13.04x faster** (85.93 ms vs 1,120.11 ms) with SQL `SELECT 1 ... LIMIT 1`.
* 🏷️ **Array Length Filtering (`whereLength()`):** PSLocalBase is **9.26x faster** (114.21 ms vs 1,057.71 ms) evaluating SQLite `json_array_length`.
* 📊 **Aggregate Count (`count()`):** PSLocalBase is **8.39x faster** (66.95 ms vs 561.58 ms).
* 🔗 **Relational Cross-Collection JOIN:** PSLocalBase is **5.61x faster** (231.31 ms vs 1,296.88 ms).
* ➕ **Mathematical Aggregations (`sum()`):** PSLocalBase is **3.30x faster** (356.76 ms vs 1,177.10 ms).
* 🎯 **Point Lookups by Key:** PSLocalBase is **3.23x faster** (238.68 ms vs 769.84 ms).
* 🔎 **Multi-filter Query (`active` AND `score >= 80`):** PSLocalBase is **3.11x faster** (163.50 ms vs 509.12 ms).

### ⚡ Part 2: In-Memory Engine & Disk Sync (10,000 Records)
* 💾 **Disk Synchronization Flush:** PSLocalBase's native atomic `VACUUM INTO` is **14.48x faster** than serializing and writing flat JSON to disk (75.72 ms vs 1,096.08 ms).
* 🎯 **In-Memory Point Lookups (100 random IDs):** PSLocalBase is **10.10x faster** (84.35 ms vs 852.07 ms) due to primary key B-Tree index lookup vs PowerShell collection scans.
* 📑 **In-Memory Sorting & Pagination:** PSLocalBase is **4.54x faster** (34.06 ms vs 154.48 ms).
* ✏️ **In-Memory Document Updates (100 docs):** PSLocalBase is **4.05x faster** (240.19 ms vs 973.39 ms).

---

## Part 1: Persistent Disk Benchmark (10,000 Records)

Direct persistence to disk (`PSLocalBase` SQLite `.db` in WAL mode vs flat `.json` file).

| Operation | PSLocalBase (ms) | Flat JSON File (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **Individual Deletions (10 records on disk)** | **70.24 ms** | 33,874.14 ms | **482.26x** | **PSLocalBase** 🏆 |
| **Atomic Upsert (10 records on disk)** | **58.59 ms** | 24,185.80 ms | **412.80x** | **PSLocalBase** 🏆 |
| **Partial Updates (10 records on disk)** | **119.25 ms** | 17,651.23 ms | **148.02x** | **PSLocalBase** 🏆 |
| **Selective Field Projection (`select()` 100 docs)** | **55.06 ms** | 774.11 ms | **14.06x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10 DESC)** | **46.94 ms** | 653.98 ms | **13.93x** | **PSLocalBase** 🏆 |
| **Instant Existence Check (`exists()`)** | **85.93 ms** | 1,120.11 ms | **13.04x** | **PSLocalBase** 🏆 |
| **Array Length Filtering (`whereLength`)** | **114.21 ms** | 1,057.71 ms | **9.26x** | **PSLocalBase** 🏆 |
| **Scalar Aggregate Count (`count()`)** | **66.95 ms** | 561.58 ms | **8.39x** | **PSLocalBase** 🏆 |
| **Dual Collection Relational JOIN (5k x 5k)** | **231.31 ms** | 1,296.88 ms | **5.61x** | **PSLocalBase** 🏆 |
| **In-Engine Mathematical Sum (`sum()`)** | **356.76 ms** | 1,177.10 ms | **3.30x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **238.68 ms** | 769.84 ms | **3.23x** | **PSLocalBase** 🏆 |
| **Multi-filter Query (`active` AND `score >= 80`)** | **163.50 ms** | 509.12 ms | **3.11x** | **PSLocalBase** 🏆 |
| **Bulk Ingestion (10,000 records to disk)** | 5,156.00 ms | 795.26 ms | 0.15x | Flat JSON *(raw string dump)* |

---

## Part 2: In-Memory Engine & Local Disk Sync (10,000 Records)

Both systems operate with the entire dataset pre-loaded in memory. Modifications happen in RAM, followed by an atomic disk synchronization to persist the dataset.

* **PSLocalBase Strategy:** `[PSLocalBase]::new(":memory:")` executes all queries and updates in unmanaged C RAM, and calls `VACUUM INTO 'disk.db'` to perform an atomic, compacted flush to disk.
* **Flat JSON Strategy:** An in-memory `List[hashtable]` or array of `PSCustomObject` mutated in RAM, then flushed to disk via `ConvertTo-Json -Depth 20 | [System.IO.File]::WriteAllText()`.

| Operation | PSLocalBase In-Memory (ms) | Flat JSON In-Memory (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **SYNC IN-MEMORY STATE TO DISK** | **75.72 ms** | 1,096.08 ms | **14.48x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **84.35 ms** | 852.07 ms | **10.10x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10)** | **34.06 ms** | 154.48 ms | **4.54x** | **PSLocalBase** 🏆 |
| **In-Memory 100 Document Updates** | **240.19 ms** | 973.39 ms | **4.05x** | **PSLocalBase** 🏆 |
| **Loading 10,000 Records into RAM** | 3,192.33 ms | 321.86 ms | 0.10x | Flat JSON |
| **Aggregate Count (Filter + Count)** | 33.59 ms | 14.40 ms | 0.43x | Flat JSON *(direct object property)* |
| **Multi-filter Query (`active` AND `score >= 80`)** | 161.10 ms | 17.20 ms | 0.11x | Flat JSON *(direct object property)* |

> **Analysis of In-Memory Filtering:** For pure in-memory read-only sequential scans across pre-allocated .NET objects, PowerShell's native pipeline can read existing object pointers without boundary transitions. However, as soon as indexing, lookups, sorting, data mutations, or disk persistence are required, PSLocalBase completely outclasses in-memory flat structures by **4x to 10x**, with **14.5x faster disk flushes**.

---

## 5,000 Records Baseline Comparison

Empirical results from `_TESTS/benchmark-comparison.ps1`:

| Operation | PSLocalBase (ms) | Flat JSON File (ms) | Speedup Factor | Winner |
| :--- | :---: | :---: | :---: | :---: |
| **Individual Deletions (10 docs)** | **50.81 ms** | 8,772.54 ms | **172.65x** | **PSLocalBase** 🏆 |
| **Partial Updates (10 docs)** | **230.71 ms** | 17,086.84 ms | **74.06x** | **PSLocalBase** 🏆 |
| **Sorting & Pagination (Top 10 DESC)** | **73.49 ms** | 825.88 ms | **11.24x** | **PSLocalBase** 🏆 |
| **Scalar Aggregate Count (`count()`)** | **93.72 ms** | 481.30 ms | **5.14x** | **PSLocalBase** 🏆 |
| **Relational JOIN (`orders` JOIN `users`)** | **31.20 ms** | 77.93 ms | **2.50x** | **PSLocalBase** 🏆 |
| **Point Lookups (100 random IDs)** | **680.12 ms** | 1,072.04 ms | **1.58x** | **PSLocalBase** 🏆 |
| **Multi-filter Query (`active` + `score >= 80`)** | **400.95 ms** | 579.65 ms | **1.45x** | **PSLocalBase** 🏆 |
| **Bulk Ingestion (5,000 docs)** | 6,913.30 ms | 587.76 ms | 0.09x | Flat JSON |

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
3. **Write-Ahead Logging (`WAL`):** Maintains transaction isolation and concurrency metadata.
4. **Conclusion:** Spending ~2.7 MB of extra disk space yields **148x to 482x faster updates and deletes**, **14.5x faster disk synchronization**, and zero risk of JSON corruption.

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
│           ▼ (ConvertTo-Json -Depth 20: Serializes ALL 10,000 Objects to JSON)   │
│  [2.0 MB JSON String in Managed Heap]                                           │
│           │                                                                     │
│           ▼ (WriteAllText: Replaces Entire File on Disk)                        │
│  [Disk JSON File]                                                               │
│                                                                                 │
│  ⚠️ MULTIPLIED BY N OPERATIONS: 10 UPDATES = ~17.6 SECONDS!                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     PSLOCALBASE IN-PLACE B-TREE ARCHITECTURE                    │
│                                                                                 │
│  [Incoming Mutation Request: .update("usr-429", @{ score = 99 })]               │
│           │                                                                     │
│           ▼                                                                     │
│  [SQLite B-Tree Index: O(log N) lookup directly to 4KB page]                    │
│           │                                                                     │
│           ▼                                                                     │
│  [Native WAL In-Place Page Write (~4KB appended to WAL journal)]                │
│           │                                                                     │
│           ▼                                                                     │
│  ⚡ COMPLETED IN ~12 MILLISECONDS PER UPDATE (148x FASTER)                       │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key Architectural Advantages of PSLocalBase:
1. **$O(\log N)$ In-Place Mutations:** PSLocalBase never rewrites the entire database to update a single record. Only the affected 4KB page is updated in the WAL log.
2. **Pushdown Filtering:** Query clauses executed inside `winsqlite3.dll` evaluate JSON paths using native C `json_extract()`. Discarded records are never instantiated in the .NET CLR heap, eliminating GC pressure.
3. **Atomic `VACUUM INTO` for In-Memory DBs:** In-memory databases can be flushed to disk at any time using SQLite's native C page streamer, bypassing PowerShell string concatenation and JSON generation entirely.
4. **Crash Safety & ACID Guarantees:** Power cuts or interrupted scripts during a flat JSON write will corrupt the JSON file. PSLocalBase uses atomic transactions with zero risk of partial file corruption.
5. **Non-Blocking Multi-Process Concurrency:** Readers never block writers and writers never block readers in WAL mode, enabling multi-threaded or multi-process PowerShell automation.

---

## Reproduction Instructions

To reproduce these benchmarks on your local machine:

```powershell
# Run the 10,000 Records Benchmark Suite (Part 1 Disk + Part 2 In-Memory & Sync):
pwsh -ExecutionPolicy Bypass -File .\_TESTS\benchmark-10k.ps1

# Run the 5,000 Records Baseline Benchmark Suite:
pwsh -ExecutionPolicy Bypass -File .\_TESTS\benchmark-comparison.ps1
```
