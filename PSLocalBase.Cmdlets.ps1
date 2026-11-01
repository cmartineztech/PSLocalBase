<#
.SYNOPSIS
    PSLocalBase.Cmdlets.ps1 - Native PowerShell Cmdlet & Pipeline Adapter for PSLocalBase.

.DESCRIPTION
    Provides an idiomatic PowerShell cmdlet interface (Verb-Noun, pipeline streaming,
    -WhatIf, -Confirm, tab completion) built as a pure, zero-overhead adapter on top
    of the PSLocalBase fluent engine.

    Preserves 100% interoperability with the primary fluent API ($db.collection().get()).
#>

# ---------------------------------------------------------------------------
# Module Execution Context & Session Management
# ---------------------------------------------------------------------------
$script:CurrentLocalBaseConnection = $null

function Get-LocalBaseExecutionContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Database
    )

    if ($Database) {
        return $Database
    }

    if ($script:CurrentLocalBaseConnection -and $script:CurrentLocalBaseConnection.DbHandle -ne [System.IntPtr]::Zero) {
        return $script:CurrentLocalBaseConnection
    }

    throw [System.InvalidOperationException]::new(
        "No active PSLocalBase database connection found. Use 'Connect-LocalBase -Path <path>' to connect, or pass -Database explicitly."
    )
}

# ---------------------------------------------------------------------------
# 1. Connection & Database Management Cmdlets
# ---------------------------------------------------------------------------

function Connect-LocalBase {
    <#
    .SYNOPSIS
        Connects to a PSLocalBase SQLite database and sets it as the active session connection.
    .DESCRIPTION
        Opens an existing SQLite database file or automatically creates and provisions
        a new database file on demand if it does not yet exist. Sets the connection
        as the ambient session default for all downstream pipeline cmdlets.
    .EXAMPLE
        Connect-LocalBase -Path "./data.db"
    .EXAMPLE
        Connect-LocalBase -Path ":memory:"
    #>
    [CmdletBinding()]
    [Alias('Open-LocalBase')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter()]
        [int]$BusyTimeoutMs = 5000,

        [Parameter()]
        [ValidateSet('WAL', 'DELETE', 'TRUNCATE', 'PERSIST', 'MEMORY', 'OFF')]
        [string]$JournalMode = 'WAL',

        [Parameter()]
        [ValidateSet('NORMAL', 'FULL', 'OFF', 'EXTRA')]
        [string]$Synchronous = 'NORMAL',

        [Parameter()]
        [switch]$PassThru
    )

    $opts = @{
        busyTimeout = $BusyTimeoutMs
        wal         = ($JournalMode -eq 'WAL')
        synchronous = $Synchronous
    }

    if ($script:CurrentLocalBaseConnection) {
        Disconnect-LocalBase
    }

    $db = New-LocalBase -Path $Path -Options $opts
    $script:CurrentLocalBaseConnection = $db

    if ($PassThru) {
        return $db
    }
}

function Disconnect-LocalBase {
    <#
    .SYNOPSIS
        Closes the active PSLocalBase connection and releases all file locks.
    .EXAMPLE
        Disconnect-LocalBase
    #>
    [CmdletBinding()]
    [Alias('Close-LocalBase')]
    param(
        [Parameter()]
        $Database
    )

    $targetDb = if ($Database) { $Database } else { $script:CurrentLocalBaseConnection }
    if ($targetDb) {
        $targetDb.close()
        if ($targetDb -eq $script:CurrentLocalBaseConnection) {
            $script:CurrentLocalBaseConnection = $null
        }
    }
}

function Get-LocalBaseConnection {
    <#
    .SYNOPSIS
        Gets the active PSLocalBase connection for the current session.
    #>
    [CmdletBinding()]
    param()

    return $script:CurrentLocalBaseConnection
}

function Backup-LocalBaseDatabase {
    <#
    .SYNOPSIS
        Performs a live, consistent online backup using SQLite VACUUM INTO.
    .EXAMPLE
        Backup-LocalBaseDatabase -DestinationPath "./backup.db"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$DestinationPath,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $cleanPath = $DestinationPath -replace "'", "''"
    $null = $ctx.query("VACUUM INTO '$cleanPath';")
}

