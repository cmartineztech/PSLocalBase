# Convenient test runner for PSLocalBase
[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$testScript = Join-Path $PSScriptRoot "PSLocalBase.Tests.ps1"
& $testScript -VerboseOutput:$VerboseOutput
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$auditScript = Join-Path $PSScriptRoot "PSLocalBase.Audit.Tests.ps1"
if (Test-Path $auditScript) {
    & $auditScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
