<#
.SYNOPSIS
    Packages and publishes PSLocalBase to the PowerShell Gallery (PSGallery).

.DESCRIPTION
    Creates a clean, production-only staging package containing exclusively the
    core database engine and metadata files (PSLocalBase.psd1, PSLocalBase.psm1,
    InitWinSqlite3Native.ps1, LICENSE, README.md, CHANGELOG.md).
    
    Explicitly excludes development assets, tests, documentation, and the
    Playground visual GUI explorer.

.PARAMETER NuGetApiKey
    The PowerShell Gallery API key. If omitted, the script checks the
    PSGALLERY_API_KEY environment variable, or prompts securely for it.

.PARAMETER DryRun
    When specified, creates the staging directory, verifies the manifest,
    and lists the package contents without publishing to PSGallery.

.EXAMPLE
    # Test packaging without uploading:
    .\Publish-PSLocalBase.ps1 -DryRun

.EXAMPLE
    # Publish by passing API key directly:
    .\Publish-PSLocalBase.ps1 -NuGetApiKey "oy2a..."

.EXAMPLE
    # Publish using environment variable:
    $env:PSGALLERY_API_KEY = "oy2a..."
    .\Publish-PSLocalBase.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$NuGetApiKey,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# 1. Resolve root repository path
$repoRoot = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

$manifestPath = Join-Path $repoRoot "PSLocalBase.psd1"
if (-not (Test-Path $manifestPath)) {
    throw "Cannot find PSLocalBase.psd1 at '$repoRoot'. Run this script from the repository root."
}

# 2. Validate manifest syntax before staging
$manifest = Test-ModuleManifest -Path $manifestPath
$version = $manifest.Version.ToString()
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Preparing to Publish PSLocalBase v$version" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 3. Resolve API Key
$resolvedKey = $NuGetApiKey
if ([string]::IsNullOrWhiteSpace($resolvedKey)) {
    $resolvedKey = $env:PSGALLERY_API_KEY
}

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($resolvedKey)) {
    Write-Host "No API key was passed as parameter or found in `$env:PSGALLERY_API_KEY." -ForegroundColor Yellow
    $secureKey = Read-Host -Prompt "Enter your PowerShell Gallery API Key" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $resolvedKey = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($resolvedKey)) {
    throw "A valid PowerShell Gallery API key is required to publish. Use -DryRun to test packaging."
}

# 4. Prepare Staging Directory (Excluding Playground, _TESTS, _DOCS, .git)
$stagingId = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSLocalBase_Publish_$stagingId"

try {
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    Write-Host "Staging production files..." -ForegroundColor Gray
    $filesToPackage = @(
        "PSLocalBase.psd1",
        "PSLocalBase.psm1",
        "InitWinSqlite3Native.ps1",
        "LICENSE",
        "README.md",
        "CHANGELOG.md"
    )

    foreach ($file in $filesToPackage) {
        $sourcePath = Join-Path $repoRoot $file
        if (-not (Test-Path $sourcePath)) {
            throw "Required package file not found: '$sourcePath'"
        }
        Copy-Item -Path $sourcePath -Destination $stagingDir -Force
        Write-Host "  + Included: $file" -ForegroundColor DarkGreen
    }

    # Normalize README.md links in staging to prevent broken links
    # (replaces relative links to Playground, _DOCS, _TESTS with absolute GitHub URLs)
    $stagedReadme = Join-Path $stagingDir "README.md"
    if (Test-Path $stagedReadme) {
        $readmeText = [System.IO.File]::ReadAllText($stagedReadme, [System.Text.Encoding]::UTF8)

        # 1. Images: Playground/screenshots/... -> raw.githubusercontent.com
        $readmeText = $readmeText -replace '\(Playground/screenshots/([^\)]+)\)', '(https://raw.githubusercontent.com/cmartineztech/PSLocalBase/main/Playground/screenshots/$1)'

        # 2. Folders: (_DOCS/) or (_DOCS/#section) -> tree/main/_DOCS
        $readmeText = $readmeText -replace '\(_DOCS/(#[^\)]*)?\)', '(https://github.com/cmartineztech/PSLocalBase/tree/main/_DOCS/$1)'

        # 3. Specific documents in _DOCS, _TESTS, Playground
        $readmeText = $readmeText -replace '\(_DOCS/([a-zA-Z0-9_\-\.]+\.md)(#[^\)]*)?\)', '(https://github.com/cmartineztech/PSLocalBase/blob/main/_DOCS/$1$2)'
        $readmeText = $readmeText -replace '\(_TESTS/([^\)]+)\)', '(https://github.com/cmartineztech/PSLocalBase/blob/main/_TESTS/$1)'
        $readmeText = $readmeText -replace '\(Playground/([^\)]+)\)', '(https://github.com/cmartineztech/PSLocalBase/blob/main/Playground/$1)'
        $readmeText = $readmeText -replace '\(SECURITY\.md\)', '(https://github.com/cmartineztech/PSLocalBase/blob/main/SECURITY.md)'

        [System.IO.File]::WriteAllText($stagedReadme, $readmeText, [System.Text.Encoding]::UTF8)
        Write-Host "  * Normalized staged README.md relative links to absolute GitHub URLs (no broken links)." -ForegroundColor DarkGreen
    }

    # Verify staging manifest
    $stagedManifestPath = Join-Path $stagingDir "PSLocalBase.psd1"
    $stagedManifest = Test-ModuleManifest -Path $stagedManifestPath
    Write-Host "[OK] Staged module manifest verified successfully (v$($stagedManifest.Version))." -ForegroundColor Green

    # Display package contents
    Write-Host "`nStaged Package Contents ($stagingDir):" -ForegroundColor Cyan
    Get-ChildItem -Path $stagingDir | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host

    Write-Host "Excluded from package:" -ForegroundColor DarkGray
    Write-Host "  - Playground/ (GUI explorer)" -ForegroundColor DarkGray
    Write-Host "  - _TESTS/     (Unit and stress test suites)" -ForegroundColor DarkGray
    Write-Host "  - _DOCS/      (Extended technical specifications)" -ForegroundColor DarkGray
    Write-Host "  - .github/    (CI/CD workflows)" -ForegroundColor DarkGray

    # 5. Execute Publish or Dry Run
    if ($DryRun) {
        Write-Host "`n[DRY RUN COMPLETE] Package is valid and ready. No upload was performed." -ForegroundColor Yellow
        Write-Host "To publish for real, run:" -ForegroundColor Yellow
        Write-Host "  .\Publish-PSLocalBase.ps1 -NuGetApiKey 'TU_API_KEY'" -ForegroundColor White
    } else {
        Write-Host "`nPublishing PSLocalBase v$version to PowerShell Gallery (PSGallery)..." -ForegroundColor Cyan
        Publish-Module -Path $stagingDir -NuGetApiKey $resolvedKey -Repository PSGallery -Verbose
        Write-Host "`n[SUCCESS] PSLocalBase v$version was published successfully to PowerShell Gallery!" -ForegroundColor Green
        Write-Host "View your published module at: https://www.powershellgallery.com/packages/PSLocalBase/$version" -ForegroundColor Cyan
        Write-Host "Install with: Install-Module -Name PSLocalBase" -ForegroundColor White
    }
} finally {
    if (Test-Path $stagingDir) {
        Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
