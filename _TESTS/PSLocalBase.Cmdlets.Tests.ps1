# ===========================================================================
# PSLocalBase.Cmdlets.Tests.ps1 - Test Suite for Native Cmdlets & Pipeline
# ===========================================================================
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:failed = 0
$script:passed = 0

function Test-CmdletCase([string]$Name, [scriptblock]$Body) {
    $testDbPath = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_cmdlet_$([System.Guid]::NewGuid().ToString('N')).db"
    try {
        Connect-LocalBase -Path $testDbPath
        & $Body $testDbPath
        $script:passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failed++
        Write-Host "[FAIL] ${Name}: $($_.Exception.Message)"
        Write-Host "       $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    } finally {
        Disconnect-LocalBase
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        if (Test-Path $testDbPath) {
            try { Remove-LocalBaseDatabase -Path $testDbPath -Confirm:$false } catch { }
        }
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running PSLocalBase.Cmdlets Dedicated Test Suite" -ForegroundColor Cyan
Write-Host " PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# C01: Connection Lifecycle & Session Context
# ---------------------------------------------------------------------------
Test-CmdletCase 'C01 - Connect-LocalBase and Disconnect-LocalBase lifecycle' {
    param($dbPath)

    $conn = Get-LocalBaseConnection
    if ($null -eq $conn -or $conn.DbHandle -eq [System.IntPtr]::Zero) {
        throw "Expected active connection handle"
    }

    Disconnect-LocalBase
    $connAfter = Get-LocalBaseConnection
    if ($null -ne $connAfter) {
        throw "Expected connection to be null after Disconnect-LocalBase"
    }

    # Should throw without active connection
    $rejected = $false
    try {
        Get-LocalBaseDocument -Collection 'test'
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Expected operation to throw when no active database connection exists"
    }

    # Reconnect for teardown
    Connect-LocalBase -Path $dbPath
}

# ---------------------------------------------------------------------------
# C02: Document Ingestion & Pipeline Streaming
# ---------------------------------------------------------------------------
Test-CmdletCase 'C02 - Add-LocalBaseDocument (Single, Explicit Id, Pipeline Streaming)' {
    param($dbPath)

    # 1. Single auto-key
    $k1 = Add-LocalBaseDocument -Collection 'users' -Data @{ name = 'Alice'; role = 'Admin' }
    if ([string]::IsNullOrWhiteSpace($k1)) { throw "Expected generated key" }

    # 2. Single explicit Id
    $k2 = Add-LocalBaseDocument -Collection 'users' -Id 'usr_custom' -Data @{ name = 'Bob'; role = 'User' }
    if ($k2 -ne 'usr_custom') { throw "Expected custom key 'usr_custom', got '$k2'" }

    # 3. Pipeline streaming (10 items)
    $items = 1..10 | ForEach-Object {
        [PSCustomObject]@{
            idx  = $_
            tag  = "tag_$_"
            even = ($_ % 2 -eq 0)
        }
    }
    $pipeKeys = $items | Add-LocalBaseDocument -Collection 'metrics'
    if ($pipeKeys.Count -ne 10) { throw "Expected 10 generated keys from pipeline, got $($pipeKeys.Count)" }

    $countMetrics = Get-LocalBaseDocument -Collection 'metrics' -Count
    if ($countMetrics -ne 10) { throw "Expected 10 stored metrics, got $countMetrics" }
}

# ---------------------------------------------------------------------------
# C03: Get-LocalBaseDocument (Point, Filter, Order, Projection, Count)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C03 - Get-LocalBaseDocument (Point, Filter, Exists/Missing, Order, Select)' {
    param($dbPath)

    $null = @(
        @{ name = 'Alice'; age = 30; dept = 'IT'; phone = '555-0101'; score = 95 }
        @{ name = 'Bob';   age = 25; dept = 'HR'; score = 80 }
        @{ name = 'Carol'; age = 40; dept = 'IT'; phone = '555-0102'; score = 90 }
        @{ name = 'Dave';  age = 35; dept = 'HR'; score = 70 }
    ) | Add-LocalBaseDocument -Collection 'employees'

    # Point Lookup
    $id = Add-LocalBaseDocument -Collection 'employees' -Id 'emp_solo' -Data @{ name = 'Solo'; age = 99 }
    $solo = Get-LocalBaseDocument -Collection 'employees' -Id 'emp_solo'
    if ($solo.name -ne 'Solo' -or $solo.id -ne 'emp_solo') { throw "Failed Point Lookup" }

    # Filter by Hashtable
    $itStaff = Get-LocalBaseDocument -Collection 'employees' -Filter @{ dept = 'IT' }
    if ($itStaff.Count -ne 2) { throw "Expected 2 IT employees, got $($itStaff.Count)" }

    # Field Operator
    $seniors = Get-LocalBaseDocument -Collection 'employees' -Field 'age' -Operator '>=' -Value 35
    if ($seniors.Count -ne 3) { throw "Expected 3 seniors (Solo 99, Carol 40, Dave 35), got $($seniors.Count)" }

    # Exists / Missing
    $withPhone = Get-LocalBaseDocument -Collection 'employees' -Exists 'phone'
    if ($withPhone.Count -ne 2) { throw "Expected 2 with phone, got $($withPhone.Count)" }

    $withoutPhone = Get-LocalBaseDocument -Collection 'employees' -Missing 'phone'
    # Bob, Dave, Solo = 3
    if ($withoutPhone.Count -ne 3) { throw "Expected 3 without phone, got $($withoutPhone.Count)" }

    # OrderBy, Descending, Skip & First
    $topScore = Get-LocalBaseDocument -Collection 'employees' -OrderBy 'score' -Descending -First 1
    if ($topScore.name -ne 'Alice' -or $topScore.score -ne 95) { throw "Expected Alice with score 95" }

    # Select Projection
    $projected = Get-LocalBaseDocument -Collection 'employees' -Id 'emp_solo' -Select 'name'
    if ($projected.PSObject.Properties['age']) { throw "Field 'age' should have been excluded by projection" }
    if ($projected.name -ne 'Solo') { throw "Field 'name' should be preserved" }

    # Distinct
    $depts = Get-LocalBaseDocument -Collection 'employees' -Distinct 'dept'
    if ($depts.Count -ne 2 -or -not ($depts -contains 'IT') -or -not ($depts -contains 'HR')) {
        throw "Expected distinct IT and HR departments"
    }

    # Count
    $total = Get-LocalBaseDocument -Collection 'employees' -Count
    if ($total -ne 5) { throw "Expected 5 total documents, got $total" }
}

# ---------------------------------------------------------------------------
# C04: Pipeline Chaining (Get-LocalBaseDocument -> Update-LocalBaseDocument)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C04 - Pipeline Chaining (Get -> Update with Deep Merge)' {
    param($dbPath)

    $null = @(
        @{ name = 'Server1'; status = 'Online'; details = @{ cpu = 20; ram = 40 }; tags = @('prod', 'web') }
        @{ name = 'Server2'; status = 'Degraded'; details = @{ cpu = 90; ram = 85 }; tags = @('stage') }
        @{ name = 'Server3'; status = 'Degraded'; details = @{ cpu = 95; ram = 90 }; tags = @('stage', 'legacy') }
    ) | Add-LocalBaseDocument -Collection 'servers'

    # Pipeline: Find degraded servers and update their maintenance flag
    Get-LocalBaseDocument -Collection 'servers' -Filter @{ status = 'Degraded' } |
        Update-LocalBaseDocument -Data @{ maintenance = $true; details = @{ flagged = $true } }

    # Verify deep merge preserved existing fields (cpu, ram, name) while merging flagged
    $degraded = Get-LocalBaseDocument -Collection 'servers' -Filter @{ status = 'Degraded' }
    if ($degraded.Count -ne 2) { throw "Expected 2 degraded servers" }

    foreach ($srv in $degraded) {
        if (-not $srv.maintenance) { throw "Expected maintenance = true" }
        if (-not $srv.details.flagged) { throw "Expected details.flagged = true" }
        if (-not $srv.details.cpu) { throw "Expected cpu property to be preserved" }
    }

    $online = Get-LocalBaseDocument -Collection 'servers' -Filter @{ status = 'Online' }
    if ($online.PSObject.Properties['maintenance']) {
        throw "Server1 should not have been updated"
    }

    # Array mutations with ArrayUnion / ArrayRemove via Update-LocalBaseDocument
    Get-LocalBaseDocument -Collection 'servers' -Filter @{ name = 'Server1' } |
        Update-LocalBaseDocument -Data @{ tags = [PSLocalBase]::ArrayUnion('monitored') }

    $s1 = Get-LocalBaseDocument -Collection 'servers' -Filter @{ name = 'Server1' }
    if (-not (@($s1.tags) -contains 'monitored')) {
        throw "Expected ArrayUnion to add 'monitored' tag"
    }

    # Pipeline into Set-LocalBaseDocument and verify zero metadata leakage
    $srvToReplace = Get-LocalBaseDocument -Collection 'servers' -Filter @{ name = 'Server2' }
    $srvToReplace.status = 'Repaired'
    $srvToReplace | Set-LocalBaseDocument

    $s2Raw = (Get-LocalBaseConnection).collection('servers').doc($srvToReplace.id).get()
    if ($s2Raw.PSObject.Properties['_localbase_collection'] -or $s2Raw.PSObject.Properties['_localbase_key']) {
        throw "Internal metadata note properties leaked into the database!"
    }
    if ($s2Raw.status -ne 'Repaired') {
        throw "Set-LocalBaseDocument failed to update repaired status"
    }
}

