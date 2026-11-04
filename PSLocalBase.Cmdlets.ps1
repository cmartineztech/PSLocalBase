<#
.SYNOPSIS
    PSLocalBase.Cmdlets.ps1 - Native PowerShell Cmdlet & Pipeline Adapter for PSLocalBase.

.DESCRIPTION
    Provides an idiomatic PowerShell cmdlet interface (Verb-Noun, pipeline integration,
    -WhatIf, -Confirm, tab completion) built as a PowerShell adapter on top
    of the PSLocalBase fluent engine.

    Preserves 100% interoperability with the primary fluent API ($db.collection().get()).
#>

# ---------------------------------------------------------------------------
# Module Execution Context & Session Management
# ---------------------------------------------------------------------------
$script:CurrentLocalBaseConnection = $null
# Identity is separate from payload properties, including colliding metadata names.
$script:LocalBaseIdentity = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Register-LocalBaseDocumentIdentity {
    param($Document, [string]$Collection, [string]$Id, [bool]$Wrapped = $false)
    $original = @{}
    foreach ($name in @('_localbase_collection', '_localbase_key')) {
        if ($Document.PSObject.Properties[$name]) { $original[$name] = $Document.$name }
    }
    $syntheticId = -not $Document.PSObject.Properties['id']
    $script:LocalBaseIdentity.Add($Document, @{ Collection = $Collection; Id = $Id; Original = $original; SyntheticId = $syntheticId; Wrapped = $Wrapped })
    Add-Member -InputObject $Document -NotePropertyName '_localbase_collection' -NotePropertyValue $Collection -Force
    Add-Member -InputObject $Document -NotePropertyName '_localbase_key' -NotePropertyValue $Id -Force
    if ($syntheticId) { Add-Member -InputObject $Document -NotePropertyName 'id' -NotePropertyValue $Id }
}

function Resolve-LocalBaseDocumentIdentity {
    param($Document, [string]$Collection, [string]$Id)
    $identity = $null
    if ($null -ne $Document) { $null = $script:LocalBaseIdentity.TryGetValue($Document, [ref]$identity) }
    if (-not $Collection) {
        if ($identity) { $Collection = $identity.Collection }
        elseif ($Document.Collection) { $Collection = $Document.Collection }
        elseif ($Document._localbase_collection) { $Collection = $Document._localbase_collection }
    }
    if (-not $Id) {
        if ($identity) { $Id = $identity.Id }
        else {
            foreach ($name in @('id', '_key', 'key', '_localbase_key')) {
                if ($Document.$name) { $Id = $Document.$name; break }
            }
        }
    }
    return @{ Collection = $Collection; Id = $Id }
}