function Remove-LocalBaseDatabase {
    <#
    .SYNOPSIS
        Deletes a PSLocalBase database file and its associated journal files (.db-wal, .db-shm).
    .EXAMPLE
        Remove-LocalBaseDatabase -Path "./old.db" -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter()]
        [switch]$Force
    )

    if ($PSCmdlet.ShouldProcess($Path, "Delete database file and SQLite journals")) {
        $resolved = $Path
        try {
            $resolved = [System.IO.Path]::GetFullPath($Path)
        } catch { }

        $connPath = if ($script:CurrentLocalBaseConnection) { $script:CurrentLocalBaseConnection.FilePath } else { $null }
        if ($connPath) {
            try { $connPath = [System.IO.Path]::GetFullPath($connPath) } catch { }
            if ($connPath -eq $resolved) {
                Disconnect-LocalBase
            }
        }

        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        foreach ($target in @($Path, "$Path-wal", "$Path-shm", "$Path-journal")) {
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Collection & Index Lifecycle Cmdlets
# ---------------------------------------------------------------------------

function Get-LocalBaseCollection {
    <#
    .SYNOPSIS
        Lists all collections present in the active database.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    return $ctx.getCollections()
}

function New-LocalBaseCollection {
    <#
    .SYNOPSIS
        Explicitly provisions a collection table in the database schema.
    .EXAMPLE
        New-LocalBaseCollection -Name "customers"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.createCollection($Name)
}

function Remove-LocalBaseCollection {
    <#
    .SYNOPSIS
        Drops a collection table and all associated indexes from the database.
    .EXAMPLE
        Remove-LocalBaseCollection -Collection "temp_data" -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter()]
        $Database
    )

    if ($PSCmdlet.ShouldProcess($Collection, "Drop collection table and associated index metadata")) {
        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $null = $ctx.collection($Collection).drop()
    }
}

function Clear-LocalBaseCollection {
    <#
    .SYNOPSIS
        Truncates/empties all documents in a collection while preserving its schema table and indexes.
    .EXAMPLE
        Clear-LocalBaseCollection -Collection "logs" -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter()]
        $Database
    )

    if ($PSCmdlet.ShouldProcess($Collection, "Delete all documents in collection")) {
        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $null = $ctx.collection($Collection).delete()
    }
}

function New-LocalBaseIndex {
    <#
    .SYNOPSIS
        Creates a secondary or unique expression index on a document field.
    .EXAMPLE
        New-LocalBaseIndex -Collection "users" -Field "email" -Unique
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Field,

        [Parameter()]
        [switch]$Unique,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.collection($Collection).createIndex($Field, [bool]$Unique)
}

function Remove-LocalBaseIndex {
    <#
    .SYNOPSIS
        Drops a secondary index on a collection field.
    .EXAMPLE
        Remove-LocalBaseIndex -Collection "users" -Field "email"
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Field,

        [Parameter()]
        $Database
    )

    if ($PSCmdlet.ShouldProcess("$Collection/$Field", "Drop secondary index")) {
        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $null = $ctx.collection($Collection).dropIndex($Field)
    }
}

# ---------------------------------------------------------------------------
# 3. Document CRUD & Pipeline Cmdlets
# ---------------------------------------------------------------------------