# ---------------------------------------------------------------------------
# C05: Pipeline Chaining (Get-LocalBaseDocument -> Remove-LocalBaseDocument) & WhatIf
# ---------------------------------------------------------------------------
Test-CmdletCase 'C05 - Pipeline Chaining (Get -> Remove) & -WhatIf Safety' {
    param($dbPath)

    $null = 1..5 | ForEach-Object {
        Add-LocalBaseDocument -Collection 'tasks' -Data @{ id_num = $_; done = ($_ -le 3) }
    }

    $beforeCount = Get-LocalBaseDocument -Collection 'tasks' -Count
    if ($beforeCount -ne 5) { throw "Expected 5 tasks" }

    # WhatIf should NOT delete anything
    Get-LocalBaseDocument -Collection 'tasks' -Filter @{ done = $true } |
        Remove-LocalBaseDocument -WhatIf

    $afterWhatIf = Get-LocalBaseDocument -Collection 'tasks' -Count
    if ($afterWhatIf -ne 5) { throw "WhatIf must not delete any documents" }

    # Real removal without confirmation
    Get-LocalBaseDocument -Collection 'tasks' -Filter @{ done = $true } |
        Remove-LocalBaseDocument -Confirm:$false

    $afterRemove = Get-LocalBaseDocument -Collection 'tasks' -Count
    if ($afterRemove -ne 2) { throw "Expected 2 remaining tasks after delete, got $afterRemove" }

    # Remove by property-name pipeline binding directly ([PSCustomObject] with Collection and Id)
    $remainingTask = Get-LocalBaseDocument -Collection 'tasks' -First 1
    [PSCustomObject]@{ Collection = 'tasks'; Id = $remainingTask.id } |
        Remove-LocalBaseDocument -Confirm:$false

    $afterObjRemove = Get-LocalBaseDocument -Collection 'tasks' -Count
    if ($afterObjRemove -ne 1) { throw "Expected 1 task remaining after pipeline property name deletion" }

    # Remove by Filter parameter directly
    Remove-LocalBaseDocument -Collection 'tasks' -Filter @{ done = $false } -Confirm:$false
    $finalCount = Get-LocalBaseDocument -Collection 'tasks' -Count
    if ($finalCount -ne 0) { throw "Expected 0 tasks after filter deletion, got $finalCount" }
}

