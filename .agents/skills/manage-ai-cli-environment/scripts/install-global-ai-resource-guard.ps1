#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $Force
)

function Get-DefaultGlobalAiResourceGuardRoot {
    $configuredRoot = [Environment]::GetEnvironmentVariable('AI_RESOURCE_GUARD_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($configuredRoot)) {
        $configuredRoot = [Environment]::GetEnvironmentVariable('AI_RESOURCE_GUARD_HOME', 'User')
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
        return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configuredRoot))
    }
    $localApplicationData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        throw 'LocalApplicationData is unavailable; set AI_RESOURCE_GUARD_HOME explicitly.'
    }
    return Join-Path $localApplicationData 'ai-resource-guard'
}

function Copy-GlobalGuardFiles {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationRoot,
        [switch] $PreserveConfiguration,
        [switch] $Force
    )

    foreach ($sourceFile in Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force) {
        $relativePath = $sourceFile.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $DestinationRoot $relativePath
        if ($PreserveConfiguration -and $relativePath -eq 'config.json' -and
            (Test-Path -LiteralPath $destination -PathType Leaf)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or $Force) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -Force
        }
    }
}

function Install-GlobalAiResourceGuard {
    [CmdletBinding()]
    param(
        [string] $TargetRoot,
        [switch] $Force
    )

    $resolvedTarget = if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        Get-DefaultGlobalAiResourceGuardRoot
    }
    else {
        [IO.Path]::GetFullPath($TargetRoot)
    }
    New-Item -ItemType Directory -Force -Path $resolvedTarget | Out-Null

    $skillRoot = Split-Path -Parent $PSScriptRoot
    $globalAssetRoot = Join-Path $skillRoot 'assets\global-resource-guard'
    $providerToolsRoot = Join-Path $skillRoot 'assets\environment-layer\tools'
    if (-not (Test-Path -LiteralPath $globalAssetRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $providerToolsRoot -PathType Container)) {
        throw 'Global guard assets are incomplete.'
    }

    Copy-GlobalGuardFiles `
        -SourceRoot $globalAssetRoot `
        -DestinationRoot $resolvedTarget `
        -PreserveConfiguration `
        -Force:$Force
    Copy-GlobalGuardFiles `
        -SourceRoot $providerToolsRoot `
        -DestinationRoot (Join-Path $resolvedTarget 'provider-tools') `
        -Force:$Force

    foreach ($directory in @('state\resources', 'profiles', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $resolvedTarget $directory) | Out-Null
    }

    return [pscustomobject]@{
        targetRoot = $resolvedTarget
        configPath = Join-Path $resolvedTarget 'config.json'
        statePath = Join-Path $resolvedTarget 'state\resources'
        evaluatePath = Join-Path $resolvedTarget 'bin\evaluate-resource.ps1'
        executePath = Join-Path $resolvedTarget 'bin\execute-resource.ps1'
        refreshPath = Join-Path $resolvedTarget 'bin\refresh-resource-state.ps1'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-GlobalAiResourceGuard -TargetRoot $TargetRoot -Force:$Force
}
