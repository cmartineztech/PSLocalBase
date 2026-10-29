# ===========================================================================
# PSLocalBase vs Flat JSON Benchmark Suite
# Compares PSLocalBase (embedded SQLite NoSQL) against Native PowerShell JSON File
# Test Scale: 5,000 records (Single Collection & Dual Collections)
# ===========================================================================

[CmdletBinding()]
param(
    [int]$RecordCount = 5000,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "PSLocalBase.psd1"
Import-Module $modulePath -Force

$benchDir = Join-Path $PSScriptRoot "temp_bench_data"
if (Test-Path $benchDir) { Remove-Item -Recurse -Force $benchDir }
New-Item -ItemType Directory -Path $benchDir -Force | Out-Null

$results = [ordered]@{}

function Measure-Operation {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    $memBefore = [System.GC]::GetTotalMemory($false)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = & $Action
    $sw.Stop()
    $memAfter = [System.GC]::GetTotalMemory($false)
    $memDeltaKB = [math]::Max(0, [math]::Round(($memAfter - $memBefore) / 1KB, 2))

    return @{
        DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        MemDeltaKB = $memDeltaKB
        Result     = $res
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PSLocalBase vs Flat JSON File Benchmark ($RecordCount Records)" -ForegroundColor Cyan
Write-Host " PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Data Generation (5,000 records)
# ---------------------------------------------------------------------------
Write-Host "[1/6] Generating synthetic dataset of $RecordCount records..." -ForegroundColor Yellow
$cities = @("New York", "London", "Tokyo", "Paris", "Berlin", "Madrid", "Toronto", "Sydney")
$departments = @("Engineering", "Sales", "Support", "Finance", "HR", "Marketing")
$domains = @("cloud.com", "tech.org", "enterprise.net", "dev.io")

$singleColData = [System.Collections.Generic.List[hashtable]]::new($RecordCount)
for ($i = 1; $i -le $RecordCount; $i++) {
    $dept = $departments[$i % $departments.Length]
    $city = $cities[$i % $cities.Length]
    $active = ($i % 3 -ne 0)
    $score = ($i * 17) % 100

    $singleColData.Add(@{
        id         = "usr-$i"
        name       = "User $i"
        email      = "user$i@$($domains[$i % $domains.Length])"
        department = $dept
        city       = $city
        active     = $active
        score      = $score
        tags       = @("tag$($i % 10)", "role$($i % 5)", "tier$($i % 3)")
        profile    = @{
            loginCount = ($i * 7) % 500
            theme      = $(if ($i % 2 -eq 0) { "dark" } else { "light" })
        }
    })
}

# ---------------------------------------------------------------------------
# BENCHMARK SCENARIO 1: Single Collection (5,000 Records)
# ---------------------------------------------------------------------------
Write-Host "`n>>> Running SCENARIO 1: Single Collection (5,000 Records)" -ForegroundColor Green

$dbPath = Join-Path $benchDir "pslocalbase_single.db"
$jsonPath = Join-Path $benchDir "flat_single.json"

# --- Operation 1: Bulk Insert / File Write ---
Write-Host "  -> Operation 1: Bulk Ingestion (5,000 records)..." -NoNewline
$m_pslb_insert = Measure-Operation "PSLB Bulk Set" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        $db.collection("users").set($singleColData)
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_insert.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_insert = Measure-Operation "JSON File Write" {
    $jsonStr = ConvertTo-Json -InputObject $singleColData -Compress -Depth 10
    [System.IO.File]::WriteAllText($jsonPath, $jsonStr, [System.Text.Encoding]::UTF8)
}
Write-Host " Flat JSON: $($m_json_insert.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 2: Point Lookups (100 individual lookups by ID) ---
$lookupKeys = 1..100 | ForEach-Object { "usr-$((($_ * 47) % $RecordCount) + 1)" }
Write-Host "  -> Operation 2: Point Lookups (100 random IDs)..." -NoNewline

$m_pslb_lookup = Measure-Operation "PSLB 100 Lookups" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        $count = 0
        foreach ($k in $lookupKeys) {
            $doc = $db.collection("users").doc($k).get()
            if ($null -ne $doc) { $count++ }
        }
        $count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_lookup.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_lookup = Measure-Operation "JSON 100 Lookups" {
    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $count = 0
    foreach ($k in $lookupKeys) {
        $found = $null
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($items[$j].id -eq $k) {
                $found = $items[$j]
                break
            }
        }
        if ($null -ne $found) { $count++ }
    }
    $count
}
Write-Host " Flat JSON: $($m_json_lookup.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 3: Filtered Query (active = true AND score >= 80) ---
Write-Host "  -> Operation 3: Multi-criteria Query Filtering..." -NoNewline

$m_pslb_query = Measure-Operation "PSLB Filter" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        $res = $db.collection("users").where("active", "=", $true).where("score", ">=", 80).get()
        $res.Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_query.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_query = Measure-Operation "JSON Filter" {
    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($item.active -eq $true -and $item.score -ge 80) {
            $matched.Add($item)
        }
    }
    $matched.Count
}
Write-Host " Flat JSON: $($m_json_query.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 4: OrderBy & Pagination (Top 10 by score desc) ---
Write-Host "  -> Operation 4: Sort & Pagination (Top 10 DESC)..." -NoNewline

$m_pslb_sort = Measure-Operation "PSLB Sort Limit" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        $res = $db.collection("users").orderBy("score", "desc").limit(10).get()
        $res.Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_sort.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_sort = Measure-Operation "JSON Sort Limit" {
    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $sorted = $items | Sort-Object -Property score -Descending | Select-Object -First 10
    ($sorted | Measure-Object).Count
}
Write-Host " Flat JSON: $($m_json_sort.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 5: Scalar Record Count ---
Write-Host "  -> Operation 5: Record Count..." -NoNewline

$m_pslb_count = Measure-Operation "PSLB Count" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        $db.collection("users").where("department", "=", "Engineering").count()
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_count.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_count = Measure-Operation "JSON Count" {
    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $count = 0
    foreach ($item in $items) {
        if ($item.department -eq "Engineering") { $count++ }
    }
    $count
}
Write-Host " Flat JSON: $($m_json_count.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 6: Partial Updates (10 random documents updated) ---
$updateKeys = 1..10 | ForEach-Object { "usr-$((($_ * 89) % $RecordCount) + 1)" }
Write-Host "  -> Operation 6: Partial Updates (10 documents)..." -NoNewline

$m_pslb_update = Measure-Operation "PSLB 10 Updates" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        foreach ($k in $updateKeys) {
            $db.collection("users").doc($k).update(@{
                lastLogin = (Get-Date).ToString("o")
                status    = "verified"
            })
        }
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_update.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_update = Measure-Operation "JSON 10 Updates" {
    # In flat JSON persistence, each persistent update requires reading the file,
    # updating the target record in memory, serializing to JSON, and overwriting disk.
    foreach ($k in $updateKeys) {
        $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $raw
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($items[$j].id -eq $k) {
                $items[$j] | Add-Member -MemberType NoteProperty -Name "lastLogin" -Value (Get-Date).ToString("o") -Force
                $items[$j] | Add-Member -MemberType NoteProperty -Name "status" -Value "verified" -Force
                break
            }
        }
        $updatedJson = ConvertTo-Json -InputObject $items -Compress -Depth 10
        [System.IO.File]::WriteAllText($jsonPath, $updatedJson, [System.Text.Encoding]::UTF8)
    }
}
Write-Host " Flat JSON: $($m_json_update.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 7: Single Document Deletions (10 documents deleted) ---
$deleteKeys = 1..10 | ForEach-Object { "usr-$((($_ * 113) % $RecordCount) + 1)" }
Write-Host "  -> Operation 7: Individual Deletions (10 documents)..." -NoNewline