# ---------------------------------------------------------------------------
# C06: Collection & Index Management Cmdlets
# ---------------------------------------------------------------------------
Test-CmdletCase 'C06 - Collection & Index Lifecycle (New, Get, Clear, Remove, Index)' {
    param($dbPath)

    New-LocalBaseCollection -Name 'inventory'
    $colls = Get-LocalBaseCollection
    if (-not (@($colls) -contains 'inventory')) { throw "Collection 'inventory' should exist" }

    # Create Unique Index
    New-LocalBaseIndex -Collection 'inventory' -Field 'sku' -Unique

    $null = Add-LocalBaseDocument -Collection 'inventory' -Data @{ sku = 'SKU-001'; name = 'Item A' }

    # Duplicate SKU must be rejected
    $duplicateRejected = $false
    try {
        $null = Add-LocalBaseDocument -Collection 'inventory' -Data @{ sku = 'SKU-001'; name = 'Item B' }
    } catch {
        $duplicateRejected = $true
    }
    if (-not $duplicateRejected) { throw "Expected unique constraint violation on duplicate SKU" }

    # Drop index
    Remove-LocalBaseIndex -Collection 'inventory' -Field 'sku'

    # Clear collection (truncate documents, retain table)
    Clear-LocalBaseCollection -Collection 'inventory' -Confirm:$false
    $cnt = Get-LocalBaseDocument -Collection 'inventory' -Count
    if ($cnt -ne 0) { throw "Expected 0 items after Clear-LocalBaseCollection" }
    $collsAfterClear = Get-LocalBaseCollection
    if (-not (@($collsAfterClear) -contains 'inventory')) { throw "Table 'inventory' should still exist after clear" }

    # Remove collection (drop table)
    Remove-LocalBaseCollection -Collection 'inventory' -Confirm:$false
    $collsAfterDrop = Get-LocalBaseCollection
    if (@($collsAfterDrop) -contains 'inventory') { throw "Collection 'inventory' should be dropped" }
}