function Get-LocalBaseDocument {
    <#
    .SYNOPSIS
        Queries and retrieves documents from a collection with pipeline streaming.
    .EXAMPLE
        Get-LocalBaseDocument -Collection "users" -Id "usr_100"
    .EXAMPLE
        Get-LocalBaseDocument -Collection "users" -Filter @{ role = 'Admin' } -OrderBy 'age' -Descending -First 10
    .EXAMPLE
        Get-LocalBaseDocument -Collection "items" -Field "price" -Operator ">=" -Value 50
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    [Alias('gld')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter(Mandatory = $true, ParameterSetName = 'ById', Position = 1)]
        [string]$Id,

        [Parameter(ParameterSetName = 'Query')]
        [hashtable]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Field,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Operator = '==',

        [Parameter(ParameterSetName = 'Query')]
        [object]$Value,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Exists,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Missing,

        [Parameter(ParameterSetName = 'Query')]
        [string]$OrderBy,

        [Parameter(ParameterSetName = 'Query')]
        [switch]$Descending,

        [Parameter(ParameterSetName = 'Query')]
        [int]$First,

        [Parameter(ParameterSetName = 'Query')]
        [int]$Skip,

        [Parameter()]
        [string[]]$Select,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Distinct,

        [Parameter(ParameterSetName = 'Query')]
        [switch]$Count,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $col = $ctx.collection($Collection)

    # Point Lookup by Id
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $q = $col.doc($Id)
        if ($Select) {
            $q = $q.select($Select)
        }
        $doc = $q.get()
        if ($null -ne $doc) {
            Add-Member -InputObject $doc -NotePropertyName '_localbase_collection' -NotePropertyValue $Collection -Force
            Add-Member -InputObject $doc -NotePropertyName '_localbase_key' -NotePropertyValue $Id -Force
            if (-not $doc.PSObject.Properties['id']) {
                Add-Member -InputObject $doc -NotePropertyName 'id' -NotePropertyValue $Id -Force
            }
            return $doc
        }
        return $null
    }

    $q = $col

    # Apply Filter hashtable
    if ($Filter) {
        foreach ($k in $Filter.Keys) {
            $q = $q.where($k, '==', $Filter[$k])
        }
    }

    # Apply explicit field filter
    if ($Field) {
        $q = $q.where($Field, $Operator, $Value)
    }

    # Apply Exists / Missing
    if ($Exists) {
        $q = $q.whereExists($Exists)
    }
    if ($Missing) {
        $q = $q.whereMissing($Missing)
    }

    # Apply OrderBy
    if ($OrderBy) {
        $dir = if ($Descending) { 'desc' } else { 'asc' }
        $q = $q.orderBy($OrderBy, $dir)
    }

    # Apply Skip & First
    if ($PSBoundParameters.ContainsKey('Skip')) {
        $q = $q.skip($Skip)
    }
    if ($PSBoundParameters.ContainsKey('First')) {
        $q = $q.limit($First)
    }

    # Return Count directly if requested
    if ($Count) {
        return $q.count()
    }

    # Return Distinct values if requested
    if ($Distinct) {
        return $q.distinct($Distinct)
    }

    # Apply Select projection
    if ($Select) {
        $q = $q.select($Select)
    }

    $results = $q.get(@{ keys = $true })
    if ($null -eq $results) { return }

    # Stream results through the pipeline
    foreach ($entry in $results) {
        if ($null -ne $entry) {
            $item = $entry.data
            if ($null -eq $item) { $item = [PSCustomObject]@{} }

            Add-Member -InputObject $item -NotePropertyName '_localbase_collection' -NotePropertyValue $Collection -Force
            Add-Member -InputObject $item -NotePropertyName '_localbase_key' -NotePropertyValue $entry.key -Force
            if (-not $item.PSObject.Properties['id']) {
                Add-Member -InputObject $item -NotePropertyName 'id' -NotePropertyValue $entry.key -Force
            }
            Write-Output $item
        }
    }
}

function Add-LocalBaseDocument {
    <#
    .SYNOPSIS
        Inserts one or more documents into a collection. Supports pipeline streaming.
    .EXAMPLE
        Add-LocalBaseDocument -Collection "users" -Data @{ name = 'Carlos'; role = 'Admin' }
    .EXAMPLE
        Get-Process | Add-LocalBaseDocument -Collection "processes"
    #>
    [CmdletBinding()]
    [Alias('ald')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Collection,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 1)]
        [object]$Data,

        [Parameter(Position = 2)]
        [string]$Id,

        [Parameter()]
        $Database
    )

    process {
        if ($null -eq $Data) { return }

        $cleanData = $Data
        if ($Data -is [System.Management.Automation.PSCustomObject]) {
            $cleanData = $Data.PSObject.Copy()
            if ($cleanData.PSObject.Properties['_localbase_collection']) {
                $cleanData.PSObject.Properties.Remove('_localbase_collection')
            }
            if ($cleanData.PSObject.Properties['_localbase_key']) {
                $cleanData.PSObject.Properties.Remove('_localbase_key')
            }
        }

        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $col = $ctx.collection($Collection)

        if ($Id) {
            $col.doc($Id).set($cleanData)
            return $Id
        } else {
            return $col.add($cleanData)
        }
    }
}

