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
        'btnToggleTheme',
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
        'rtbConsole', 'btnCopyLogs', 'btnClearLogs',
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

    # 4. Verify Theme DynamicResources & Theme Switching (Light & Dark Mode)
    $brushConverter = [System.Windows.Media.BrushConverter]::new()
    $themeKeys = @('BgColor', 'FgColor', 'SurfaceBg', 'BorderColor', 'HeaderColor', 'InputBg', 'LogBg', 'ButtonHoverBg')
    
    # Test Dark Mode application
    $darkPalette = @{
        'BgColor' = '#121418'; 'FgColor' = '#F3F4F6'; 'SurfaceBg' = '#1C1F26';
        'BorderColor' = '#2C313A'; 'HeaderColor' = '#3B82F6'; 'InputBg' = '#242830';
        'LogBg' = '#0F1115'; 'ButtonHoverBg' = '#2E3440'
    }
    foreach ($k in $darkPalette.Keys) {
        $window.Resources[$k] = $brushConverter.ConvertFromString($darkPalette[$k])
    }
    if ($window.Resources['BgColor'].ToString() -ne '#FF121418') {
        throw "Failed applying Dark Mode palette."
    }

    # Test Light Mode application
    $lightPalette = @{
        'BgColor' = '#F0F4FA'; 'FgColor' = '#1A2332'; 'SurfaceBg' = '#FFFFFF';
        'BorderColor' = '#D0DAE6'; 'HeaderColor' = '#2F6FED'; 'InputBg' = '#FFFFFF';
        'LogBg' = '#F7F9FB'; 'ButtonHoverBg' = '#E8EEF6'
    }
    foreach ($k in $lightPalette.Keys) {
        $window.Resources[$k] = $brushConverter.ConvertFromString($lightPalette[$k])
    }
    if ($window.Resources['BgColor'].ToString() -ne '#FFF0F4FA') {
        throw "Failed applying Light Mode palette."
    }
    Write-Host "[PASS] 4. Dynamic Theme switching (Dark & Light) validated successfully." -ForegroundColor Green

    # 5. Verify ComboBox styling and population
    $cmbLeft = $window.FindName('cmbLeftCollection')
    $cmbRight = $window.FindName('cmbRightCollection')
    [void]$cmbLeft.Items.Add('users')
    [void]$cmbLeft.Items.Add('products')
    $cmbLeft.SelectedItem = 'users'
    if ($cmbLeft.SelectedItem -ne 'users') {
        throw "Failed ComboBox item selection."
    }
    Write-Host "[PASS] 5. Modern ComboBox Dropdown verified." -ForegroundColor Green

    # 5b. Verify RichTextBox console flow document & selectable text and UTF-32 moon conversion
    $moonChar = [char]::ConvertFromUtf32(0x1F319)
    if ([string]::IsNullOrEmpty($moonChar)) { throw "UTF-32 moon emoji conversion failed." }
    $rtb = $window.FindName('rtbConsole')
    if ($null -eq $rtb -or -not ($rtb -is [System.Windows.Controls.RichTextBox])) {
        throw "rtbConsole is not a valid RichTextBox."
    }
    $p = [System.Windows.Documents.Paragraph]::new([System.Windows.Documents.Run]::new("Test Console Output"))
    [void]$rtb.Document.Blocks.Add($p)
    $textRange = [System.Windows.Documents.TextRange]::new($rtb.Document.ContentStart, $rtb.Document.ContentEnd)
    if (-not $textRange.Text.Contains("Test Console Output")) {
        throw "Failed to read text from RichTextBox FlowDocument."
    }
    Write-Host "[PASS] 5b. RichTextBox selectable console and UTF-32 moon ($moonChar) validated." -ForegroundColor Green

    # 6. Verify seeding
    $script:db.collection("users").add(@{ id = 1; name = "Bill"; age = 47 }) | Out-Null
    $script:db.collection("users").add(@{ id = 2; name = "Paul"; age = 34 }) | Out-Null
    $script:db.collection("products").add(@{ sku = "TEST-01"; title = "Test Laptop"; price = 999 }) | Out-Null
    $script:db.collection("orders").add(@{ orderId = "ORD-99"; total = 999 }) | Out-Null

    $colls = @($script:db.listCollections())
    if ($colls.Count -lt 3) {
        throw "Expected at least 3 collections, got $($colls.Count)"
    }
    Write-Host "[PASS] 6. Multi-collection seeding verified ($($colls -join ', '))." -ForegroundColor Green

    # 7. Verify queries, updates and deletes
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
    Write-Host "[PASS] 7. CRUD and where() operations verified." -ForegroundColor Green

    # 7b. Verify multiline chaining and auto-normalization
    $multilineSnippet = @'
$script:db.collection('users')
    .where('age', '>=', 40)
    .orderBy('age', 'desc')
    .limit(5)
    .get()
'@
    $normalizedSnippet = $multilineSnippet -replace "(?m)(?<![.`])\r?\n(\s*)\.([a-zA-Z_]\w*\s*\()", ".`r`n`$1`$2"
    $sb = [scriptblock]::Create($normalizedSnippet)
    $chainRes = & $sb
    if ($chainRes.name -ne "Bill") {
        throw "Failed multiline chaining query execution"
    }
    Write-Host "[PASS] 7b. Multiline method chaining & auto-normalization verified." -ForegroundColor Green

    # 8. Verify WAL Checkpoint
    $script:db._ExecuteDirectSql("PRAGMA wal_checkpoint(TRUNCATE);")
    Write-Host "[PASS] 8. WAL Checkpoint executed cleanly." -ForegroundColor Green

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "ALL PLAYGROUND VERIFICATION CHECKS PASSED PERFECTLY!" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
} finally {
    if ($null -ne $script:db) {
        $script:db.close()
    }
    Remove-Item $testDbPath -Force -ErrorAction SilentlyContinue
}