# ---------------------------------------------------------------------------
# C07: Measure-LocalBaseDocument (Aggregations)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C07 - Measure-LocalBaseDocument (Sum, Average, Min, Max)' {
    param($dbPath)

    $null = @(
        @{ cat = 'A'; price = 10 }
        @{ cat = 'A'; price = 20 }
        @{ cat = 'A'; price = 30 }
        @{ cat = 'B'; price = 100 }
    ) | Add-LocalBaseDocument -Collection 'products'

    $statsA = Measure-LocalBaseDocument -Collection 'products' -Field 'price' -Filter @{ cat = 'A' } -Sum -Average -Minimum -Maximum
    if ($statsA.Count -ne 3) { throw "Expected count 3, got $($statsA.Count)" }
    if ($statsA.Sum -ne 60) { throw "Expected sum 60, got $($statsA.Sum)" }
    if ($statsA.Average -ne 20) { throw "Expected average 20, got $($statsA.Average)" }
    if ($statsA.Minimum -ne 10) { throw "Expected min 10, got $($statsA.Minimum)" }
    if ($statsA.Maximum -ne 30) { throw "Expected max 30, got $($statsA.Maximum)" }

    # Measure on empty collection
    $emptyStats = Measure-LocalBaseDocument -Collection 'empty_items' -Field 'val' -Sum -Average -Minimum -Maximum
    if ($emptyStats.Count -ne 0) { throw "Expected count 0 for empty collection" }
    if ($emptyStats.Sum -ne 0) { throw "Expected sum 0 for empty collection" }
}