function Set-LocalBaseDocument {
    <#
    .SYNOPSIS
        Sets/replaces a document with a specific key, or upserts if it does not exist.
    .EXAMPLE
        Set-LocalBaseDocument -Collection "users" -Id "usr_1" -Data @{ name = 'Carlos'; active = $true }
    .EXAMPLE
        $user.status = 'Inactive'
        $user | Set-LocalBaseDocument
    #>
    [CmdletBinding()]
    [Alias('sld')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Collection,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 2)]
        [object]$Data,

        [Parameter()]
        $Database
    )

    process {
        if ($null -eq $Data) { return }

        $targetCollection = $Collection
        $targetId = $Id

        if (-not $targetCollection) {
            if ($Data.PSObject.Properties['Collection']) { $targetCollection = $Data.Collection }
            elseif ($Data.PSObject.Properties['collection']) { $targetCollection = $Data.collection }
            elseif ($Data.PSObject.Properties['_localbase_collection']) { $targetCollection = $Data._localbase_collection }
        }

        if (-not $targetId) {
            if ($Data.PSObject.Properties['id']) { $targetId = $Data.id }
            elseif ($Data.PSObject.Properties['_localbase_key']) { $targetId = $Data._localbase_key }
            elseif ($Data.PSObject.Properties['_key']) { $targetId = $Data._key }
            elseif ($Data.PSObject.Properties['key']) { $targetId = $Data.key }
        }

        if (-not $targetCollection) {
            throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
        }
        if (-not $targetId) {
            throw [System.ArgumentException]::new("Document Id must be specified via -Id or pipeline object.")
        }

        # Strip internal decoration metadata if piped from Get-LocalBaseDocument
        $cleanData = $Data
        if ($Data -is [System.Management.Automation.PSCustomObject]) {
            $cleanData = $Data.PSObject.Copy()
            if ($cleanData.PSObject.Properties['_localbase_collection']) {
                $cleanData.PSObject.Properties.Remove('_localbase_collection')
            }
            if ($cleanData.PSObject.Properties['_localbase_key']) {
                $cleanData.PSObject.Properties.Remove('_localbase_key')
            }
        }

        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $col = $ctx.collection($targetCollection)
        $null = $col.doc($targetId).set($cleanData)
    }
}

function Update-LocalBaseDocument {
    <#
    .SYNOPSIS
        Updates documents with partial recursive JSON merge. Supports pipeline forwarding.
    .EXAMPLE
        Update-LocalBaseDocument -Collection "users" -Id "usr_1" -Data @{ active = $true }
    .EXAMPLE
        Get-LocalBaseDocument -Collection "users" -Filter @{ role = 'Guest' } |
            Update-LocalBaseDocument -Data @{ expired = $true }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Alias('uld')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Collection,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [object]$Data,

        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,

        [Parameter()]
        $Database
    )

    process {
        $targetCollection = $Collection
        $targetId = $Id

        if ($InputObject) {
            if (-not $targetCollection) {
                if ($InputObject.PSObject.Properties['Collection']) { $targetCollection = $InputObject.Collection }
                elseif ($InputObject.PSObject.Properties['collection']) { $targetCollection = $InputObject.collection }
                elseif ($InputObject.PSObject.Properties['_localbase_collection']) { $targetCollection = $InputObject._localbase_collection }
            }
            if (-not $targetId) {
                if ($InputObject.PSObject.Properties['_localbase_key']) { $targetId = $InputObject._localbase_key }
                elseif ($InputObject.PSObject.Properties['id']) { $targetId = $InputObject.id }
                elseif ($InputObject.PSObject.Properties['_key']) { $targetId = $InputObject._key }
                elseif ($InputObject.PSObject.Properties['key']) { $targetId = $InputObject.key }
            }
        }

        if (-not $targetCollection) {
            throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
        }
        if (-not $targetId) {
            throw [System.ArgumentException]::new("Document Id must be specified via -Id or pipeline object.")
        }

        if ($PSCmdlet.ShouldProcess("$targetCollection/$targetId", "Update document fields")) {
            $ctx = Get-LocalBaseExecutionContext -Database $Database
            $null = $ctx.collection($targetCollection).doc($targetId).update($Data)
        }
    }
}

