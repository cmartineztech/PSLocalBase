# Convenient test runner for PSLocalBase
[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$testScript = Join-Path $PSScriptRoot "PSLocalBase.Tests.ps1"
& $testScript -VerboseOutput:$VerboseOutput
