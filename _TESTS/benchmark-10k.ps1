# ===========================================================================
# PSLocalBase 10,000 Records Benchmark Suite
# Dual Comparisons:
#   Part 1: Persistent Disk vs Flat JSON Disk
#   Part 2: In-Memory Engine + Local Disk Sync vs In-Memory JSON + Local Disk Sync
# ===========================================================================

[CmdletBinding()]
param(
    [int]$RecordCount = 10000
)

$ErrorActionPreference = "Stop"
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "PSLocalBase.psd1"
Import-Module $modulePath -Force

$benchDir = Join-Path $PSScriptRoot "temp_bench_10k"
if (Test-Path $benchDir) { Remove-Item -Recurse -Force $benchDir }
New-Item -ItemType Directory -Path $benchDir -Force | Out-Null

function Measure-Op {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    $memBefore = [System.GC]::GetTotalMemory($true)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = & $Action
    $sw.Stop()
    $memAfter = [System.GC]::GetTotalMemory($true)
    $memDeltaMB = [math]::Max(0, [math]::Round(($memAfter - $memBefore) / 1MB, 2))

    return @{
        DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        MemDeltaMB = $memDeltaMB
        Result     = $res
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PSLocalBase 10,000 Records High-Scale Benchmark Suite" -ForegroundColor Cyan
Write-Host " PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
Write-Host " Host OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Data Generation (10,000 records)
# ---------------------------------------------------------------------------
Write-Host "[1/3] Generating synthetic 10,000 records dataset..." -ForegroundColor Yellow
$cities = @("New York", "London", "Tokyo", "Paris", "Berlin", "Madrid", "Toronto", "Sydney", "Singapore", "Seoul")
$departments = @("Engineering", "Sales", "Support", "Finance", "HR", "Marketing", "Security", "Product")
$domains = @("cloud.com", "tech.org", "enterprise.net", "dev.io")

$usersData = [System.Collections.Generic.List[hashtable]]::new($RecordCount)
for ($i = 1; $i -le $RecordCount; $i++) {
    $dept = $departments[$i % $departments.Length]
    $city = $cities[$i % $cities.Length]
    $active = ($i % 3 -ne 0)
    $score = ($i * 17) % 100

    $usersData.Add(@{
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

$half = [int]($RecordCount / 2)
$dualUsers = [System.Collections.Generic.List[hashtable]]::new($half)
$dualOrders = [System.Collections.Generic.List[hashtable]]::new($half)
for ($i = 1; $i -le $half; $i++) {
    $dualUsers.Add(@{
        id         = "u-$i"
        name       = "Customer $i"
        tier       = $(if ($i % 5 -eq 0) { "Platinum" } elseif ($i % 2 -eq 0) { "Gold" } else { "Silver" })
        city       = $cities[$i % $cities.Length]
    })
    $dualOrders.Add(@{
        id         = "ord-$i"
        userId     = "u-$((($i * 3) % $half) + 1)"
        item       = "SKU-$((($i * 11) % 500) + 1)"
        amount     = [math]::Round((($i * 23.45) % 1500) + 10, 2)
        status     = $(if ($i % 4 -eq 0) { "Delivered" } elseif ($i % 2 -eq 0) { "Shipped" } else { "Pending" })
    })
}

# ===========================================================================
# PART 1: PERSISTENT DISK-TO-DISK BENCHMARK (10,000 Records)
# ===========================================================================
Write-Host "`n>>> [PART 1] PERSISTENT DISK BENCHMARK (10,000 Records)" -ForegroundColor Green

$dbPathDisk = Join-Path $benchDir "disk_10k.db"
$jsonPathDisk = Join-Path $benchDir "disk_10k.json"

# Op 1: Bulk Ingestion (10,000 records)
Write-Host "  -> Op 1: Bulk Ingestion (10,000 records to disk)..." -NoNewline
$m_p1_pslb_insert = Measure-Op "PSLB Disk Insert" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").set($usersData)
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_insert.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_insert = Measure-Op "JSON Disk Insert" {
    $jsonStr = ConvertTo-Json -InputObject $usersData -Compress -Depth 10
    [System.IO.File]::WriteAllText($jsonPathDisk, $jsonStr, [System.Text.Encoding]::UTF8)
}
Write-Host " Flat JSON: $($m_p1_json_insert.DurationMs) ms" -ForegroundColor Magenta

# Op 2: Point Lookups (100 random IDs)
$lookupKeys = 1..100 | ForEach-Object { "usr-$((($_ * 79) % $RecordCount) + 1)" }
Write-Host "  -> Op 2: Point Lookups (100 random IDs)..." -NoNewline

$m_p1_pslb_lookup = Measure-Op "PSLB Disk Lookups" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $found = 0
        foreach ($k in $lookupKeys) {
            $doc = $db.collection("users").doc($k).get()
            if ($null -ne $doc) { $found++ }
        }
        $found
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_lookup.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_lookup = Measure-Op "JSON Disk Lookups" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $found = 0
    foreach ($k in $lookupKeys) {
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($items[$j].id -eq $k) {
                $found++
                break
            }
        }
    }
    $found
}
Write-Host " Flat JSON: $($m_p1_json_lookup.DurationMs) ms" -ForegroundColor Magenta

# Op 3: Filter Query
Write-Host "  -> Op 3: Filtered Query (active = true AND score >= 80)..." -NoNewline
$m_p1_pslb_query = Measure-Op "PSLB Disk Filter" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").where("active", "=", $true).where("score", ">=", 80).get().Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_query.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_query = Measure-Op "JSON Disk Filter" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $cnt = 0
    foreach ($item in $items) {
        if ($item.active -eq $true -and $item.score -ge 80) { $cnt++ }
    }
    $cnt
}
Write-Host " Flat JSON: $($m_p1_json_query.DurationMs) ms" -ForegroundColor Magenta

# Op 4: Sort & Pagination (Top 10 DESC)
Write-Host "  -> Op 4: Sorting & Pagination (Top 10 DESC)..." -NoNewline
$m_p1_pslb_sort = Measure-Op "PSLB Disk Sort" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").orderBy("score", "desc").limit(10).get().Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_sort.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_sort = Measure-Op "JSON Disk Sort" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    ($items | Sort-Object -Property score -Descending | Select-Object -First 10 | Measure-Object).Count
}
Write-Host " Flat JSON: $($m_p1_json_sort.DurationMs) ms" -ForegroundColor Magenta

# Op 5: Aggregate Count
Write-Host "  -> Op 5: Aggregate Count (Engineering)..." -NoNewline
$m_p1_pslb_count = Measure-Op "PSLB Disk Count" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").where("department", "=", "Engineering").count()
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_count.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_count = Measure-Op "JSON Disk Count" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $cnt = 0
    foreach ($item in $items) {
        if ($item.department -eq "Engineering") { $cnt++ }
    }
    $cnt
}
Write-Host " Flat JSON: $($m_p1_json_count.DurationMs) ms" -ForegroundColor Magenta