function ConvertTo-LocalBasePayload {
    param($Document)
    $identity = $null
    if ($null -ne $Document -and $script:LocalBaseIdentity.TryGetValue($Document, [ref]$identity)) {
        if ($identity.Wrapped) { return ,$Document.Value }
        $clean = $Document.PSObject.Copy()
        foreach ($name in @('_localbase_collection', '_localbase_key')) {
            $clean.PSObject.Properties.Remove($name)
            if ($identity.Original.ContainsKey($name)) {
                Add-Member -InputObject $clean -NotePropertyName $name -NotePropertyValue $identity.Original[$name]
            }
        }
        if ($identity.SyntheticId) { $clean.PSObject.Properties.Remove('id') }
        return ,$clean
    }
    return ,$Document
}

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
        [ValidateRange(0, 2147483647)]
        [int]$BusyTimeoutMs = 5000,

        [Parameter()]
        [ValidateSet('WAL', 'DELETE')]
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

    # Opening/validating may throw. Keep the original ambient connection and transaction intact.
    $db = New-LocalBase -Path $Path -Options $opts
    try {
        if ($script:CurrentLocalBaseConnection) { $script:CurrentLocalBaseConnection.close() }
    } catch {
        $db.close()
        throw
    }
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
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    $cleanPath = $resolvedPath -replace "'", "''"
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

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($PSCmdlet.ShouldProcess($resolved, "Delete database file and SQLite journals")) {
        $targets = @($resolved, "$resolved-wal", "$resolved-shm", "$resolved-journal")
        $locks = [System.Collections.Generic.List[System.IDisposable]]::new()
        try {
            # Check every file before removing any. Active SQLite handles prevent
            # exclusive access, including connections outside the ambient context.
            foreach ($target in $targets) {
                if (Test-Path -LiteralPath $target -ErrorAction Stop) {
                    $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
                    if ($item.PSIsContainer) { throw "Database path is a directory: '$target'." }
                    if ($item.IsReadOnly -and -not $Force) { throw "Database file '$target' is read-only. Use -Force to remove it." }
                    $locks.Add([System.IO.File]::Open($target, 'Open', 'Read', 'None'))
                }
            }
        } catch {
            throw [System.IO.IOException]::new("Cannot remove database '$resolved'. Close all connections and check file permissions. $($_.Exception.Message)", $_.Exception)
        } finally {
            foreach ($fileLock in $locks) { $fileLock.Dispose() }
        }
        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target -ErrorAction Stop) {
                Remove-Item -LiteralPath $target -Force:$Force -ErrorAction Stop
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter()]
        $Database
    )

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    if ($PSCmdlet.ShouldProcess($Name, "Create collection")) { $null = $ctx.createCollection($Name) }
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
    [CmdletBinding(SupportsShouldProcess = $true)]
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
    if ($PSCmdlet.ShouldProcess("$Collection/$Field", "Create index")) { $null = $ctx.collection($Collection).createIndex($Field, [bool]$Unique) }
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
        Materializes selected documents, then emits each document to the pipeline.
        Use -First/-Skip to bound reads; downstream Select-Object -First does not reduce database reading.
    .DESCRIPTION
        JSON objects expose their payload properties. Top-level arrays, scalars and null
        expose the payload in Value. Set/Add unwrap these trusted envelopes; Remove uses
        their private identity. Missing point reads emit no item. Distinct rejects paging
        and ordering modifiers. Unsupported numeric comparisons throw instead of rounding.
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
        $entry = $q.get(@{ keys = $true })
        if ($null -ne $entry) {
            $doc = $entry.data
            $wrapped = $null -eq $doc -or $doc -isnot [System.Management.Automation.PSCustomObject]
            if ($wrapped) { $doc = [pscustomobject]@{ Value = $doc } }
            Register-LocalBaseDocumentIdentity -Document $doc -Collection $Collection -Id $Id -Wrapped $wrapped
            $PSCmdlet.WriteObject($doc, $false)
        }
        return
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

    # Emit the already materialized results through the pipeline
    foreach ($entry in $results) {
        if ($null -ne $entry) {
            $item = $entry.data
            $wrapped = $null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]
            if ($wrapped) { $item = [pscustomobject]@{ Value = $item } }

            Register-LocalBaseDocumentIdentity -Document $item -Collection $Collection -Id $entry.key -Wrapped $wrapped
            $PSCmdlet.WriteObject($item, $false)
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
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Data,

        [Parameter(Position = 2)]
        [string]$Id,

        [Parameter()]
        $Database
    )

    process {
        $cleanData = ConvertTo-LocalBasePayload $Data

        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $col = $ctx.collection($Collection)

        if ($Id) {
            return $col.add($cleanData, $Id)
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Alias('sld')]
    param(
        [Parameter(Position = 0)]
        [string]$Collection,

        [Parameter(Position = 1)]
        [string]$Id,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 2)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Data,

        [Parameter()]
        $Database
    )

    process {
        $identity = Resolve-LocalBaseDocumentIdentity -Document $Data -Collection $Collection -Id $Id
        $targetCollection = $identity.Collection
        $targetId = $identity.Id

        if (-not $targetCollection) {
            throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
        }
        if (-not $targetId) {
            throw [System.ArgumentException]::new("Document Id must be specified via -Id or pipeline object.")
        }

        # Strip internal decoration metadata if piped from Get-LocalBaseDocument
        $cleanData = ConvertTo-LocalBasePayload $Data

        $ctx = Get-LocalBaseExecutionContext -Database $Database
        $col = $ctx.collection($targetCollection)
        if ($PSCmdlet.ShouldProcess("$targetCollection/$targetId", "Set document")) { $null = $col.doc($targetId).set($cleanData) }
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
        [Parameter(Position = 0)]
        [string]$Collection,

        [Parameter(Position = 1)]
        [string]$Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [object]$Data,

        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,

        [Parameter()]
        $Database
    )

    process {
        $identity = Resolve-LocalBaseDocumentIdentity -Document $InputObject -Collection $Collection -Id $Id
        $targetCollection = $identity.Collection
        $targetId = $identity.Id

        if (-not $targetCollection) {
            throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
        }
        if (-not $targetId) {
            throw [System.ArgumentException]::new("Document Id must be specified via -Id or pipeline object.")
        }

        if ($PSCmdlet.ShouldProcess("$targetCollection/$targetId", "Update document fields")) {
            $ctx = Get-LocalBaseExecutionContext -Database $Database
            $null = $ctx.collection($targetCollection).doc($targetId).update((ConvertTo-LocalBasePayload $Data))
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
        [Parameter(Position = 0)]
        [string]$Collection,

        [Parameter(Position = 1)]
        [string]$Id,

        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,

        [Parameter()]
        [hashtable]$Filter,

        [Parameter()]
        $Database
    )

    process {
        $identity = Resolve-LocalBaseDocumentIdentity -Document $InputObject -Collection $Collection -Id $Id
        $targetCollection = $identity.Collection
        $targetId = $identity.Id

        $ctx = Get-LocalBaseExecutionContext -Database $Database

        if ($targetId) {
            if (-not $targetCollection) {
                throw [System.ArgumentException]::new("Collection name must be specified via -Collection or pipeline object.")
            }
            $target = $ctx.collection($targetCollection).doc($targetId)
            if ($Filter) {
                foreach ($k in $Filter.Keys) {
                    $target = $target.where($k, '==', $Filter[$k])
                }
            }
            $desc = if ($Filter) { "$targetCollection/$targetId (filtered by $(($Filter.Keys -join ', ')))" } else { "$targetCollection/$targetId" }
            if ($PSCmdlet.ShouldProcess($desc, "Delete document")) {
                $null = $target.delete()
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
    # Reject same-connection nesting before changing ambient state.
    $null = $ctx.beginTransaction()
    $previousConnection = $script:CurrentLocalBaseConnection
    $previousPreference = $ErrorActionPreference
    try {
        $script:CurrentLocalBaseConnection = $ctx
        $ErrorActionPreference = 'Stop'
        # Caller-created scriptblocks retain their session state. Inject the
        # preference into the invocation scope instead of only this module scope.
        $variables = [System.Collections.Generic.List[System.Management.Automation.PSVariable]]::new()
        $variables.Add([System.Management.Automation.PSVariable]::new('ErrorActionPreference', 'Stop'))
        $result = $ScriptBlock.InvokeWithContext($null, $variables, @())
        $null = $ctx.commit()
        return $result
    }
    catch {
        try { $null = $ctx.rollback() } catch { Write-Verbose "Rollback failed: $($_.Exception.Message)" }
        throw
    }
    finally {
        $script:CurrentLocalBaseConnection = $previousConnection
        $ErrorActionPreference = $previousPreference
    }
}

function Start-LocalBaseTransaction {
    <#
    .SYNOPSIS
        Manually starts an atomic transaction on the database.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter()]$Database)

    $ctx = Get-LocalBaseExecutionContext -Database $Database
    if ($PSCmdlet.ShouldProcess("Database", "Begin transaction")) { $null = $ctx.beginTransaction() }
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
