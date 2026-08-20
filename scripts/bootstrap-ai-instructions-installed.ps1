[CmdletBinding()]
param(
    [string] $TargetRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$codexHome = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $PSScriptRoot 'ai-instructions-runtime'
$configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
$catalogPath = Join-Path $runtimeRoot 'catalog\skills-catalog.json'
$lockPath = Join-Path $runtimeRoot 'catalog\skills-catalog-lock.json'
$bootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'

foreach ($requiredPath in @($configurationPath, $catalogPath, $lockPath, $bootstrapPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installed AI instruction runtime is incomplete: $requiredPath"
    }
}

$arguments = @{
    CatalogPath = $catalogPath
    LockPath = $lockPath
    ConfigurationPath = $configurationPath
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
    $arguments.TargetRoot = $TargetRoot
}

& $bootstrapPath @arguments