# Op 6: Partial Updates (10 records persistent)
$updateKeys = 1..10 | ForEach-Object { "usr-$((($_ * 89) % $RecordCount) + 1)" }
Write-Host "  -> Op 6: Partial Updates (10 records on disk)..." -NoNewline
$m_p1_pslb_update = Measure-Op "PSLB Disk Update" {
    $db = [PSLocalBase]::new($dbPathDisk)
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
Write-Host " PSLB: $($m_p1_pslb_update.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_update = Measure-Op "JSON Disk Update" {
    foreach ($k in $updateKeys) {
        $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $raw
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($items[$j].id -eq $k) {
                $items[$j] | Add-Member -MemberType NoteProperty -Name "lastLogin" -Value (Get-Date).ToString("o") -Force
                $items[$j] | Add-Member -MemberType NoteProperty -Name "status" -Value "verified" -Force
                break
            }
        }
        $updatedJson = ConvertTo-Json -InputObject $items -Compress -Depth 10
        [System.IO.File]::WriteAllText($jsonPathDisk, $updatedJson, [System.Text.Encoding]::UTF8)
    }
}
Write-Host " Flat JSON: $($m_p1_json_update.DurationMs) ms" -ForegroundColor Magenta

# Op 7: Individual Deletions (10 records persistent)
$deleteKeys = 1..10 | ForEach-Object { "usr-$((($_ * 113) % $RecordCount) + 1)" }
Write-Host "  -> Op 7: Individual Deletions (10 records on disk)..." -NoNewline
$m_p1_pslb_delete = Measure-Op "PSLB Disk Delete" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        foreach ($k in $deleteKeys) {
            $db.collection("users").doc($k).delete()
        }
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_delete.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_delete = Measure-Op "JSON Disk Delete" {
    foreach ($k in $deleteKeys) {
        $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $raw
        $filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            if ($item.id -ne $k) { $filtered.Add($item) }
        }
        $updatedJson = ConvertTo-Json -InputObject $filtered -Compress -Depth 10
        [System.IO.File]::WriteAllText($jsonPathDisk, $updatedJson, [System.Text.Encoding]::UTF8)
    }
}
Write-Host " Flat JSON: $($m_p1_json_delete.DurationMs) ms" -ForegroundColor Magenta

