Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

$parentDir = Split-Path $PSScriptRoot -Parent
if (-not $parentDir) { $parentDir = (Get-Location).Path }
$modulePsd1 = Join-Path $parentDir "PSLocalBase.psd1"
Import-Module $modulePsd1 -Force

$testDbPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pg_verify_" + [System.Guid]::NewGuid().ToString("N") + ".db")
$script:db = [PSLocalBase]::new($testDbPath, @{ cacheSizeMB = 32; wal = $true; depth = 20 })

try {
    # 1. Parse and compile Playground.ps1 AST
    $errs = $null
    $playgroundScript = Join-Path $parentDir "Playground\Playground.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($playgroundScript, [ref]$null, [ref]$errs)
    if ($errs) {
        throw "Syntax error in Playground.ps1: $($errs -join '; ')"
    }
    Write-Host "[PASS] 1. Syntax & AST verification succeeded." -ForegroundColor Green

    # 2. Extract and load XAML
    $content = Get-Content -Path $playgroundScript -Raw
    $startToken = '$xaml = @"'
    $endToken = '"@'
    $startIdx = $content.IndexOf($startToken) + $startToken.Length
    $endIdx = $content.IndexOf($endToken, $startIdx)
    $xaml = $content.Substring($startIdx, $endIdx - $startIdx).Trim()

    $xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Dispose()
    Write-Host "[PASS] 2. WPF XAML parsed and Window instance instantiated." -ForegroundColor Green

    # 3. Verify all named elements
    $requiredElements = @(
        'btnNavAdd', 'btnNavGet', 'btnNavUpdate', 'btnNavDelete', 'btnNavCustom',
        'btnSeedDemo', 'btnCheckpointWal', 'btnResetDatabase',
        'lblCategoryTitle', 'cmbLeftCollection', 'cmbRightCollection', 'txtKeySearch',
        'card1', 'card2', 'card3',
        'lblCard1Title', 'lblCard2Title', 'lblCard3Title',
        'txtCodeCard1', 'txtCodeCard2', 'txtCodeCard3',
        'btnRunCard1', 'btnRunCard2', 'btnRunCard3',
        'lblCard1Status', 'lblCard2Status', 'lblCard3Status',
        'dgDocuments', 'lblTotalEntries', 'lblDbMetrics',
        'btnRefreshTable', 'btnClearCollection', 'btnDeleteDoc',
        'panelConsoleLogs', 'scrollConsole', 'btnClearLogs',
        'txtConsoleInput', 'txtConsolePerf', 'txtStatusBadge',
        'txtStatusMsg', 'txtMemoryUsage'
    )
    foreach ($elemName in $requiredElements) {
        $found = $window.FindName($elemName)
        if ($null -eq $found) {
            throw "UI Element '$elemName' is missing from XAML!"
        }
    }
    Write-Host "[PASS] 3. All $($requiredElements.Count) UI elements resolved correctly." -ForegroundColor Green

    # 4. Verify seeding
    $script:db.collection("users").add(@{ id = 1; name = "Bill"; age = 47 }) | Out-Null
    $script:db.collection("users").add(@{ id = 2; name = "Paul"; age = 34 }) | Out-Null
    $script:db.collection("products").add(@{ sku = "TEST-01"; title = "Test Laptop"; price = 999 }) | Out-Null
    $script:db.collection("orders").add(@{ orderId = "ORD-99"; total = 999 }) | Out-Null

    $colls = @($script:db.listCollections())
    if ($colls.Count -lt 3) {
        throw "Expected at least 3 collections, got $($colls.Count)"
    }
    Write-Host "[PASS] 4. Multi-collection seeding verified ($($colls -join ', '))." -ForegroundColor Green

    # 5. Verify queries, updates and deletes
    $retrieved = $script:db.collection("users").where("age", ">=", 40).get()
    if ($retrieved.name -ne "Bill") {
        throw "Failed where query filter"
    }

    $script:db.collection("users").doc("test-custom").set(@{ name = "Custom"; role = "Dev" })
    $doc = $script:db.collection("users").doc("test-custom").get()
    if ($doc.name -ne "Custom") {
        throw "Failed set with custom key"
    }

    $script:db.collection("users").doc("test-custom").update(@{ role = "Senior Dev" })
    $updated = $script:db.collection("users").doc("test-custom").get()
    if ($updated.role -ne "Senior Dev" -or $updated.name -ne "Custom") {
        throw "Failed update deep merge"
    }

    $script:db.collection("users").doc("test-custom").delete()
    if ($null -ne $script:db.collection("users").doc("test-custom").get()) {
        throw "Failed delete doc"
    }
    Write-Host "[PASS] 5. CRUD and where() operations verified." -ForegroundColor Green

    # 6. Verify WAL Checkpoint
    $script:db._ExecuteDirectSql("PRAGMA wal_checkpoint(TRUNCATE);")
    Write-Host "[PASS] 6. WAL Checkpoint executed cleanly." -ForegroundColor Green

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "ALL PLAYGROUND VERIFICATION CHECKS PASSED PERFECTLY!" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
} finally {
    if ($null -ne $script:db) {
        $script:db.close()
    }
    Remove-Item $testDbPath -Force -ErrorAction SilentlyContinue
}