# ---------------------------------------------------------------------------
# C08: Atomic Transactions (Invoke-LocalBaseTransaction, Start/Complete/Undo)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C08 - Atomic Transactions (Commit, Rollback on Error)' {
    param($dbPath)

    # 1. Successful commit via Invoke-LocalBaseTransaction
    Invoke-LocalBaseTransaction {
        $null = Add-LocalBaseDocument -Collection 'ledger' -Data @{ entry = 1; amount = 100 }
        $null = Add-LocalBaseDocument -Collection 'ledger' -Data @{ entry = 2; amount = 200 }
    }
    $cnt1 = Get-LocalBaseDocument -Collection 'ledger' -Count
    if ($cnt1 -ne 2) { throw "Expected 2 ledger entries after committed transaction" }

    # 2. Rollback on failure via Invoke-LocalBaseTransaction
    $errOccurred = $false
    try {
        Invoke-LocalBaseTransaction {
            $null = Add-LocalBaseDocument -Collection 'ledger' -Data @{ entry = 3; amount = 300 }
            throw "Simulated network or validation fault"
        }
    } catch {
        $errOccurred = $true
    }
    if (-not $errOccurred) { throw "Expected transaction error" }

    $cnt2 = Get-LocalBaseDocument -Collection 'ledger' -Count
    if ($cnt2 -ne 2) { throw "Expected count to remain 2 after rolled back transaction, got $cnt2" }

    # 3. Manual Start / Complete
    Start-LocalBaseTransaction
    $null = Add-LocalBaseDocument -Collection 'ledger' -Data @{ entry = 4; amount = 400 }
    Complete-LocalBaseTransaction
    $cnt3 = Get-LocalBaseDocument -Collection 'ledger' -Count
    if ($cnt3 -ne 3) { throw "Expected count 3 after Complete-LocalBaseTransaction, got $cnt3" }

    # 4. Manual Start / Undo
    Start-LocalBaseTransaction
    $null = Add-LocalBaseDocument -Collection 'ledger' -Data @{ entry = 5; amount = 500 }
    Undo-LocalBaseTransaction
    $cnt4 = Get-LocalBaseDocument -Collection 'ledger' -Count
    if ($cnt4 -ne 3) { throw "Expected count 3 after Undo-LocalBaseTransaction, got $cnt4" }
}

# ---------------------------------------------------------------------------
# C09: Multi-Database Routing via -Database Parameter
# ---------------------------------------------------------------------------
Test-CmdletCase 'C09 - Multi-Database Routing via -Database parameter' {
    param($dbPath)

    $dbPath2 = "$dbPath.secondary.db"
    $db2 = $null
    try {
        $db2 = New-LocalBase -Path $dbPath2

        # Active default DB gets Doc A
        $null = Add-LocalBaseDocument -Collection 'shared' -Data @{ db = 'Default' }

        # Explicit -Database $db2 gets Doc B
        $null = Add-LocalBaseDocument -Collection 'shared' -Data @{ db = 'Secondary' } -Database $db2

        $defDocs = Get-LocalBaseDocument -Collection 'shared'
        $secDocs = Get-LocalBaseDocument -Collection 'shared' -Database $db2

        if (@($defDocs).Count -ne 1 -or @($defDocs)[0].db -ne 'Default') {
            throw "Default database corrupted or cross-contaminated"
        }
        if (@($secDocs).Count -ne 1 -or @($secDocs)[0].db -ne 'Secondary') {
            throw "Secondary database corrupted or cross-contaminated"
        }
    } finally {
        if ($db2) { $db2.close() }
        if (Test-Path $dbPath2) { Remove-LocalBaseDatabase -Path $dbPath2 -Confirm:$false }
    }
}