# Op 8: Relational JOIN across Dual Collections (5,000 + 5,000 records)
$dbPathDualDisk = Join-Path $benchDir "disk_dual_10k.db"
$usersJsonDual = Join-Path $benchDir "disk_users_5k.json"
$ordersJsonDual = Join-Path $benchDir "disk_orders_5k.json"

Write-Host "  -> Op 8: Dual Collection JOIN (5,000 orders x 5,000 users)..." -NoNewline
$dbDual = [PSLocalBase]::new($dbPathDualDisk)
$dbDual.collection("users").set($dualUsers)
$dbDual.collection("orders").set($dualOrders)
$dbDual.close()

$uJson = ConvertTo-Json -InputObject $dualUsers -Compress -Depth 10
$oJson = ConvertTo-Json -InputObject $dualOrders -Compress -Depth 10
[System.IO.File]::WriteAllText($usersJsonDual, $uJson, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($ordersJsonDual, $oJson, [System.Text.Encoding]::UTF8)

$m_p1_pslb_join = Measure-Op "PSLB Disk JOIN" {
    $db = [PSLocalBase]::new($dbPathDualDisk)
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
WHERE CAST(json_extract(o.doc, '$.amount') AS REAL) > 750
ORDER BY OrderAmount DESC
LIMIT 100;
"@
        $db.query($sql).Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_join.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_join = Measure-Op "JSON Disk JOIN" {
    $uRaw = [System.IO.File]::ReadAllText($usersJsonDual, [System.Text.Encoding]::UTF8)
    $oRaw = [System.IO.File]::ReadAllText($ordersJsonDual, [System.Text.Encoding]::UTF8)
    $uItems = ConvertFrom-Json -InputObject $uRaw
    $oItems = ConvertFrom-Json -InputObject $oRaw

    $userMap = @{}
    foreach ($u in $uItems) { $userMap[$u.id] = $u }

    $joined = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ord in $oItems) {
        if ($ord.amount -gt 750) {
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
    ($joined | Sort-Object -Property OrderAmount -Descending | Select-Object -First 100 | Measure-Object).Count
}
Write-Host " Flat JSON: $($m_p1_json_join.DurationMs) ms" -ForegroundColor Magenta

# Op 9: In-Engine Mathematical Sum (.sum())
Write-Host "  -> Op 9: In-Engine Mathematical Sum (.sum())..." -NoNewline
$m_p1_pslb_sum = Measure-Op "PSLB Disk Sum" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").where("active", "=", $true).sum("score")
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_sum.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_sum = Measure-Op "JSON Disk Sum" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $sum = 0
    foreach ($item in $items) {
        if ($item.active -eq $true) { $sum += $item.score }
    }
    $sum
}
Write-Host " Flat JSON: $($m_p1_json_sum.DurationMs) ms" -ForegroundColor Magenta

# Op 10: Selective Field Projection (.select())
Write-Host "  -> Op 10: Selective Field Projection (.select())..." -NoNewline
$m_p1_pslb_select = Measure-Op "PSLB Disk Select" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").select("id", "name", "city").limit(100).get().Count
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_select.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_select = Measure-Op "JSON Disk Select" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $selected = [System.Collections.Generic.List[object]]::new(100)
    for ($i = 0; $i -lt [math]::Min(100, $items.Count); $i++) {
        $selected.Add([PSCustomObject]@{
            id   = $items[$i].id
            name = $items[$i].name
            city = $items[$i].city
        })
    }
    $selected.Count
}
Write-Host " Flat JSON: $($m_p1_json_select.DurationMs) ms" -ForegroundColor Magenta

# Op 11: Array Cardinality Filtering (whereLength)
Write-Host "  -> Op 11: Array Length Filtering (whereLength)..." -NoNewline
$m_p1_pslb_len = Measure-Op "PSLB Disk whereLength" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").whereLength("tags", ">=", 3).count()
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_len.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_len = Measure-Op "JSON Disk Array Length" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $cnt = 0
    foreach ($item in $items) {
        if ($item.tags.Count -ge 3) { $cnt++ }
    }
    $cnt
}
Write-Host " Flat JSON: $($m_p1_json_len.DurationMs) ms" -ForegroundColor Magenta

