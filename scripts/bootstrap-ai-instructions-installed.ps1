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
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
$bootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'

foreach ($requiredPath in @($configurationPath, $catalogPath, $lockPath, $bundlePath, $bootstrapPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installed AI instruction runtime is incomplete: $requiredPath"
    }
}

try {
    $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
    $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
}
catch {
    throw "Installed AI instruction runtime identity is invalid: $($_.Exception.Message)"
}

if ($configuration.schemaVersion -ne 3 -or
    $bundle.schemaVersion -ne 1 -or
    [string]$bundle.repository -cne [string]$configuration.catalog.repository -or
    [string]$bundle.commit -cne [string]$configuration.catalog.ref -or
    [string]$bundle.commit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Installed AI instruction runtime bundle does not match the configured immutable Catalog bundle pin. Re-run the installer before bootstrapping.'
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
