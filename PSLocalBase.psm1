<#
.SYNOPSIS
    PSLocalBase - Embedded NoSQL document database for PowerShell.
.DESCRIPTION
    Zero-dependency embedded document/NoSQL database for PowerShell 5.1+ and 7.x+ using Windows native winsqlite3.dll.
#>

# ---------------------------------------------------------------------------
# 1. Native Interoperability Layer (WinSqlite3)
# ---------------------------------------------------------------------------
# WinSqlite3 is compiled into the AppDomain before module classes are parsed via
# ScriptsToProcess = @('InitWinSqlite3Native.ps1') in PSLocalBase.psd1.
# Fallback if imported or dot-sourced without manifest:
if (-not ('WinSqlite3' -as [type])) {
    $initScript = Join-Path $PSScriptRoot "InitWinSqlite3Native.ps1"
    if (Test-Path $initScript) {
        . $initScript
    }
}

# ---------------------------------------------------------------------------
# 1b. Array Operation Sentinel for Atomic Mutations
# ---------------------------------------------------------------------------
class PSLocalBaseArrayOp {
    [string]$OpType
    [object[]]$Values

    PSLocalBaseArrayOp([string]$type, [object[]]$vals) {
        $this.OpType = $type
        $this.Values = $vals
    }
}

# ---------------------------------------------------------------------------
# 2. Main PSLocalBase Class Definition
# ---------------------------------------------------------------------------
class PSLocalBase : System.IDisposable {
    static [string]$IdentifierPattern = '\A[a-zA-Z0-9_]+\z'
    static [string]$FieldPathPattern = '\A[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*\z'
    static [string]$IndexedFieldPathPattern = '\A[a-zA-Z0-9_]+(\[\d+\])*(\.[a-zA-Z0-9_]+(\[\d+\])*)*\z'
    static [string]$GroupPatternPattern = '\A[a-zA-Z0-9_*?]+\z'
    static [object]$SupportsDateKind = $null

    hidden [IntPtr]$DbHandle = [IntPtr]::Zero
    hidden [System.Runtime.InteropServices.SafeHandle]$ConnectionOwner = $null
    hidden [long]$HandleGeneration = 0
    hidden [bool]$WasOpened = $false
    hidden [string]$FilePath
    hidden [string]$CurrentCollection = ""
    hidden [string]$CurrentKey = ""
    hidden [System.Collections.Generic.List[string]]$WhereClauses
    hidden [System.Collections.Generic.List[object]]$WhereParameters
    [string]$JournalMode = ""
    hidden [string]$OrderByClause = ""
    hidden [System.Nullable[int]]$LimitValue = $null
    hidden [System.Nullable[int]]$SkipValue = $null
    [bool]$InTransaction = $false
    [hashtable]$config
    hidden [bool]$IsChildInstance = $false
    hidden [PSLocalBase]$ParentDb = $null
    hidden [System.Collections.Generic.List[hashtable]]$PopulateClauses
    hidden [PSLocalBase]$UnionQuery = $null
    hidden [PSLocalBase]$UnionLeftQuery = $null
    hidden [string]$UnionType = ""
    hidden [bool]$IsCollectionGroup = $false
    hidden [string[]]$GroupTables = @()
    hidden [bool]$IsComposedInUnion = $false
    hidden [System.Collections.Generic.List[string]]$SelectedFields

    # Default constructor (in-memory)
    PSLocalBase() {
        $this.Init(":memory:", @{})
    }

    # Primary constructor with database file path
    PSLocalBase([string]$filePath) {
        $this.Init($filePath, @{})
    }

    # Overload constructor with database file path and config options
    PSLocalBase([string]$filePath, [hashtable]$options) {
        $this.Init($filePath, $options)
    }

    # Internal constructor for isolated collection instances
    PSLocalBase([IntPtr]$handle, [string]$filePath, [hashtable]$cfg, [PSLocalBase]$parent) {
        $this.DbHandle = $handle
        $this.FilePath = $filePath
        $this.config = $cfg
        $this.ParentDb = $parent
        $this.IsChildInstance = $true
        $this.WhereClauses = [System.Collections.Generic.List[string]]::new()
        $this.WhereParameters = [System.Collections.Generic.List[object]]::new()
        $this.JournalMode = if ($parent) { $parent.JournalMode } else { "" }
        $this.PopulateClauses = [System.Collections.Generic.List[hashtable]]::new()
        $this.SelectedFields = [System.Collections.Generic.List[string]]::new()
        $this.UnionQuery = $null
        $this.UnionLeftQuery = $null
        $this.UnionType = ""
        $this.IsCollectionGroup = $false
        $this.GroupTables = @()
        $this.InTransaction = if ($parent) { $parent.InTransaction } else { $false }
        $this.HandleGeneration = if ($parent) { $parent.HandleGeneration } else { 0 }
    }

    static [bool] _ToStrictBool([string]$name, [object]$value) {
        if ($value -is [bool]) { return $value }
        if ([PSLocalBase]::_IsNumber($value)) { return ([double]$value -ne 0) }
        $text = ([string]$value).Trim().ToLowerInvariant()
        if ($text -in @('true', '1', 'yes', 'on')) { return $true }
        if ($text -in @('false', '0', 'no', 'off', '')) { return $false }
        throw [System.ArgumentException]::new("Option '$name' must be a boolean value. Provided: '$value'.")
    }

    hidden [void] Init([string]$filePath, [hashtable]$options) {
        if ($this.WasOpened) {
            throw [System.InvalidOperationException]::new("A PSLocalBase instance cannot be reopened. Create a new instance instead.")
        }
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            throw [System.ArgumentException]::new("Database file path cannot be null or empty.")
        }

        $this.WhereClauses = [System.Collections.Generic.List[string]]::new()
        $this.WhereParameters = [System.Collections.Generic.List[object]]::new()
        $this.PopulateClauses = [System.Collections.Generic.List[hashtable]]::new()
        $this.SelectedFields = [System.Collections.Generic.List[string]]::new()
        $this.UnionQuery = $null
        $this.UnionLeftQuery = $null
        $this.UnionType = ""
        $this.IsCollectionGroup = $false
        $this.GroupTables = @()
        $this.InTransaction = $false
        $this.config = @{
            debug       = $false
            depth       = 20
            wal         = $true
            cacheSizeMB = 16
            busyTimeout = 5000
        }

        if ($null -ne $options) {
            foreach ($k in $options.Keys) {
                $this.config[$k] = $options[$k]
            }
        }
        foreach ($boolKey in @('debug', 'wal')) {
            $this.config[$boolKey] = [PSLocalBase]::_ToStrictBool($boolKey, $this.config[$boolKey])
        }
        $depthKey = if ($null -ne $options -and -not $options.ContainsKey('depth') -and $options.ContainsKey('maxDepth')) { 'maxDepth' } else { 'depth' }
        $depthValue = 0
        if (-not [int]::TryParse([string]$this.config[$depthKey], [ref]$depthValue) -or $depthValue -lt 1 -or $depthValue -gt 100) {
            throw [System.ArgumentOutOfRangeException]::new($depthKey, "Option '$depthKey' must be an integer between 1 and 100.")
        }
        $this.config['depth'] = $depthValue
        foreach ($limitKey in @('maxDocumentBytes', 'maxReadDepth')) {
            if ($this.config.ContainsKey($limitKey)) {
                $parsedLimit = 0L
                if (-not [long]::TryParse([string]$this.config[$limitKey], [ref]$parsedLimit) -or $parsedLimit -lt 1) {
                    throw [System.ArgumentOutOfRangeException]::new($limitKey, "Option '$limitKey' must be a positive integer.")
                }
                $this.config[$limitKey] = $parsedLimit
            }
        }
        if (-not $this.config.ContainsKey('maxDocumentBytes')) { $this.config['maxDocumentBytes'] = 16MB }
        if (-not $this.config.ContainsKey('maxReadDepth')) { $this.config['maxReadDepth'] = 100L }

        # Resolve path
        if ($filePath -eq ":memory:") {
            $this.FilePath = ":memory:"
        } else {
            $trimmedInputPath = $filePath.Trim()
            if ($trimmedInputPath -match '^(\\\\|//)' -and $trimmedInputPath -notmatch '^\\\\\?\\[A-Za-z]:\\') {
                throw [System.InvalidOperationException]::new("SQLite WAL databases cannot be hosted on UNC or SMB network paths ('$filePath'). Use a local disk path.")
            }

            # Normalize path for PowerShell session
            if ([System.IO.Path]::IsPathRooted($trimmedInputPath)) {
                $this.FilePath = [System.IO.Path]::GetFullPath($trimmedInputPath)
            } else {
                $pwdPath = (Get-Location).Path
                $this.FilePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($pwdPath, $trimmedInputPath))
            }

            if ($this.FilePath.StartsWith("\\") -and $this.FilePath -notmatch '^\\\\\?\\[A-Za-z]:\\') {
                throw [System.InvalidOperationException]::new("SQLite WAL databases cannot be hosted on UNC or SMB network paths ('$($this.FilePath)'). Use a local disk path.")
            }

            $pathRoot = [System.IO.Path]::GetPathRoot($this.FilePath)
            if (-not [string]::IsNullOrEmpty($pathRoot)) {
                if ($pathRoot.StartsWith("\\") -and $pathRoot -notmatch '^\\\\\?\\[A-Za-z]:\\') {
                    throw [System.InvalidOperationException]::new("SQLite WAL databases cannot be hosted on UNC or SMB network paths ('$($this.FilePath)'). Use a local disk path.")
                }
                if ($pathRoot -match '^[A-Za-z]:') {
                    $driveInfo = [System.IO.DriveInfo]::new($pathRoot.Substring(0, 2))
                    if ($driveInfo.DriveType -eq [System.IO.DriveType]::Network) {
                        throw [System.InvalidOperationException]::new("SQLite WAL databases cannot be hosted on network-mapped drives ('$($this.FilePath)'). Use a local disk path.")
                    }
                }
            }