# Op 12: Instant Existence Verification (.exists())
Write-Host "  -> Op 12: Instant Existence Check (.exists())..." -NoNewline
$m_p1_pslb_exists = Measure-Op "PSLB Disk exists" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        $db.collection("users").where("city", "=", "Tokyo").exists()
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_exists.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_exists = Measure-Op "JSON Disk Exists" {
    $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
    $items = ConvertFrom-Json -InputObject $raw
    $found = $false
    foreach ($item in $items) {
        if ($item.city -eq "Tokyo") { $found = $true; break }
    }
    $found
}
Write-Host " Flat JSON: $($m_p1_json_exists.DurationMs) ms" -ForegroundColor Magenta

# Op 13: Atomic Upsert (.upsert() on 10 records)
$upsertKeys = 1..10 | ForEach-Object { "usr-$((($_ * 101) % $RecordCount) + 1)" }
Write-Host "  -> Op 13: Atomic Upsert (10 records on disk)..." -NoNewline
$m_p1_pslb_upsert = Measure-Op "PSLB Disk Upsert" {
    $db = [PSLocalBase]::new($dbPathDisk)
    try {
        foreach ($k in $upsertKeys) {
            $db.collection("users").upsert(@{ id = $k; score = 99; status = "upserted" }, $k)
        }
    } finally {
        $db.close()
    }
}
Write-Host " PSLB: $($m_p1_pslb_upsert.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p1_json_upsert = Measure-Op "JSON Disk Upsert" {
    foreach ($k in $upsertKeys) {
        $raw = [System.IO.File]::ReadAllText($jsonPathDisk, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $raw
        $found = $false
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($items[$j].id -eq $k) {
                $items[$j].score = 99
                $items[$j] | Add-Member -MemberType NoteProperty -Name "status" -Value "upserted" -Force
                $found = $true
                break
            }
        }
        if (-not $found) {
            $items += [PSCustomObject]@{ id = $k; score = 99; status = "upserted" }
        }
        $updatedJson = ConvertTo-Json -InputObject $items -Compress -Depth 10
        [System.IO.File]::WriteAllText($jsonPathDisk, $updatedJson, [System.Text.Encoding]::UTF8)
    }
}
Write-Host " Flat JSON: $($m_p1_json_upsert.DurationMs) ms" -ForegroundColor Magenta

# ===========================================================================
# PART 2: IN-MEMORY ENGINE + LOCAL DISK SYNC BENCHMARK (10,000 Records)
# ===========================================================================
Write-Host "`n>>> [PART 2] IN-MEMORY ENGINE & LOCAL DISK SYNC (10,000 Records)" -ForegroundColor Green
$syncDbTarget = Join-Path $benchDir "synced_mem_10k.db"
$syncJsonTarget = Join-Path $benchDir "synced_mem_10k.json"

# In-Memory Initialization
Write-Host "  -> Op 1: Loading 10,000 records into RAM..." -NoNewline
$memDb = [PSLocalBase]::new(":memory:")
$m_p2_pslb_load = Measure-Op "PSLB Mem Load" {
    $memDb.collection("users").set($usersData)
}
Write-Host " PSLB: $($m_p2_pslb_load.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$memJsonList = $null
$m_p2_json_load = Measure-Op "JSON Mem Load" {
    $script:memJsonList = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $usersData) {
        $script:memJsonList.Add([PSCustomObject]$item)
    }
}
Write-Host " Flat JSON: $($m_p2_json_load.DurationMs) ms" -ForegroundColor Magenta