function Remove-LocalBaseDocument {
    <#
    .SYNOPSIS
        Deletes documents by ID, pipeline, or filter with -WhatIf and -Confirm safety.
    .EXAMPLE
        Remove-LocalBaseDocument -Collection "users" -Id "usr_1" -Confirm:$false
    .EXAMPLE
        Get-LocalBaseDocument -Collection "logs" -Filter @{ level = 'Debug' } |
            Remove-LocalBaseDocument -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [Alias('rld')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Collection,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Id,

        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,

        [Parameter()]
        [hashtable]$Filter,

        [Parameter()]
        $Database
    )

    process {
        $targetCollection = $Collection
        $targetId = $Id

        if ($InputObject) {
            if (-not $targetCollection) {
                if ($InputObject.PSObject.Properties['Collection']) { $targetCollection = $InputObject.Collection }
                elseif ($InputObject.PSObject.Properties['collection']) { $targetCollection = $InputObject.collection }
                elseif ($InputObject.PSObject.Properties['_localbase_collection']) { $targetCollection = $InputObject._localbase_collection }
            }
            if (-not $targetId) {
                if ($InputObject.PSObject.Properties['_localbase_key']) { $targetId = $InputObject._localbase_key }
                elseif ($InputObject.PSObject.Properties['id']) { $targetId = $InputObject.id }
                elseif ($InputObject.PSObject.Properties['_key']) { $targetId = $InputObject._key }
                elseif ($InputObject.PSObject.Properties['key']) { $targetId = $InputObject.key }
            }
        }

        $ctx = Get-LocalBaseExecutionContext -Database $Database

        if ($targetId) {
            if (-not $targetCollection) {
                throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
            }
            if ($PSCmdlet.ShouldProcess("$targetCollection/$targetId", "Delete document")) {
                $null = $ctx.collection($targetCollection).doc($targetId).delete()
            }
        }
        elseif ($Filter -and $targetCollection) {
            $col = $ctx.collection($targetCollection)
            $q = $col
            foreach ($k in $Filter.Keys) {
                $q = $q.where($k, '==', $Filter[$k])
            }
            if ($PSCmdlet.ShouldProcess("$targetCollection (filtered by $(($Filter.Keys -join ', ')))", "Delete matching documents")) {
                $null = $q.delete()
            }
        }
        else {
            throw [System.ArgumentException]::new("Specify either -Id (or pipeline object) or -Filter to delete documents.")
        }
    }
}

function Measure-LocalBaseDocument {
    <#
    .SYNOPSIS
        Calculates mathematical aggregations (Sum, Average, Min, Max, Count) on a numeric field.
    .EXAMPLE
        Measure-LocalBaseDocument -Collection "sales" -Field "amount" -Sum -Average
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Collection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Field,

        [Parameter()]
        [hashtable]$Filter,

        [Parameter()]
        [switch]$Sum,

        [Parameter()]
        [switch]$Average,

        [Parameter()]
        [switch]$Minimum,

        [Parameter()]
        [switch]$Maximum,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $q = $ctx.collection($Collection)

    if ($Filter) {
        foreach ($k in $Filter.Keys) {
            $q = $q.where($k, '==', $Filter[$k])
        }
    }

    $out = [ordered]@{
        Collection = $Collection
        Field      = $Field
        Count      = $q.count()
    }

    if ($Sum) { $out['Sum'] = $q.sum($Field) }
    if ($Average) { $out['Average'] = $q.avg($Field) }
    if ($Minimum) { $out['Minimum'] = $q.min($Field) }
    if ($Maximum) { $out['Maximum'] = $q.max($Field) }

    return [PSCustomObject]$out
}

# ---------------------------------------------------------------------------
# 4. Transaction Cmdlets
# ---------------------------------------------------------------------------

function Invoke-LocalBaseTransaction {
    <#
    .SYNOPSIS
        Executes a scriptblock inside an atomic SQLite transaction (BEGIN IMMEDIATE / COMMIT / ROLLBACK).
    .EXAMPLE
        Invoke-LocalBaseTransaction {
            Add-LocalBaseDocument -Collection "accounts" -Data @{ id = 1; balance = 90 }
            Add-LocalBaseDocument -Collection "accounts" -Data @{ id = 2; balance = 110 }
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.beginTransaction()
    try {
        $result = & $ScriptBlock
        $null = $ctx.commit()
        return $result
    }
    catch {
        try { $null = $ctx.rollback() } catch { }
        throw
    }
}

function Start-LocalBaseTransaction {
    <#
    .SYNOPSIS
        Manually starts an atomic transaction on the database.
    #>
    [CmdletBinding()]
    param([Parameter()]$Database)

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.beginTransaction()
}

function Complete-LocalBaseTransaction {
    <#
    .SYNOPSIS
        Commits all pending changes in the current transaction.
    #>
    [CmdletBinding()]
    param([Parameter()]$Database)

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.commit()
}

function Undo-LocalBaseTransaction {
    <#
    .SYNOPSIS
        Rolls back all pending changes in the current transaction.
    #>
    [CmdletBinding()]
    param([Parameter()]$Database)

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    $null = $ctx.rollback()
}
