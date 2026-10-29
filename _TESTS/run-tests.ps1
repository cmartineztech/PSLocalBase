# Convenient test runner for PSLocalBase
[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$tests = @(
    "PSLocalBase.Tests.ps1",
    "PSLocalBase.Audit.Tests.ps1",
    "PSLocalBase.Reevaluation.Tests.ps1",
    "PSLocalBase.NativeStress.Tests.ps1",
    "PSLocalBase.Independent-c57b52c.Tests.ps1",
    "PSLocalBase.Revalidation-3ecc2c1.Tests.ps1",
    "PSLocalBase.Review-83ed742.Tests.ps1"
)

foreach ($testFile in $tests) {
    $script = Join-Path $PSScriptRoot $testFile
    if (-not (Test-Path $script)) {
        Write-Error "Required test suite file not found: $testFile"
        exit 1
    }
    Write-Host "`n>>> Running $testFile <<<" -ForegroundColor Cyan
    & $script -VerboseOutput:$VerboseOutput
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