# In-Memory 100 Point Lookups
Write-Host "  -> Op 2: In-Memory 100 Point Lookups..." -NoNewline
$m_p2_pslb_lookup = Measure-Op "PSLB Mem Lookups" {
    $found = 0
    foreach ($k in $lookupKeys) {
        $doc = $memDb.collection("users").doc($k).get()
        if ($null -ne $doc) { $found++ }
    }
    $found
}
Write-Host " PSLB: $($m_p2_pslb_lookup.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_lookup = Measure-Op "JSON Mem Lookups" {
    $found = 0
    foreach ($k in $lookupKeys) {
        for ($j = 0; $j -lt $memJsonList.Count; $j++) {
            if ($memJsonList[$j].id -eq $k) {
                $found++
                break
            }
        }
    }
    $found
}
Write-Host " Flat JSON: $($m_p2_json_lookup.DurationMs) ms" -ForegroundColor Magenta

# In-Memory Filter Query
Write-Host "  -> Op 3: In-Memory Filter (active = true AND score >= 80)..." -NoNewline
$m_p2_pslb_query = Measure-Op "PSLB Mem Filter" {
    $memDb.collection("users").where("active", "=", $true).where("score", ">=", 80).get().Count
}
Write-Host " PSLB: $($m_p2_pslb_query.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_query = Measure-Op "JSON Mem Filter" {
    $cnt = 0
    foreach ($item in $memJsonList) {
        if ($item.active -eq $true -and $item.score -ge 80) { $cnt++ }
    }
    $cnt
}
Write-Host " Flat JSON: $($m_p2_json_query.DurationMs) ms" -ForegroundColor Magenta

# In-Memory Sorting & Pagination
Write-Host "  -> Op 4: In-Memory Sort & Limit (Top 10 DESC)..." -NoNewline
$m_p2_pslb_sort = Measure-Op "PSLB Mem Sort" {
    $memDb.collection("users").orderBy("score", "desc").limit(10).get().Count
}
Write-Host " PSLB: $($m_p2_pslb_sort.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_sort = Measure-Op "JSON Mem Sort" {
    ($memJsonList | Sort-Object -Property score -Descending | Select-Object -First 10 | Measure-Object).Count
}
Write-Host " Flat JSON: $($m_p2_json_sort.DurationMs) ms" -ForegroundColor Magenta

# In-Memory Scalar Count
Write-Host "  -> Op 5: In-Memory Aggregate Count (Engineering)..." -NoNewline
$m_p2_pslb_count = Measure-Op "PSLB Mem Count" {
    $memDb.collection("users").where("department", "=", "Engineering").count()
}
Write-Host " PSLB: $($m_p2_pslb_count.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_count = Measure-Op "JSON Mem Count" {
    $cnt = 0
    foreach ($item in $memJsonList) {
        if ($item.department -eq "Engineering") { $cnt++ }
    }
    $cnt
}
Write-Host " Flat JSON: $($m_p2_json_count.DurationMs) ms" -ForegroundColor Magenta

# In-Memory 100 Mutations / Updates
$memUpdateKeys = 1..100 | ForEach-Object { "usr-$((($_ * 89) % $RecordCount) + 1)" }
Write-Host "  -> Op 6: In-Memory 100 Partial Updates..." -NoNewline
$m_p2_pslb_update = Measure-Op "PSLB Mem 100 Updates" {
    foreach ($k in $memUpdateKeys) {
        $memDb.collection("users").doc($k).update(@{
            lastLogin = (Get-Date).ToString("o")
            status    = "verified"
        })
    }
}
Write-Host " PSLB: $($m_p2_pslb_update.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_update = Measure-Op "JSON Mem 100 Updates" {
    foreach ($k in $memUpdateKeys) {
        for ($j = 0; $j -lt $memJsonList.Count; $j++) {
            if ($memJsonList[$j].id -eq $k) {
                $memJsonList[$j] | Add-Member -MemberType NoteProperty -Name "lastLogin" -Value (Get-Date).ToString("o") -Force
                $memJsonList[$j] | Add-Member -MemberType NoteProperty -Name "status" -Value "verified" -Force
                break
            }
        }
    }
}
Write-Host " Flat JSON: $($m_p2_json_update.DurationMs) ms" -ForegroundColor Magenta

