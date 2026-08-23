[CmdletBinding()]
param(
    [string] $CodexHome,
    [switch] $ForceCheck,
    [switch] $InstallApproved
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$installedModule = Join-Path $PSScriptRoot 'ai-instructions-runtime\ai-instructions-updater.psm1'
$modulePath = if (Test-Path -LiteralPath $installedModule -PathType Leaf) { $installedModule } else { Join-Path $PSScriptRoot 'ai-instructions-updater.psm1' }
Import-Module $modulePath -Force

$result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $CodexHome -ForceCheck:$ForceCheck -InstallApproved:$InstallApproved
Write-Output "AI instructions update outcome: $($result.outcome). $($result.message)"
if ([string]$result.outcome -in @('failed','drift')) {
    throw "AI instructions update stopped: $($result.message)"
}