            # Ensure parent directory exists
            $parentDir = [System.IO.Path]::GetDirectoryName($this.FilePath)
            if (-not [string]::IsNullOrEmpty($parentDir) -and -not [System.IO.Directory]::Exists($parentDir)) {
                [void][System.IO.Directory]::CreateDirectory($parentDir)
            }
        }

        $handle = [IntPtr]::Zero
        $openResult = [WinSqlite3]::Open($this.FilePath, [ref]$handle)
        if ($openResult -ne [WinSqlite3]::SQLITE_OK) {
            $errMsg = [WinSqlite3]::GetErrorMessage($handle)
            if ($handle -ne [IntPtr]::Zero) { [void][WinSqlite3]::Close($handle) }
            throw [System.InvalidOperationException]::new("Failed to open SQLite database '$($this.FilePath)': $errMsg (Code: $openResult)")
        }

        $this.DbHandle = $handle
        $this.WasOpened = $true
        $this.HandleGeneration++

        try {
            $bridgeVersion = [WinSqlite3].GetField('BridgeVersion')
            if ($null -eq $bridgeVersion -or [int]$bridgeVersion.GetValue($null) -lt 2) {
                throw [System.InvalidOperationException]::new("Restart PowerShell to load the updated PSLocalBase native bridge.")
            }
            $this.ConnectionOwner = ('PSLocalBaseConnectionHandle' -as [type])::new($handle)
            $likeRc = [WinSqlite3]::RegisterPsLike($this.DbHandle)
            if ($likeRc -ne [WinSqlite3]::SQLITE_OK) {
                throw [System.InvalidOperationException]::new("Failed to register PSLocalBase pattern matching (Code: $likeRc).")
            }
            # Schema objects (triggers, views, CHECK and index expressions) may only call innocuous functions.
            $this._ExecuteDirectSql("PRAGMA trusted_schema = OFF;")
            $busyMs = if ($this.config.ContainsKey("busyTimeout")) { [int]$this.config["busyTimeout"] } else { 5000 }
            [void][WinSqlite3]::BusyTimeout($this.DbHandle, $busyMs)
            $this._ExecuteDirectSql("PRAGMA busy_timeout = $busyMs;")

            $useWal = [bool]$this.config["wal"]
            if ($this.FilePath -ne ":memory:") {
                if ($useWal) {
                    $this._ExecuteDirectSql("PRAGMA journal_mode = WAL;")
                } else {
                    $this._ExecuteDirectSql("PRAGMA journal_mode = DELETE;")
                }
                $syncVal = if ($this.config.ContainsKey("synchronous")) {
                    [string]$this.config["synchronous"]
                } elseif ($useWal) {
                    "NORMAL"
                } else {
                    "FULL"
                }
                $syncUpper = $syncVal.Trim().ToUpperInvariant()
                if ($syncUpper -notmatch '\A(EXTRA|FULL|NORMAL|OFF|0|1|2|3)\z') {
                    throw [System.ArgumentException]::new("Invalid synchronous mode '$syncVal'. Supported modes: EXTRA, FULL, NORMAL, OFF, 0, 1, 2, 3.")
                }
                $this._ExecuteDirectSql("PRAGMA synchronous = $syncUpper;")
                $this.config["synchronous"] = $syncUpper
            } else {
                $this.config["synchronous"] = if ($this.config.ContainsKey("synchronous")) { [string]$this.config["synchronous"] } else { "NORMAL" }
            }

            # Query effective journal mode
            $modeRows = $this._ExecuteBoundQuery("PRAGMA journal_mode;", @())
            $effectiveMode = if ($modeRows.Count -gt 0 -and $modeRows[0].Length -gt 0) { [string]$modeRows[0][0].ToLowerInvariant() } else { "" }
            $this.JournalMode = $effectiveMode
            $this.config["effectiveJournalMode"] = $effectiveMode

            $this._ExecuteDirectSql("PRAGMA temp_store = MEMORY;")

            $cacheMB = if ($this.config.ContainsKey("cacheSizeMB")) { [int]$this.config["cacheSizeMB"] } else { 16 }
            $cacheKib = -1 * ($cacheMB * 1024)
            $this._ExecuteDirectSql("PRAGMA cache_size = $cacheKib;")
        } catch {
            $this.close()
            throw
        }
    }

    # -----------------------------------------------------------------------
    # Fluent Navigation Methods
    # -----------------------------------------------------------------------
    [string[]] getCollections() {
        $this._EnsureOpen()
        $rows = $this._ExecuteBoundQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';", @())
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $rows) {
            $tableName = $r[0]
            # Names come from the database file, which may be untrusted.
            if ($tableName -notmatch [PSLocalBase]::IdentifierPattern) { continue }
            $cols = $this._ExecuteBoundQuery("SELECT name FROM pragma_table_info(?);", @($tableName))
            $hasKey = $false
            $hasDoc = $false
            foreach ($c in $cols) {
                if ($c[0] -eq "key") { $hasKey = $true }
                if ($c[0] -eq "doc") { $hasDoc = $true }
            }
            if ($hasKey -and $hasDoc) {
                $names.Add($tableName)
            }
        }
        return [string[]]$names.ToArray()
    }

    [string[]] listCollections() {
        return $this.getCollections()
    }

    [void] _ResetQueryState() {
        $this.CurrentKey = ""
        if ($null -ne $this.WhereClauses) { $this.WhereClauses.Clear() }
        if ($null -ne $this.WhereParameters) { $this.WhereParameters.Clear() }
        if ($null -ne $this.PopulateClauses) { $this.PopulateClauses.Clear() }
        if ($null -ne $this.SelectedFields) { $this.SelectedFields.Clear() }
        $this.UnionQuery = $null
        $this.UnionLeftQuery = $null
        $this.UnionType = ""
        $this.OrderByClause = ""
        $this.LimitValue = $null
        $this.SkipValue = $null
    }

    [bool] _CollectionExists([string]$name) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        $rows = $this._ExecuteBoundQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? COLLATE NOCASE LIMIT 1;", @($name))
        return ($rows.Count -gt 0)
    }

    [bool] collectionExists([string]$name) {
        return $this._CollectionExists($name)
    }

    [string] _ResolveCanonicalCollectionName([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return "" }
        $rows = $this._ExecuteBoundQuery("SELECT name FROM sqlite_master WHERE type='table' AND name = ? COLLATE NOCASE LIMIT 1;", @($name))
        if ($rows.Count -gt 0 -and $rows[0].Count -gt 0 -and $null -ne $rows[0][0]) {
            return [string]$rows[0][0]
        }
        return $name.ToLowerInvariant()
    }

    [void] _EnsureCollectionTable() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified.")
        }
        $createSql = "CREATE TABLE IF NOT EXISTS [$($this.CurrentCollection)] (key TEXT PRIMARY KEY, doc TEXT NOT NULL CHECK (json_valid(doc)));"
        $this._ExecuteDirectSql($createSql)
    }

    [bool] validate() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified to validate. Call .collection('name').validate()")
        }
        if (-not $this._CollectionExists($this.CurrentCollection)) {
            return $true
        }
        $rows = $this._ExecuteBoundQuery("SELECT 1 FROM [$($this.CurrentCollection)] WHERE doc IS NULL OR json_valid(doc) = 0 LIMIT 1;", @())
        return ($rows.Count -eq 0)
    }

    [PSLocalBase] create() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified to create. Call .collection('name').create()")
        }
        if ($this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot create collection from a collectionGroup. Collection groups are read-only.")
        }
        if ($null -ne $this.UnionQuery) {
            throw [System.InvalidOperationException]::new("Cannot create collection on a composite query (union).")
        }
        $this._EnsureCollectionTable()
        return $this
    }

    [PSLocalBase] createCollection([string]$name) {
        return $this.collection($name).create()
    }

    static [string] _PathHash([string]$collection, [string]$field) {
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($collection):$($field)"))
            return [BitConverter]::ToString($hashBytes).Replace("-", "")
        } finally {
            $hasher.Dispose()
        }
    }

    [PSLocalBase] createIndex([string]$field) {
        return $this.createIndex($field, @{})
    }

    [PSLocalBase] createIndex([string]$field, [object]$options) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified to create index. Call .collection('name').createIndex('field')")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("createIndex is not supported on composite queries (union) or collection groups.")
        }
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in createIndex.")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid for index. Only alphanumeric characters, underscores, and dots are allowed.")
        }

        $this._EnsureCollectionTable()

        $canonicalCol = $this._ResolveCanonicalCollectionName($this.CurrentCollection)
        $pathHex = [PSLocalBase]::_PathHash($canonicalCol, $fieldToCheck)
        $pathHash = $pathHex.Substring(0, 16)
        $pathHash8 = $pathHex.Substring(0, 8)
        $cleanCol = $canonicalCol -replace '[^a-zA-Z0-9_]', '_'
        $cleanField = $fieldToCheck -replace '[^a-zA-Z0-9_]', '_'
        $indexName = "idx_${cleanCol}__${cleanField}_${pathHash}"

        $isUnique = $false
        $orderStr = "ASC"
        if ($options -is [bool]) {
            $isUnique = $options
        } elseif ($options -is [System.Collections.IDictionary]) {
            if ($options["unique"] -eq $true) { $isUnique = $true }
            if ([string]$options["order"] -match '^(?i)desc$') { $orderStr = "DESC" }
        }
        $uniqueStr = if ($isUnique) { "UNIQUE" } else { "" }

        $docColPattern = '(?:["''`\[]?\w+["''`\]]?\.)?(?:["''`\[]doc["''`\]]|doc)'
        $escapedField = [regex]::Escape($fieldToCheck)
        $jsonExtractRegex = "json_extract\s*\(\s*${docColPattern}\s*,\s*['\""]\$\.(?:\""$escapedField\""|$escapedField)['\""]\s*\)"

        # Check if index already exists for this table and field in sqlite_master (case-insensitive collection, exact field expression)
        $allCandidateRows = $this._ExecuteBoundQuery("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE AND (name = ? OR name LIKE ? OR name LIKE ?);", @($this.CurrentCollection, $indexName, "%__${cleanField}_${pathHash}", "%__${cleanField}_${pathHash8}"))
        $existingRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($row in $allCandidateRows) {
            $candSql = if ($row.Length -gt 1 -and $null -ne $row[1]) { [string]$row[1] } else { "" }
            if (-not [string]::IsNullOrEmpty($candSql) -and $candSql -cmatch $jsonExtractRegex) {
                $existingRows.Add($row)
            }
        }
        if ($existingRows.Count -gt 0 -and $null -ne $existingRows[0][1]) {
            $existingSql = [string]$existingRows[0][1]
            $wasUnique = ($existingSql -match '(?i)\bCREATE\s+UNIQUE\s+INDEX\b')
            if ($wasUnique -eq $isUnique) {
                return $this
            }
            # Uniqueness changed: wrap DROP and CREATE in an explicit SAVEPOINT
            $this._ExecuteDirectSql("SAVEPOINT sp_idx_upgrade;")
            try {
                foreach ($row in $existingRows) {
                    $idxNameToDrop = [string]$row[0]
                    if (-not [string]::IsNullOrEmpty($idxNameToDrop)) {
                        $escapedName = $idxNameToDrop.Replace('"', '""')
                        $this._ExecuteDirectSql("DROP INDEX IF EXISTS ""$escapedName"";")
                    }
                }
                $indexSql = "CREATE $uniqueStr INDEX ""$indexName"" ON [$canonicalCol] ((json_extract(doc, '`$.$fieldToCheck')) $orderStr);"
                $this._ExecuteDirectSql($indexSql)
                $this._ExecuteDirectSql("RELEASE SAVEPOINT sp_idx_upgrade;")
                return $this
            } catch {
                try {
                    $this._ExecuteDirectSql("ROLLBACK TO SAVEPOINT sp_idx_upgrade;")
                    $this._ExecuteDirectSql("RELEASE SAVEPOINT sp_idx_upgrade;")
                } catch { }
                throw
            }
        }

        $indexSql = "CREATE $uniqueStr INDEX IF NOT EXISTS ""$indexName"" ON [$canonicalCol] ((json_extract(doc, '`$.$fieldToCheck')) $orderStr);"
        $this._ExecuteDirectSql($indexSql)

        return $this
    }

    [PSLocalBase] dropIndex([string]$field) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified to drop index. Call .collection('name').dropIndex('field')")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("dropIndex is not supported on composite queries (union) or collection groups.")
        }
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in dropIndex.")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid for index. Only alphanumeric characters, underscores, and dots are allowed.")
        }

        $canonicalCol = $this._ResolveCanonicalCollectionName($this.CurrentCollection)
        $pathHex = [PSLocalBase]::_PathHash($canonicalCol, $fieldToCheck)
        $pathHash = $pathHex.Substring(0, 16)
        $pathHash8 = $pathHex.Substring(0, 8)
        $cleanCol = $canonicalCol -replace '[^a-zA-Z0-9_]', '_'
        $cleanField = $fieldToCheck -replace '[^a-zA-Z0-9_]', '_'
        $indexName = "idx_${cleanCol}__${cleanField}_${pathHash}"
        $hashPattern16 = "*__${cleanField}_${pathHash}"
        $hashPattern8 = "*__${cleanField}_${pathHash8}"

        $rawCol = $this.CurrentCollection -replace '[^a-zA-Z0-9_]', '_'
        $rawPathHash = [PSLocalBase]::_PathHash($this.CurrentCollection, $fieldToCheck).Substring(0, 16)
        $rawIndexName = "idx_${rawCol}__${cleanField}_${rawPathHash}"

        $docColPattern = '(?:["''`\[]?\w+["''`\]]?\.)?(?:["''`\[]doc["''`\]]|doc)'
        $escapedField = [regex]::Escape($fieldToCheck)
        $jsonExtractRegex = "json_extract\s*\(\s*${docColPattern}\s*,\s*['\""]\$\.(?:\""$escapedField\""|$escapedField)['\""]\s*\)"
        $anyJsonExtractPattern = "json_extract\s*\(\s*${docColPattern}\s*,"

        # Inspect actual index definition sql column in sqlite_master
        $indexes = $this._ExecuteBoundQuery("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE;", @($this.CurrentCollection))
        foreach ($row in $indexes) {
            $idxName = [string]$row[0]
            $idxSql = if ($row.Length -gt 1 -and $null -ne $row[1]) { [string]$row[1] } else { "" }
            if ([string]::IsNullOrEmpty($idxName)) { continue }

            $shouldDrop = $false
            if (-not [string]::IsNullOrEmpty($idxSql) -and $idxSql -cmatch $jsonExtractRegex) {
                $shouldDrop = $true
            } elseif ([string]::IsNullOrEmpty($idxSql) -or -not ($idxSql -match $anyJsonExtractPattern)) {
                if ($idxName -ceq $indexName -or $idxName -ceq $rawIndexName -or $idxName -clike $hashPattern16 -or $idxName -clike $hashPattern8) {
                    $shouldDrop = $true
                }
            }

            if ($shouldDrop) {
                $escapedName = $idxName.Replace('"', '""')
                $this._ExecuteDirectSql("DROP INDEX IF EXISTS ""$escapedName"";")
            }
        }

        return $this
    }

    # -----------------------------------------------------------------------
    # Static Array Mutation Sentinels: ArrayUnion, ArrayRemove
    # -----------------------------------------------------------------------
    static [PSLocalBaseArrayOp] ArrayUnion([object]$val1) {
        return [PSLocalBase]::ArrayUnion(@($val1))
    }
    static [PSLocalBaseArrayOp] ArrayUnion([object]$val1, [object]$val2) {
        return [PSLocalBase]::ArrayUnion(@($val1, $val2))
    }
    static [PSLocalBaseArrayOp] ArrayUnion([object]$val1, [object]$val2, [object]$val3) {
        return [PSLocalBase]::ArrayUnion(@($val1, $val2, $val3))
    }
    static [PSLocalBaseArrayOp] ArrayUnion([object]$val1, [object]$val2, [object]$val3, [object]$val4) {
        return [PSLocalBase]::ArrayUnion(@($val1, $val2, $val3, $val4))
    }
    static [PSLocalBaseArrayOp] ArrayUnion([object[]]$elements) {
        $flat = [System.Collections.Generic.List[object]]::new()
        foreach ($elem in $elements) {
            if ($elem -is [System.Collections.IEnumerable] -and $elem -isnot [string] -and $elem -isnot [System.Collections.IDictionary]) {
                foreach ($sub in $elem) { [void]$flat.Add($sub) }
            } else {
                [void]$flat.Add($elem)
            }
        }
        return [PSLocalBaseArrayOp]::new('union', $flat.ToArray())
    }

    static [PSLocalBaseArrayOp] ArrayRemove([object]$val1) {
        return [PSLocalBase]::ArrayRemove(@($val1))
    }
    static [PSLocalBaseArrayOp] ArrayRemove([object]$val1, [object]$val2) {
        return [PSLocalBase]::ArrayRemove(@($val1, $val2))
    }
    static [PSLocalBaseArrayOp] ArrayRemove([object]$val1, [object]$val2, [object]$val3) {
        return [PSLocalBase]::ArrayRemove(@($val1, $val2, $val3))
    }
    static [PSLocalBaseArrayOp] ArrayRemove([object]$val1, [object]$val2, [object]$val3, [object]$val4) {
        return [PSLocalBase]::ArrayRemove(@($val1, $val2, $val3, $val4))
    }
    static [PSLocalBaseArrayOp] ArrayRemove([object[]]$elements) {
        $flat = [System.Collections.Generic.List[object]]::new()
        foreach ($elem in $elements) {
            if ($elem -is [System.Collections.IEnumerable] -and $elem -isnot [string] -and $elem -isnot [System.Collections.IDictionary]) {
                foreach ($sub in $elem) { [void]$flat.Add($sub) }
            } else {
                [void]$flat.Add($elem)
            }
        }
        return [PSLocalBaseArrayOp]::new('remove', $flat.ToArray())
    }

    # -----------------------------------------------------------------------
    # Cross-Collection Reference Population: .populate()
    # -----------------------------------------------------------------------
    [PSLocalBase] populate([string]$foreignField) {
        return $this.populate($foreignField, $foreignField, "")
    }

    [PSLocalBase] populate([string]$foreignField, [string]$foreignCollection) {
        return $this.populate($foreignField, $foreignCollection, "")
    }

    [PSLocalBase] populate([string]$foreignField, [hashtable]$options) {
        $foreignCol = if ($null -ne $options -and $options.ContainsKey("from")) { [string]$options["from"] } else { $foreignField }
        $asProp = if ($null -ne $options -and $options.ContainsKey("as")) { [string]$options["as"] } else { "" }
        return $this.populate($foreignField, $foreignCol, $asProp)
    }

    [PSLocalBase] populate([string]$foreignField, [string]$foreignCollection, [string]$asProperty) {
        $this._EnsureOpen()
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("populate() is not supported on composite queries (union/collectionGroup).")
        }
        if ([string]::IsNullOrWhiteSpace($foreignField)) {
            throw [System.ArgumentException]::new("Foreign field cannot be null or empty in populate.")
        }
        if ([string]::IsNullOrWhiteSpace($foreignCollection)) {
            throw [System.ArgumentException]::new("Foreign collection cannot be null or empty in populate.")
        }
        $cleanFField = $foreignField.Trim()
        if ($cleanFField.StartsWith("$.")) { $cleanFField = $cleanFField.Substring(2) }
        if ($cleanFField -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Foreign field '$foreignField' is invalid. Only alphanumeric characters, underscores, and dots are allowed.")
        }
        $cleanFCol = $foreignCollection.Trim()
        if ($cleanFCol -notmatch [PSLocalBase]::IdentifierPattern) {
            throw [System.ArgumentException]::new("Foreign collection name '$foreignCollection' is invalid. Only alphanumeric characters and underscores are allowed.")
        }
        $cleanAs = if (-not [string]::IsNullOrWhiteSpace($asProperty)) {
            $asProperty.Trim()
        } else {
            $cleanFField
        }
        if ($cleanAs.StartsWith("$.")) { $cleanAs = $cleanAs.Substring(2) }
        if ($cleanAs -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Target property name '$cleanAs' is invalid. Only alphanumeric characters, underscores, and dots are allowed.")
        }

        $target = $this.clone()
        $target.PopulateClauses.Add(@{
            foreignField      = $cleanFField
            foreignCollection = $cleanFCol
            asProperty        = $cleanAs
        })

        return $target
    }

    [PSLocalBase] clone() {
        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        $copy = [PSLocalBase]::new($this.DbHandle, $this.FilePath, $this.config, $root)
        $copy.HandleGeneration = $this.HandleGeneration
        $copy.CurrentCollection = $this.CurrentCollection
        $copy.CurrentKey = $this.CurrentKey
        if ($null -ne $this.WhereClauses) { $copy.WhereClauses.AddRange($this.WhereClauses) }
        if ($null -ne $this.WhereParameters) { $copy.WhereParameters.AddRange($this.WhereParameters) }
        if ($null -ne $this.PopulateClauses) {
            foreach ($p in $this.PopulateClauses) {
                $copy.PopulateClauses.Add([hashtable]::new($p))
            }
        }
        if ($null -ne $this.SelectedFields) { $copy.SelectedFields.AddRange($this.SelectedFields) }
        $copy.OrderByClause = $this.OrderByClause
        $copy.LimitValue = $this.LimitValue
        $copy.SkipValue = $this.SkipValue
        if ($null -ne $this.UnionQuery) { $copy.UnionQuery = $this.UnionQuery.clone() }
        if ($null -ne $this.UnionLeftQuery) { $copy.UnionLeftQuery = $this.UnionLeftQuery.clone() }
        $copy.UnionType = $this.UnionType
        $copy.IsCollectionGroup = $this.IsCollectionGroup
        $copy.IsComposedInUnion = $this.IsComposedInUnion
        if ($null -ne $this.GroupTables) {
            $copy.GroupTables = [string[]]$this.GroupTables.Clone()
        }
        $copy.JournalMode = $this.JournalMode
        $copy.InTransaction = $this.InTransaction
        return $copy
    }

    [PSLocalBase] fork() {
        return $this.clone()
    }

    # -----------------------------------------------------------------------
    # Compound Queries & Sharding: .union(), .unionAll(), collectionGroup()
    # -----------------------------------------------------------------------
    [PSLocalBase] union([PSLocalBase]$otherQuery) {
        if ($null -eq $otherQuery) {
            throw [System.ArgumentNullException]::new("otherQuery", "otherQuery cannot be null in union.")
        }
        if ($this.IsCollectionGroup -or $otherQuery.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("union() does not support collectionGroup() queries. Query each collection explicitly or use collectionGroup() alone.")
        }
        if ($this.IsComposedInUnion -or $null -ne $this.UnionQuery -or $null -ne $otherQuery.UnionQuery -or $otherQuery.IsComposedInUnion) {
            throw [System.InvalidOperationException]::new("Nested composite queries (nested union/unionAll) are not supported.")
        }
        if ($otherQuery.DbHandle -ne $this.DbHandle) {
            throw [System.InvalidOperationException]::new("Cannot execute composite union across different database connections.")
        }
        if (($null -ne $this.PopulateClauses -and $this.PopulateClauses.Count -gt 0) -or ($null -ne $otherQuery.PopulateClauses -and $otherQuery.PopulateClauses.Count -gt 0)) {
            throw [System.InvalidOperationException]::new("populate() is not supported on composite queries (union/collectionGroup).")
        }
        $target = $this.clone()
        $target._ResetQueryState()
        $target.UnionLeftQuery = $this.clone()
        $target.UnionQuery = $otherQuery.clone()
        $target.UnionQuery.IsComposedInUnion = $true
        $target.IsComposedInUnion = $true
        $target.UnionType = "UNION"
        return $target
    }

    [PSLocalBase] unionAll([PSLocalBase]$otherQuery) {
        if ($null -eq $otherQuery) {
            throw [System.ArgumentNullException]::new("otherQuery", "otherQuery cannot be null in unionAll.")
        }
        if ($this.IsCollectionGroup -or $otherQuery.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("unionAll() does not support collectionGroup() queries. Query each collection explicitly or use collectionGroup() alone.")
        }
        if ($this.IsComposedInUnion -or $null -ne $this.UnionQuery -or $null -ne $otherQuery.UnionQuery -or $otherQuery.IsComposedInUnion) {
            throw [System.InvalidOperationException]::new("Nested composite queries (nested union/unionAll) are not supported.")
        }
        if ($otherQuery.DbHandle -ne $this.DbHandle) {
            throw [System.InvalidOperationException]::new("Cannot execute composite union across different database connections.")
        }
        if (($null -ne $this.PopulateClauses -and $this.PopulateClauses.Count -gt 0) -or ($null -ne $otherQuery.PopulateClauses -and $otherQuery.PopulateClauses.Count -gt 0)) {
            throw [System.InvalidOperationException]::new("populate() is not supported on composite queries (union/collectionGroup).")
        }
        $target = $this.clone()
        $target._ResetQueryState()
        $target.UnionLeftQuery = $this.clone()
        $target.UnionQuery = $otherQuery.clone()
        $target.UnionQuery.IsComposedInUnion = $true
        $target.IsComposedInUnion = $true
        $target.UnionType = "UNION ALL"
        return $target
    }

    [PSLocalBase] collectionGroup([string]$pattern) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            throw [System.ArgumentException]::new("Collection pattern cannot be null or whitespace.")
        }
        $trimmedPattern = $pattern.Trim()
        if ($trimmedPattern -notmatch [PSLocalBase]::GroupPatternPattern) {
            throw [System.ArgumentException]::new("Collection group pattern '$pattern' is invalid. Only alphanumeric characters, underscores, and wildcard * ? are allowed.")
        }

        $allTables = $this._ExecuteBoundQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';", @())
        $patternRegex = '\A' + [regex]::Escape($trimmedPattern).Replace('\*', '.*').Replace('\?', '.') + '\z'
        $matchedTables = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $allTables) {
            $tableName = $row[0]
            if ($tableName -match $patternRegex -and $tableName -match [PSLocalBase]::IdentifierPattern) {
                $matchedTables.Add($tableName)
            }
        }

        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        $child = [PSLocalBase]::new($this.DbHandle, $this.FilePath, $this.config, $root)
        $child.HandleGeneration = $this.HandleGeneration
        $child.CurrentCollection = $trimmedPattern
        $child.IsCollectionGroup = $true
        $child.GroupTables = $matchedTables.ToArray()
        $child._ResetQueryState()

        return $child
    }

    [PSLocalBase] collection([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw [System.ArgumentException]::new("Collection name cannot be null or whitespace.")
        }
        if ($name -notmatch [PSLocalBase]::IdentifierPattern) {
            throw [System.ArgumentException]::new("Collection name '$name' is invalid. Only alphanumeric characters and underscores are allowed.")
        }

        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        $child = [PSLocalBase]::new($this.DbHandle, $this.FilePath, $this.config, $root)
        $child.HandleGeneration = $this.HandleGeneration
        $child.CurrentCollection = $name
        $child._ResetQueryState()

        return $child
    }

    [string] _ExtractDocumentId([object]$data) {
        if ($null -eq $data) { return "" }
        if ($data -is [System.Collections.IDictionary]) {
            if ($data.Contains("key") -and -not [string]::IsNullOrWhiteSpace([string]$data["key"])) { return [string]$data["key"] }
            if ($data.Contains("id") -and -not [string]::IsNullOrWhiteSpace([string]$data["id"])) { return [string]$data["id"] }
            if ($data.Contains("_key") -and -not [string]::IsNullOrWhiteSpace([string]$data["_key"])) { return [string]$data["_key"] }
            return ""
        }
        if ($data -is [System.Management.Automation.PSCustomObject]) {
            if ($data.PSObject.Properties["key"] -and -not [string]::IsNullOrWhiteSpace([string]$data.key)) { return [string]$data.key }
            if ($data.PSObject.Properties["id"] -and -not [string]::IsNullOrWhiteSpace([string]$data.id)) { return [string]$data.id }
            if ($data.PSObject.Properties["_key"] -and -not [string]::IsNullOrWhiteSpace([string]$data._key)) { return [string]$data._key }
            return ""
        }
        return ""
    }
    [string] _ResolveKeyFromCriteria([object]$keyOrCriteria) {
        if ($null -eq $keyOrCriteria) { return "" }
        if ($keyOrCriteria -is [string]) { return $keyOrCriteria }
        # Criteria objects must name the key explicitly; any other property is not an identity.
        if ($keyOrCriteria -is [System.Collections.IDictionary]) {
            if ($keyOrCriteria.Contains("key")) { return [string]$keyOrCriteria["key"] }
            if ($keyOrCriteria.Contains("id")) { return [string]$keyOrCriteria["id"] }
            if ($keyOrCriteria.Contains("_key")) { return [string]$keyOrCriteria["_key"] }
            return ""
        }
        if ($keyOrCriteria -is [System.Management.Automation.PSCustomObject]) {
            if ($keyOrCriteria.PSObject.Properties["key"]) { return [string]$keyOrCriteria.key }
            if ($keyOrCriteria.PSObject.Properties["id"]) { return [string]$keyOrCriteria.id }
            if ($keyOrCriteria.PSObject.Properties["_key"]) { return [string]$keyOrCriteria._key }
            return ""
        }
        return [string]$keyOrCriteria
    }

    [PSLocalBase] doc([object]$keyOrCriteria) {
        $this._EnsureOpen()
        if ($this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("collectionGroup does not support point document lookups via .doc().")
        }
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .doc().")
        }
        if ($null -eq $keyOrCriteria) {
            throw [System.ArgumentException]::new("Document key cannot be null.")
        }

        # Support string key or object/hashtable criteria like @{ id = 1 } or @{ key = 'abc' }
        $resolvedKey = $this._ResolveKeyFromCriteria($keyOrCriteria)

        if ([string]::IsNullOrWhiteSpace($resolvedKey)) {
            throw [System.ArgumentException]::new("Document key could not be resolved from criteria. Pass a string key or an object with a 'key', 'id', or '_key' property.")
        }

        if ($resolvedKey.IndexOf([char]0) -ge 0) {
            throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
        }

        $target = $this.clone()
        $target.CurrentKey = $resolvedKey
        $target.WhereClauses.Clear()
        $target.WhereParameters.Clear()
        return $target
    }

    [bool] _ExceedsDepth([object]$obj, [int]$maxDepth, [int]$currentDepth) {
        if ($null -eq $obj) { return $false }
        if ($currentDepth -gt $maxDepth) { return $true }
        if ($obj -is [string] -or $obj.GetType().IsPrimitive -or $obj -is [decimal] -or $obj -is [datetime] -or $obj -is [guid]) { return $false }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($val in $obj.Values) {
                if ($this._ExceedsDepth($val, $maxDepth, $currentDepth + 1)) { return $true }
            }
            return $false
        }
        if ($obj -is [System.Collections.IEnumerable]) {
            foreach ($elem in $obj) {
                if ($this._ExceedsDepth($elem, $maxDepth, $currentDepth + 1)) { return $true }
            }
            return $false
        }
        if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties -and $obj.PSObject.Properties.Count -gt 0) {
            foreach ($prop in $obj.PSObject.Properties) {
                if ($this._ExceedsDepth($prop.Value, $maxDepth, $currentDepth + 1)) { return $true }
            }
            return $false
        }
        return ($currentDepth -gt $maxDepth)
    }

    static [bool] _IsNumber([object]$value) {
        return ($value -is [byte] -or $value -is [sbyte] -or $value -is [int16] -or $value -is [uint16] -or
                $value -is [int32] -or $value -is [uint32] -or $value -is [int64] -or $value -is [uint64] -or
                $value -is [single] -or $value -is [double] -or $value -is [decimal])
    }

    static [object] _NormalizeScalar([object]$value) {
        if ($value -is [datetime]) {
            return ([datetime]$value).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($value -is [System.DateTimeOffset]) {
            return ([System.DateTimeOffset]$value).UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return $value
    }

    hidden [object] _NormalizeForJson([object]$obj) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [datetime] -or $obj -is [System.DateTimeOffset]) { return [PSLocalBase]::_NormalizeScalar($obj) }
        if ($obj -is [string] -or $obj -is [System.ValueType] -or $obj -is [PSLocalBaseArrayOp]) { return $obj }
        if ($obj -is [System.Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($k in $obj.Keys) {
                $this._AddNormalizedMember($copy, [string]$k, $obj[$k])
            }
            return $copy
        }
        if ($obj -is [System.Management.Automation.PSCustomObject]) {
            $copy = [ordered]@{}
            foreach ($prop in $obj.PSObject.Properties) {
                $this._AddNormalizedMember($copy, $prop.Name, $prop.Value)
            }
            return $copy
        }
        if ($obj -is [System.Collections.IEnumerable]) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($elem in $obj) { $list.Add($this._NormalizeForJson($elem)) }
            return [object[]]$list.ToArray()
        }
        return $obj
    }

    hidden [void] _AddNormalizedMember([System.Collections.Specialized.OrderedDictionary]$target, [string]$name, [object]$value) {
        # ConvertFrom-Json rejects empty and case-insensitively duplicated names, which would make the collection unreadable.
        if ([string]::IsNullOrEmpty($name)) {
            throw [System.ArgumentException]::new("Document property names cannot be empty.")
        }
        if ($target.Contains($name)) {
            throw [System.ArgumentException]::new("Document property '$name' is duplicated (property names are case-insensitive).")
        }
        $target[$name] = $this._NormalizeForJson($value)
    }

    hidden [object] _DeserializeDoc([string]$key, [string]$json) {
        $maxBytes = [long]$this.config['maxDocumentBytes']
        $maxDepth = [long]$this.config['maxReadDepth']
        if (([long]$json.Length * 2) -gt $maxBytes) {
            throw [System.IO.InvalidDataException]::new("Document '$key' exceeds maxDocumentBytes ($maxBytes).")
        }
        if ([WinSqlite3]::JsonNestingDepth($json) -gt $maxDepth) {
            throw [System.IO.InvalidDataException]::new("Document '$key' exceeds maxReadDepth ($maxDepth).")
        }
        if ($null -eq [PSLocalBase]::SupportsDateKind) {
            [PSLocalBase]::SupportsDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
        }
        try {
            # DateKind String keeps stored date text unchanged across editions.
            if ([PSLocalBase]::SupportsDateKind) {
                return (ConvertFrom-Json -InputObject $json -DateKind String)
            }
            return (ConvertFrom-Json -InputObject $json)
        } catch {
            throw [System.IO.InvalidDataException]::new("Document '$key' could not be deserialized.")
        }
    }

    [string] _SerializeJson([object]$data) {
        $depth = 20
        if ($this.config -and $this.config.ContainsKey("depth")) {
            $depth = [int]$this.config["depth"]
        } elseif ($this.config -and $this.config.ContainsKey("maxDepth")) {
            $depth = [int]$this.config["maxDepth"]
        }
        # Pre-flight depth check guarantees identical rejection in both PowerShell 5.1 and 7+
        if ($this._ExceedsDepth($data, $depth, 0)) {
            throw [System.InvalidOperationException]::new("Object serialization exceeded configured maximum depth ($depth). Increase 'depth' in configuration options to serialize deeply nested structures.")
        }
        $normalized = $this._NormalizeForJson($data)
        $jsonWarn = $null
        $json = ConvertTo-Json -InputObject $normalized -Compress -Depth $depth -WarningVariable jsonWarn -WarningAction SilentlyContinue
        if ($jsonWarn -and $jsonWarn.Count -gt 0) {
            throw [System.InvalidOperationException]::new("Object serialization exceeded configured maximum depth ($depth). Increase 'depth' in configuration options to serialize deeply nested structures.")
        }
        return $json
    }

    # -----------------------------------------------------------------------
    # Write Methods: set, add, update
    # -----------------------------------------------------------------------
    [void] set([object]$data) {
        $this.set($data, @{})
    }

    [void] set([object]$data, [hashtable]$options) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .set().")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot execute mutation operation on a composite query (union/collectionGroup).")
        }

        # Case 1: Targeted document (.doc('key').set(data))
        if (-not [string]::IsNullOrEmpty($this.CurrentKey) -and $null -eq $this.UnionQuery -and -not $this.IsCollectionGroup) {
            if ($this.CurrentKey.IndexOf([char]0) -ge 0) {
                throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
            }
            $this._EnsureCollectionTable()
            $json = $this._SerializeJson($data)
            $sql = "INSERT INTO [$($this.CurrentCollection)] (key, doc) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET doc = excluded.doc;"
            $this._ExecuteBoundSql($sql, @($this.CurrentKey, $json))
            return
        }

        # Case 2: Collection-level set (overwrite entire collection)
        if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string] -and $data -isnot [System.Collections.IDictionary]) {
            $this._ReplaceAll($data, $options)
            return
        }

        throw [System.InvalidOperationException]::new("No document key selected. Call .doc('key') to set a single document or pass an array of items to overwrite the collection.")
    }

    [void] replaceAll([object]$items) {
        $this.replaceAll($items, @{})
    }

    [void] replaceAll([object]$items, [hashtable]$options) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .replaceAll().")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot execute mutation operation on a composite query (union/collectionGroup).")
        }
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            throw [System.InvalidOperationException]::new("replaceAll() replaces the whole collection and cannot be called after doc().")
        }
        if ($null -eq $items -or $items -is [string] -or $items -is [System.Collections.IDictionary] -or $items -isnot [System.Collections.IEnumerable]) {
            throw [System.ArgumentException]::new("replaceAll() expects an array of documents.")
        }
        $this._ReplaceAll($items, $options)
    }

    hidden [void] _ReplaceAll([object]$data, [hashtable]$options) {
        if ($this.WhereClauses.Count -gt 0 -or -not [string]::IsNullOrEmpty($this.OrderByClause) -or $null -ne $this.LimitValue -or $null -ne $this.SkipValue) {
            throw [System.InvalidOperationException]::new("Replacing a collection is not allowed on a filtered, sorted, or paginated query because it deletes every document. Call replaceAll() on the unfiltered collection, or use where(...).delete() and add()/set() to modify a subset.")
        }
        $this._EnsureCollectionTable()
        $isOuterTx = $this._GetInTransaction()
        $spName = ""
        if ($isOuterTx) {
            $spName = "sp_bulk_" + [System.Guid]::NewGuid().ToString("N")
            $this._ExecuteDirectSql("SAVEPOINT $spName;")
        } else {
            $this.beginTransaction()
        }
        try {
            $this._ExecuteDirectSql("DELETE FROM [$($this.CurrentCollection)];")
            foreach ($item in $data) {
                $itemKey = ""
                $itemData = $item
                if ($options -and $options["keys"] -eq $true) {
                    # Exported wrappers @{ key = ...; data = ... } are unwrapped to their payload.
                    if ($item -is [System.Collections.IDictionary] -and $item.Contains("key") -and $item.Contains("data")) {
                        $itemKey = [string]$item["key"]
                        $itemData = $item["data"]
                    } elseif ($item -is [System.Management.Automation.PSCustomObject] -and $null -ne $item.PSObject.Properties["key"] -and $null -ne $item.PSObject.Properties["data"]) {
                        $itemKey = [string]$item.key
                        $itemData = $item.data
                    } elseif ($item -is [System.Collections.IDictionary] -and $item.Contains("_key")) {
                        $itemKey = [string]$item["_key"]
                    } elseif ($item -is [System.Management.Automation.PSCustomObject] -and $null -ne $item.PSObject.Properties["_key"]) {
                        $itemKey = [string]$item._key
                    } elseif ($item -is [System.Collections.IDictionary] -and $item.Contains("key")) {
                        $itemKey = [string]$item["key"]
                    } elseif ($item -is [System.Management.Automation.PSCustomObject] -and $null -ne $item.PSObject.Properties["key"]) {
                        $itemKey = [string]$item.key
                    }
                }
                if ([string]::IsNullOrEmpty($itemKey)) {
                    if ($itemData -is [System.Collections.IDictionary] -and $itemData.Contains("id")) {
                        $itemKey = [string]$itemData["id"]
                    } elseif ($itemData -is [System.Management.Automation.PSCustomObject] -and $null -ne $itemData.PSObject.Properties["id"]) {
                        $itemKey = [string]$itemData.id
                    } else {
                        $itemKey = [System.Guid]::NewGuid().ToString("N")
                    }
                }
                if ($itemKey.IndexOf([char]0) -ge 0) {
                    throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
                }
                $json = $this._SerializeJson($itemData)
                $sql = "INSERT INTO [$($this.CurrentCollection)] (key, doc) VALUES (?, ?);"
                $this._ExecuteBoundSql($sql, @($itemKey, $json))
            }
            if ($isOuterTx) {
                $this._ExecuteDirectSql("RELEASE SAVEPOINT $spName;")
            } else {
                $this.commit()
            }
        } catch {
            if ($isOuterTx) {
                try { $this._ExecuteDirectSql("ROLLBACK TO SAVEPOINT $spName; RELEASE SAVEPOINT $spName;") } catch { }
            } else {
                try { $this.rollback() } catch { }
            }
            throw
        }
    }

    [string] add([object]$data) {
        return $this.add($data, "")
    }

    [string] add([object]$data, [string]$customKey) {
        $this._EnsureOpen()
        if ($this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot execute add() on a collectionGroup query.")
        }
        if ($null -ne $this.UnionQuery) {
            throw [System.InvalidOperationException]::new("Cannot execute add() on a composite query (union).")
        }
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            throw [System.InvalidOperationException]::new("Cannot call add() after doc(). Use .set() or .upsert() to modify targeted documents.")
        }
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .add().")
        }

        $newKey = if (-not [string]::IsNullOrWhiteSpace($customKey)) {
            $customKey
        } else {
            [System.Guid]::NewGuid().ToString("N")
        }

        if ($newKey.IndexOf([char]0) -ge 0) {
            throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
        }

        $this._EnsureCollectionTable()
        $json = $this._SerializeJson($data)
        $sql = "INSERT INTO [$($this.CurrentCollection)] (key, doc) VALUES (?, ?);"
        $this._ExecuteBoundSql($sql, @($newKey, $json))
        return $newKey
    }

    [string] insert([object]$data) {
        if ($data -is [System.Collections.IDictionary] -and $data.Contains("id") -and -not [string]::IsNullOrWhiteSpace($data["id"])) {
            return $this.add($data, [string]$data["id"])
        } elseif ($data -is [PSCustomObject] -and $null -ne $data.PSObject.Properties["id"] -and -not [string]::IsNullOrWhiteSpace($data.id)) {
            return $this.add($data, [string]$data.id)
        }
        return $this.add($data, "")
    }

    [string] upsert([object]$data) {
        return $this.upsert($data, "")
    }

    [string] upsert([object]$data, [string]$customKey) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .upsert().")
        }
        if ($this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot upsert documents in a collectionGroup. Collection groups are read-only.")
        }
        if ($null -ne $this.UnionQuery) {
            throw [System.InvalidOperationException]::new("Cannot upsert documents on a composite query (union).")
        }

        $targetKey = if (-not [string]::IsNullOrWhiteSpace($this.CurrentKey)) {
            $this.CurrentKey
        } elseif (-not [string]::IsNullOrWhiteSpace($customKey)) {
            $customKey
        } else {
            $this._ExtractDocumentId($data)
        }

        if ([string]::IsNullOrWhiteSpace($targetKey)) {
            $targetKey = [System.Guid]::NewGuid().ToString("N")
        }

        if ($targetKey.IndexOf([char]0) -ge 0) {
            throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
        }

        $this._EnsureCollectionTable()
        $json = $this._SerializeJson($data)
        $sql = "INSERT INTO [$($this.CurrentCollection)] (key, doc) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET doc = excluded.doc;"
        $this._ExecuteBoundSql($sql, @($targetKey, $json))
        return $targetKey
    }

    [void] update([object]$partialData) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .update().")
        }
        if ([string]::IsNullOrEmpty($this.CurrentKey)) {
            throw [System.InvalidOperationException]::new("No document key specified. Call .doc('key') before .update().")
        }

        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot execute mutation operation on a composite query (union/collectionGroup).")
        }
        $this._EnsureCollectionTable()
        $targetKey = $this.CurrentKey
        $startedTx = $false
        if (-not $this._GetInTransaction()) {
            $this._ExecuteDirectSql("BEGIN IMMEDIATE;")
            $startedTx = $true
        }

        try {
            # Retrieve existing raw document without any select/populate view transformations
            $rawRows = $this._ExecuteBoundQuery("SELECT key, doc FROM [$($this.CurrentCollection)] WHERE key = ?;", @($targetKey))
            $existing = if ($rawRows.Count -gt 0 -and $null -ne $rawRows[0][1]) {
                $this._DeserializeDoc($targetKey, $rawRows[0][1])
            } else {
                $null
            }
            $this.CurrentKey = $targetKey
            if ($null -eq $existing) {
                # If document doesn't exist, evaluate partialData against an empty document
                # so that array mutations (ArrayUnion, ArrayRemove, descriptors) are properly applied!
                $merged = $this._DeepMerge(@{}, $partialData)
                $this.set($merged)
                if ($startedTx) { $this._ExecuteDirectSql("COMMIT;") }
                return
            }

            # Deep merge partialData into existing
            $merged = $this._DeepMerge($existing, $partialData)
            $this.set($merged)
            if ($startedTx) { $this._ExecuteDirectSql("COMMIT;") }
        } catch {
            if ($startedTx) {
                try { $this._ExecuteDirectSql("ROLLBACK;") } catch { }
            }
            throw
        }
    }

    # -----------------------------------------------------------------------
    # Query & Filtering Methods: where, orderBy, limit, get
    # -----------------------------------------------------------------------
    static [string] _ConvertPsWildcardToSqlLike([string]$pattern) {
        if ($null -eq $pattern) { return "" }
        $sb = [System.Text.StringBuilder]::new()
        $i = 0
        $len = $pattern.Length
        while ($i -lt $len) {
            $ch = $pattern[$i]
            if ($ch -eq '`') {
                if ($i + 1 -lt $len) {
                    $i++
                    $next = $pattern[$i]
                    if ($next -eq '\' -or $next -eq '%' -or $next -eq '_') {
                        [void]$sb.Append('\')
                        [void]$sb.Append($next)
                    } else {
                        [void]$sb.Append($next)
                    }
                } else {
                    [void]$sb.Append('`')
                }
            } elseif ($ch -eq '*') {
                [void]$sb.Append('%')
            } elseif ($ch -eq '?') {
                [void]$sb.Append('_')
            } elseif ($ch -eq '\' -or $ch -eq '%' -or $ch -eq '_') {
                [void]$sb.Append('\')
                [void]$sb.Append($ch)
            } elseif ($ch -eq '[') {
                $closeIdx = $pattern.IndexOf(']', $i + 1)
                if ($closeIdx -gt $i + 1) {
                    throw [System.NotSupportedException]::new("Bracket range patterns '[...]' in -like are not supported by the SQL engine.")
                }
                [void]$sb.Append($ch)
            } else {
                [void]$sb.Append($ch)
            }
            $i++
        }
        return $sb.ToString()
    }

    [string] _BuildBranchSelect([PSLocalBase]$q, [System.Collections.Generic.List[object]]$queryParams) {
        if ($q.CurrentCollection -notmatch [PSLocalBase]::IdentifierPattern) {
            throw [System.InvalidOperationException]::new("Collection name '$($q.CurrentCollection)' is invalid.")
        }
        if (-not $this._CollectionExists($q.CurrentCollection)) {
            return "SELECT '' AS key, '' AS doc WHERE 0"
        }

        $branchDocExpr = "doc"
        if ($null -ne $q.SelectedFields -and $q.SelectedFields.Count -gt 0) {
            $selectPairs = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $q.SelectedFields) {
                $cleanField = $f.Trim().Replace("'", "''")
                $selectPairs.Add("'$cleanField', CASE WHEN json_type(doc, '$.$cleanField') IN ('array', 'object') THEN json(json_extract(doc, '$.$cleanField')) WHEN json_type(doc, '$.$cleanField') = 'true' THEN json('true') WHEN json_type(doc, '$.$cleanField') = 'false' THEN json('false') ELSE json_extract(doc, '$.$cleanField') END")
            }
            $branchDocExpr = "json_object(" + [string]::Join(", ", $selectPairs) + ")"
        }

        $branchConditions = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrEmpty($q.CurrentKey)) {
            $branchConditions.Add("key = ?")
            $queryParams.Add($q.CurrentKey)
        }
        if ($null -ne $q.WhereClauses -and $q.WhereClauses.Count -gt 0) {
            $branchConditions.AddRange($q.WhereClauses)
            if ($null -ne $q.WhereParameters) {
                $queryParams.AddRange($q.WhereParameters)
            }
        }
        $branchWhere = if ($branchConditions.Count -gt 0) { " WHERE " + [string]::Join(" AND ", $branchConditions) } else { "" }

        $branchOrder = if (-not [string]::IsNullOrEmpty($q.OrderByClause)) { " " + $q.OrderByClause } else { "" }

        $branchLimit = $q._PagingSql()

        return "SELECT key, $branchDocExpr AS doc FROM [$($q.CurrentCollection)]$branchWhere$branchOrder$branchLimit"
    }

    [PSLocalBase] where([string]$field, [string]$operator, [object]$value) {
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in where clause.")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::IndexedFieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid. Only alphanumeric characters, underscores, dots, and balanced numeric array brackets are allowed.")
        }

        if ([string]::IsNullOrWhiteSpace($operator)) {
            throw [System.ArgumentException]::new("Operator cannot be null or empty in where clause.")
        }

        $trimmedOp = $operator.Trim().ToUpperInvariant()
        $sqlOp = [PSLocalBase]::_NormalizeOperator($operator)

        # Work on an isolated clone to ensure query immutability
        $target = $this.clone()
        $target.CurrentKey = ""
        return $this._CompileFilter($target, "`$.$fieldToCheck", $sqlOp, $trimmedOp, [PSLocalBase]::_NormalizeScalar($value))
    }

    static [string] _NormalizeOperator([string]$operator) {
        $trimmedOp = $operator.Trim().ToUpperInvariant()
        $sqlOp = switch -Regex ($trimmedOp) {
            '^(=|==|-EQ)$'                 { '=' }
            '^(!=|<>|-NE)$'                { '!=' }
            '^(>|-GT)$'                    { '>' }
            '^(<|-LT)$'                    { '<' }
            '^(>=|-GE)$'                   { '>=' }
            '^(<=|-LE)$'                   { '<=' }
            '^(LIKE|-LIKE)$'               { 'LIKE' }
            '^(NOT LIKE|-NOTLIKE)$'        { 'NOT LIKE' }
            '^(IN|-IN)$'                   { 'IN' }
            '^(NOT[\s_-]?IN|-NOTIN)$'            { 'NOT IN' }
            '^(ARRAY-CONTAINS|-CONTAINS)$' { 'ARRAY-CONTAINS' }
            '^(ARRAY-CONTAINS-ANY)$'       { 'ARRAY-CONTAINS-ANY' }
            '^(LENGTH|ARRAY-LENGTH|SIZE)$'       { 'LENGTH' }
            '^(LENGTH>|LENGTH-GT|SIZE>)$'        { 'LENGTH>' }
            '^(LENGTH>=|LENGTH-GE|SIZE>=)$'      { 'LENGTH>=' }
            '^(LENGTH<|LENGTH-LT|SIZE<)$'        { 'LENGTH<' }
            '^(LENGTH<=|LENGTH-LE|SIZE<=)$'      { 'LENGTH<=' }
            '^(LENGTH!=|LENGTH-NE|SIZE!=)$'      { 'LENGTH!=' }
            '^(TYPE|JSON-TYPE)$'                 { 'TYPE' }
            default {
                throw [System.ArgumentException]::new("Unsupported operator '$operator' in where clause.")
            }
        }
        return $sqlOp
    }

    # Appends the SQL predicate for one validated where() condition to $target.
    hidden [PSLocalBase] _CompileFilter([PSLocalBase]$target, [string]$jsonField, [string]$sqlOp, [string]$trimmedOp, [object]$value) {
        # Case A: Parameterized IN and NOT IN list
        if ($sqlOp -eq 'IN' -or $sqlOp -eq 'NOT IN') {
            if ($null -eq $value -or $value -is [System.Collections.IDictionary]) {
                throw [System.ArgumentException]::new("Value for '$sqlOp' operator must be an array or scalar value, not null or a dictionary.")
            }
            $items = @($value)
            $placeholders = [System.Collections.Generic.List[string]]::new()
            $matchesNull = $false
            foreach ($rawElem in $items) {
                $elem = [PSLocalBase]::_NormalizeScalar($rawElem)
                if ($null -eq $elem) {
                    $matchesNull = $true
                } elseif ($elem -is [bool]) {
                    $placeholders.Add($(if ($elem) { "1" } else { "0" }))
                } elseif ([PSLocalBase]::_IsNumber($elem)) {
                    $placeholders.Add("?")
                    $target.WhereParameters.Add($elem)
                } else {
                    $placeholders.Add("?")
                    $target.WhereParameters.Add([string]$elem)
                }
            }
            $extract = "json_extract(doc, '$jsonField')"
            $list = [string]::Join(", ", $placeholders)
            # SQL NULL never satisfies IN/NOT IN, so null members are matched with IS NULL.
            if ($sqlOp -eq 'IN') {
                $parts = [System.Collections.Generic.List[string]]::new()
                if ($placeholders.Count -gt 0) { $parts.Add("$extract IN ($list)") }
                if ($matchesNull) { $parts.Add("$extract IS NULL") }
                $clause = if ($parts.Count -eq 0) { "1 = 0" } else { "(" + [string]::Join(" OR ", $parts) + ")" }
            } elseif ($placeholders.Count -gt 0) {
                $clause = "($extract IS NOT NULL AND $extract NOT IN ($list))"
            } else {
                # Like every not-in, an empty exclusion list still requires the field to be present.
                $clause = "$extract IS NOT NULL"
            }
            $target.WhereClauses.Add($clause)
            return $target
        }

        # Case A2: array-contains
        if ($sqlOp -eq 'ARRAY-CONTAINS') {
            if ($null -eq $value) {
                throw [System.ArgumentException]::new("Value for 'array-contains' operator cannot be null.")
            }
            if ($value -is [bool]) {
                $boolLit = if ($value) { "1" } else { "0" }
                $target.WhereClauses.Add("(json_type(doc, '$jsonField') = 'array' AND EXISTS (SELECT 1 FROM json_each(doc, '$jsonField') WHERE value = $boolLit))")
            } elseif ([PSLocalBase]::_IsNumber($value)) {
                $target.WhereClauses.Add("(json_type(doc, '$jsonField') = 'array' AND EXISTS (SELECT 1 FROM json_each(doc, '$jsonField') WHERE value = ?))")
                $target.WhereParameters.Add($value)
            } else {
                $target.WhereClauses.Add("(json_type(doc, '$jsonField') = 'array' AND EXISTS (SELECT 1 FROM json_each(doc, '$jsonField') WHERE value = ?))")
                $target.WhereParameters.Add([string]$value)
            }
            return $target
        }

        # Case A3: array-contains-any
        if ($sqlOp -eq 'ARRAY-CONTAINS-ANY') {
            if ($null -eq $value -or $value -is [System.Collections.IDictionary]) {
                throw [System.ArgumentException]::new("Value for 'array-contains-any' operator must be an array or collection, not null or a dictionary.")
            }
            $items = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                @($value)
            } else {
                @($value)
            }
            if ($items.Count -eq 0) {
                $target.WhereClauses.Add("1 = 0")
                return $target
            }
            $jsonArray = ConvertTo-Json -InputObject $items -Compress
            $target.WhereClauses.Add("(json_type(doc, '$jsonField') = 'array' AND EXISTS (SELECT 1 FROM json_each(doc, '$jsonField') WHERE value IN (SELECT value FROM json_each(?))))")
            $target.WhereParameters.Add($jsonArray)
            return $target
        }

        # Case A4: array length / size
        if ($sqlOp -eq 'LENGTH' -or $sqlOp -eq 'ARRAY-LENGTH' -or $sqlOp -eq 'SIZE') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) = $len")
            return $target
        }
        if ($sqlOp -eq 'LENGTH>' -or $sqlOp -eq 'LENGTH-GT' -or $sqlOp -eq 'SIZE>') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) > $len")
            return $target
        }
        if ($sqlOp -eq 'LENGTH>=' -or $sqlOp -eq 'LENGTH-GE' -or $sqlOp -eq 'SIZE>=') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) >= $len")
            return $target
        }
        if ($sqlOp -eq 'LENGTH<' -or $sqlOp -eq 'LENGTH-LT' -or $sqlOp -eq 'SIZE<') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) < $len")
            return $target
        }
        if ($sqlOp -eq 'LENGTH<=' -or $sqlOp -eq 'LENGTH-LE' -or $sqlOp -eq 'SIZE<=') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) <= $len")
            return $target
        }
        if ($sqlOp -eq 'LENGTH!=' -or $sqlOp -eq 'LENGTH-NE' -or $sqlOp -eq 'SIZE!=') {
            $len = [int]$value
            $target.WhereClauses.Add("COALESCE(json_array_length(doc, '$jsonField'), 0) != $len")
            return $target
        }

        # Case A5: type / json-type
        if ($sqlOp -eq 'TYPE' -or $sqlOp -eq 'JSON-TYPE') {
            if ($null -eq $value) {
                throw [System.ArgumentException]::new("Value for type operator cannot be null.")
            }
            $targetType = [string]$value.ToString().Trim().ToLowerInvariant()
            if ($targetType -eq 'number' -or $targetType -eq 'numeric') {
                $target.WhereClauses.Add("json_type(doc, '$jsonField') IN ('integer', 'real')")
            } elseif ($targetType -eq 'boolean' -or $targetType -eq 'bool') {
                $target.WhereClauses.Add("json_type(doc, '$jsonField') IN ('true', 'false')")
            } else {
                $validTypes = @('null', 'integer', 'real', 'text', 'array', 'object', 'true', 'false')
                if ($validTypes -notcontains $targetType) {
                    throw [System.ArgumentException]::new("Invalid JSON type '$targetType'. Expected one of: $($validTypes -join ', '), number, numeric, boolean.")
                }
                $target.WhereClauses.Add("json_type(doc, '$jsonField') = ?")
                $target.WhereParameters.Add($targetType)
            }
            return $target
        }

        # Case B: Null comparisons
        if ($null -eq $value) {
            if ($sqlOp -eq '=') {
                $target.WhereClauses.Add("json_extract(doc, '$jsonField') IS NULL")
                return $target
            } elseif ($sqlOp -eq '!=') {
                $target.WhereClauses.Add("json_extract(doc, '$jsonField') IS NOT NULL")
                return $target
            } else {
                $target.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp NULL")
                return $target
            }
        }

        # PowerShell patterns always use complete strings, including typed pattern arguments.
        if ($trimmedOp -eq '-LIKE' -or $trimmedOp -eq '-NOTLIKE') {
            [void][PSLocalBase]::_ConvertPsWildcardToSqlLike([string]$value)
            $matchResult = if ($trimmedOp -eq '-LIKE') { 1 } else { 0 }
            $patternValue = if ($value -is [bool]) { [int]$value } else { $value }
            $target.WhereClauses.Add("pslocalbase_like(json_extract(doc, '$jsonField'), ?) = $matchResult")
            $target.WhereParameters.Add($patternValue)
            return $target
        }

        # Case C: Strongly-typed Boolean
        if ($value -is [bool]) {
            $boolLit = if ($value) { "1" } else { "0" }
            $target.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp $boolLit")
            return $target
        }

        # Case D: Strongly-typed Numbers
        if ([PSLocalBase]::_IsNumber($value)) {
            $target.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp ?")
            $target.WhereParameters.Add($value)
            return $target
        }

        # Case E: String values and native SQL LIKE patterns
        $paramVal = [string]$value
        $target.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp ?")
        $target.WhereParameters.Add($paramVal)

        return $target
    }

    [PSLocalBase] whereLength([string]$field, [int]$count) {
        return $this.where($field, "length", $count)
    }

    [PSLocalBase] whereLength([string]$field, [string]$operator, [int]$count) {
        if ([string]::IsNullOrWhiteSpace($operator)) {
            throw [System.ArgumentException]::new("Operator cannot be null or empty in whereLength().")
        }
        $cleanOp = $operator.Trim().ToLowerInvariant()
        $op = switch ($cleanOp) {
            '='   { 'length' }
            '=='  { 'length' }
            '-eq' { 'length' }
            '>'   { 'length>' }
            '-gt' { 'length>' }
            '>='  { 'length>=' }
            '-ge' { 'length>=' }
            '<'   { 'length<' }
            '-lt' { 'length<' }
            '<='  { 'length<=' }
            '-le' { 'length<=' }
            '!='  { 'length!=' }
            '-ne' { 'length!=' }
            default { throw [System.ArgumentException]::new("Unsupported operator '$operator' in whereLength(). Use =, !=, >, >=, <, or <=.") }
        }
        return $this.where($field, $op, $count)
    }

    [PSLocalBase] whereType([string]$field, [string]$expectedType) {
        return $this.where($field, "type", $expectedType)
    }

    [PSLocalBase] _ApplySelect([string[]]$fields) {
        if ($null -eq $fields -or $fields.Length -eq 0) {
            throw [System.ArgumentException]::new("Fields array cannot be null or empty in select().")
        }
        $target = $this.clone()
        if ($null -eq $target.SelectedFields) {
            $target.SelectedFields = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($f in $fields) {
            if (-not [string]::IsNullOrWhiteSpace($f)) {
                $clean = $f.Trim()
                if ($clean.StartsWith("$.")) { $clean = $clean.Substring(2) }
                if ($clean -notmatch [PSLocalBase]::FieldPathPattern) {
                    throw [System.ArgumentException]::new("Field name '$f' is invalid for select(). Only alphanumeric characters, underscores, and dots are allowed.")
                }
                if (-not $target.SelectedFields.Contains($clean)) {
                    $target.SelectedFields.Add($clean)
                }
            }
        }
        return $target
    }

    [PSLocalBase] select([string[]]$fields) {
        return $this._ApplySelect($fields)
    }

    [PSLocalBase] select([string]$field1) {
        $arr = [string[]]@($field1)
        return $this._ApplySelect($arr)
    }

    [PSLocalBase] select([string]$field1, [string]$field2) {
        $arr = [string[]]@($field1, $field2)
        return $this._ApplySelect($arr)
    }

    [PSLocalBase] select([string]$field1, [string]$field2, [string]$field3) {
        $arr = [string[]]@($field1, $field2, $field3)
        return $this._ApplySelect($arr)
    }

    [PSLocalBase] select([string]$field1, [string]$field2, [string]$field3, [string]$field4) {
        $arr = [string[]]@($field1, $field2, $field3, $field4)
        return $this._ApplySelect($arr)
    }

    [PSLocalBase] orderBy([string]$field) {
        return $this.orderBy($field, "asc")
    }

    [PSLocalBase] orderBy([string]$field, [string]$direction) {
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in orderBy.")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::IndexedFieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid in orderBy. Only alphanumeric characters, underscores, dots, and balanced numeric array brackets are allowed.")
        }
        if ([string]::IsNullOrWhiteSpace($direction)) {
            throw [System.ArgumentException]::new("Order direction must be 'asc' or 'desc'.")
        }
        $dir = $direction.Trim().ToUpperInvariant()
        if ($dir -ne "ASC" -and $dir -ne "DESC") {
            throw [System.ArgumentException]::new("Order direction must be 'asc' or 'desc'. Provided: '$direction'")
        }

        $target = $this.clone()
        $jsonField = "`$.$fieldToCheck"
        $target.OrderByClause = "ORDER BY json_extract(doc, '$jsonField') $dir"
        return $target
    }

    [PSLocalBase] limit([int]$count) {
        if ($count -lt 0) {
            throw [System.ArgumentOutOfRangeException]::new("Limit count must be greater than or equal to 0.")
        }
        $target = $this.clone()
        $target.LimitValue = $count
        return $target
    }

    [PSLocalBase] skip([int]$offset) {
        if ($offset -lt 0) {
            throw [System.ArgumentOutOfRangeException]::new("Skip offset must be greater than or equal to 0.")
        }
        $target = $this.clone()
        $target.SkipValue = $offset
        return $target
    }

    [object] get() {
        return $this.get(@{})
    }

    [object] get([hashtable]$options) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .get().")
        }

        if (-not $this.IsCollectionGroup -and ($null -eq $this.UnionQuery) -and -not $this._CollectionExists($this.CurrentCollection)) {
            if (-not [string]::IsNullOrEmpty($this.CurrentKey) -and $null -eq $this.UnionQuery -and -not $this.IsCollectionGroup) {
                return $null
            }
            return @()
        }

        $withKeys = ($null -ne $options -and $options["keys"] -eq $true)

        $hasPopulate = ($null -ne $this.PopulateClauses -and $this.PopulateClauses.Count -gt 0)

        # Build populate expression and joins if requested
        $docExpr = "doc"
        $joinsBuilder = [System.Text.StringBuilder]::new()
        if ($hasPopulate) {
            $docExpr = "m.doc"
            for ($i = 0; $i -lt $this.PopulateClauses.Count; $i++) {
                $p = $this.PopulateClauses[$i]
                $fCol = $p.foreignCollection
                $fKey = $p.foreignField
                $asP = $p.asProperty
                if ($fCol -notmatch [PSLocalBase]::IdentifierPattern -or $fKey -notmatch [PSLocalBase]::FieldPathPattern -or $asP -notmatch [PSLocalBase]::FieldPathPattern) {
                    throw [System.InvalidOperationException]::new("Invalid populate() definition.")
                }
                if (-not $this._CollectionExists($fCol)) {
                    # A missing foreign collection resolves every reference to null, like a missing document.
                    $docExpr = "json_set($docExpr, '`$.$asP', NULL)"
                    continue
                }
                [void]$joinsBuilder.Append(" LEFT JOIN [$fCol] f$i ON f$i.key = json_extract(m.doc, '`$.$fKey')")
                $docExpr = "json_set($docExpr, '`$.$asP', CASE WHEN f$i.key IS NULL THEN NULL ELSE json(f$i.doc) END)"
            }
        }

        $hasSelect = ($null -ne $this.SelectedFields -and $this.SelectedFields.Count -gt 0)
        if ($hasSelect) {
            $selectPairs = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $this.SelectedFields) {
                $selectPairs.Add("'$f', CASE WHEN json_type($docExpr, '`$.$f') IN ('array', 'object') THEN json(json_extract($docExpr, '`$.$f')) WHEN json_type($docExpr, '`$.$f') = 'true' THEN json('true') WHEN json_type($docExpr, '`$.$f') = 'false' THEN json('false') ELSE json_extract($docExpr, '`$.$f') END")
            }
            $docExpr = "json_object(" + [string]::Join(", ", $selectPairs) + ")"
        }

        # Case 1: Point lookup by key (.doc('key').get())
        if (-not [string]::IsNullOrEmpty($this.CurrentKey) -and $null -eq $this.UnionQuery -and -not $this.IsCollectionGroup) {
            $sql = if ($hasPopulate) {
                "SELECT m.key, $docExpr AS doc FROM [$($this.CurrentCollection)] m$($joinsBuilder.ToString()) WHERE m.key = ?;"
            } elseif ($hasSelect) {
                "SELECT key, $docExpr AS doc FROM [$($this.CurrentCollection)] WHERE key = ?;"
            } else {
                "SELECT key, doc FROM [$($this.CurrentCollection)] WHERE key = ?;"
            }
            $rows = $this._ExecuteBoundQuery($sql, @($this.CurrentKey))
            if ($rows.Count -eq 0) {
                return $null
            }
            $k = $rows[0][0]
            $obj = $this._DeserializeDoc($k, $rows[0][1])

            if ($withKeys) {
                return [PSCustomObject]@{
                    key  = $k
                    data = $obj
                }
            }
            return $obj
        }

        # Case 2: CollectionGroup, Union, or standard Collection retrieval
        $querySql = ""
        $queryParams = [System.Collections.Generic.List[object]]::new()

        if ($this.IsCollectionGroup) {
            $innerSql = $this._BuildGroupSource($queryParams)
            if ([string]::IsNullOrEmpty($innerSql)) {
                return @()
            }

            $sqlBuilder = [System.Text.StringBuilder]::new()
            if ($hasSelect) {
                [void]$sqlBuilder.Append("SELECT key, $docExpr AS doc FROM ($innerSql)")
            } else {
                [void]$sqlBuilder.Append("SELECT key, doc FROM ($innerSql)")
            }
            if (-not [string]::IsNullOrEmpty($this.OrderByClause)) {
                [void]$sqlBuilder.Append(" $($this.OrderByClause)")
            }
            [void]$sqlBuilder.Append($this._PagingSql())
            $querySql = $sqlBuilder.ToString()
        } elseif ($null -ne $this.UnionQuery) {
            if ($this.UnionQuery.DbHandle -ne $this.DbHandle) {
                throw [System.InvalidOperationException]::new("Cannot execute composite union across different database connections.")
            }
            if ($null -ne $this.UnionQuery.UnionQuery) {
                throw [System.InvalidOperationException]::new("Nested composite queries (nested union/unionAll) are not supported.")
            }
            if ($null -ne $this.UnionQuery.PopulateClauses -and $this.UnionQuery.PopulateClauses.Count -gt 0) {
                throw [System.InvalidOperationException]::new("populate() is not supported on composite queries (union/collectionGroup).")
            }
            $q1Exists = $this._CollectionExists($this.CurrentCollection)
            $q2Exists = $this._CollectionExists($this.UnionQuery.CurrentCollection)
            if (-not $q1Exists -and -not $q2Exists) {
                return @()
            }

            $q1Sql = $this._BuildBranchSelect($this.UnionLeftQuery, $queryParams)
            $q2Sql = $this._BuildBranchSelect($this.UnionQuery, $queryParams)

            $uType = if ($this.UnionType) { $this.UnionType } else { "UNION" }
            $sqlBuilder = [System.Text.StringBuilder]::new()
            if ($hasSelect) {
                [void]$sqlBuilder.Append("SELECT key, $docExpr AS doc FROM (SELECT key, doc FROM ($q1Sql) $uType SELECT key, doc FROM ($q2Sql))")
            } else {
                [void]$sqlBuilder.Append("SELECT key, doc FROM (SELECT key, doc FROM ($q1Sql) $uType SELECT key, doc FROM ($q2Sql))")
            }
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                [void]$sqlBuilder.Append(" WHERE key = ?")
                $queryParams.Add($this.CurrentKey)
            } elseif ($this.WhereClauses.Count -gt 0) {
                [void]$sqlBuilder.Append(" WHERE " + [string]::Join(" AND ", $this.WhereClauses))
                $queryParams.AddRange($this.WhereParameters)
            }
            if (-not [string]::IsNullOrEmpty($this.OrderByClause)) {
                [void]$sqlBuilder.Append(" $($this.OrderByClause)")
            }
            [void]$sqlBuilder.Append($this._PagingSql())
            $querySql = $sqlBuilder.ToString()
        } else {
            $sqlBuilder = [System.Text.StringBuilder]::new()
            if ($hasPopulate) {
                [void]$sqlBuilder.Append("SELECT m.key, $docExpr AS doc FROM [$($this.CurrentCollection)] m")
                [void]$sqlBuilder.Append($joinsBuilder.ToString())
            } elseif ($hasSelect) {
                [void]$sqlBuilder.Append("SELECT key, $docExpr AS doc FROM [$($this.CurrentCollection)]")
            } else {
                [void]$sqlBuilder.Append("SELECT key, doc FROM [$($this.CurrentCollection)]")
            }

            if ($this.WhereClauses.Count -gt 0) {
                [void]$sqlBuilder.Append(" WHERE ")
                $whereStr = [string]::Join(" AND ", $this.WhereClauses)
                if ($hasPopulate) {
                    $whereStr = $whereStr -replace '(?<![a-zA-Z0-9_\.])\bdoc\b', 'm.doc'
                }
                [void]$sqlBuilder.Append($whereStr)
            }

            if (-not [string]::IsNullOrEmpty($this.OrderByClause)) {
                [void]$sqlBuilder.Append(" ")
                $orderStr = $this.OrderByClause
                if ($hasPopulate) {
                    $orderStr = $orderStr -replace '(?<![a-zA-Z0-9_\.])\bdoc\b', 'm.doc'
                }
                [void]$sqlBuilder.Append($orderStr)
            }

            [void]$sqlBuilder.Append($this._PagingSql())
            $querySql = $sqlBuilder.ToString()
            if ($null -ne $this.WhereParameters) { $queryParams.AddRange($this.WhereParameters) }
        }

        $rows = $this._ExecuteBoundQuery($querySql, $queryParams.ToArray())

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($row in $rows) {
            $k = $row[0]
            $obj = $this._DeserializeDoc($k, $row[1])

            if ($withKeys) {
                $results.Add([PSCustomObject]@{
                    key  = $k
                    data = $obj
                })
            } else {
                $results.Add([PSCustomObject]$obj)
            }
        }

        return [PSCustomObject[]]$results.ToArray()
    }

    [object] first() {
        return $this.first(@{})
    }

    [object] first([hashtable]$options) {
        if ($null -ne $this.LimitValue -and $this.LimitValue -eq 0) { return $null }
        $clone = $this.clone()
        $clone.LimitValue = 1
        $res = $clone.get($options)
        if ($null -eq $res) { return $null }
        if ($res -is [System.Array]) {
            if ($res.Length -gt 0) { return $res[0] }
            return $null
        }
        return $res
    }

    [bool] exists() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .exists().")
        }
        if ($null -ne $this.LimitValue -or $null -ne $this.SkipValue) {
            # Pagination changes which documents are visible, so exists() follows count().
            return ($this.count() -gt 0)
        }
        if ($this.IsCollectionGroup) {
            $queryParams = [System.Collections.Generic.List[object]]::new()
            $innerSql = $this._BuildGroupSource($queryParams)
            if ([string]::IsNullOrEmpty($innerSql)) {
                return $false
            }
            $rows = $this._ExecuteBoundQuery("SELECT 1 FROM ($innerSql) LIMIT 1;", $queryParams.ToArray())
            return ($rows.Count -gt 0)
        }

        if ($null -ne $this.UnionQuery) {
            if ($null -ne $this.UnionQuery.UnionQuery) {
                throw [System.InvalidOperationException]::new("Nested composite queries (nested union/unionAll) are not supported.")
            }
            if ($this.UnionQuery.DbHandle -ne $this.DbHandle) {
                throw [System.InvalidOperationException]::new("Cannot execute composite union across different database connections.")
            }
            $rows = $this.limit(1).get()
            return ($null -ne $rows -and $rows.Count -gt 0)
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            return $false
        }
        if (-not [string]::IsNullOrEmpty($this.CurrentKey) -and $null -eq $this.UnionQuery -and -not $this.IsCollectionGroup) {
            $sql = "SELECT 1 FROM [$($this.CurrentCollection)] WHERE key = ? LIMIT 1;"
            $rows = $this._ExecuteBoundQuery($sql, @($this.CurrentKey))
            return ($rows.Count -gt 0)
        }
        $sqlBuilder = [System.Text.StringBuilder]::new()
        [void]$sqlBuilder.Append("SELECT 1 FROM [$($this.CurrentCollection)]")
        $queryParams = [System.Collections.Generic.List[object]]::new()
        if ($this.WhereClauses.Count -gt 0) {
            [void]$sqlBuilder.Append(" WHERE ")
            [void]$sqlBuilder.Append([string]::Join(" AND ", $this.WhereClauses))
            if ($null -ne $this.WhereParameters) { $queryParams.AddRange($this.WhereParameters) }
        }
        [void]$sqlBuilder.Append(" LIMIT 1;")
        $rows = $this._ExecuteBoundQuery($sqlBuilder.ToString(), $queryParams.ToArray())
        return ($rows.Count -gt 0)
    }

    [object[]] distinct([string]$field) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .distinct().")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("distinct() is not supported on composite queries (union) or collection groups.")
        }
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in distinct().")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid in distinct(). Only alphanumeric characters, underscores, and dots are allowed.")
        }
        if (-not $this._CollectionExists($this.CurrentCollection)) {
            return @()
        }
        $sqlBuilder = [System.Text.StringBuilder]::new()
        $jsonExtract = "json_extract(doc, '`$.$fieldToCheck')"
        [void]$sqlBuilder.Append("SELECT DISTINCT $jsonExtract AS v FROM [$($this.CurrentCollection)]")
        $queryParams = [System.Collections.Generic.List[object]]::new()
        $whereList = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            $whereList.Add("key = ?")
            $queryParams.Add($this.CurrentKey)
        }
        if ($this.WhereClauses.Count -gt 0) {
            $whereList.AddRange($this.WhereClauses)
            if ($null -ne $this.WhereParameters) { $queryParams.AddRange($this.WhereParameters) }
        }
        $whereList.Add("$jsonExtract IS NOT NULL")
        [void]$sqlBuilder.Append(" WHERE " + [string]::Join(" AND ", $whereList))
        [void]$sqlBuilder.Append(" ORDER BY $jsonExtract ASC;")

        $rows = $this._ExecuteTypedQuery($sqlBuilder.ToString(), $queryParams.ToArray())
        $distinctList = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            if ($null -ne $row.v) {
                $distinctList.Add($row.v)
            }
        }
        return [object[]]$distinctList.ToArray()
    }

    [double] sum([string]$field) {
        return [double]$this._ExecuteAggregate("SUM", $field)
    }

    [double] avg([string]$field) {
        return [double]$this._ExecuteAggregate("AVG", $field)
    }

    [object] min([string]$field) {
        return $this._ExecuteAggregate("MIN", $field)
    }

    [object] max([string]$field) {
        return $this._ExecuteAggregate("MAX", $field)
    }

    [object] _ExecuteAggregate([string]$aggFunc, [string]$field) {
        $this._EnsureOpen()
        $cleanAgg = $aggFunc.Trim().ToUpperInvariant()
        if ($cleanAgg -notmatch '^(SUM|AVG|MIN|MAX|COUNT)$') {
            throw [System.ArgumentException]::new("Invalid aggregate function '$aggFunc'.")
        }
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .$aggFunc().")
        }
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in $aggFunc().")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch [PSLocalBase]::FieldPathPattern) {
            throw [System.ArgumentException]::new("Field name '$field' is invalid in $aggFunc(). Only alphanumeric characters, underscores, and dots are allowed.")
        }
        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Aggregate functions ($aggFunc) are not supported on composite queries (union) or collection groups.")
        }
        if ($null -ne $this.LimitValue -or $null -ne $this.SkipValue) {
            throw [System.InvalidOperationException]::new("Aggregate functions ($aggFunc) do not support pagination (limit/skip).")
        }
        if (-not $this._CollectionExists($this.CurrentCollection)) {
            if ($aggFunc -eq "SUM" -or $aggFunc -eq "AVG") { return 0.0 }
            return $null
        }
        $isNumericAgg = ($aggFunc -eq "SUM" -or $aggFunc -eq "AVG")
        $extract = "json_extract(doc, '`$.$fieldToCheck')"
        $numericFilter = "json_type(doc, '`$.$fieldToCheck') IN ('integer', 'real')"
        if ($isNumericAgg) {
            $value = $this._AggregateValue("COALESCE($aggFunc($extract), 0.0)", $numericFilter)
            if ($null -eq $value) { return 0.0 }
            return [double]$value
        }
        # MIN/MAX compare JSON numbers numerically; text is used only when no numbers exist.
        $numericResult = $this._AggregateValue("$aggFunc($extract)", $numericFilter)
        if ($null -ne $numericResult) { return $numericResult }
        return $this._AggregateValue("$aggFunc($extract)", "json_type(doc, '`$.$fieldToCheck') = 'text'")
    }

    hidden [object] _AggregateValue([string]$aggExpr, [string]$typeFilter) {
        $queryParams = [System.Collections.Generic.List[object]]::new()
        $whereList = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            $whereList.Add("key = ?")
            $queryParams.Add($this.CurrentKey)
        }
        if ($this.WhereClauses.Count -gt 0) {
            $whereList.AddRange($this.WhereClauses)
            if ($null -ne $this.WhereParameters) { $queryParams.AddRange($this.WhereParameters) }
        }
        $whereList.Add($typeFilter)
        $sql = "SELECT $aggExpr AS v FROM [$($this.CurrentCollection)] WHERE " + [string]::Join(" AND ", $whereList) + ";"
        $rows = $this._ExecuteTypedQuery($sql, $queryParams.ToArray())
        if ($rows.Count -eq 0) { return $null }
        return $rows[0].v
    }

    [int] count() {
        $this._EnsureOpen()

        if ($this.IsCollectionGroup) {
            $queryParams = [System.Collections.Generic.List[object]]::new()
            $innerSql = $this._BuildGroupSource($queryParams)
            if ([string]::IsNullOrEmpty($innerSql)) {
                return 0
            }
            $rows = $this._ExecuteBoundQuery("SELECT COUNT(*) FROM ($innerSql$($this._PagingSql()));", $queryParams.ToArray())
            if ($rows.Count -gt 0 -and $rows[0].Count -gt 0) {
                return [int]$rows[0][0]
            }
            return 0
        }

        if ($null -ne $this.UnionQuery) {
            if ($this.UnionQuery.DbHandle -ne $this.DbHandle) {
                throw [System.InvalidOperationException]::new("Cannot execute composite union across different database connections.")
            }
            if ($null -ne $this.UnionQuery.UnionQuery) {
                throw [System.InvalidOperationException]::new("Nested composite queries (nested union/unionAll) are not supported.")
            }
            if ($null -ne $this.UnionQuery.PopulateClauses -and $this.UnionQuery.PopulateClauses.Count -gt 0) {
                throw [System.InvalidOperationException]::new("populate() is not supported on composite queries (union/collectionGroup).")
            }
            $q1Exists = $this._CollectionExists($this.CurrentCollection)
            $q2Exists = $this._CollectionExists($this.UnionQuery.CurrentCollection)
            if (-not $q1Exists -and -not $q2Exists) {
                return 0
            }
            $queryParams = [System.Collections.Generic.List[object]]::new()
            $q1Sql = $this._BuildBranchSelect($this.UnionLeftQuery, $queryParams)
            $q2Sql = $this._BuildBranchSelect($this.UnionQuery, $queryParams)

            $uType = if ($this.UnionType) { $this.UnionType } else { "UNION" }
            $innerUnion = "SELECT key, doc FROM ($q1Sql) $uType SELECT key, doc FROM ($q2Sql)"
            $pagedSql = "SELECT key, doc FROM ($innerUnion)"
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                $pagedSql += " WHERE key = ?"
                $queryParams.Add($this.CurrentKey)
            } elseif ($this.WhereClauses.Count -gt 0) {
                $pagedSql += " WHERE " + [string]::Join(" AND ", $this.WhereClauses)
                $queryParams.AddRange($this.WhereParameters)
            }
            if (-not [string]::IsNullOrEmpty($this.OrderByClause)) { $pagedSql += " " + $this.OrderByClause }
            $pagedSql += $this._PagingSql()
            $rows = $this._ExecuteBoundQuery("SELECT COUNT(*) FROM ($pagedSql);", $queryParams.ToArray())
            if ($rows.Count -gt 0 -and $rows[0].Count -gt 0) {
                return [int]$rows[0][0]
            }
            return 0
        }

        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .count().")
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            return 0
        }

        $source = "SELECT 1 FROM [$($this.CurrentCollection)]"
        $queryParams = [System.Collections.Generic.List[object]]::new()
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            $source += " WHERE key = ?"
            $queryParams.Add($this.CurrentKey)
        } elseif ($this.WhereClauses.Count -gt 0) {
            $source += " WHERE " + [string]::Join(" AND ", $this.WhereClauses)
            $queryParams.AddRange($this.WhereParameters)
        }
        $rows = $this._ExecuteBoundQuery("SELECT COUNT(*) FROM ($source$($this._PagingSql()));", $queryParams.ToArray())
        if ($rows.Count -gt 0 -and $rows[0].Count -gt 0) {
            return [int]$rows[0][0]
        }
        return 0
    }

    # -----------------------------------------------------------------------
    # Custom SQL Execution
    # -----------------------------------------------------------------------
    [PSCustomObject[]] query([string]$sql) {
        return $this.query($sql, @())
    }

    [PSCustomObject[]] query([string]$sql, [object[]]$parameters) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($sql)) {
            throw [System.ArgumentException]::new("SQL query cannot be null or empty.")
        }

        if ($this.config -and $this.config["debug"] -eq $true) {
            Write-Host "[PSLocalBase Custom SQL] $sql" -ForegroundColor DarkCyan
        }
        return $this._ExecuteTypedQuery($sql, $parameters)
    }

    hidden [PSCustomObject[]] _ExecuteTypedQuery([string]$sql, [object[]]$parameters) {
        $this._EnsureOpen()
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $stmt = [IntPtr]::Zero
        try {
            $hasTrailing = $false
            $prepRc = [WinSqlite3]::PrepareSingle($this.DbHandle, $sql, [ref]$stmt, [ref]$hasTrailing)
            if ($prepRc -ne [WinSqlite3]::SQLITE_OK) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Failed to prepare query: $msg (Code: $prepRc$($this._SqlContext($sql)))")
            }
            if ($hasTrailing) {
                throw [System.InvalidOperationException]::new("query() executes exactly one SQL statement; remove the statements after the first ';'.")
            }

            # Validate parameter count against statement placeholders and bind with typed affinities
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $colCount = [WinSqlite3]::ColumnCount($stmt)
            $colNames = [string[]]::new($colCount)
            for ($c = 0; $c -lt $colCount; $c++) {
                $namePtr = [WinSqlite3]::ColumnName($stmt, $c)
                $colNames[$c] = [WinSqlite3]::GetString($namePtr)
            }

            while (($stepRc = [WinSqlite3]::Step($stmt)) -eq [WinSqlite3]::SQLITE_ROW) {
                $rowObj = [ordered]@{}
                for ($c = 0; $c -lt $colCount; $c++) {
                    $colName = $colNames[$c]
                    $val = $null
                    $typeCode = [WinSqlite3]::ColumnType($stmt, $c)
                    # 1 = SQLITE_INTEGER, 2 = SQLITE_FLOAT, 3 = SQLITE_TEXT, 4 = SQLITE_BLOB, 5 = SQLITE_NULL
                    switch ($typeCode) {
                        1 { $val = [WinSqlite3]::ColumnInt64($stmt, $c) }
                        2 { $val = [WinSqlite3]::ColumnDouble($stmt, $c) }
                        3 {
                            $colPtr = [WinSqlite3]::ColumnText($stmt, $c)
                            $byteLen = [WinSqlite3]::ColumnBytes16($stmt, $c)
                            $val = [WinSqlite3]::GetString($colPtr, [int]($byteLen / 2))
                        }
                        4 {
                            throw [System.NotSupportedException]::new("BLOB columns are not supported in query(). PSLocalBase stores documents as JSON text.")
                        }
                        5 { $val = $null }
                        default {
                            $colPtr = [WinSqlite3]::ColumnText($stmt, $c)
                            $val = [WinSqlite3]::GetString($colPtr)
                        }
                    }

                    $rowObj[$colName] = $val
                }
                $results.Add([PSCustomObject]$rowObj)
            }

            if ($stepRc -ne [WinSqlite3]::SQLITE_DONE) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Query execution interrupted: $msg (Code: $stepRc$($this._SqlContext($sql)))")
            }
        } finally {
            [void][WinSqlite3]::Finalize($stmt)
        }

        return [PSCustomObject[]]$results.ToArray()
    }

    # -----------------------------------------------------------------------
    # Deletion Methods: drop, delete, deleteDatabase
    # -----------------------------------------------------------------------
    [void] drop() {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .drop().")
        }
        if ($this.IsCollectionGroup -or $null -ne $this.UnionQuery) {
            throw [System.InvalidOperationException]::new("Cannot drop collection from a composite query (union/collectionGroup). Collection groups are read-only.")
        }
        if ($this._CollectionExists($this.CurrentCollection)) {
            $sql = "DROP TABLE IF EXISTS [$($this.CurrentCollection)];"
            $this._ExecuteDirectSql($sql)
        }
    }

    [void] delete() {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .delete().")
        }

        if ($null -ne $this.UnionQuery -or $this.IsCollectionGroup) {
            throw [System.InvalidOperationException]::new("Cannot execute mutation operation on a composite query (union/collectionGroup).")
        }
        if ($null -ne $this.LimitValue -or $null -ne $this.SkipValue -or -not [string]::IsNullOrEmpty($this.OrderByClause)) {
            throw [System.InvalidOperationException]::new("delete() does not support orderBy(), limit(), or skip(). Use point document deletion (.doc('key').delete()), filter deletion (.where(...).delete()), or explicit collection drop (.drop()).")
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            return
        }

        if (-not [string]::IsNullOrEmpty($this.CurrentKey) -and $null -eq $this.UnionQuery -and -not $this.IsCollectionGroup) {
            # Delete single document
            $sql = "DELETE FROM [$($this.CurrentCollection)] WHERE key = ?;"
            $this._ExecuteBoundSql($sql, @($this.CurrentKey))
        } elseif ($this.WhereClauses.Count -gt 0) {
            # Delete filtered documents
            $whereStr = [string]::Join(" AND ", $this.WhereClauses)
            $sql = "DELETE FROM [$($this.CurrentCollection)] WHERE $whereStr;"
            $this._ExecuteBoundSql($sql, $this.WhereParameters.ToArray())
        } else {
            # Truncate collection records while preserving table schema and secondary indexes
            $sql = "DELETE FROM [$($this.CurrentCollection)];"
            $this._ExecuteDirectSql($sql)
        }
    }

    [void] deleteDatabase() {
        $this._EnsureOpen()
        if ($this.IsChildInstance) {
            throw [System.InvalidOperationException]::new("deleteDatabase() cannot be executed from a collection instance. Call it on the root PSLocalBase instance.")
        }
        # The path comes from SQLite itself so a modified FilePath field cannot redirect the deletion.
        $path = [WinSqlite3]::DbFilename($this.DbHandle)
        $this.close()

        if (-not [string]::IsNullOrEmpty($path)) {
            $deletionErrors = [System.Collections.Generic.List[string]]::new()
            foreach ($targetPath in @($path, "$path-wal", "$path-shm", "$path-journal")) {
                if ([System.IO.File]::Exists($targetPath)) {
                    try {
                        [System.IO.File]::Delete($targetPath)
                    } catch {
                        $deletionErrors.Add("Could not delete '$targetPath': $($_.Exception.Message)")
                    }
                }
            }
            if ($deletionErrors.Count -gt 0) {
                throw [System.IO.IOException]::new([string]::Join("; ", $deletionErrors))
            }
        }
    }

    # -----------------------------------------------------------------------
    # Transactions
    # -----------------------------------------------------------------------
    [bool] _GetInTransaction() {
        $this._EnsureOpen()
        return ([WinSqlite3]::GetAutocommit($this.DbHandle) -eq 0)
    }

    [void] beginTransaction() {
        # IMMEDIATE takes the write lock up front, so busy_timeout applies instead of failing on lock upgrade.
        $this.beginTransaction("immediate")
    }

    [void] beginTransaction([string]$mode) {
        $this._EnsureOpen()
        $keyword = switch (([string]$mode).Trim().ToLowerInvariant()) {
            'immediate' { 'IMMEDIATE' }
            'deferred'  { 'DEFERRED' }
            'exclusive' { 'EXCLUSIVE' }
            default { throw [System.ArgumentException]::new("Transaction mode must be 'immediate', 'deferred', or 'exclusive'. Provided: '$mode'") }
        }
        $this._ExecuteDirectSql("BEGIN $keyword TRANSACTION;")
        $this.InTransaction = $true
        if ($this.ParentDb) { $this.ParentDb.InTransaction = $true }
    }

    [void] commit() {
        $this._EnsureOpen()
        try {
            $this._ExecuteDirectSql("COMMIT;")
        } catch {
            # A failed COMMIT (for example SQLITE_BUSY) leaves the transaction open.
            $stillOpen = $this._GetInTransaction()
            $this.InTransaction = $stillOpen
            if ($this.ParentDb) { $this.ParentDb.InTransaction = $stillOpen }
            throw
        }
        $this.InTransaction = $false
        if ($this.ParentDb) { $this.ParentDb.InTransaction = $false }
    }

    [void] rollback() {
        $this._EnsureOpen()
        try {
            $this._ExecuteDirectSql("ROLLBACK;")
        } finally {
            $this.InTransaction = $false
            if ($this.ParentDb) { $this.ParentDb.InTransaction = $false }
        }
    }

    # -----------------------------------------------------------------------
    # Lifecycle & Cleanup
    # -----------------------------------------------------------------------
    [void] close() {
        if (-not $this.IsChildInstance) {
            $owner = $this.ConnectionOwner
            $this.ConnectionOwner = $null
            if ($this.DbHandle -ne [IntPtr]::Zero) {
                if ($null -ne $owner -and -not $owner.IsClosed -and $owner.DangerousGetHandle() -eq $this.DbHandle) {
                    $owner.Dispose()
                    $owner = $null
                } else {
                    [void][WinSqlite3]::CloseV2($this.DbHandle)
                }
            }
            if ($null -ne $owner) { $owner.Dispose() }
            if ($this.DbHandle -ne [IntPtr]::Zero) { $this.HandleGeneration++ }
        }
        $this.DbHandle = [IntPtr]::Zero
        $this.InTransaction = $false
    }

    [void] Dispose() {
        $this.close()
    }

    # -----------------------------------------------------------------------
    # Internal Engine Helpers
    # -----------------------------------------------------------------------
    [void] _EnsureOpen() {
        if ($this.IsChildInstance) {
            $root = $this.ParentDb
            # A generation mismatch means the root closed; a reused native address must not be trusted.
            if ($null -eq $root -or $root.DbHandle -eq [IntPtr]::Zero -or $root.DbHandle -ne $this.DbHandle -or $root.HandleGeneration -ne $this.HandleGeneration) {
                $this.DbHandle = [IntPtr]::Zero
            }
        }
        if ($this.DbHandle -eq [IntPtr]::Zero) {
            throw [System.InvalidOperationException]::new("Database connection is closed.")
        }
        # Collection names are interpolated into SQL, so they are re-validated on every operation.
        if (-not [string]::IsNullOrEmpty($this.CurrentCollection)) {
            $pattern = if ($this.IsCollectionGroup) { [PSLocalBase]::GroupPatternPattern } else { [PSLocalBase]::IdentifierPattern }
            if ($this.CurrentCollection -notmatch $pattern) {
                throw [System.InvalidOperationException]::new("Collection name '$($this.CurrentCollection)' is invalid.")
            }
        }
    }

    hidden [string] _PagingSql() {
        if ($null -ne $this.LimitValue -and $this.LimitValue -ge 0) {
            if ($null -ne $this.SkipValue -and $this.SkipValue -gt 0) {
                return " LIMIT $([int]$this.LimitValue) OFFSET $([int]$this.SkipValue)"
            }
            return " LIMIT $([int]$this.LimitValue)"
        }
        if ($null -ne $this.SkipValue -and $this.SkipValue -gt 0) {
            return " LIMIT -1 OFFSET $([int]$this.SkipValue)"
        }
        return ""
    }

    # Filtered rows of every table matching the group pattern, resolved when the query runs.
    hidden [string] _BuildGroupSource([System.Collections.Generic.List[object]]$queryParams) {
        $tables = $this._ResolveGroupTables()
        if ($tables.Count -eq 0) { return "" }
        $subqueries = [System.Collections.Generic.List[string]]::new()
        foreach ($tbl in $tables) {
            $subqueries.Add("SELECT key, json_set(doc, '$._collection', '$tbl') AS doc FROM [$tbl]")
        }
        $source = "SELECT key, doc FROM (" + [string]::Join(" UNION ALL ", $subqueries) + ")"
        if ($this.WhereClauses.Count -gt 0) {
            $source += " WHERE " + [string]::Join(" AND ", $this.WhereClauses)
            if ($null -ne $this.WhereParameters) { $queryParams.AddRange($this.WhereParameters) }
        }
        return $source
    }

    hidden [string[]] _ResolveGroupTables() {
        $allTables = $this._ExecuteBoundQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';", @())
        $patternRegex = '\A' + [regex]::Escape($this.CurrentCollection).Replace('\*', '.*').Replace('\?', '.') + '\z'
        $matched = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $allTables) {
            $tableName = $row[0]
            if ($tableName -match $patternRegex -and $tableName -match [PSLocalBase]::IdentifierPattern) {
                $matched.Add($tableName)
            }
        }
        return [string[]]$matched.ToArray()
    }

    hidden [string] _SqlContext([string]$sql) {
        # SQL text can contain literals copied from user data, so it is only exposed when debugging.
        if ($this.config -and $this.config["debug"] -eq $true) { return ", Query: $sql" }
        return ""
    }

    [void] _BindStatementParameters([IntPtr]$stmt, [object[]]$parameters, [string]$sql) {
        $expectedCount = [WinSqlite3]::BindParameterCount($stmt)
        $actualCount = if ($null -ne $parameters) { $parameters.Count } else { 0 }
        if ($expectedCount -ne $actualCount) {
            throw [System.InvalidOperationException]::new("Parameter count mismatch: query expects $expectedCount parameters, but $actualCount were provided.")
        }

        if ($null -ne $parameters -and $parameters.Count -gt 0) {
            for ($i = 0; $i -lt $parameters.Count; $i++) {
                $paramIdx = $i + 1
                $val = $parameters[$i]
                $bindRc = [WinSqlite3]::SQLITE_OK

                $val = [PSLocalBase]::_NormalizeScalar($val)
                if ($null -eq $val) {
                    $bindRc = [WinSqlite3]::BindNull($stmt, $paramIdx)
                } elseif ($val -is [byte] -or $val -is [sbyte] -or $val -is [int16] -or $val -is [uint16] -or $val -is [int32] -or $val -is [uint32] -or $val -is [int64] -or ($val -is [uint64] -and [uint64]$val -le [uint64][long]::MaxValue)) {
                    $bindRc = [WinSqlite3]::BindInt64($stmt, $paramIdx, [long]$val)
                } elseif ($val -is [single] -or $val -is [double] -or $val -is [decimal] -or $val -is [uint64]) {
                    $bindRc = [WinSqlite3]::BindDouble($stmt, $paramIdx, [double]$val)
                } elseif ($val -is [bool]) {
                    $boolVal = if ($val) { 1L } else { 0L }
                    $bindRc = [WinSqlite3]::BindInt64($stmt, $paramIdx, $boolVal)
                } else {
                    $strVal = [string]$val
                    $byteCount = [System.Text.Encoding]::Unicode.GetByteCount($strVal)
                    $bindRc = [WinSqlite3]::BindText($stmt, $paramIdx, $strVal, $byteCount, [WinSqlite3]::SQLITE_TRANSIENT)
                }

                if ($bindRc -ne [WinSqlite3]::SQLITE_OK) {
                    $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                    throw [System.InvalidOperationException]::new("Failed to bind parameter at index ${paramIdx}: $msg (Code: $bindRc$($this._SqlContext($sql)))")
                }
            }
        }
    }

    [void] _ExecuteDirectSql([string]$sql) {
        $this._EnsureOpen()
        if ($this.config -and $this.config["debug"] -eq $true) {
            Write-Host "[PSLocalBase SQL] $sql" -ForegroundColor DarkCyan
        }

        $errPtr = [IntPtr]::Zero
        try {
            $rc = [WinSqlite3]::Exec($this.DbHandle, $sql, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$errPtr)
            if ($rc -ne [WinSqlite3]::SQLITE_OK) {
                $msg = [WinSqlite3]::GetUtf8String($errPtr)
                if ([string]::IsNullOrEmpty($msg)) {
                    $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                }
                throw [System.InvalidOperationException]::new("SQLite execution error: $msg (Code: $rc$($this._SqlContext($sql)))")
            }
        } finally {
            if ($errPtr -ne [IntPtr]::Zero) {
                [WinSqlite3]::Free($errPtr)
            }
        }
    }

    [void] _ExecuteBoundSql([string]$sql, [object[]]$parameters) {
        $this._EnsureOpen()
        if ($this.config -and $this.config["debug"] -eq $true) {
            Write-Host "[PSLocalBase Bound SQL] $sql | Params count: $($parameters.Count)" -ForegroundColor DarkCyan
        }

        $stmt = [IntPtr]::Zero
        $prepRc = [WinSqlite3]::Prepare($this.DbHandle, $sql, -1, [ref]$stmt, [IntPtr]::Zero)
        if ($prepRc -ne [WinSqlite3]::SQLITE_OK) {
            $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
            throw [System.InvalidOperationException]::new("Failed to prepare statement: $msg (Code: $prepRc$($this._SqlContext($sql)))")
        }

        try {
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $stepRc = [WinSqlite3]::Step($stmt)
            if ($stepRc -ne [WinSqlite3]::SQLITE_DONE -and $stepRc -ne [WinSqlite3]::SQLITE_ROW) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Failed to execute statement: $msg (Code: $stepRc$($this._SqlContext($sql)))")
            }
        } finally {
            [void][WinSqlite3]::Finalize($stmt)
        }
    }

    [System.Collections.Generic.List[string[]]] _ExecuteBoundQuery([string]$sql, [object[]]$parameters) {
        $this._EnsureOpen()
        if ($this.config -and $this.config["debug"] -eq $true) {
            Write-Host "[PSLocalBase Query] $sql" -ForegroundColor DarkCyan
        }

        $results = [System.Collections.Generic.List[string[]]]::new()
        $stmt = [IntPtr]::Zero
        $prepRc = [WinSqlite3]::Prepare($this.DbHandle, $sql, -1, [ref]$stmt, [IntPtr]::Zero)
        if ($prepRc -ne [WinSqlite3]::SQLITE_OK) {
            $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
            throw [System.InvalidOperationException]::new("Failed to prepare query: $msg (Code: $prepRc$($this._SqlContext($sql)))")
        }

        try {
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $colCount = [WinSqlite3]::ColumnCount($stmt)
            while (($stepRc = [WinSqlite3]::Step($stmt)) -eq [WinSqlite3]::SQLITE_ROW) {
                $row = [string[]]::new($colCount)
                for ($c = 0; $c -lt $colCount; $c++) {
                    $typeCode = [WinSqlite3]::ColumnType($stmt, $c)
                    if ($typeCode -eq 4) {
                        throw [System.NotSupportedException]::new("BLOB columns are not supported in query(). PSLocalBase stores documents as JSON text.")
                    }
                    $colPtr = [WinSqlite3]::ColumnText($stmt, $c)
                    $byteLen = [WinSqlite3]::ColumnBytes16($stmt, $c)
                    $row[$c] = [WinSqlite3]::GetString($colPtr, [int]($byteLen / 2))
                }
                $results.Add($row)
            }

            if ($stepRc -ne [WinSqlite3]::SQLITE_DONE) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Query execution interrupted: $msg (Code: $stepRc)")
            }
        } finally {
            [void][WinSqlite3]::Finalize($stmt)
        }

        return $results
    }

    # -----------------------------------------------------------------------
    # Structural JSON Model Equality (Preserves scalar types, numbers vs strings,
    # and normalizes IDictionary vs PSCustomObject representations)
    # -----------------------------------------------------------------------
    static [bool] _JsonValuesEqual([object]$a, [object]$b) {
        if ($null -eq $a -and $null -eq $b) { return $true }
        if ($null -eq $a -or $null -eq $b) { return $false }

        # Booleans
        if ($a -is [bool] -or $b -is [bool]) {
            if ($a -is [bool] -and $b -is [bool]) {
                return $a -eq $b
            }
            return $false
        }

        # Numbers: byte, int16, int32, int64, single, double, decimal, uint, biginteger
        $isFloatA = ($a -is [double] -or $a -is [single])
        $isFloatB = ($b -is [double] -or $b -is [single])
        $isIntA = ($a -is [byte] -or $a -is [sbyte] -or $a -is [int16] -or $a -is [uint16] -or $a -is [int32] -or $a -is [uint32] -or $a -is [int64] -or $a -is [uint64] -or $a -is [System.Numerics.BigInteger])
        $isIntB = ($b -is [byte] -or $b -is [sbyte] -or $b -is [int16] -or $b -is [uint16] -or $b -is [int32] -or $b -is [uint32] -or $b -is [int64] -or $b -is [uint64] -or $b -is [System.Numerics.BigInteger])
        $isDecA = ($a -is [decimal])
        $isDecB = ($b -is [decimal])
        $isNumA = ($isFloatA -or $isIntA -or $isDecA)
        $isNumB = ($isFloatB -or $isIntB -or $isDecB)

        if ($isNumA -or $isNumB) {
            if ($isNumA -and $isNumB) {
                # 1. Both are floating-point
                if ($isFloatA -and $isFloatB) {
                    return ([double]$a) -eq ([double]$b)
                }

                # 2. Both are integers or BigInteger
                if ($isIntA -and $isIntB) {
                    try {
                        return ([System.Numerics.BigInteger]$a) -eq ([System.Numerics.BigInteger]$b)
                    } catch {
                        return $a -eq $b
                    }
                }

                # 3. One is integer and the other is floating-point
                if (($isIntA -and $isFloatB) -or ($isFloatA -and $isIntB)) {
                    $fVal = if ($isFloatA) { [double]$a } else { [double]$b }
                    $iVal = if ($isIntA) { $a } else { $b }
                    if ([double]::IsNaN($fVal) -or [double]::IsInfinity($fVal)) { return $false }
                    if ([Math]::Floor($fVal) -ne $fVal) { return $false }
                    try {
                        $fBi = [System.Numerics.BigInteger]$fVal
                        $iBi = [System.Numerics.BigInteger]$iVal
                        return $fBi -eq $iBi
                    } catch {
                        return $false
                    }
                }

                # 4. Decimals (e.g. from PS 5.1 JSON or explicit decimal)
                if ($isDecA -and $isDecB) {
                    return [decimal]$a -eq [decimal]$b
                }
                if ($isDecA -and $isIntB) {
                    $decVal = [decimal]$a
                    if ([decimal]::Truncate($decVal) -ne $decVal) { return $false }
                    try {
                        return ([System.Numerics.BigInteger]$decVal) -eq ([System.Numerics.BigInteger]$b)
                    } catch {
                        return $false
                    }
                }
                if ($isIntA -and $isDecB) {
                    $decVal = [decimal]$b
                    if ([decimal]::Truncate($decVal) -ne $decVal) { return $false }
                    try {
                        return ([System.Numerics.BigInteger]$a) -eq ([System.Numerics.BigInteger]$decVal)
                    } catch {
                        return $false
                    }
                }
                if (($isDecA -and $isFloatB) -or ($isFloatA -and $isDecB)) {
                    $fVal = if ($isFloatA) { [double]$a } else { [double]$b }
                    $dVal = if ($isDecA) { [decimal]$a } else { [decimal]$b }
                    if ([double]::IsNaN($fVal) -or [double]::IsInfinity($fVal)) { return $false }
                    if ([Math]::Abs($fVal) -lt 1e-28) {
                        return $fVal -eq 0.0 -and $dVal -eq [decimal]0
                    }
                    try {
                        $fStrR = $fVal.ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
                        $fDecR = [decimal]::Parse($fStrR, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
                        if ($dVal -eq $fDecR) {
                            $fBackR = [double]::Parse($fDecR.ToString([System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
                            if ($fBackR -eq $fVal) { return $true }
                        }
                    } catch {}
                    try {
                        $fStrG = $fVal.ToString("G17", [System.Globalization.CultureInfo]::InvariantCulture)
                        $fDecG = [decimal]::Parse($fStrG, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
                        if ($dVal -eq $fDecG) {
                            $fBackG = [double]::Parse($fDecG.ToString([System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
                            if ($fBackG -eq $fVal) { return $true }
                        }
                    } catch {}
                    return $false
                }
            }
            return $false
        }

        # Strings
        if ($a -is [string] -or $b -is [string]) {
            if ($a -is [string] -and $b -is [string]) {
                return $a -ceq $b
            }
            return $false
        }

        # Arrays
        $isArrA = ($a -is [System.Collections.IEnumerable] -and $a -isnot [string] -and $a -isnot [System.Collections.IDictionary] -and $a -isnot [System.Management.Automation.PSCustomObject])
        $isArrB = ($b -is [System.Collections.IEnumerable] -and $b -isnot [string] -and $b -isnot [System.Collections.IDictionary] -and $b -isnot [System.Management.Automation.PSCustomObject])
        if ($isArrA -or $isArrB) {
            if ($isArrA -and $isArrB) {
                $listA = @($a)
                $listB = @($b)
                if ($listA.Count -ne $listB.Count) { return $false }
                for ($i = 0; $i -lt $listA.Count; $i++) {
                    if (-not [PSLocalBase]::_JsonValuesEqual($listA[$i], $listB[$i])) {
                        return $false
                    }
                }
                return $true
            }
            return $false
        }

        # Objects (Hashtable, Dictionary, or PSCustomObject)
        $isObjA = ($a -is [System.Collections.IDictionary] -or $a -is [System.Management.Automation.PSCustomObject])
        $isObjB = ($b -is [System.Collections.IDictionary] -or $b -is [System.Management.Automation.PSCustomObject])
        if ($isObjA -and $isObjB) {
            $propsA = if ($a -is [System.Collections.IDictionary]) { @($a.Keys) } else { @($a.PSObject.Properties | ForEach-Object { $_.Name }) }
            $propsB = if ($b -is [System.Collections.IDictionary]) { @($b.Keys) } else { @($b.PSObject.Properties | ForEach-Object { $_.Name }) }
            
            $sortedA = @($propsA) | Sort-Object
            $sortedB = @($propsB) | Sort-Object
            if ($sortedA.Count -ne $sortedB.Count) { return $false }
            for ($i = 0; $i -lt $sortedA.Count; $i++) {
                if ($sortedA[$i] -ne $sortedB[$i]) { return $false }
            }
            foreach ($prop in $propsA) {
                $valA = if ($a -is [System.Collections.IDictionary]) { $a[$prop] } else { $a.$prop }
                $valB = if ($b -is [System.Collections.IDictionary]) { $b[$prop] } else { $b.$prop }
                if (-not [PSLocalBase]::_JsonValuesEqual($valA, $valB)) {
                    return $false
                }
            }
            return $true
        }

        return [object]::Equals($a, $b)
    }
    [object] _DeepMerge([object]$target, [object]$source) {
        if ($null -eq $target) { return $source }
        if ($null -eq $source) { return $target }

        $dict = [ordered]@{}

        # Populate target properties
        if ($target -is [System.Collections.IDictionary]) {
            foreach ($k in $target.Keys) { $dict[$k] = $target[$k] }
        } elseif ($target -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $target.PSObject.Properties) { $dict[$prop.Name] = $prop.Value }
        } else {
            return $source
        }

        # Determine source properties
        $sourceKeys = if ($source -is [System.Collections.IDictionary]) {
            $source.Keys
        } else {
            $source.PSObject.Properties | ForEach-Object { $_.Name }
        }

        foreach ($k in $sourceKeys) {
            $srcVal = if ($source -is [System.Collections.IDictionary]) { $source[$k] } else { $source.$k }

            # Check for ArrayUnion / ArrayRemove sentinel or descriptor
            $isArrayOp = $false
            $opType = ""
            $opVals = @()

            if ($srcVal -is [PSLocalBaseArrayOp]) {
                $isArrayOp = $true
                $opType = $srcVal.OpType
                $opVals = $srcVal.Values
            } elseif ($srcVal -is [System.Collections.IDictionary]) {
                if ($srcVal.Contains('$arrayUnion')) {
                    $isArrayOp = $true
                    $opType = 'union'
                    $v = $srcVal['$arrayUnion']
                    $opVals = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { @($v) } else { @($v) }
                } elseif ($srcVal.Contains('$arrayRemove')) {
                    $isArrayOp = $true
                    $opType = 'remove'
                    $v = $srcVal['$arrayRemove']
                    $opVals = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { @($v) } else { @($v) }
                }
            } elseif ($srcVal -is [System.Management.Automation.PSCustomObject]) {
                $propUnion = $srcVal.PSObject.Properties['$arrayUnion']
                $propRemove = $srcVal.PSObject.Properties['$arrayRemove']
                if ($null -ne $propUnion) {
                    $isArrayOp = $true
                    $opType = 'union'
                    $v = $propUnion.Value
                    $opVals = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { @($v) } else { @($v) }
                } elseif ($null -ne $propRemove) {
                    $isArrayOp = $true
                    $opType = 'remove'
                    $v = $propRemove.Value
                    $opVals = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { @($v) } else { @($v) }
                }
            }

            if ($isArrayOp) {
                $existingArr = [System.Collections.Generic.List[object]]::new()
                if ($dict.Contains($k) -and $null -ne $dict[$k] -and $dict[$k] -is [System.Collections.IEnumerable] -and $dict[$k] -isnot [string]) {
                    foreach ($item in $dict[$k]) { [void]$existingArr.Add($item) }
                }
                if ($opType -eq 'union') {
                    foreach ($val in $opVals) {
                        $found = $false
                        foreach ($ex in $existingArr) {
                            if ([PSLocalBase]::_JsonValuesEqual($ex, $val)) {
                                $found = $true
                                break
                            }
                        }
                        if (-not $found) {
                            [void]$existingArr.Add($val)
                        }
                    }
                } elseif ($opType -eq 'remove') {
                    $kept = [System.Collections.Generic.List[object]]::new()
                    foreach ($ex in $existingArr) {
                        $match = $false
                        foreach ($val in $opVals) {
                            if ([PSLocalBase]::_JsonValuesEqual($ex, $val)) {
                                $match = $true
                                break
                            }
                        }
                        if (-not $match) {
                            [void]$kept.Add($ex)
                        }
                    }
                    $existingArr = $kept
                }
                $dict[$k] = $existingArr.ToArray()
                continue
            }

            if ($dict.Contains($k) -and
                ($dict[$k] -is [System.Collections.IDictionary] -or $dict[$k] -is [System.Management.Automation.PSCustomObject]) -and
                ($srcVal -is [System.Collections.IDictionary] -or $srcVal -is [System.Management.Automation.PSCustomObject])) {
                $dict[$k] = $this._DeepMerge($dict[$k], $srcVal)
            } else {
                $dict[$k] = $srcVal
            }
        }

        return [PSCustomObject]$dict
    }
}

# ---------------------------------------------------------------------------
# 3. Exported Module Functions (Cmdlet aliases & helper commands)
# ---------------------------------------------------------------------------
function New-LocalBase {
    <#
    .SYNOPSIS
        Creates or connects to a PSLocalBase database instance.
    .PARAMETER Path
        Path to the SQLite database file, or ':memory:' for an in-memory database.
    .EXAMPLE
        $db = New-LocalBase -Path .\app.db
    #>
    [CmdletBinding()]
    [OutputType([PSLocalBase])]
    param(
        [Parameter(Position = 0, Mandatory = $false)]
        [string]$Path = ":memory:",
        [Parameter(Position = 1, Mandatory = $false)]
        [hashtable]$Options = @{}
    )
    return [PSLocalBase]::new($Path, $Options)
}

# ---------------------------------------------------------------------------
# 4. Type Accelerator Registration
# ---------------------------------------------------------------------------
try {
    $typeAcceleratorsClass = [PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if ($typeAcceleratorsClass) {
        if ($typeAcceleratorsClass::Get.ContainsKey('PSLocalBase')) {
            [void]$typeAcceleratorsClass::Remove('PSLocalBase')
        }
        [void]$typeAcceleratorsClass::Add('PSLocalBase', [PSLocalBase])
    }
} catch {
    # Non-fatal fallback
}

# ---------------------------------------------------------------------------
# 4b. InTransaction reflects the native autocommit state
# ---------------------------------------------------------------------------
# Raw SQL (for example query('BEGIN')) can open a transaction without beginTransaction().
Update-TypeData -TypeName PSLocalBase -MemberType ScriptProperty -MemberName InTransaction -Value {
    if ($this.IsChildInstance -and ($null -eq $this.ParentDb -or $this.ParentDb.DbHandle -eq [IntPtr]::Zero)) { return $false }
    if ($this.DbHandle -eq [IntPtr]::Zero) { return $false }
    return ([WinSqlite3]::GetAutocommit($this.DbHandle) -eq 0)
} -SecondValue {
    param($val)
} -Force

# ---------------------------------------------------------------------------
# 5. Clean Module Unload
# ---------------------------------------------------------------------------
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    try {
        $typeAcceleratorsClass = [PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
        if ($typeAcceleratorsClass -and $typeAcceleratorsClass::Get.ContainsKey('PSLocalBase')) {
            [void]$typeAcceleratorsClass::Remove('PSLocalBase')
        }
    } catch { }
}

Export-ModuleMember -Function New-LocalBase
