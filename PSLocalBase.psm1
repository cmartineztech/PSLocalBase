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
# 2. Main PSLocalBase Class Definition
# ---------------------------------------------------------------------------
class PSLocalBase : System.IDisposable {
    [IntPtr]$DbHandle = [IntPtr]::Zero
    [string]$FilePath
    [string]$CurrentCollection = ""
    [string]$CurrentKey = ""
    [System.Collections.Generic.List[string]]$WhereClauses
    [System.Collections.Generic.List[string]]$WhereParameters
    [string]$OrderByClause = ""
    [object]$LimitValue = $null
    [object]$SkipValue = $null
    [bool]$InTransaction = $false
    [hashtable]$config
    [bool]$IsChildInstance = $false
    [PSLocalBase]$ParentDb = $null

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
        $this.WhereParameters = [System.Collections.Generic.List[string]]::new()
        $this.InTransaction = if ($parent) { $parent.InTransaction } else { $false }
    }

    [void] Init([string]$filePath, [hashtable]$options) {
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            throw [System.ArgumentException]::new("Database file path cannot be null or empty.")
        }

        $this.WhereClauses = [System.Collections.Generic.List[string]]::new()
        $this.WhereParameters = [System.Collections.Generic.List[string]]::new()
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

        try {
            $busyMs = if ($this.config.ContainsKey("busyTimeout")) { [int]$this.config["busyTimeout"] } else { 5000 }
            [void][WinSqlite3]::BusyTimeout($this.DbHandle, $busyMs)
            $this._ExecuteDirectSql("PRAGMA busy_timeout = $busyMs;")

            $useWal = if ($this.config.ContainsKey("wal")) { [bool]$this.config["wal"] } else { $true }
            if ($this.FilePath -ne ":memory:") {
                if ($useWal) {
                    $this._ExecuteDirectSql("PRAGMA journal_mode = WAL;")
                    $this._ExecuteDirectSql("PRAGMA synchronous = NORMAL;")
                } else {
                    $this._ExecuteDirectSql("PRAGMA journal_mode = DELETE;")
                    $this._ExecuteDirectSql("PRAGMA synchronous = FULL;")
                }
            }

            $this._ExecuteDirectSql("PRAGMA temp_store = MEMORY;")

            $cacheMB = if ($this.config.ContainsKey("cacheSizeMB")) { [int]$this.config["cacheSizeMB"] } else { 16 }
            $cacheKib = -1 * ($cacheMB * 1024)
            $this._ExecuteDirectSql("PRAGMA cache_size = $cacheKib;")
        } catch {
            if ($this.DbHandle -ne [IntPtr]::Zero) {
                [void][WinSqlite3]::CloseV2($this.DbHandle)
                $this.DbHandle = [IntPtr]::Zero
            }
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
            # Verify table has compatible schema (key and doc columns)
            $cols = $this._ExecuteBoundQuery("PRAGMA table_info([$tableName]);", @())
            $hasKey = $false
            $hasDoc = $false
            foreach ($c in $cols) {
                if ($c[1] -eq "key") { $hasKey = $true }
                if ($c[1] -eq "doc") { $hasDoc = $true }
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

    [void] _EnsureCollectionTable() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified.")
        }
        $createSql = "CREATE TABLE IF NOT EXISTS [$($this.CurrentCollection)] (key TEXT PRIMARY KEY, doc TEXT);"
        $this._ExecuteDirectSql($createSql)
    }

    [PSLocalBase] create() {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified to create. Call .collection('name').create()")
        }
        $this._EnsureCollectionTable()
        return $this
    }

    [PSLocalBase] createCollection([string]$name) {
        return $this.collection($name).create()
    }

    [PSLocalBase] collection([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw [System.ArgumentException]::new("Collection name cannot be null or whitespace.")
        }
        if ($name -notmatch '^[a-zA-Z0-9_]+$') {
            throw [System.ArgumentException]::new("Collection name '$name' is invalid. Only alphanumeric characters and underscores are allowed.")
        }

        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        $child = [PSLocalBase]::new($this.DbHandle, $this.FilePath, $this.config, $root)
        $child.CurrentCollection = $name
        $child._ResetQueryState()

        return $child
    }

    [PSLocalBase] doc([object]$keyOrCriteria) {
        $this._EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .doc().")
        }
        if ($null -eq $keyOrCriteria) {
            throw [System.ArgumentException]::new("Document key cannot be null.")
        }

        # Support string key or object/hashtable criteria like @{ id = 1 } or @{ key = 'abc' }
        $resolvedKey = ""
        if ($keyOrCriteria -is [string]) {
            $resolvedKey = $keyOrCriteria
        } elseif ($keyOrCriteria -is [System.Collections.IDictionary]) {
            if ($keyOrCriteria.Contains("key")) {
                $resolvedKey = [string]$keyOrCriteria["key"]
            } elseif ($keyOrCriteria.Contains("id")) {
                $resolvedKey = [string]$keyOrCriteria["id"]
            } else {
                # Fallback to first entry or string representation
                foreach ($val in $keyOrCriteria.Values) {
                    $resolvedKey = [string]$val
                    break
                }
            }
        } elseif ($keyOrCriteria -is [System.Management.Automation.PSCustomObject]) {
            if ($keyOrCriteria.PSObject.Properties["key"]) {
                $resolvedKey = [string]$keyOrCriteria.key
            } elseif ($keyOrCriteria.PSObject.Properties["id"]) {
                $resolvedKey = [string]$keyOrCriteria.id
            } else {
                foreach ($prop in $keyOrCriteria.PSObject.Properties) {
                    $resolvedKey = [string]$prop.Value
                    break
                }
            }
        } else {
            $resolvedKey = [string]$keyOrCriteria
        }

        if ([string]::IsNullOrWhiteSpace($resolvedKey)) {
            throw [System.ArgumentException]::new("Document key could not be resolved from criteria.")
        }

        if ($resolvedKey.IndexOf([char]0) -ge 0) {
            throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
        }

        $this.CurrentKey = $resolvedKey
        $this.WhereClauses.Clear()
        $this.WhereParameters.Clear()

        # Automatic schema provisioning on target navigation (.doc())
        $this._EnsureCollectionTable()
        return $this
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
        $jsonWarn = $null
        $json = ConvertTo-Json -InputObject $data -Compress -Depth $depth -WarningVariable jsonWarn -WarningAction SilentlyContinue
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
        $this._EnsureCollectionTable()

        # Case 1: Targeted document (.doc('key').set(data))
        if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
            if ($this.CurrentKey.IndexOf([char]0) -ge 0) {
                throw [System.ArgumentException]::new("Document key cannot contain null characters (U+0000).")
            }
            try {
                $json = $this._SerializeJson($data)
                $sql = "INSERT OR REPLACE INTO [$($this.CurrentCollection)] (key, doc) VALUES (?, ?);"
                $this._ExecuteBoundSql($sql, @($this.CurrentKey, $json))
            } finally {
                $this.CurrentKey = ""
            }
            return
        }

        # Case 2: Collection-level set (overwrite entire collection)
        if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string] -and $data -isnot [System.Collections.IDictionary]) {
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
                        # If item is exported wrapper @{ key = ...; data = ... }, unwrap payload cleanly
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
            } finally {
                $this._ResetQueryState()
            }
            return
        }

        throw [System.InvalidOperationException]::new("No document key selected. Call .doc('key') to set a single document or pass an array of items to overwrite the collection.")
    }

    [string] add([object]$data) {
        return $this.add($data, "")
    }

    [string] add([object]$data, [string]$customKey) {
        $this._EnsureOpen()
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

        [void]$this.doc($newKey).set($data)
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

    [void] update([object]$partialData) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .update().")
        }
        if ([string]::IsNullOrEmpty($this.CurrentKey)) {
            throw [System.InvalidOperationException]::new("No document key specified. Call .doc('key') before .update().")
        }

        $targetKey = $this.CurrentKey
        $startedTx = $false
        if (-not $this._GetInTransaction()) {
            $this._ExecuteDirectSql("BEGIN IMMEDIATE;")
            $startedTx = $true
        }

        try {
            # Retrieve existing document
            $existing = $this.get()
            $this.CurrentKey = $targetKey
            if ($null -eq $existing) {
                # If document doesn't exist, create it with partialData (upsert behavior)
                $this.set($partialData)
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
        } finally {
            $this.CurrentKey = ""
        }
    }

    # -----------------------------------------------------------------------
    # Query & Filtering Methods: where, orderBy, limit, get
    # -----------------------------------------------------------------------
    [PSLocalBase] where([string]$field, [string]$operator, [object]$value) {
        if ([string]::IsNullOrWhiteSpace($field)) {
            throw [System.ArgumentException]::new("Field name cannot be null or empty in where clause.")
        }
        $trimmedField = $field.Trim()
        $fieldToCheck = if ($trimmedField.StartsWith("$.")) { $trimmedField.Substring(2) } else { $trimmedField }
        if ($fieldToCheck -notmatch '^[a-zA-Z0-9_]+(\[\d+\])*(\.[a-zA-Z0-9_]+(\[\d+\])*)*$') {
            throw [System.ArgumentException]::new("Field name '$field' is invalid. Only alphanumeric characters, underscores, dots, and balanced numeric array brackets are allowed.")
        }

        if ([string]::IsNullOrWhiteSpace($operator)) {
            throw [System.ArgumentException]::new("Operator cannot be null or empty in where clause.")
        }

        $trimmedOp = $operator.Trim().ToUpperInvariant()

        # Normalize operator
        $sqlOp = switch -Regex ($trimmedOp) {
            '^(=|==|-EQ)$'          { '=' }
            '^(!=|<>|-NE)$'         { '!=' }
            '^(>|-GT)$'             { '>' }
            '^(<|-LT)$'             { '<' }
            '^(>=|-GE)$'            { '>=' }
            '^(<=|-LE)$'            { '<=' }
            '^(LIKE|-LIKE)$'        { 'LIKE' }
            '^(NOT LIKE|-NOTLIKE)$' { 'NOT LIKE' }
            '^(IN|-IN)$'            { 'IN' }
            default {
                throw [System.ArgumentException]::new("Unsupported operator '$operator' in where clause.")
            }
        }

        # Clear any stale document key when applying query filters
        $this.CurrentKey = ""

        # Format JSON field selector using trimmed field path
        $jsonField = "`$.$fieldToCheck"

        # Case A: Parameterized IN list
        if ($sqlOp -eq 'IN') {
            if ($null -eq $value -or $value -is [System.Collections.IDictionary]) {
                throw [System.ArgumentException]::new("Value for 'IN' operator must be an array or scalar value, not null or a dictionary.")
            }
            $items = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                $value
            } else {
                @($value)
            }
            $placeholders = [System.Collections.Generic.List[string]]::new()
            foreach ($elem in $items) {
                if ($null -eq $elem) {
                    $placeholders.Add("NULL")
                } elseif ($elem -is [bool]) {
                    $placeholders.Add($(if ($elem) { "1" } else { "0" }))
                } elseif ($elem -is [byte] -or $elem -is [int16] -or $elem -is [int32] -or $elem -is [int64] -or
                          $elem -is [single] -or $elem -is [double] -or $elem -is [decimal]) {
                    $placeholders.Add([System.Convert]::ToString($elem, [System.Globalization.CultureInfo]::InvariantCulture))
                } else {
                    $placeholders.Add("?")
                    $this.WhereParameters.Add([string]$elem)
                }
            }
            if ($placeholders.Count -eq 0) {
                $this.WhereClauses.Add("1 = 0")
                return $this
            }
            $clause = "json_extract(doc, '$jsonField') IN (" + [string]::Join(", ", $placeholders) + ")"
            $this.WhereClauses.Add($clause)
            return $this
        }

        # Case B: Null comparisons
        if ($null -eq $value) {
            if ($sqlOp -eq '=') {
                $this.WhereClauses.Add("json_extract(doc, '$jsonField') IS NULL")
                return $this
            } elseif ($sqlOp -eq '!=') {
                $this.WhereClauses.Add("json_extract(doc, '$jsonField') IS NOT NULL")
                return $this
            } else {
                $this.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp NULL")
                return $this
            }
        }

        # Case C: Strongly-typed Boolean
        if ($value -is [bool]) {
            $boolLit = if ($value) { "1" } else { "0" }
            $this.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp $boolLit")
            return $this
        }

        # Case D: Strongly-typed Numbers
        if ($value -is [byte] -or $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or
            $value -is [single] -or $value -is [double] -or $value -is [decimal]) {
            $numLit = [System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture)
            $this.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp $numLit")
            return $this
        }

        # Case E: String values (PowerShell -like conversion to SQL wildcard)
        $paramVal = [string]$value
        if ($trimmedOp -eq '-LIKE' -or $trimmedOp -eq '-NOTLIKE') {
            if ($paramVal.Contains("*") -or $paramVal.Contains("?")) {
                $paramVal = $paramVal.Replace("%", "[%]").Replace("_", "[_]").Replace("*", "%").Replace("?", "_")
            }
        }

        $this.WhereClauses.Add("json_extract(doc, '$jsonField') $sqlOp ?")
        $this.WhereParameters.Add($paramVal)

        return $this
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
        if ($fieldToCheck -notmatch '^[a-zA-Z0-9_]+(\[\d+\])*(\.[a-zA-Z0-9_]+(\[\d+\])*)*$') {
            throw [System.ArgumentException]::new("Field name '$field' is invalid in orderBy. Only alphanumeric characters, underscores, dots, and balanced numeric array brackets are allowed.")
        }
        if ([string]::IsNullOrWhiteSpace($direction)) {
            throw [System.ArgumentException]::new("Order direction must be 'asc' or 'desc'.")
        }
        $dir = $direction.Trim().ToUpperInvariant()
        if ($dir -ne "ASC" -and $dir -ne "DESC") {
            throw [System.ArgumentException]::new("Order direction must be 'asc' or 'desc'. Provided: '$direction'")
        }

        $jsonField = "`$.$fieldToCheck"
        $this.OrderByClause = "ORDER BY json_extract(doc, '$jsonField') $dir"
        return $this
    }

    [PSLocalBase] limit([int]$count) {
        if ($count -lt 0) {
            throw [System.ArgumentOutOfRangeException]::new("Limit count must be greater than or equal to 0.")
        }
        $this.LimitValue = $count
        return $this
    }

    [PSLocalBase] skip([int]$offset) {
        if ($offset -lt 0) {
            throw [System.ArgumentOutOfRangeException]::new("Skip offset must be greater than or equal to 0.")
        }
        $this.SkipValue = $offset
        return $this
    }

    [object] get() {
        return $this.get(@{})
    }

    [object] get([hashtable]$options) {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .get().")
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            $this._ResetQueryState()
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                return $null
            }
            return @()
        }

        $withKeys = ($null -ne $options -and $options["keys"] -eq $true)

        try {
            # Case 1: Point lookup by key (.doc('key').get())
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                $sql = "SELECT key, doc FROM [$($this.CurrentCollection)] WHERE key = ?;"
                $rows = $this._ExecuteBoundQuery($sql, @($this.CurrentKey))
                if ($rows.Count -eq 0) {
                    return $null
                }
                $k = $rows[0][0]
                $json = $rows[0][1]
                $obj = ConvertFrom-Json -InputObject $json

                if ($withKeys) {
                    return [PSCustomObject]@{
                        key  = $k
                        data = $obj
                    }
                }
                return $obj
            }

            # Case 2: Collection retrieval with optional where, orderBy, limit, and skip
            $sqlBuilder = [System.Text.StringBuilder]::new()
            [void]$sqlBuilder.Append("SELECT key, doc FROM [$($this.CurrentCollection)]")

            if ($this.WhereClauses.Count -gt 0) {
                [void]$sqlBuilder.Append(" WHERE ")
                [void]$sqlBuilder.Append([string]::Join(" AND ", $this.WhereClauses))
            }

            if (-not [string]::IsNullOrEmpty($this.OrderByClause)) {
                [void]$sqlBuilder.Append(" ")
                [void]$sqlBuilder.Append($this.OrderByClause)
            }

            if ($null -ne $this.LimitValue -and $this.LimitValue -ge 0) {
                if ($null -ne $this.SkipValue -and $this.SkipValue -gt 0) {
                    [void]$sqlBuilder.Append(" LIMIT $($this.LimitValue) OFFSET $($this.SkipValue)")
                } else {
                    [void]$sqlBuilder.Append(" LIMIT $($this.LimitValue)")
                }
            } elseif ($null -ne $this.SkipValue -and $this.SkipValue -gt 0) {
                [void]$sqlBuilder.Append(" LIMIT -1 OFFSET $($this.SkipValue)")
            }

            $querySql = $sqlBuilder.ToString()
            $rows = $this._ExecuteBoundQuery($querySql, $this.WhereParameters.ToArray())

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($row in $rows) {
                $k = $row[0]
                $json = $row[1]
                $obj = ConvertFrom-Json -InputObject $json

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
        } finally {
            $this._ResetQueryState()
        }
    }

    [int] count() {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .count().")
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            $this._ResetQueryState()
            return 0
        }

        try {
            # Point lookup count by key
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                $sql = "SELECT COUNT(*) FROM [$($this.CurrentCollection)] WHERE key = ?;"
                $rows = $this._ExecuteBoundQuery($sql, @($this.CurrentKey))
                if ($rows.Count -gt 0 -and $rows[0].Count -gt 0) {
                    return [int]$rows[0][0]
                }
                return 0
            }

            # Multi-document count with optional where filters and limits
            $sqlBuilder = [System.Text.StringBuilder]::new()
            
            if (($null -ne $this.LimitValue -and $this.LimitValue -ge 0) -or ($null -ne $this.SkipValue -and $this.SkipValue -gt 0)) {
                # Subquery count when limit and/or skip are applied to source documents
                $limitClause = if ($null -ne $this.LimitValue -and $this.LimitValue -ge 0) { "LIMIT $($this.LimitValue)" } else { "LIMIT -1" }
                $offsetClause = if ($null -ne $this.SkipValue -and $this.SkipValue -gt 0) { "OFFSET $($this.SkipValue)" } else { "" }
                [void]$sqlBuilder.Append("SELECT COUNT(*) FROM (SELECT 1 FROM [$($this.CurrentCollection)]")
                if ($this.WhereClauses.Count -gt 0) {
                    [void]$sqlBuilder.Append(" WHERE ")
                    [void]$sqlBuilder.Append([string]::Join(" AND ", $this.WhereClauses))
                }
                [void]$sqlBuilder.Append(" $limitClause $offsetClause);")
            } else {
                [void]$sqlBuilder.Append("SELECT COUNT(*) FROM [$($this.CurrentCollection)]")
                if ($this.WhereClauses.Count -gt 0) {
                    [void]$sqlBuilder.Append(" WHERE ")
                    [void]$sqlBuilder.Append([string]::Join(" AND ", $this.WhereClauses))
                }
            }

            $querySql = $sqlBuilder.ToString()
            $rows = $this._ExecuteBoundQuery($querySql, $this.WhereParameters.ToArray())

            if ($rows.Count -gt 0 -and $rows[0].Count -gt 0) {
                return [int]$rows[0][0]
            }
            return 0
        } finally {
            $this._ResetQueryState()
        }
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

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $stmt = [IntPtr]::Zero
        try {
            $prepRc = [WinSqlite3]::Prepare($this.DbHandle, $sql, -1, [ref]$stmt, [IntPtr]::Zero)
            if ($prepRc -ne [WinSqlite3]::SQLITE_OK) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Failed to prepare query: $msg (Code: $prepRc, Query: $sql)")
            }

            # Validate parameter count against statement placeholders and bind with typed affinities
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $colCount = [WinSqlite3]::ColumnCount($stmt)
            $colNames = [string[]]::new($colCount)
            for ($c = 0; $c -lt $colCount; $c++) {
                $namePtr = [WinSqlite3]::ColumnName($stmt, $c)
                $colNames[$c] = [WinSqlite3]::GetString($namePtr)
            }

            $typeMethod = [WinSqlite3].GetMethod('ColumnType')

            while (($stepRc = [WinSqlite3]::Step($stmt)) -eq [WinSqlite3]::SQLITE_ROW) {
                $rowObj = [ordered]@{}
                for ($c = 0; $c -lt $colCount; $c++) {
                    $colName = $colNames[$c]
                    $val = $null

                    if ($null -ne $typeMethod) {
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
                            5 { $val = $null }
                            default {
                                $colPtr = [WinSqlite3]::ColumnText($stmt, $c)
                                $val = [WinSqlite3]::GetString($colPtr)
                            }
                        }
                    } else {
                        $colPtr = [WinSqlite3]::ColumnText($stmt, $c)
                        $val = [WinSqlite3]::GetString($colPtr)
                    }

                    $rowObj[$colName] = $val
                }
                $results.Add([PSCustomObject]$rowObj)
            }

            if ($stepRc -ne [WinSqlite3]::SQLITE_DONE) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Query execution interrupted: $msg (Code: $stepRc, Query: $sql)")
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
        if ($this._CollectionExists($this.CurrentCollection)) {
            $sql = "DROP TABLE IF EXISTS [$($this.CurrentCollection)];"
            $this._ExecuteDirectSql($sql)
        }
        $this.CurrentCollection = ""
        $this._ResetQueryState()
    }

    [void] delete() {
        $this._EnsureOpen()
        if ([string]::IsNullOrEmpty($this.CurrentCollection)) {
            throw [System.InvalidOperationException]::new("No collection specified. Call .collection('name') before .delete().")
        }

        if ($null -ne $this.LimitValue -or $null -ne $this.SkipValue) {
            throw [System.InvalidOperationException]::new("delete() does not support limit() or skip(). Use point document deletion (.doc('key').delete()) or filter deletion (.where(...).delete()).")
        }

        if (-not $this._CollectionExists($this.CurrentCollection)) {
            $this._ResetQueryState()
            return
        }

        try {
            if (-not [string]::IsNullOrEmpty($this.CurrentKey)) {
                # Delete single document
                $sql = "DELETE FROM [$($this.CurrentCollection)] WHERE key = ?;"
                $this._ExecuteBoundSql($sql, @($this.CurrentKey))
            } elseif ($this.WhereClauses.Count -gt 0) {
                # Delete filtered documents
                $whereStr = [string]::Join(" AND ", $this.WhereClauses)
                $sql = "DELETE FROM [$($this.CurrentCollection)] WHERE $whereStr;"
                $this._ExecuteBoundSql($sql, $this.WhereParameters.ToArray())
            } else {
                # Drop entire collection table
                $sql = "DROP TABLE IF EXISTS [$($this.CurrentCollection)];"
                $this._ExecuteDirectSql($sql)
                $this.CurrentCollection = ""
            }
        } finally {
            $this._ResetQueryState()
        }
    }

    [void] deleteDatabase() {
        $this._EnsureOpen()
        if ($this.IsChildInstance) {
            throw [System.InvalidOperationException]::new("deleteDatabase() cannot be executed from a collection instance. Call it on the root PSLocalBase instance.")
        }
        $path = $this.FilePath
        $this.close()

        if (-not [string]::IsNullOrEmpty($path) -and $path -ne ":memory:") {
            $deletionErrors = [System.Collections.Generic.List[string]]::new()
            foreach ($targetPath in @($path, "$path-wal", "$path-shm")) {
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
        $method = [WinSqlite3].GetMethod('GetAutocommit')
        if ($null -ne $method) {
            return ([WinSqlite3]::GetAutocommit($this.DbHandle) -eq 0)
        }
        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        return $root.InTransaction
    }

    [void] beginTransaction() {
        $this._EnsureOpen()
        $this._ExecuteDirectSql("BEGIN TRANSACTION;")
        $this.InTransaction = $true
        if ($this.ParentDb) { $this.ParentDb.InTransaction = $true }
    }

    [void] commit() {
        $this._EnsureOpen()
        try {
            $this._ExecuteDirectSql("COMMIT;")
        } finally {
            $this.InTransaction = $false
            if ($this.ParentDb) { $this.ParentDb.InTransaction = $false }
        }
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
            if ($this.DbHandle -ne [IntPtr]::Zero) {
                $rc = [WinSqlite3]::Close($this.DbHandle)
                if ($rc -eq [WinSqlite3]::SQLITE_BUSY) {
                    [void][WinSqlite3]::CloseV2($this.DbHandle)
                }
                $this.DbHandle = [IntPtr]::Zero
            }
        } else {
            $this.DbHandle = [IntPtr]::Zero
        }
        $this.InTransaction = $false
    }

    [void] Dispose() {
        $this.close()
    }

    # -----------------------------------------------------------------------
    # Internal Engine Helpers
    # -----------------------------------------------------------------------
    [void] _EnsureOpen() {
        if ($this.IsChildInstance -and ($null -eq $this.ParentDb -or $this.ParentDb.DbHandle -eq [IntPtr]::Zero)) {
            $this.DbHandle = [IntPtr]::Zero
        }
        if ($this.DbHandle -eq [IntPtr]::Zero) {
            throw [System.InvalidOperationException]::new("Database connection is closed.")
        }
    }

    [void] _BindStatementParameters([IntPtr]$stmt, [object[]]$parameters, [string]$sql) {
        $expectedCount = 0
        $bindCountMethod = [WinSqlite3].GetMethod('BindParameterCount')
        if ($null -ne $bindCountMethod) {
            $expectedCount = [WinSqlite3]::BindParameterCount($stmt)
        }
        $actualCount = if ($null -ne $parameters) { $parameters.Count } else { 0 }
        if ($expectedCount -ne $actualCount) {
            throw [System.InvalidOperationException]::new("Parameter count mismatch: query expects $expectedCount parameters, but $actualCount were provided.")
        }

        if ($null -ne $parameters -and $parameters.Count -gt 0) {
            for ($i = 0; $i -lt $parameters.Count; $i++) {
                $paramIdx = $i + 1
                $val = $parameters[$i]
                $bindRc = [WinSqlite3]::SQLITE_OK

                if ($null -eq $val) {
                    $bindRc = [WinSqlite3]::BindNull($stmt, $paramIdx)
                } elseif ($val -is [byte] -or $val -is [sbyte] -or $val -is [int16] -or $val -is [uint16] -or $val -is [int32] -or $val -is [uint32] -or $val -is [int64]) {
                    $bindRc = [WinSqlite3]::BindInt64($stmt, $paramIdx, [long]$val)
                } elseif ($val -is [single] -or $val -is [double] -or $val -is [decimal]) {
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
                    throw [System.InvalidOperationException]::new("Failed to bind parameter at index ${paramIdx}: $msg (Code: $bindRc, Query: $sql)")
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
                throw [System.InvalidOperationException]::new("SQLite execution error: $msg (Code: $rc, Query: $sql)")
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
            throw [System.InvalidOperationException]::new("Failed to prepare statement: $msg (Code: $prepRc, Query: $sql)")
        }

        try {
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $stepRc = [WinSqlite3]::Step($stmt)
            if ($stepRc -ne [WinSqlite3]::SQLITE_DONE -and $stepRc -ne [WinSqlite3]::SQLITE_ROW) {
                $msg = [WinSqlite3]::GetErrorMessage($this.DbHandle)
                throw [System.InvalidOperationException]::new("Failed to execute statement: $msg (Code: $stepRc, Query: $sql)")
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
            throw [System.InvalidOperationException]::new("Failed to prepare query: $msg (Code: $prepRc, Query: $sql)")
        }

        try {
            $this._BindStatementParameters($stmt, $parameters, $sql)

            $colCount = [WinSqlite3]::ColumnCount($stmt)
            while (($stepRc = [WinSqlite3]::Step($stmt)) -eq [WinSqlite3]::SQLITE_ROW) {
                $row = [string[]]::new($colCount)
                for ($c = 0; $c -lt $colCount; $c++) {
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
# 4b. Dynamic Method Fallbacks (Ensures hot-reload parity in warm sessions)
# ---------------------------------------------------------------------------
try {
    Update-TypeData -TypeName PSLocalBase -MemberType ScriptProperty -MemberName InTransaction -Value {
        if ($this.IsChildInstance -and ($null -eq $this.ParentDb -or $this.ParentDb.DbHandle -eq [IntPtr]::Zero)) {
            $this.DbHandle = [IntPtr]::Zero
        }
        if ($this.DbHandle -eq [IntPtr]::Zero) { return $false }
        $m = [WinSqlite3].GetMethod('GetAutocommit')
        if ($null -ne $m) {
            return ([WinSqlite3]::GetAutocommit($this.DbHandle) -eq 0)
        }
        $root = if ($this.ParentDb) { $this.ParentDb } else { $this }
        return $root.InTransaction
    } -SecondValue {
        param($val)
    } -Force
    if ($null -eq ([PSLocalBase].GetMethod('drop'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName drop -Value {
            $this._EnsureOpen()
            if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
                throw [System.InvalidOperationException]::new("No collection specified to drop.")
            }
            $this._ExecuteDirectSql("DROP TABLE IF EXISTS [$($this.CurrentCollection)];")
            $this.CurrentCollection = ""
            $this._ResetQueryState()
        } -Force
    }

    if ($null -eq ([PSLocalBase].GetMethod('_CollectionExists'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName _CollectionExists -Value {
            param([string]$name)
            $this._EnsureOpen()
            if ([string]::IsNullOrWhiteSpace($name)) { return $false }
            $rows = $this._ExecuteBoundQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? COLLATE NOCASE LIMIT 1;", @($name))
            return ($rows.Count -gt 0)
        } -Force
    }

    if ($null -eq ([PSLocalBase].GetMethod('_EnsureCollectionTable'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName _EnsureCollectionTable -Value {
            $this._EnsureOpen()
            if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
                throw [System.InvalidOperationException]::new("No collection specified.")
            }
            $createSql = "CREATE TABLE IF NOT EXISTS [$($this.CurrentCollection)] (key TEXT PRIMARY KEY, doc TEXT);"
            $this._ExecuteDirectSql($createSql)
        } -Force
    }

    if ($null -eq ([PSLocalBase].GetMethod('create'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName create -Value {
            $this._EnsureOpen()
            if ([string]::IsNullOrWhiteSpace($this.CurrentCollection)) {
                throw [System.InvalidOperationException]::new("No collection specified to create. Call .collection('name').create()")
            }
            $createSql = "CREATE TABLE IF NOT EXISTS [$($this.CurrentCollection)] (key TEXT PRIMARY KEY, doc TEXT);"
            $this._ExecuteDirectSql($createSql)
            return $this
        } -Force
    }

    if ($null -eq ([PSLocalBase].GetMethod('createCollection'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName createCollection -Value {
            param([string]$name)
            return $this.collection($name).create()
        } -Force
    }

    if ($null -eq ([PSLocalBase].GetMethod('collectionExists'))) {
        Update-TypeData -TypeName PSLocalBase -MemberType ScriptMethod -MemberName collectionExists -Value {
            param([string]$name)
            $this._EnsureOpen()
            if ([string]::IsNullOrWhiteSpace($name)) { return $false }
            $rows = $this._ExecuteBoundQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? COLLATE NOCASE LIMIT 1;", @($name))
            return ($rows.Count -gt 0)
        } -Force
    }
} catch { }

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