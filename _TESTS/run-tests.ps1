# Convenient test runner for PSLocalBase
[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$tests = @(
    "PSLocalBase.Tests.ps1",
    "PSLocalBase.Audit.Tests.ps1",
    "PSLocalBase.Reevaluation.Tests.ps1",
    "PSLocalBase.NativeStress.Tests.ps1"
)

foreach ($testFile in $tests) {
    $script = Join-Path $PSScriptRoot $testFile
    if (Test-Path $script) {
        Write-Host "`n>>> Running $testFile <<<" -ForegroundColor Cyan
        & $script -VerboseOutput:$VerboseOutput
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