# ---------------------------------------------------------------------------
# C10: Mixed-Mode Interoperability (Fluent <-> Cmdlets)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C10 - Mixed-Mode Interoperability (Fluent API + Cmdlet Pipeline)' {
    param($dbPath)

    # 1. Ingest via Cmdlet
    $null = @(
        @{ id = 'item_A1'; sku = 'A1'; price = 50 }
        @{ id = 'item_B2'; sku = 'B2'; price = 120 }
        @{ id = 'item_C3'; sku = 'C3'; price = 200 }
    ) | Add-LocalBaseDocument -Collection 'items'

    # 2. Query via Primary Fluent API on active connection
    $db = Get-LocalBaseConnection
    $fluentItems = $db.collection('items').where('price', '>', 100).orderBy('price').get()
    if (@($fluentItems).Count -ne 2) { throw "Fluent query expected 2 items" }

    # 3. Pipe fluent results back to Cmdlet
    $fluentItems | Update-LocalBaseDocument -Collection 'items' -Data @{ premium = $true }

    # 4. Verify via Cmdlet
    $premiumCount = Get-LocalBaseDocument -Collection 'items' -Filter @{ premium = $true } -Count
    if ($premiumCount -ne 2) { throw "Expected 2 premium items after mixed update, got $premiumCount" }
}

# ---------------------------------------------------------------------------
# C11: Backup-LocalBaseDatabase (Online VACUUM INTO)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C11 - Backup-LocalBaseDatabase (Hot Snapshot)' {
    param($dbPath)

    $null = Add-LocalBaseDocument -Collection 'vault' -Data @{ secret = 'TopSecretData'; level = 5 }

    $backupPath = "$dbPath.backup.db"
    try {
        Backup-LocalBaseDatabase -DestinationPath $backupPath

        if (-not (Test-Path $backupPath)) { throw "Backup file was not created" }

        # Verify backup contents
        $bDb = New-LocalBase -Path $backupPath
        $bSecret = $bDb.collection('vault').first()
        if ($bSecret.secret -ne 'TopSecretData') { throw "Backup content mismatch" }
        $bDb.close()
    } finally {
        if (Test-Path $backupPath) { Remove-LocalBaseDatabase -Path $backupPath -Confirm:$false }
    }
}

# ---------------------------------------------------------------------------
# C12: Cmdlet Aliases (gld, ald, sld, uld, rld)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C12 - Cmdlet Aliases (gld, ald, sld, uld, rld)' {
    param($dbPath)

    $id = ald 'alias_test' @{ val = 1 }
    $doc = gld 'alias_test' -Id $id
    if ($doc.val -ne 1) { throw "gld failed" }

    sld 'alias_test' $id @{ val = 2 }
    $doc2 = gld 'alias_test' -Id $id
    if ($doc2.val -ne 2) { throw "sld failed" }

    uld 'alias_test' $id @{ val = 3 }
    $doc3 = gld 'alias_test' -Id $id
    if ($doc3.val -ne 3) { throw "uld failed" }

    rld 'alias_test' $id -Confirm:$false
    $cnt = gld 'alias_test' -Count
    if ($cnt -ne 0) { throw "rld failed" }
}

# ---------------------------------------------------------------------------
# C13: Empty Results, Missing ID, and Non-Existent Collection
# ---------------------------------------------------------------------------
Test-CmdletCase 'C13 - Empty Results, Missing ID, and Non-Existent Collection' {
    param($dbPath)

    # 1. Non-existent collection returns empty / 0
    $emptyList = @(Get-LocalBaseDocument -Collection 'nonexistent')
    if ($emptyList.Count -ne 0) { throw "Expected 0 results from non-existent collection" }

    $emptyCount = Get-LocalBaseDocument -Collection 'nonexistent' -Count
    if ($emptyCount -ne 0) { throw "Expected count 0 from non-existent collection" }

    # 2. Point lookup for missing ID returns $null
    New-LocalBaseCollection -Name 'test_empty'
    $missingDoc = Get-LocalBaseDocument -Collection 'test_empty' -Id 'missing_key'
    if ($null -ne $missingDoc) { throw "Expected null for missing document ID" }

    # 3. Query filter with zero matches returns empty array
    $null = Add-LocalBaseDocument -Collection 'test_empty' -Data @{ status = 'Pending' }
    $filteredEmpty = @(Get-LocalBaseDocument -Collection 'test_empty' -Filter @{ status = 'Completed' })
    if ($filteredEmpty.Count -ne 0) { throw "Expected 0 results for non-matching filter" }
}

