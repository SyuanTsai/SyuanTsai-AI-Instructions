[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $SkipUpdateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $PSScriptRoot 'ai-instructions-runtime'
$configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
$catalogPath = Join-Path $runtimeRoot 'catalog\skills-catalog.json'
$lockPath = Join-Path $runtimeRoot 'catalog\skills-catalog-lock.json'
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
$contractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
$updaterPath = Join-Path $runtimeRoot 'update-ai-instructions.ps1'
$bootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'

function Assert-InstalledRuntime {
    foreach ($requiredPath in @($configurationPath,$catalogPath,$lockPath,$bundlePath,$contractPath,$updaterPath,$bootstrapPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Installed AI instruction runtime is incomplete: $requiredPath" }
    }
    try {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
    }
    catch { throw "Installed AI instruction runtime identity is invalid: $($_.Exception.Message)" }
    Import-Module $contractPath -Force
    Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot | Out-Null
}

Assert-InstalledRuntime
if (-not $SkipUpdateCheck) {
    $engineName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $enginePath = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { $enginePath = $engineName }
    $updateOutput = & $enginePath -NoProfile -ExecutionPolicy Bypass -File $updaterPath -CodexHome $codexHome 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AI instructions update check failed: $($updateOutput -join [Environment]::NewLine)" }
    foreach ($line in @($updateOutput)) { Write-Output $line }
    Assert-InstalledRuntime
}

$arguments = @{
    CatalogPath = $catalogPath
    LockPath = $lockPath
    ConfigurationPath = $configurationPath
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) { $arguments.TargetRoot = $TargetRoot }
& $bootstrapPath @arguments