# Op 7: Sync In-Memory State to Persistent Local Disk
Write-Host "  -> Op 7: SYNC IN-MEMORY STATE TO LOCAL DISK (10,000 Records)..." -NoNewline
if (Test-Path $syncDbTarget) { Remove-Item $syncDbTarget -Force }
$m_p2_pslb_sync = Measure-Op "PSLB VACUUM INTO Sync" {
    $escaped = $syncDbTarget -replace "'", "''"
    $memDb._ExecuteDirectSql("VACUUM INTO '$escaped';")
}
Write-Host " PSLB (VACUUM INTO): $($m_p2_pslb_sync.DurationMs) ms |" -ForegroundColor Cyan -NoNewline

$m_p2_json_sync = Measure-Op "JSON Disk Serialization Sync" {
    $jsonText = ConvertTo-Json -InputObject $memJsonList -Compress -Depth 10
    [System.IO.File]::WriteAllText($syncJsonTarget, $jsonText, [System.Text.Encoding]::UTF8)
}
Write-Host " Flat JSON (Serialize & Write): $($m_p2_json_sync.DurationMs) ms" -ForegroundColor Magenta

# Cleanup In-Memory DB
$memDb.close()

# ---------------------------------------------------------------------------
# Storage & Disk Metrics
# ---------------------------------------------------------------------------
$p1DbSizeKB = [math]::Round((Get-Item $dbPathDisk).Length / 1KB, 2)
$p1JsonSizeKB = [math]::Round((Get-Item $jsonPathDisk).Length / 1KB, 2)

$p2DbSizeKB = [math]::Round((Get-Item $syncDbTarget).Length / 1KB, 2)
$p2JsonSizeKB = [math]::Round((Get-Item $syncJsonTarget).Length / 1KB, 2)

$swTotal.Stop()
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " 10,000 Records Benchmark Completed in $([math]::Round($swTotal.Elapsed.TotalSeconds, 2))s" -ForegroundColor Cyan
Write-Host " Part 1 Disk DB Size: $p1DbSizeKB KB | Part 1 JSON Size: $p1JsonSizeKB KB" -ForegroundColor DarkGray
Write-Host " Part 2 Synced DB Size: $p2DbSizeKB KB | Part 2 Synced JSON Size: $p2JsonSizeKB KB" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

