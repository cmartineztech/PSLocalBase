# ===========================================================================
# PSLocalBase High-Volume Multi-Operation Stress & Benchmark Test
# ===========================================================================

[CmdletBinding()]
param(
    [int]$TotalRecords = 10000
)

$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::new()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PSLocalBase High-Volume Stress & Benchmark Test" -ForegroundColor Cyan
Write-Host " Target Record Count: $TotalRecords" -ForegroundColor Yellow
Write-Host " PowerShell Version:  $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

# Import Module
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "PSLocalBase.psd1"
Import-Module $modulePath -Force

$dbFile = Join-Path ([System.IO.Path]::GetTempPath()) "pslocalbase_stress_$([Guid]::NewGuid().ToString('N')).db"
$db = [PSLocalBase]::new($dbFile)

try {
    # -----------------------------------------------------------------------
    # 1. BULK INSERTION (10,000 complex JSON documents)
    # -----------------------------------------------------------------------
    Write-Host "`n[1/7] Bulk Inserting $TotalRecords complex documents within a transaction..." -ForegroundColor Cyan
    $departments = @("Engineering", "Finance", "HumanResources", "Sales", "Marketing", "Legal", "Operations")
    $roles = @("Junior", "Mid", "Senior", "Lead", "Manager", "Director")
    $cities = @("Madrid", "London", "New York", "Tokyo", "Berlin", "Paris", "Toronto")

    $sw.Restart()
    $db.beginTransaction()

    for ($i = 1; $i -le $TotalRecords; $i++) {
        $dept = $departments[$i % $departments.Count]
        $role = $roles[$i % $roles.Count]
        $city = $cities[$i % $cities.Count]
        $salary = 40000 + (($i * 17) % 110000)
        $active = ($i % 3 -ne 0) # ~66% active

        $db.collection("employees").doc("emp-$i").set(@{
                id         = $i
                name       = "Employee_$i"
                email      = "emp$i@enterprise.corp"
                department = $dept
                role       = $role
                salary     = $salary
                active     = $active
                profile    = @{
                    city       = $city
                    experience = ($i % 15) + 1
                }
                tags       = @("staff", $dept.ToLower(), $role.ToLower())
            })
    }

    $db.commit()
    $sw.Stop()

    $insertElapsedMs = $sw.ElapsedMilliseconds
    $insertRate = [Math]::Round($TotalRecords / ($insertElapsedMs / 1000), 2)
    Write-Host "  -> Inserted $TotalRecords documents in: $insertElapsedMs ms" -ForegroundColor Green
    Write-Host "  -> Throughput: $insertRate operations/sec" -ForegroundColor Green

    $dbSize = (Get-Item $dbFile).Length / 1MB
    Write-Host "  -> Database File Size on disk: $([Math]::Round($dbSize, 2)) MB" -ForegroundColor DarkGray

    # -----------------------------------------------------------------------
    # 2. RANDOM POINT LOOKUPS (.doc('key').get())
    # -----------------------------------------------------------------------
    $lookupCount = 1000
    Write-Host "`n[2/7] Performing $lookupCount random point lookups by primary key..." -ForegroundColor Cyan
    $sw.Restart()

    for ($k = 0; $k -lt $lookupCount; $k++) {
        $randId = Get-Random -Minimum 1 -Maximum ($TotalRecords + 1)
        $doc = $db.collection("employees").doc("emp-$randId").get()
        if ($null -eq $doc -or $doc.id -ne $randId) {
            throw "Point lookup failed for key: emp-$randId"
        }
    }

    $sw.Stop()
    $lookupElapsedMs = $sw.ElapsedMilliseconds
    $avgLookupLatency = [Math]::Round(($lookupElapsedMs / $lookupCount), 4)
    Write-Host "  -> Executed $lookupCount random lookups in: $lookupElapsedMs ms" -ForegroundColor Green
    Write-Host "  -> Average Latency per lookup: $avgLookupLatency ms ($([Math]::Round(1000 / $avgLookupLatency, 2)) reads/sec)" -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 3. FILTERING WITH NATIVE JSON_EXTRACT (.where(...).get())
    # -----------------------------------------------------------------------
    Write-Host "`n[3/7] Running complex JSON queries across all $TotalRecords records..." -ForegroundColor Cyan

    # Query A: Boolean filter
    $sw.Restart()
    $activeEmployees = $db.collection("employees").where("active", "=", $true).get()
    $sw.Stop()
    Write-Host "  -> [Query A] Boolean active=true: Found $($activeEmployees.Count) records in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # Query B: Number comparison
    $sw.Restart()
    $highEarners = $db.collection("employees").where("salary", ">=", 100000).get()
    $sw.Stop()
    Write-Host "  -> [Query B] Numeric salary >= 100,000: Found $($highEarners.Count) records in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # Query C: Chained multi-field filter
    $sw.Restart()
    $topEngineers = $db.collection("employees").where("department", "=", "Engineering").where("active", "=", $true).where("salary", ">=", 80000).get()
    $sw.Stop()
    Write-Host "  -> [Query C] Compound filter (dept=Engineering AND active=true AND salary>=80k): Found $($topEngineers.Count) records in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # Query D: IN Operator
    $sw.Restart()
    $management = $db.collection("employees").where("role", "IN", @("Lead", "Manager", "Director")).get()
    $sw.Stop()
    Write-Host "  -> [Query D] IN filter (role IN ['Lead', 'Manager', 'Director']): Found $($management.Count) records in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 4. ORDER BY & PAGINATION / LIMIT
    # -----------------------------------------------------------------------
    Write-Host "`n[4/7] Testing Sorting (orderBy) and Limits..." -ForegroundColor Cyan
    $sw.Restart()
    $topPaid = $db.collection("employees").orderBy("salary", "desc").limit(5).get()
    $sw.Stop()
    Write-Host "  -> Top 5 highest paid employees (retrieved in $($sw.ElapsedMilliseconds) ms):" -ForegroundColor Green
    foreach ($emp in $topPaid) {
        Write-Host "     * $($emp.name) | Dept: $($emp.department) | Salary: `$$($emp.salary)" -ForegroundColor White
    }

    # -----------------------------------------------------------------------
    # 5. PARTIAL UPDATES (.update() with recursive merge)
    # -----------------------------------------------------------------------
    $updateCount = 1000
    Write-Host "`n[5/7] Executing $updateCount deep recursive partial updates..." -ForegroundColor Cyan
    $sw.Restart()
    $db.beginTransaction()

    for ($u = 1; $u -le $updateCount; $u++) {
        $db.collection("employees").doc("emp-$u").update(@{
                salary   = 150000
                promoted = $true
                profile  = @{
                    city = "Zurich" # updates city, preserves experience
                }
            })
    }

    $db.commit()
    $sw.Stop()

    $updateElapsedMs = $sw.ElapsedMilliseconds
    Write-Host "  -> Updated $updateCount records in: $updateElapsedMs ms ($([Math]::Round($updateCount / ($updateElapsedMs / 1000), 2)) updates/sec)" -ForegroundColor Green

    # Verify deep merge integrity on updated record
    $checkEmp = $db.collection("employees").doc("emp-1").get()
    if ($checkEmp.salary -ne 150000 -or $checkEmp.promoted -ne $true -or $checkEmp.profile.city -ne "Zurich" -or $checkEmp.profile.experience -ne 2) {
        throw "Deep merge integrity check failed on emp-1"
    }
    Write-Host "  -> Deep merge verification passed (city updated, experience preserved, non-updated fields intact)." -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 6. GET WITH KEYS (.get({ keys = $true }))
    # -----------------------------------------------------------------------
    Write-Host "`n[6/7] Retrieving documents with explicit SQLite keys metadata..." -ForegroundColor Cyan
    $sw.Restart()
    $keyedSample = $db.collection("employees").limit(3).get(@{ keys = $true })
    $sw.Stop()
    Write-Host "  -> Key metadata verification (retrieved in $($sw.ElapsedMilliseconds) ms):" -ForegroundColor Green
    foreach ($item in $keyedSample) {
        Write-Host "     * Key: $($item.key) -> Data Name: $($item.data.name)" -ForegroundColor White
    }

    # -----------------------------------------------------------------------
    # 7. FILTERED DELETION & ATOMIC CLEANUP
    # -----------------------------------------------------------------------
    Write-Host "`n[7/7] Testing filtered and point deletions..." -ForegroundColor Cyan
    $sw.Restart()
    $db.collection("employees").where("active", "=", $false).delete()
    $sw.Stop()
    Write-Host "  -> Bulk deleted all inactive employees in $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    $remainingCount = ($db.collection("employees").get()).Count
    Write-Host "  -> Remaining active employees in collection: $remainingCount" -ForegroundColor Green

}
finally {
    # Clean up database
    $db.deleteDatabase()
    Write-Host "`n[Clean Up] Database and WAL/SHM files deleted cleanly from disk." -ForegroundColor Cyan
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Stress & Benchmark Test Completed Successfully!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