$m_pslb_delete = Measure-Operation "PSLB 10 Deletes" {
    $db = [PSLocalBase]::new($dbPath)
    try {
        foreach ($k in $deleteKeys) {
            $db.collection("users").doc($k).delete()
        }
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_delete.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_delete = Measure-Operation "JSON 10 Deletes" {
    foreach ($k in $deleteKeys) {
        $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $raw
        $filteredList = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            if ($item.id -ne $k) { $filteredList.Add($item) }
        }
        $updatedJson = ConvertTo-Json -InputObject $filteredList -Compress -Depth 10
        [System.IO.File]::WriteAllText($jsonPath, $updatedJson, [System.Text.Encoding]::UTF8)
    }
}
Write-Host " Flat JSON: $($m_json_delete.DurationMs) ms" -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# BENCHMARK SCENARIO 2: Dual Collections (5,000 Records Total: 2,500 Users + 2,500 Orders)
# ---------------------------------------------------------------------------
Write-Host "`n>>> Running SCENARIO 2: Dual Collections & Cross-Collection JOIN (5,000 Records Total)" -ForegroundColor Green

$dbPathDual = Join-Path $benchDir "pslocalbase_dual.db"
$usersJsonPath = Join-Path $benchDir "flat_users.json"
$ordersJsonPath = Join-Path $benchDir "flat_orders.json"

$half = [int]($RecordCount / 2)
$usersList = [System.Collections.Generic.List[hashtable]]::new($half)
$ordersList = [System.Collections.Generic.List[hashtable]]::new($half)

for ($i = 1; $i -le $half; $i++) {
    $usersList.Add(@{
        id         = "u-$i"
        name       = "Customer $i"
        tier       = $(if ($i % 5 -eq 0) { "Platinum" } elseif ($i % 2 -eq 0) { "Gold" } else { "Silver" })
        city       = $cities[$i % $cities.Length]
    })

    $ordersList.Add(@{
        id         = "ord-$i"
        userId     = "u-$((($i * 3) % $half) + 1)"
        item       = "SKU-$((($i * 11) % 500) + 1)"
        amount     = [math]::Round((($i * 23.45) % 1500) + 10, 2)
        status     = $(if ($i % 4 -eq 0) { "Delivered" } elseif ($i % 2 -eq 0) { "Shipped" } else { "Pending" })
    })
}

# --- Operation 8: Dual Collection Ingestion ---
Write-Host "  -> Operation 8: Ingestion Across 2 Collections (5,000 total)..." -NoNewline
$m_pslb_dual_insert = Measure-Operation "PSLB Dual Ingestion" {
    $db = [PSLocalBase]::new($dbPathDual)
    try {
        $db.collection("users").set($usersList)
        $db.collection("orders").set($ordersList)
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_dual_insert.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_dual_insert = Measure-Operation "JSON Dual Ingestion" {
    $uJson = ConvertTo-Json -InputObject $usersList -Compress -Depth 10
    $oJson = ConvertTo-Json -InputObject $ordersList -Compress -Depth 10
    [System.IO.File]::WriteAllText($usersJsonPath, $uJson, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($ordersJsonPath, $oJson, [System.Text.Encoding]::UTF8)
}
Write-Host " Flat JSON: $($m_json_dual_insert.DurationMs) ms" -ForegroundColor Magenta

# --- Operation 9: Cross-Collection Relational JOIN (Orders with Customer Details) ---
Write-Host "  -> Operation 9: Relational Cross-Collection Query (JOIN)..." -NoNewline

$m_pslb_join = Measure-Operation "PSLB SQL JOIN" {
    $db = [PSLocalBase]::new($dbPathDual)
    try {
        $sql = @"
SELECT 
    json_extract(o.doc, '$.id') AS OrderId,
    json_extract(u.doc, '$.name') AS CustomerName,
    json_extract(u.doc, '$.tier') AS Tier,
    CAST(json_extract(o.doc, '$.amount') AS REAL) AS OrderAmount,
    json_extract(o.doc, '$.status') AS Status
FROM orders o
INNER JOIN users u ON json_extract(o.doc, '$.userId') = u.key
WHERE CAST(json_extract(o.doc, '$.amount') AS REAL) > 500
ORDER BY OrderAmount DESC
LIMIT 100;
"@
        $res = $db.query($sql)
        $res.Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_pslb_join.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_json_join = Measure-Operation "JSON Client-side JOIN" {
    # Flat JSON requires reading both files, indexing in a dictionary, and iterating
    $uRaw = [System.IO.File]::ReadAllText($usersJsonPath, [System.Text.Encoding]::UTF8)
    $oRaw = [System.IO.File]::ReadAllText($ordersJsonPath, [System.Text.Encoding]::UTF8)
    $uItems = ConvertFrom-Json -InputObject $uRaw
    $oItems = ConvertFrom-Json -InputObject $oRaw

    # Build lookup hashtable
    $userMap = @{}
    foreach ($u in $uItems) { $userMap[$u.id] = $u }

    $joined = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ord in $oItems) {
        if ($ord.amount -gt 500) {
            $matchedUser = $userMap[$ord.userId]
            if ($null -ne $matchedUser) {
                $joined.Add([PSCustomObject]@{
                    OrderId      = $ord.id
                    CustomerName = $matchedUser.name
                    Tier         = $matchedUser.tier
                    OrderAmount  = $ord.amount
                    Status       = $ord.status
                })
            }
        }
    }
    $sorted = $joined | Sort-Object -Property OrderAmount -Descending | Select-Object -First 100
    ($sorted | Measure-Object).Count
}
Write-Host " Flat JSON: $($m_json_join.DurationMs) ms" -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# Storage & Disk Metrics
# ---------------------------------------------------------------------------
$pslbFileSize = (Get-Item $dbPath).Length
$jsonFileSize = (Get-Item $jsonPath).Length
$pslbFileSizeKB = [math]::Round($pslbFileSize / 1KB, 2)
$jsonFileSizeKB = [math]::Round($jsonFileSize / 1KB, 2)

# ---------------------------------------------------------------------------
# Summary Data Consolidation
# ---------------------------------------------------------------------------
$benchData = [ordered]@{
    Metadata = @{
        Date              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OS                = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        TotalRecords      = $RecordCount
    }
    Scenario1_SingleCollection = @(
        @{
            Operation     = "Bulk Insertion (5,000 docs)"
            PSLocalBaseMs = $m_pslb_insert.DurationMs
            FlatJsonMs    = $m_json_insert.DurationMs
            Speedup       = [math]::Round($m_json_insert.DurationMs / [math]::Max(0.01, $m_pslb_insert.DurationMs), 2)
            Winner        = if ($m_pslb_insert.DurationMs -le $m_json_insert.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Point Lookups (100 random IDs)"
            PSLocalBaseMs = $m_pslb_lookup.DurationMs
            FlatJsonMs    = $m_json_lookup.DurationMs
            Speedup       = [math]::Round($m_json_lookup.DurationMs / [math]::Max(0.01, $m_pslb_lookup.DurationMs), 2)
            Winner        = if ($m_pslb_lookup.DurationMs -le $m_json_lookup.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Multi-filter Query (active AND score >= 80)"
            PSLocalBaseMs = $m_pslb_query.DurationMs
            FlatJsonMs    = $m_json_query.DurationMs
            Speedup       = [math]::Round($m_json_query.DurationMs / [math]::Max(0.01, $m_pslb_query.DurationMs), 2)
            Winner        = if ($m_pslb_query.DurationMs -le $m_json_query.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Sorting & Pagination (Top 10 DESC)"
            PSLocalBaseMs = $m_pslb_sort.DurationMs
            FlatJsonMs    = $m_json_sort.DurationMs
            Speedup       = [math]::Round($m_json_sort.DurationMs / [math]::Max(0.01, $m_pslb_sort.DurationMs), 2)
            Winner        = if ($m_pslb_sort.DurationMs -le $m_json_sort.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Scalar Aggregate Count"
            PSLocalBaseMs = $m_pslb_count.DurationMs
            FlatJsonMs    = $m_json_count.DurationMs
            Speedup       = [math]::Round($m_json_count.DurationMs / [math]::Max(0.01, $m_pslb_count.DurationMs), 2)
            Winner        = if ($m_pslb_count.DurationMs -le $m_json_count.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Partial Updates (10 documents)"
            PSLocalBaseMs = $m_pslb_update.DurationMs
            FlatJsonMs    = $m_json_update.DurationMs
            Speedup       = [math]::Round($m_json_update.DurationMs / [math]::Max(0.01, $m_pslb_update.DurationMs), 2)
            Winner        = if ($m_pslb_update.DurationMs -le $m_json_update.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Individual Deletions (10 documents)"
            PSLocalBaseMs = $m_pslb_delete.DurationMs
            FlatJsonMs    = $m_json_delete.DurationMs
            Speedup       = [math]::Round($m_json_delete.DurationMs / [math]::Max(0.01, $m_pslb_delete.DurationMs), 2)
            Winner        = if ($m_pslb_delete.DurationMs -le $m_json_delete.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        }
    )
    Scenario2_DualCollections = @(
        @{
            Operation     = "Dual Collection Ingestion (5,000 total)"
            PSLocalBaseMs = $m_pslb_dual_insert.DurationMs
            FlatJsonMs    = $m_json_dual_insert.DurationMs
            Speedup       = [math]::Round($m_json_dual_insert.DurationMs / [math]::Max(0.01, $m_pslb_dual_insert.DurationMs), 2)
            Winner        = if ($m_pslb_dual_insert.DurationMs -le $m_json_dual_insert.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Relational JOIN & Filter (Orders + Users)"
            PSLocalBaseMs = $m_pslb_join.DurationMs
            FlatJsonMs    = $m_json_join.DurationMs
            Speedup       = [math]::Round($m_json_join.DurationMs / [math]::Max(0.01, $m_pslb_join.DurationMs), 2)
            Winner        = if ($m_pslb_join.DurationMs -le $m_json_join.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        }
    )
    DiskMetrics = @{
        PSLocalBaseSizeKB = $pslbFileSizeKB
        FlatJsonSizeKB    = $jsonFileSizeKB
        Ratio             = [math]::Round($pslbFileSizeKB / $jsonFileSizeKB, 2)
    }
}

$swTotal.Stop()
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Benchmark Suite Finished in $([math]::Round($swTotal.Elapsed.TotalSeconds, 2)) seconds" -ForegroundColor Cyan
Write-Host " Database File Size: $pslbFileSizeKB KB | Flat JSON File Size: $jsonFileSizeKB KB" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

# Output results as JSON
$jsonResultPath = Join-Path $benchDir "benchmark_summary.json"
$benchData | ConvertTo-Json -Depth 5 | Set-Content $jsonResultPath -Encoding UTF8
Write-Host "Results serialized to: $jsonResultPath" -ForegroundColor Green

return $benchData