# Structure Output Data
$finalReport = [ordered]@{
    Metadata = @{
        Date              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TotalRecords      = $RecordCount
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OS                = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    Part1_PersistentDisk = @(
        @{
            Operation     = "Bulk Ingestion (10,000 docs to disk)"
            PSLocalBaseMs = $m_p1_pslb_insert.DurationMs
            FlatJsonMs    = $m_p1_json_insert.DurationMs
            Speedup       = [math]::Round($m_p1_json_insert.DurationMs / [math]::Max(0.01, $m_p1_pslb_insert.DurationMs), 2)
            Winner        = if ($m_p1_pslb_insert.DurationMs -le $m_p1_json_insert.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Point Lookups (100 random IDs on disk)"
            PSLocalBaseMs = $m_p1_pslb_lookup.DurationMs
            FlatJsonMs    = $m_p1_json_lookup.DurationMs
            Speedup       = [math]::Round($m_p1_json_lookup.DurationMs / [math]::Max(0.01, $m_p1_pslb_lookup.DurationMs), 2)
            Winner        = if ($m_p1_pslb_lookup.DurationMs -le $m_p1_json_lookup.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Multi-filter Query (active AND score >= 80)"
            PSLocalBaseMs = $m_p1_pslb_query.DurationMs
            FlatJsonMs    = $m_p1_json_query.DurationMs
            Speedup       = [math]::Round($m_p1_json_query.DurationMs / [math]::Max(0.01, $m_p1_pslb_query.DurationMs), 2)
            Winner        = if ($m_p1_pslb_query.DurationMs -le $m_p1_json_query.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Sorting & Pagination (Top 10 DESC)"
            PSLocalBaseMs = $m_p1_pslb_sort.DurationMs
            FlatJsonMs    = $m_p1_json_sort.DurationMs
            Speedup       = [math]::Round($m_p1_json_sort.DurationMs / [math]::Max(0.01, $m_p1_pslb_sort.DurationMs), 2)
            Winner        = if ($m_p1_pslb_sort.DurationMs -le $m_p1_json_sort.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Scalar Aggregate Count (Engineering)"
            PSLocalBaseMs = $m_p1_pslb_count.DurationMs
            FlatJsonMs    = $m_p1_json_count.DurationMs
            Speedup       = [math]::Round($m_p1_json_count.DurationMs / [math]::Max(0.01, $m_p1_pslb_count.DurationMs), 2)
            Winner        = if ($m_p1_pslb_count.DurationMs -le $m_p1_json_count.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Partial Updates (10 docs on disk)"
            PSLocalBaseMs = $m_p1_pslb_update.DurationMs
            FlatJsonMs    = $m_p1_json_update.DurationMs
            Speedup       = [math]::Round($m_p1_json_update.DurationMs / [math]::Max(0.01, $m_p1_pslb_update.DurationMs), 2)
            Winner        = if ($m_p1_pslb_update.DurationMs -le $m_p1_json_update.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Individual Deletions (10 docs on disk)"
            PSLocalBaseMs = $m_p1_pslb_delete.DurationMs
            FlatJsonMs    = $m_p1_json_delete.DurationMs
            Speedup       = [math]::Round($m_p1_json_delete.DurationMs / [math]::Max(0.01, $m_p1_pslb_delete.DurationMs), 2)
            Winner        = if ($m_p1_pslb_delete.DurationMs -le $m_p1_json_delete.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Dual Collection Relational JOIN (5k orders x 5k users)"
            PSLocalBaseMs = $m_p1_pslb_join.DurationMs
            FlatJsonMs    = $m_p1_json_join.DurationMs
            Speedup       = [math]::Round($m_p1_json_join.DurationMs / [math]::Max(0.01, $m_p1_pslb_join.DurationMs), 2)
            Winner        = if ($m_p1_pslb_join.DurationMs -le $m_p1_json_join.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Engine Mathematical Sum (.sum())"
            PSLocalBaseMs = $m_p1_pslb_sum.DurationMs
            FlatJsonMs    = $m_p1_json_sum.DurationMs
            Speedup       = [math]::Round($m_p1_json_sum.DurationMs / [math]::Max(0.01, $m_p1_pslb_sum.DurationMs), 2)
            Winner        = if ($m_p1_pslb_sum.DurationMs -le $m_p1_json_sum.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Selective Field Projection (.select() 100 docs)"
            PSLocalBaseMs = $m_p1_pslb_select.DurationMs
            FlatJsonMs    = $m_p1_json_select.DurationMs
            Speedup       = [math]::Round($m_p1_json_select.DurationMs / [math]::Max(0.01, $m_p1_pslb_select.DurationMs), 2)
            Winner        = if ($m_p1_pslb_select.DurationMs -le $m_p1_json_select.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Array Length Filtering (whereLength)"
            PSLocalBaseMs = $m_p1_pslb_len.DurationMs
            FlatJsonMs    = $m_p1_json_len.DurationMs
            Speedup       = [math]::Round($m_p1_json_len.DurationMs / [math]::Max(0.01, $m_p1_pslb_len.DurationMs), 2)
            Winner        = if ($m_p1_pslb_len.DurationMs -le $m_p1_json_len.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Instant Existence Check (.exists())"
            PSLocalBaseMs = $m_p1_pslb_exists.DurationMs
            FlatJsonMs    = $m_p1_json_exists.DurationMs
            Speedup       = [math]::Round($m_p1_json_exists.DurationMs / [math]::Max(0.01, $m_p1_pslb_exists.DurationMs), 2)
            Winner        = if ($m_p1_pslb_exists.DurationMs -le $m_p1_json_exists.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "Atomic Upsert (10 records on disk)"
            PSLocalBaseMs = $m_p1_pslb_upsert.DurationMs
            FlatJsonMs    = $m_p1_json_upsert.DurationMs
            Speedup       = [math]::Round($m_p1_json_upsert.DurationMs / [math]::Max(0.01, $m_p1_pslb_upsert.DurationMs), 2)
            Winner        = if ($m_p1_pslb_upsert.DurationMs -le $m_p1_json_upsert.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        }
    )
    Part2_InMemoryAndSync = @(
        @{
            Operation     = "In-Memory Ingestion (10,000 docs)"
            PSLocalBaseMs = $m_p2_pslb_load.DurationMs
            FlatJsonMs    = $m_p2_json_load.DurationMs
            Speedup       = [math]::Round($m_p2_json_load.DurationMs / [math]::Max(0.01, $m_p2_pslb_load.DurationMs), 2)
            Winner        = if ($m_p2_pslb_load.DurationMs -le $m_p2_json_load.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Memory Point Lookups (100 random IDs)"
            PSLocalBaseMs = $m_p2_pslb_lookup.DurationMs
            FlatJsonMs    = $m_p2_json_lookup.DurationMs
            Speedup       = [math]::Round($m_p2_json_lookup.DurationMs / [math]::Max(0.01, $m_p2_pslb_lookup.DurationMs), 2)
            Winner        = if ($m_p2_pslb_lookup.DurationMs -le $m_p2_json_lookup.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Memory Multi-filter Query"
            PSLocalBaseMs = $m_p2_pslb_query.DurationMs
            FlatJsonMs    = $m_p2_json_query.DurationMs
            Speedup       = [math]::Round($m_p2_json_query.DurationMs / [math]::Max(0.01, $m_p2_pslb_query.DurationMs), 2)
            Winner        = if ($m_p2_pslb_query.DurationMs -le $m_p2_json_query.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Memory Sorting & Pagination (Top 10)"
            PSLocalBaseMs = $m_p2_pslb_sort.DurationMs
            FlatJsonMs    = $m_p2_json_sort.DurationMs
            Speedup       = [math]::Round($m_p2_json_sort.DurationMs / [math]::Max(0.01, $m_p2_pslb_sort.DurationMs), 2)
            Winner        = if ($m_p2_pslb_sort.DurationMs -le $m_p2_json_sort.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Memory Aggregate Count (WHERE + count)"
            PSLocalBaseMs = $m_p2_pslb_count.DurationMs
            FlatJsonMs    = $m_p2_json_count.DurationMs
            Speedup       = [math]::Round($m_p2_json_count.DurationMs / [math]::Max(0.01, $m_p2_pslb_count.DurationMs), 2)
            Winner        = if ($m_p2_pslb_count.DurationMs -le $m_p2_json_count.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "In-Memory 100 Document Updates"
            PSLocalBaseMs = $m_p2_pslb_update.DurationMs
            FlatJsonMs    = $m_p2_json_update.DurationMs
            Speedup       = [math]::Round($m_p2_json_update.DurationMs / [math]::Max(0.01, $m_p2_pslb_update.DurationMs), 2)
            Winner        = if ($m_p2_pslb_update.DurationMs -le $m_p2_json_update.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        },
        @{
            Operation     = "SYNC TO DISK (10,000 Records Flush)"
            PSLocalBaseMs = $m_p2_pslb_sync.DurationMs
            FlatJsonMs    = $m_p2_json_sync.DurationMs
            Speedup       = [math]::Round($m_p2_json_sync.DurationMs / [math]::Max(0.01, $m_p2_pslb_sync.DurationMs), 2)
            Winner        = if ($m_p2_pslb_sync.DurationMs -le $m_p2_json_sync.DurationMs) { "PSLocalBase" } else { "Flat JSON" }
        }
    )
    StorageMetrics = @{
        Part1_PSLocalBaseDiskKB = $p1DbSizeKB
        Part1_FlatJsonDiskKB    = $p1JsonSizeKB
        Part2_SyncedDbKB        = $p2DbSizeKB
        Part2_SyncedJsonKB      = $p2JsonSizeKB
    }
}

$summaryPath = Join-Path $benchDir "benchmark_10k_summary.json"
$finalReport | ConvertTo-Json -Depth 6 | Set-Content $summaryPath -Encoding UTF8
Write-Host "Summary JSON exported to: $summaryPath" -ForegroundColor Green

return $finalReport
