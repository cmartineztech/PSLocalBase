# ===========================================================================
# PSLocalBase Multi-Collection Stress & Benchmark Test
# Validates multiple independent collections in a single database
# ===========================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::new()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PSLocalBase Multi-Collection Stress Test" -ForegroundColor Cyan
Write-Host " Testing 4 distinct collections concurrently" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# Import Module
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "PSLocalBase.psd1"
Import-Module $modulePath -Force

$dbFile = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_multicoll_$([Guid]::NewGuid().ToString('N')).db"
$db = [PSLocalBase]::new($dbFile)

try {
    # -----------------------------------------------------------------------
    # 1. Bulk insertion across 4 separate collections
    # -----------------------------------------------------------------------
    Write-Host "`n[1/5] Inserting data across 4 distinct collections in a single transaction..." -ForegroundColor Cyan
    
    $sw.Restart()
    $db.beginTransaction()

    # Collection 1: Users (3,000 records)
    for ($i = 1; $i -le 3000; $i++) {
        $db.collection("users").doc("usr-$i").set(@{
            id       = $i
            username = "user_$i"
            tier     = $(if ($i % 5 -eq 0) { "Premium" } else { "Free" })
            country  = @("ES", "US", "UK", "MX", "DE")[$i % 5]
        })
    }

    # Collection 2: Products (2,000 records)
    for ($p = 1; $p -le 2000; $p++) {
        $db.collection("products").doc("prod-$p").set(@{
            sku      = "SKU-$p"
            category = @("Electronics", "Home", "Books", "Clothing")[$p % 4]
            price    = [Math]::Round((10 + ($p * 1.5)), 2)
            inStock  = ($p % 2 -eq 0)
        })
    }

    # Collection 3: Orders (5,000 records)
    for ($o = 1; $o -le 5000; $o++) {
        $db.collection("orders").doc("ord-$o").set(@{
            orderId = "ORD-$o"
            userId  = "usr-$((($o * 7) % 3000) + 1)"
            total   = [Math]::Round((25 + ($o * 0.8)), 2)
            status  = @("Pending", "Shipped", "Delivered", "Cancelled")[$o % 4]
        })
    }

    # Collection 4: System Event Logs (10,000 records using .add())
    for ($l = 1; $l -le 10000; $l++) {
        [void]$db.collection("system_logs").add(@{
            severity  = @("INFO", "WARN", "ERROR")[$l % 3]
            component = @("Auth", "API", "Billing", "Worker")[$l % 4]
            code      = 100 + ($l % 20)
        })
    }

    $db.commit()
    $sw.Stop()

    $totalDocs = 3000 + 2000 + 5000 + 10000 # 20,000 documents
    $elapsedMs = $sw.ElapsedMilliseconds
    Write-Host "  -> Successfully inserted $totalDocs documents across 4 collections in: $elapsedMs ms" -ForegroundColor Green
    Write-Host "  -> Global throughput: $([Math]::Round($totalDocs / ($elapsedMs / 1000), 2)) operations/sec" -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 2. Query each collection independently to verify isolation
    # -----------------------------------------------------------------------
    Write-Host "`n[2/5] Querying each collection independently to verify schema isolation..." -ForegroundColor Cyan

    $uCount = ($db.collection("users").get()).Count
    $pCount = ($db.collection("products").get()).Count
    $oCount = ($db.collection("orders").get()).Count
    $lCount = ($db.collection("system_logs").get()).Count

    Write-Host "  -> Collection 'users':       $uCount records (Expected: 3,000)" -ForegroundColor White
    Write-Host "  -> Collection 'products':    $pCount records (Expected: 2,000)" -ForegroundColor White
    Write-Host "  -> Collection 'orders':      $oCount records (Expected: 5,000)" -ForegroundColor White
    Write-Host "  -> Collection 'system_logs': $lCount records (Expected: 10,000)" -ForegroundColor White

    if ($uCount -ne 3000 -or $pCount -ne 2000 -or $oCount -ne 5000 -or $lCount -ne 10000) {
        throw "Collection isolation count check failed!"
    }

    # -----------------------------------------------------------------------
    # 3. Targeted queries on specific collections
    # -----------------------------------------------------------------------
    Write-Host "`n[3/5] Executing targeted queries across specific collections..." -ForegroundColor Cyan

    $sw.Restart()
    $premiumUsers = $db.collection("users").where("tier", "=", "Premium").get()
    $sw.Stop()
    Write-Host "  -> Queried $($premiumUsers.Count) Premium users in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    $sw.Restart()
    $expensiveProducts = $db.collection("products").where("price", ">=", 1000).orderBy("price", "desc").limit(5).get()
    $sw.Stop()
    Write-Host "  -> Queried top 5 most expensive products in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    $sw.Restart()
    $shippedOrders = $db.collection("orders").where("status", "=", "Shipped").get()
    $sw.Stop()
    Write-Host "  -> Queried $($shippedOrders.Count) Shipped orders in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 4. Independent collection deletion
    # -----------------------------------------------------------------------
    Write-Host "`n[4/5] Testing independent collection deletion (dropping table without affecting others)..." -ForegroundColor Cyan

    # Drop only system_logs
    $db.collection("system_logs").delete()
    Write-Host "  -> Dropped collection 'system_logs'" -ForegroundColor Yellow

    # Verify other collections are untouched
    $remainingUsers = ($db.collection("users").get()).Count
    $remainingOrders = ($db.collection("orders").get()).Count
    $remainingProducts = ($db.collection("products").get()).Count
    $remainingLogs = ($db.collection("system_logs").get()).Count

    Write-Host "  -> Collection 'users' remaining:       $remainingUsers (untouched)" -ForegroundColor Green
    Write-Host "  -> Collection 'orders' remaining:      $remainingOrders (untouched)" -ForegroundColor Green
    Write-Host "  -> Collection 'products' remaining:    $remainingProducts (untouched)" -ForegroundColor Green
    Write-Host "  -> Collection 'system_logs' remaining: $remainingLogs (successfully dropped)" -ForegroundColor Green

    if ($remainingUsers -ne 3000 -or $remainingOrders -ne 5000 -or $remainingProducts -ne 2000 -or $remainingLogs -ne 0) {
        throw "Independent collection deletion check failed!"
    }

    # -----------------------------------------------------------------------
    # 5. Disk size and cleanup
    # -----------------------------------------------------------------------
    $fileSizeMB = [Math]::Round(((Get-Item $dbFile).Length / 1MB), 2)
    Write-Host "`n[5/5] Database file size with remaining 10,000 records: $fileSizeMB MB" -ForegroundColor Cyan

} finally {
    $db.deleteDatabase()
    Write-Host "  -> Database deleted cleanly from disk." -ForegroundColor DarkGray
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Multi-Collection Test Passed Successfully!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
