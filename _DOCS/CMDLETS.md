# Native PowerShell Cmdlets & Pipeline Reference Guide

PSLocalBase exports **22 PowerShell advanced functions and 7 aliases**, referred to as cmdlets throughout this guide. `New-LocalBase` is the connection factory; `PSLocalBase.Cmdlets.ps1` provides the remaining 21 adapter functions. While the primary interface is a modern Fluent API (`$db.collection().where().get()`), this cmdlet layer offers an idiomatic PowerShell experience for **DevOps automation**, **system administration scripts**, and **interactive console workflows**.

Both styles use the same native SQLite engine (`winsqlite3.dll`) through the module's C# interop bridge and can be combined within the same script without external database dependencies.

> 🔗 **Looking for the Primary Fluent API?** If you are building applications or prefer the object-oriented NoSQL method-chaining syntax (`$db.collection().where().get()`), see the [Full PSLocalBase Fluent API Documentation](README.md) or the [Main Project README](../README.md).

> [!NOTE]
> **Available in 2.1.0 and `main`:** The published module and the `main` branch include the cmdlet adapter. Windows with Windows PowerShell 5.1 or PowerShell 7+ is required; the engine uses Windows' native `winsqlite3.dll`.

---

## Table of Contents

- [Installation & Setup](#installation--setup)
  - [Option A: Install from PowerShell Gallery (Recommended)](#option-a-install-from-powershell-gallery-recommended)
  - [Option B: Clone into User Module Directory from GitHub `main` Branch](#option-b-clone-into-user-module-directory-from-github-main-branch)
  - [Option C: Clone into Local Workspace](#option-c-clone-into-local-workspace)
  - [Verification & Get-Help](#verification--get-help)
- [Core Concepts & Architecture](#core-concepts--architecture)
  - [Session Context Management](#session-context-management)
  - [Pipeline Materialization and Bounded Reads](#pipeline-materialization-and-bounded-reads)
  - [Automatic Property Binding](#automatic-property-binding)
  - [Safety Mechanics: `-WhatIf` & `-Confirm`](#safety-mechanics--whatif---confirm)
  - [Short Interactive Aliases](#short-interactive-aliases)
- [Cmdlet Reference](#cmdlet-reference)
  - [1. Connection & Database Management](#1-connection--database-management)
  - [2. Document CRUD & Querying](#2-document-crud--querying)
  - [3. Collections & Indexes](#3-collections--indexes)
  - [4. Transactions & Atomicity](#4-transactions--atomicity)
- [Feature Parity Matrix (Fluent vs Cmdlet)](#feature-parity-matrix-fluent-vs-cmdlet)
- [Mixed-Mode Interoperability](#mixed-mode-interoperability)
- [Real-World Automation Script](#real-world-automation-script)

---

## Installation & Setup

### Option A: Install from PowerShell Gallery (Recommended)
PSLocalBase 2.1.0 includes all 22 native cmdlets and 7 aliases directly on the official PowerShell Gallery:

```powershell
# Install for current user:
Install-Module -Name PSLocalBase -Repository PSGallery -Scope CurrentUser

# Import and start using:
Import-Module PSLocalBase -Force
```

### Option B: Clone into User Module Directory from GitHub `main` Branch
Cloning directly into your PowerShell `$env:PSModulePath` allows you to run `Import-Module PSLocalBase` from **any** terminal or script without specifying file paths:

```powershell
# 1. Resolve your user module directory (PowerShell 7+ or Windows PowerShell 5.1):
$moduleDir = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Modules\PSLocalBase"
} else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) "WindowsPowerShell\Modules\PSLocalBase"
}

# 2. Clone the 'main' branch directly into the module folder:
git clone -b main https://github.com/cmartineztech/PSLocalBase.git $moduleDir

# 3. Import and start using:
Import-Module PSLocalBase -Force
```

### Option C: Clone into Local Workspace
If you prefer to keep the repository in a development or working directory:

```powershell
# 1. Clone 'main' branch:
git clone -b main https://github.com/cmartineztech/PSLocalBase.git
cd PSLocalBase

# 2. Import directly from the downloaded location:
Import-Module .\PSLocalBase.psd1 -Force
```

---

### Verification & Get-Help

Once imported, verify that all 22 cmdlets and 7 aliases are active, and test the native `Get-Help` integration:

```powershell
# List all 22 native cmdlets:
Get-Command -Module PSLocalBase -CommandType Function

# List short interactive aliases (gld, ald, sld, uld, rld):
Get-Command -Module PSLocalBase -CommandType Alias

# Test built-in native PowerShell Get-Help:
Get-Help Get-LocalBaseDocument -Full
Get-Help Add-LocalBaseDocument -Examples
Get-Help Connect-LocalBase -Detailed
```

---

## Core Concepts & Architecture

### Session Context Management

In traditional PowerShell scripting, having to pass `-Database $db` into every single command is tedious. PSLocalBase introduces **ambient session context**:

Whether the database file **already exists** or **does not exist yet**, you run `Connect-LocalBase` (or `Open-LocalBase`). If the `.db` file does not exist, SQLite automatically provisions and initializes it on disk on demand:

```powershell
# Establishes the active session connection (creates './infrastructure.db' if missing, or opens it if it exists)
Connect-LocalBase -Path "./infrastructure.db"

# All subsequent cmdlets automatically use the active connection!
Get-LocalBaseDocument -Collection "nodes"

# Closes the connection and releases locks
Disconnect-LocalBase
```

If you are working with multiple databases concurrently, pass `-Database $dbInstance` to commands that operate on a connection. `Connect-LocalBase`, `New-LocalBase`, `Get-LocalBaseConnection`, and path-based `Remove-LocalBaseDatabase` do not accept that parameter. A successful `Connect-LocalBase` replaces and closes the previous ambient connection, rolling back its uncommitted work. Use `New-LocalBase` for independent connections.

### Pipeline Materialization and Bounded Reads

`Get-LocalBaseDocument`, fluent `get()`, and their query helpers materialize the selected rows before emitting results. Memory grows with the selected result size, including raw JSON and deserialized objects. A downstream `Select-Object -First` does **not** save database reads or this allocation. Use `Get-LocalBaseDocument -First 100 -Skip 0` (or fluent `limit(100).skip(0)`) and fetch bounded pages. Statements are finalized before pipeline delivery, including early downstream termination.

Write cmdlets process incoming documents individually; for example:

```powershell
# Streams 50,000 CSV lines directly into SQLite one by one with minimal RAM usage:
Import-Csv ./big_dataset.csv | Add-LocalBaseDocument -Collection "telemetry"
```

### Automatic Property Binding

`Set-LocalBaseDocument`, `Update-LocalBaseDocument`, and `Remove-LocalBaseDocument` resolve identity separately for each pipeline object: explicit `-Collection`/`-Id` first, then the identity registered by `Get-LocalBaseDocument`, then content properties for ordinary objects (`Collection`, and `id`/`_key`/`key`). They intentionally do not bind Collection/Id by pipeline property name, which would confuse payload fields with explicit arguments.

Get identity is held separately from editable properties for the lifetime of the returned object. A payload `id` or `Collection`, or even a collision with `_localbase_key`/`_localbase_collection`, cannot redirect a write. The adapter removes its own decorations and synthetic `id` before writing, restoring original colliding payload fields. This identity is in-process and object-specific: after copying, projecting into a new object, or serializing, supply explicit parameters. Ordinary objects may also use `_localbase_collection` and `_localbase_key` as fallback content; these are not authenticated identity.

```powershell
# Chaining: Queries inactive users and updates them directly:
Get-LocalBaseDocument -Collection "users" -Filter @{ status = 'Inactive' } |
    Update-LocalBaseDocument -Data @{ archived = $true }
```

### Safety Mechanics: `-WhatIf` & `-Confirm`

`Remove-LocalBaseDatabase`, `Remove-LocalBaseDocument`, `Remove-LocalBaseCollection`, `Clear-LocalBaseCollection`, `New-LocalBaseCollection`, `New-LocalBaseIndex`, `Remove-LocalBaseIndex`, `Set-LocalBaseDocument`, `Update-LocalBaseDocument`, and `Start-LocalBaseTransaction` support `-WhatIf` and `-Confirm`. Database and collection removal have high confirmation impact; the others use medium impact. Confirmation depends on `$ConfirmPreference` unless explicitly requested or suppressed.

`Add-LocalBaseDocument`, `Connect-LocalBase`, `New-LocalBase`, `Backup-LocalBaseDatabase`, `Invoke-LocalBaseTransaction`, `Complete-LocalBaseTransaction`, and `Undo-LocalBaseTransaction` do not support these switches.

```powershell
# Simulate deletion without modifying data:
Get-LocalBaseDocument -Collection "logs" -Filter @{ level = 'Debug' } |
    Remove-LocalBaseDocument -WhatIf

# Prompt for interactive confirmation before each delete:
Get-LocalBaseDocument -Collection "servers" | Remove-LocalBaseDocument -Confirm
```

### Short Interactive Aliases

For fast typing in the interactive PowerShell console, PSLocalBase exports standard short aliases:

| Alias | Target Cmdlet | Purpose |
| :---: | :--- | :--- |
| `gld` | `Get-LocalBaseDocument` | Query / Point lookup |
| `ald` | `Add-LocalBaseDocument` | Insert document |
| `sld` | `Set-LocalBaseDocument` | Replace / Put document |
| `uld` | `Update-LocalBaseDocument` | Partial merge update |
| `rld` | `Remove-LocalBaseDocument` | Delete document |
| `Open-LocalBase` | `Connect-LocalBase` | Set ambient connection |
| `Close-LocalBase` | `Disconnect-LocalBase` | Close connection |

---

## Cmdlet Reference

### 1. Connection & Database Management

#### `New-LocalBase`
Returns a new `[PSLocalBase]` connection without setting or replacing the ambient connection. The default path is `:memory:`. Close this connection explicitly when finished.

```text
$db = New-LocalBase [-Path <string>] [-Options <hashtable>]
```

`-Options` accepts the fluent engine's connection settings, including `wal`, `synchronous`, `busyTimeout`, `cacheSizeMB`, `depth`, `maxDocumentBytes`, `maxReadDepth`, and `debug`; see [connection options](README.md). Pass `$db` with `-Database` to use it with adapter commands.

#### `Connect-LocalBase` (Alias: `Open-LocalBase`)
Connects to an embedded SQLite database and sets it as the ambient session connection.

* **If the database file does NOT exist:** SQLite automatically creates and initializes the file on disk (or in memory with `":memory:"`).
* **If the database file ALREADY exists:** Opens the database file and verifies pragmas and schema.

All subsequent pipeline cmdlets (`Get-LocalBaseDocument`, `Add-LocalBaseDocument`, etc.) automatically route to this active connection without requiring `-Database`.

```text
Connect-LocalBase [-Path] <string> `
    [-BusyTimeoutMs <int>] `
    [-JournalMode <WAL|DELETE>] `
    [-Synchronous <NORMAL|FULL|OFF|EXTRA>] `
    [-PassThru]
```

File-backed databases support WAL and DELETE. Unsupported journal modes are rejected before changing the ambient connection. In-memory databases use SQLite's MEMORY journal; inspect the returned connection's `JournalMode` for the effective mode.

Defaults are `-BusyTimeoutMs 5000`, `-JournalMode WAL`, and `-Synchronous NORMAL`. Busy timeout must be a nonnegative 32-bit integer. Without `-PassThru`, this command emits no connection object; `-PassThru` returns the new `[PSLocalBase]` connection.

*Examples:*
```powershell
# Auto-creates or opens a database file on disk:
Connect-LocalBase -Path "./data.db" -JournalMode WAL -BusyTimeoutMs 10000

# High-speed temporary database purely in memory:
Connect-LocalBase -Path ":memory:"
```

#### `Disconnect-LocalBase` (Alias: `Close-LocalBase`)
Closes the active database connection, checks in all resources, and releases SQLite disk file locks.

```text
Disconnect-LocalBase [[-Database] <PSLocalBase>]
```

#### `Get-LocalBaseConnection`
Returns the currently active `[PSLocalBase]` database session object.

Returns no object if there is no ambient connection. If an ambient object was closed directly with `.close()`, this getter still returns that object; database commands reject a closed ambient connection.

```powershell
$currentDb = Get-LocalBaseConnection
```

#### `Backup-LocalBaseDatabase`
Performs an online, transactionally consistent live backup using SQLite `VACUUM INTO`.

Relative destinations resolve from the current PowerShell location. The parent directory must exist; the destination must be absent or empty. `VACUUM INTO` cannot run inside an active transaction and requires support from the Windows-provided SQLite version. The command returns no object and does not support `-WhatIf` or `-Confirm`.

```text
Backup-LocalBaseDatabase [-DestinationPath] <string> [[-Database] <PSLocalBase>]
```

#### `Remove-LocalBaseDatabase`
Permanently deletes the database and its `-wal`, `-shm`, and `-journal` sidecars. Close all connections first (including explicit connections opened with `New-LocalBase`). Active or inaccessible files cause an actionable terminating error; the cmdlet does not disconnect them. `-Force` permits removing read-only files, but never bypasses active-file protection, `-WhatIf`, or confirmation. Missing files are a no-op; directories are rejected. Files are checked before removal, but multi-file deletion is not atomic: a later filesystem failure is reported and can leave some sidecars. Do not open new connections concurrently with removal.

```text
Remove-LocalBaseDatabase [-Path] <string> [-Force] [-WhatIf] [-Confirm]
```

---

### 2. Document CRUD & Querying

#### `Get-LocalBaseDocument` (Alias: `gld`)
Queries documents from a collection. Supports point lookups, filter hashtables, comparison operators, field existence, sorting, pagination, and projections.

```text
# Parameter Set 1: Point Lookup
Get-LocalBaseDocument [-Collection] <string> [-Id] <string> `
    [-Select <string[]>] [[-Database] <PSLocalBase>]

# Parameter Set 2: Query / Search
Get-LocalBaseDocument [-Collection] <string> `
    [-Filter <hashtable>] `
    [-Field <string>] [-Operator <string>] [-Value <object>] `
    [-Exists <string>] [-Missing <string>] `
    [-OrderBy <string>] [-Descending] `
    [-First <int>] [-Skip <int>] `
    [-Select <string[]>] `
    [-Distinct <string>] `
    [-Count] `
    [[-Database] <PSLocalBase>]
```

Query predicates are combined with logical AND. `-Filter` entries use equality; `-Field`/`-Operator`/`-Value` accepts the fluent [filter operators](README.md#filtering-with-where), defaulting to `==`. `-Operator` and `-Value` have no effect without `-Field`; `-Descending` requires `-OrderBy` to affect ordering. An empty `-Filter` adds no predicate. Null equality matches both missing and explicit JSON-null fields; `-Exists` includes explicit null and `-Missing` tests absence.

`-First` and `-Skip` must be nonnegative; `-First 0` returns no documents. `-Count` returns the count after pagination, takes precedence over `-Distinct`, and ignores `-Select`. Without `-Count`, `-Distinct` returns sorted non-null field values, ignores `-Select`, and rejects `-First`, `-Skip`, and `-OrderBy` even when paging is zero. Do not combine count, distinct, and projection when their results are intended separately.

Ordinary reads emit document objects with `_localbase_collection`, `_localbase_key`, and a synthetic `id` only when the payload has no `id`. Non-object JSON documents use a `Value` envelope; see [Second-review contracts](#second-review-contracts). A missing point lookup emits nothing. Projections retain storage identity but contain only the selected payload fields: piping a projection into `Set-LocalBaseDocument` replaces the document with that projected payload.

*Examples:*
```powershell
# Point lookup:
$user = Get-LocalBaseDocument -Collection "users" -Id "usr_100"

# Simple filter hashtable:
$admins = Get-LocalBaseDocument -Collection "users" -Filter @{ role = 'Admin'; active = $true }

# Range comparison operator:
$seniors = Get-LocalBaseDocument -Collection "users" -Field "age" -Operator ">=" -Value 65

# Field existence & missing checks:
$withPhone = Get-LocalBaseDocument -Collection "users" -Exists "phone"
$noPhone   = Get-LocalBaseDocument -Collection "users" -Missing "phone"

# Sorting, pagination, and projection:
$topPaid = Get-LocalBaseDocument -Collection "employees" `
    -OrderBy "salary" -Descending -First 5 -Select "name", "salary"

# Fast document count:
$total = Get-LocalBaseDocument -Collection "events" -Count
```

#### `Add-LocalBaseDocument` (Alias: `ald`)
Inserts one or more documents into a collection. Accepts objects via the PowerShell pipeline (`ValueFromPipeline = $true`) and returns each inserted key. An explicit `-Id` must be new: duplicates throw and preserve the existing document. Use `Set-LocalBaseDocument` to replace/upsert. If `-Id` is omitted, a GUID is generated. Wrap a multi-item pipeline in `Invoke-LocalBaseTransaction` when the entire batch must be atomic.

```text
Add-LocalBaseDocument [-Collection] <string> `
    [-Data] <object> `
    [[-Id] <string>] `
    [[-Database] <PSLocalBase>]
```

*Examples:*
```powershell
# Single insert:
Add-LocalBaseDocument -Collection "logs" -Data @{ level = 'Info'; msg = 'Started' }

# Pipeline batch insertion:
Get-Process | Select-Object ProcessName, Id, CPU | 
    Add-LocalBaseDocument -Collection "system_procs"
```

#### `Set-LocalBaseDocument` (Alias: `sld`)
Replaces the entire document, creating it if the key is absent. Collection and key may be explicit or resolved from pipeline identity. Accepts JSON null and empty arrays. Emits no result object; use Get to read the stored document.

```text
Set-LocalBaseDocument [[-Collection] <string>] `
    [[-Id] <string>] `
    [-Data] <object> `
    [[-Database] <PSLocalBase>] [-WhatIf] [-Confirm]
```

#### `Update-LocalBaseDocument` (Alias: `uld`)
Performs a deep recursive partial JSON merge into target documents. Supports pipeline forwarding from `Get-LocalBaseDocument`.

Creates a document from the merge if the key is absent. `-Data` is the patch; pipeline objects bind to `-InputObject` to identify targets. Emits no result object. Use `Set-LocalBaseDocument` to replace the entire payload.

```text
Update-LocalBaseDocument [[-Collection] <string>] `
    [[-Id] <string>] `
    [-Data] <object> `
    [-InputObject <object>] `
    [[-Database] <PSLocalBase>] `
    [-WhatIf] [-Confirm]
```

*Examples:*
```powershell
# Pipeline update with deep merge:
Get-LocalBaseDocument -Collection "users" -Filter @{ role = 'Guest' } |
    Update-LocalBaseDocument -Data @{ expired = $true; flags = @{ reviewed = $false } }

# Array mutations (ArrayUnion / ArrayRemove):
Update-LocalBaseDocument -Collection "users" -Id "usr_1" -Data @{
    tags = [PSLocalBase]::ArrayUnion('devops', 'admin')
}
```

#### `Remove-LocalBaseDocument` (Alias: `rld`)
Deletes documents by ID, by filter, or via the pipeline with `-WhatIf` and `-Confirm` safety. When both `-Id` and `-Filter` are specified, deletion uses logical AND semantics matching the Fluent API (`$col.doc($Id).where(...)`), deleting the document only if it satisfies the filter criteria.

An empty filter is rejected when there is no resolved ID; use `Clear-LocalBaseCollection` to delete every document. With an ID, an empty filter adds no restriction. Emits no count or deleted document.

```text
Remove-LocalBaseDocument [[-Collection] <string>] `
    [[-Id] <string>] `
    [-Filter <hashtable>] `
    [-InputObject <object>] `
    [[-Database] <PSLocalBase>] `
    [-WhatIf] [-Confirm]
```

*Examples:*
```powershell
# By ID:
Remove-LocalBaseDocument -Collection "users" -Id "usr_100" -Confirm:$false

# By ID with Filter (conditional point deletion):
Remove-LocalBaseDocument -Collection "users" -Id "usr_100" -Filter @{ role = 'guest' } -Confirm:$false

# Pipeline deletion with simulation:
Get-LocalBaseDocument -Collection "temp" -Filter @{ expired = $true } |
    Remove-LocalBaseDocument -WhatIf
```

#### `Measure-LocalBaseDocument`
Calculates mathematical aggregations (`Sum`, `Average`, `Minimum`, `Maximum`, `Count`) directly via SQLite engine primitives.

Returns one object containing `Collection`, `Field`, and `Count`, plus only the explicitly requested aggregate properties. There is no `-Count` switch: `Count` is always included and counts all matching documents. Sum and Average use only JSON numbers (not numeric strings or booleans) and return zero if there are none. Minimum and Maximum prefer numeric values; if no numeric values exist, they compare text values, otherwise return null. Unsupported numeric values throw. Each aggregate runs as a separate query; use a transaction when a consistent view across concurrent writes is required.

```text
Measure-LocalBaseDocument [-Collection] <string> `
    [-Field] <string> `
    [-Filter <hashtable>] `
    [-Sum] [-Average] [-Minimum] [-Maximum] `
    [[-Database] <PSLocalBase>]
```

*Example:*
```powershell
Measure-LocalBaseDocument -Collection "orders" -Field "total" -Sum -Average -Maximum
```

---

### 3. Collections & Indexes

#### `Get-LocalBaseCollection`
Lists all collection tables provisioned in the database schema.

```text
Get-LocalBaseCollection [[-Database] <PSLocalBase>]
```

#### `New-LocalBaseCollection`
Explicitly provisions a collection table in the SQLite schema before inserting records.

```text
New-LocalBaseCollection [-Name] <string> [[-Database] <PSLocalBase>] [-WhatIf] [-Confirm]
```

#### `Clear-LocalBaseCollection`
Truncates all documents in a collection while preserving the table schema and secondary indexes.

```text
Clear-LocalBaseCollection [-Collection] <string> [[-Database] <PSLocalBase>] [-WhatIf] [-Confirm]
```

#### `Remove-LocalBaseCollection`
Drops the collection table and associated SQLite index metadata.

```text
Remove-LocalBaseCollection [-Collection] <string> [[-Database] <PSLocalBase>] [-WhatIf] [-Confirm]
```

#### `New-LocalBaseIndex`
Creates a secondary expression index or unique constraint on a JSON field.

```text
New-LocalBaseIndex [-Collection] <string> `
    [-Field] <string> `
    [-Unique] `
    [[-Database] <PSLocalBase>] [-WhatIf] [-Confirm]
```

*Example:*
```powershell
New-LocalBaseIndex -Collection "users" -Field "email" -Unique
```

#### `Remove-LocalBaseIndex`
Drops a secondary index from a collection.

```text
Remove-LocalBaseIndex [-Collection] <string> `
    [-Field] <string> `
    [[-Database] <PSLocalBase>] `
    [-WhatIf] [-Confirm]
```

---

### 4. Transactions & Atomicity

#### `Invoke-LocalBaseTransaction`
Executes a scriptblock inside an atomic SQLite transaction (`BEGIN IMMEDIATE`). Cmdlets without `-Database` inside the block use the selected transaction database. The previous ambient connection is restored in `finally`, without closing either connection. The block receives a scoped `ErrorActionPreference = 'Stop'`, so unhandled terminating errors and ordinary `Write-Error` both trigger rollback. The caller's preference is preserved. Explicitly suppressing or catching an error inside the block remains the caller's responsibility.

Same-connection nesting is rejected before entering the inner block and does not roll back the outer transaction by itself. Nested blocks on different databases restore their respective contexts; they are independent transactions, not a distributed atomic commit. Successful pipeline output is returned only after commit.

```text
Invoke-LocalBaseTransaction [-ScriptBlock] <scriptblock> [[-Database] <PSLocalBase>]
```

*Example:*
```powershell
Invoke-LocalBaseTransaction {
    Add-LocalBaseDocument -Collection "accounts" -Data @{ id = 1; balance = 90 }
    Add-LocalBaseDocument -Collection "accounts" -Data @{ id = 2; balance = 110 }
}
```

#### Manual Transaction Commands
For advanced scenarios requiring explicit multi-step boundary control:

- `Start-LocalBaseTransaction`: Begins `IMMEDIATE` transaction.
- `Complete-LocalBaseTransaction`: Commits changes.
- `Undo-LocalBaseTransaction`: Rolls back changes.

```text
Start-LocalBaseTransaction [-Database <PSLocalBase>] [-WhatIf] [-Confirm]
Complete-LocalBaseTransaction [-Database <PSLocalBase>]
Undo-LocalBaseTransaction [-Database <PSLocalBase>]
```

All three emit no result object. Starting an already active transaction throws; committing or rolling back without an active transaction also throws. These commands act on their selected connection without changing the ambient connection.

---

## Feature Parity Matrix (Fluent vs Cmdlet)

The adapter covers the operations below. Advanced fluent features such as `populate()`, `union()`, `collectionGroup()`, `replaceAll()`, `upsert()` with criteria, `validate()`, and raw `query()` have no dedicated adapter command; obtain the connection with `Get-LocalBaseConnection` and call its methods.

| Capability | Primary Fluent API | Native PowerShell Cmdlet API |
| :--- | :--- | :--- |
| **Open Connection** | `$db = New-LocalBase -Path ...` | `Connect-LocalBase -Path ...` |
| **Close Connection** | `$db.close()` | `Disconnect-LocalBase` |
| **Delete Database** | `$db.deleteDatabase()` | `Remove-LocalBaseDatabase` |
| **Live Snapshot** | `$db.query("VACUUM INTO ...")` | `Backup-LocalBaseDatabase -DestinationPath ...` |
| **List Collections** | `$db.getCollections()` | `Get-LocalBaseCollection` |
| **Create Collection** | `$db.createCollection('c')` | `New-LocalBaseCollection -Name 'c'` |
| **Drop Collection** | `$db.collection('c').drop()` | `Remove-LocalBaseCollection -Collection 'c'` |
| **Truncate Collection**| `$db.collection('c').delete()` | `Clear-LocalBaseCollection -Collection 'c'` |
| **Create Index** | `$col.createIndex('f', $true)` | `New-LocalBaseIndex -Collection 'c' -Field 'f' -Unique` |
| **Drop Index** | `$col.dropIndex('f')` | `Remove-LocalBaseIndex -Collection 'c' -Field 'f'` |
| **Add Document** | `$col.add($data)` | `Add-LocalBaseDocument -Collection 'c' -Data $data` |
| **Set Document** | `$col.doc($id).set($data)` | `Set-LocalBaseDocument -Collection 'c' -Id $id -Data $data` |
| **Update Document** | `$col.doc($id).update($data)` | `Update-LocalBaseDocument -Collection 'c' -Id $id -Data $data` |
| **Delete Document** | `$col.doc($id).delete()` | `Remove-LocalBaseDocument -Collection 'c' -Id $id` |
| **Point Lookup** | `$col.doc($id).get()` | `Get-LocalBaseDocument -Collection 'c' -Id $id` |
| **Filter Query** | `$col.where('k', '==', 'v').get()` | `Get-LocalBaseDocument -Collection 'c' -Filter @{ k = 'v' }` |
| **Exists / Missing** | `$col.whereExists('f').get()` | `Get-LocalBaseDocument -Collection 'c' -Exists 'f'` |
| **Count** | `$col.count()` | `Get-LocalBaseDocument -Collection 'c' -Count` |
| **Aggregations** | `$col.sum('n')` / `.avg()` | `Measure-LocalBaseDocument -Collection 'c' -Field 'n' -Sum` |
| **Atomic Block** | Manual `try / commit / rollback` | `Invoke-LocalBaseTransaction { ... }` |

---

## Mixed-Mode Interoperability

You can freely mix both styles within the same PowerShell script:

```powershell
Import-Module PSLocalBase -Force

# 1. Connect via Cmdlet
Connect-LocalBase -Path "./mixed.db"

# 2. Use Cmdlet pipeline to ingest initial data (convert enum properties to string for clean querying)
Get-Service | Select-Object -First 20 Name, @{ N='Status'; E={ $_.Status.ToString() } } | 
    Add-LocalBaseDocument -Collection "services"

# 3. Retrieve database handle and execute advanced Fluent query with storage keys
$db = Get-LocalBaseConnection
$runningServices = $db.collection("services").where("Status", "==", "Running").get(@{ keys = $true })

# 4. Update documents via Cmdlet with explicit Collection and storage Key
$runningServices | ForEach-Object {
    Update-LocalBaseDocument -Collection "services" -Id $_.key -Data @{ audited = $true }
}

# (Alternative) Query and update directly via Cmdlet pipeline with automatic identity tracking:
# Get-LocalBaseDocument -Collection "services" -Filter @{ Status = 'Running' } | Update-LocalBaseDocument -Data @{ audited = $true }

# 5. Disconnect
Disconnect-LocalBase
```

---

## Real-World Automation Script

Here is an example of an operational automation script using PSLocalBase cmdlets:

```powershell
<#
.SYNOPSIS
    Audit-WindowsServices.ps1 - Audits services, persists snapshots, and flags anomalies.
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = "$PSScriptRoot/service_audit.db"
)

Import-Module PSLocalBase -Force
Connect-LocalBase -Path $DatabasePath

try {
    Write-Host "Creating index on service Name..." -ForegroundColor Cyan
    New-LocalBaseIndex -Collection "services" -Field "Name" -Unique

    Write-Host "Clearing previous snapshot and streaming current services into database..." -ForegroundColor Cyan
    Clear-LocalBaseCollection -Collection "services" -Confirm:$false
    Get-Service | Select-Object Name, DisplayName, @{ N='Status'; E={ $_.Status.ToString() } }, @{ N='StartType'; E={ $_.StartType.ToString() } } | 
        Add-LocalBaseDocument -Collection "services"

    Write-Host "Detecting automatic services that are stopped..." -ForegroundColor Yellow
    $stopped = Get-LocalBaseDocument -Collection "services" `
        -Filter @{ Status = 'Stopped'; StartType = 'Automatic' }

    if ($stopped) {
        Write-Warning "Found $($stopped.Count) stopped automatic services!"
        $stopped | Format-Table Name, DisplayName, Status -AutoSize

        # Flag anomalies with timestamp
        $stopped | Update-LocalBaseDocument -Data @{ 
            Alerted = $true
            CheckedAt = (Get-Date).ToString("o") 
        }
    }

    $total = Get-LocalBaseDocument -Collection "services" -Count
    Write-Host "Total audited services: $total" -ForegroundColor Green
}
finally {
    Disconnect-LocalBase
}
```

---

## 🔗 Related Documentation & Primary Fluent API

To explore the full documentation of the primary Fluent API, indexing strategies, cross-collection joins (`.populate()`), composite queries (`.union()`), and engine internals:

- [Full PSLocalBase Fluent API Guide (_DOCS/README.md)](README.md)
- [Main Repository Overview & Benchmarks (README.md)](../README.md)
- [Core Architecture Specification (_DOCS/SPECIFICATION.md)](SPECIFICATION.md)
- [PowerShell Pipeline Integration & Object Standard](README.md#10-powershell-pipeline-integration--object-standard)

### Second-review contracts

- A replacement `Connect-LocalBase` is opened and fully validated before the old ambient connection is closed. Failed paths/options leave its transaction, data and identity intact. Successful replacement closes the old connection (rolling back any uncommitted transaction).
- Get emits each JSON document as one pipeline item. JSON objects retain their normal properties. Top-level arrays, scalars and JSON null use an adapter envelope with a `Value` property, plus identity decorations. Modify `.Value` to edit these documents. Set/Add unwrap only envelopes registered in the private identity table; an ordinary business object with a `Value` property remains an object. Remove resolves the same trusted identity. Missing point reads emit no item. Copying/serializing an envelope loses its trusted identity: pass its `.Value` explicitly with Collection/Id.
- `-Distinct` rejects `-First`, `-Skip`, and `-OrderBy`, even zero values, rather than silently ignoring selection modifiers. Unmodified distinct respects filters and returns sorted non-null values.
- New collection/index, Set document and Start transaction now implement ShouldProcess; `-WhatIf` has no database effects.
- Numeric SQL filters obey the [comparison domain](SPECIFICATION.md#numeric-comparison-domain). Unsupported stored numbers can reject a query even when its parameter is safe.