# ---------------------------------------------------------------------------
# C14: Boolean, Null, and DataType Filtering
# ---------------------------------------------------------------------------
Test-CmdletCase 'C14 - Boolean, Null, and DataType Filtering' {
    param($dbPath)

    $null = @(
        @{ name = 'Alpha'; active = $true;  note = $null }
        @{ name = 'Beta';  active = $false; note = 'urgent' }
        @{ name = 'Gamma'; active = $true;  note = 'normal' }
    ) | Add-LocalBaseDocument -Collection 'items'

    # Filter by boolean
    $actives = @(Get-LocalBaseDocument -Collection 'items' -Filter @{ active = $true })
    if ($actives.Count -ne 2) { throw "Expected 2 active items, got $($actives.Count)" }

    $inactives = @(Get-LocalBaseDocument -Collection 'items' -Filter @{ active = $false })
    if ($inactives.Count -ne 1) { throw "Expected 1 inactive item, got $($inactives.Count)" }

    # Filter with -Operator and -Value
    $falseItems = @(Get-LocalBaseDocument -Collection 'items' -Field 'active' -Operator '==' -Value $false)
    if ($falseItems.Count -ne 1 -or $falseItems[0].name -ne 'Beta') { throw "Field operator boolean filter failed" }
}

# ---------------------------------------------------------------------------
# C15: Pipeline Update with Array Mutations (Union / Remove)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C15 - Pipeline Update with Array Mutations (Union / Remove)' {
    param($dbPath)

    $id = Add-LocalBaseDocument -Collection 'articles' -Data @{
        title = 'Post 1'; tags = @('powershell', 'database')
    }

    # ArrayUnion via Update-LocalBaseDocument
    Update-LocalBaseDocument -Collection 'articles' -Id $id -Data @{
        tags = @{ '$arrayUnion' = @('nosql', 'powershell') }
    }

    $docAfterUnion = Get-LocalBaseDocument -Collection 'articles' -Id $id
    if (@($docAfterUnion.tags).Count -ne 3 -or -not (@($docAfterUnion.tags) -contains 'nosql')) {
        throw "Expected tags to have 3 elements containing 'nosql'"
    }

    # ArrayRemove via Update-LocalBaseDocument
    Update-LocalBaseDocument -Collection 'articles' -Id $id -Data @{
        tags = @{ '$arrayRemove' = @('database') }
    }

    $docAfterRemove = Get-LocalBaseDocument -Collection 'articles' -Id $id
    if (@($docAfterRemove.tags).Count -ne 2 -or (@($docAfterRemove.tags) -contains 'database')) {
        throw "Expected 'database' to be removed from tags"
    }
}

# ---------------------------------------------------------------------------
# C16: Transaction Lifecycle (Start, Complete, Pipeline Return, State)
# ---------------------------------------------------------------------------
Test-CmdletCase 'C16 - Transaction Lifecycle (Start, Complete, Pipeline Return, State)' {
    param($dbPath)

    $conn = Get-LocalBaseConnection
    if ($conn.InTransaction) { throw "Should not be in transaction initially" }

    # Manual Start & Complete
    Start-LocalBaseTransaction
    if (-not $conn.InTransaction) { throw "Expected InTransaction = true after Start-LocalBaseTransaction" }

    $null = Add-LocalBaseDocument -Collection 'tx_test' -Data @{ n = 1 }
    Complete-LocalBaseTransaction
    if ($conn.InTransaction) { throw "Expected InTransaction = false after Complete-LocalBaseTransaction" }

    $count = Get-LocalBaseDocument -Collection 'tx_test' -Count
    if ($count -ne 1) { throw "Expected 1 document after Complete-LocalBaseTransaction" }

    # Invoke-LocalBaseTransaction returning output to pipeline
    $returnedKey = Invoke-LocalBaseTransaction {
        Add-LocalBaseDocument -Collection 'tx_test' -Data @{ n = 2 }
    }
    if ([string]::IsNullOrWhiteSpace($returnedKey)) {
        throw "Invoke-LocalBaseTransaction should propagate scriptblock output"
    }
    $finalCount = Get-LocalBaseDocument -Collection 'tx_test' -Count
    if ($finalCount -ne 2) { throw "Expected 2 documents after transaction block" }
}

