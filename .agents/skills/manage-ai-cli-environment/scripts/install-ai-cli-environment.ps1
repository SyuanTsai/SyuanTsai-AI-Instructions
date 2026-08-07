#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $TargetRoot = (Get-Location).Path,
    [switch] $Force
)

function Install-AiCliEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetRoot,

        [switch] $Force
    )

    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetRoot)
    if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
        throw "Target repository directory does not exist: $resolvedTarget"
    }

    $skillRoot = Split-Path -Parent $PSScriptRoot
    $sourceRoot = Join-Path $skillRoot 'assets\environment-layer'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Environment layer assets were not found: $sourceRoot"
    }

    foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force) {
        $relativePath = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $resolvedTarget $relativePath
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

        $isConfiguration = $relativePath -eq '.ai\config.json'
        if ($isConfiguration -and (Test-Path -LiteralPath $destination)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $destination) -or $Force) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -Force
        }
    }

    $gitIgnorePath = Join-Path $resolvedTarget '.gitignore'
    $entries = @('.ai/logs/', '.ai/usage-state.json', '.ai/profiles/')
    $existing = if (Test-Path -LiteralPath $gitIgnorePath) {
        @(Get-Content -LiteralPath $gitIgnorePath)
    }
    else {
        @()
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $existing) {
        $updated.Add($line)
    }
    foreach ($entry in $entries) {
        if ($entry -notin $updated) {
            $updated.Add($entry)
        }
    }

    [System.IO.File]::WriteAllText(
        $gitIgnorePath,
        (($updated -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )

    return [pscustomobject]@{
        targetRoot = $resolvedTarget
        configPath = Join-Path $resolvedTarget '.ai\config.json'
        toolsPath = Join-Path $resolvedTarget 'tools'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-AiCliEnvironment -TargetRoot $TargetRoot -Force:$Force
}