# ---------------------------------------------------------------------------
# C17: Comprehensive -WhatIf Safety
# ---------------------------------------------------------------------------
Test-CmdletCase 'C17 - Comprehensive -WhatIf Safety' {
    param($dbPath)

    $id = Add-LocalBaseDocument -Collection 'safeguard' -Data @{ v = 10 }

    # 1. Update-LocalBaseDocument -WhatIf
    Update-LocalBaseDocument -Collection 'safeguard' -Id $id -Data @{ v = 99 } -WhatIf
    $docAfterWhatIf = Get-LocalBaseDocument -Collection 'safeguard' -Id $id
    if ($docAfterWhatIf.v -ne 10) { throw "Update -WhatIf must not alter document" }

    # 2. Clear-LocalBaseCollection -WhatIf
    Clear-LocalBaseCollection -Collection 'safeguard' -WhatIf
    $cntAfterClearWhatIf = Get-LocalBaseDocument -Collection 'safeguard' -Count
    if ($cntAfterClearWhatIf -ne 1) { throw "Clear -WhatIf must not truncate documents" }

    # 3. Remove-LocalBaseCollection -WhatIf
    Remove-LocalBaseCollection -Collection 'safeguard' -WhatIf
    $colls = Get-LocalBaseCollection
    if (-not (@($colls) -contains 'safeguard')) { throw "Remove-Collection -WhatIf must not drop collection" }
}

# ---------------------------------------------------------------------------
# C18: Nested Projections in Point Lookup & Active Connection Disconnect Check
# ---------------------------------------------------------------------------
Test-CmdletCase 'C18 - Nested Select Projection and Active Session Disconnect' {
    param($dbPath)

    $null = Add-LocalBaseDocument -Collection 'profiles' -Id 'p1' -Data @{
        name    = 'Carlos'
        contact = @{ email = 'carlos@example.com'; city = 'Miami' }
    }

    # Nested projection in ById parameter set
    $p = Get-LocalBaseDocument -Collection 'profiles' -Id 'p1' -Select 'name', 'contact.city'
    if ($p.name -ne 'Carlos') { throw "Expected projected name" }
    if ($p.PSObject.Properties['contact.city'].Value -ne 'Miami') { throw "Expected projected nested contact.city" }

    # Remove-LocalBaseDatabase disconnects active session cleanly
    $tempDb = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_removal_$([System.Guid]::NewGuid().ToString('N')).db"
    try {
        Connect-LocalBase -Path $tempDb
        $null = Add-LocalBaseDocument -Collection 'data' -Data @{ ok = $true }

        Remove-LocalBaseDatabase -Path $tempDb -Confirm:$false

        $conn = Get-LocalBaseConnection
        if ($null -ne $conn) {
            throw "Expected active connection to be disconnected upon database removal"
        }
        if (Test-Path $tempDb) {
            throw "Expected database file to be deleted from disk"
        }
    } finally {
        Disconnect-LocalBase
        if (Test-Path $tempDb) {
            Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PSLocalBase.Cmdlets Test Suite Completed" -ForegroundColor Cyan
Write-Host " Total Passed: $script:passed" -ForegroundColor Green
Write-Host " Total Failed: $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($script:failed -gt 0) {
    exit 1
}
