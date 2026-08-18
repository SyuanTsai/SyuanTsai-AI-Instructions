[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [Parameter(Mandatory = $true)][string] $LockPath,
    [Parameter(Mandatory = $true)][string] $ConfigurationPath,
    [hashtable] $SourceArchivePaths = @{},
    [string] $InstructionSourceArchivePath,
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $TargetRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-selection.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-routing.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-retrieval.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-acquisition.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-composition.psm1') -Force

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Name does not exist: $fullPath"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $fullPath | ConvertFrom-Json
    }
    catch {
        throw "$Name is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
}

function Get-InstructionArchive {
    param(
        [string] $ProvidedArchivePath,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Ref,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedArchivePath)) {
        $fullPath = [System.IO.Path]::GetFullPath($ProvidedArchivePath)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Instruction source archive does not exist: $fullPath"
        }
        return $fullPath
    }

    if ($Repository -notmatch '^[^/]+/[^/]+$') {
        throw "SourceRepository must use owner/repository format: $Repository"
    }
    $repositoryParts = $Repository.Split('/')
    $owner = [System.Uri]::EscapeDataString($repositoryParts[0])
    $repo = [System.Uri]::EscapeDataString($repositoryParts[1])
    $escapedRef = [System.Uri]::EscapeDataString($Ref)
    $uri = "https://github.com/$owner/$repo/archive/refs/heads/$escapedRef.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers @{ 'User-Agent'='Codex-AI-Instructions-MultiSource-Bootstrap' } -OutFile $DestinationPath
    return $DestinationPath
}

$catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
$lock = Read-JsonDocument -Path $LockPath -Name 'Skills Catalog lock'
$configuration = Read-JsonDocument -Path $ConfigurationPath -Name 'AI instruction sync configuration'

if ($configuration.schemaVersion -ne 3) {
    throw "Multi-source bootstrap requires AI instruction sync configuration schemaVersion 3; actual: $($configuration.schemaVersion)"
}
if ($null -eq $configuration.PSObject.Properties['catalog']) {
    throw 'AI instruction sync configuration is missing catalog selection.'
}

$selectedSkillIds = Resolve-SkillsSelection -Catalog $catalog -Selection $configuration.catalog
$plan = Resolve-SkillsSourcePlan -Catalog $catalog -Lock $lock -SkillIds $selectedSkillIds

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\\', '/'))
$workingRoot = Join-Path $tempRoot ('syp79-multisource-' + [Guid]::NewGuid().ToString('N'))
$instructionExtract = Join-Path $workingRoot 'instruction-source'
$instructionArchiveDownload = Join-Path $workingRoot 'instruction-source.zip'
$sourceDownloads = Join-Path $workingRoot 'source-downloads'
$sourceStaging = Join-Path $workingRoot 'skill-sources'
$composedParent = Join-Path $workingRoot 'composed'
$composedRoot = Join-Path $composedParent 'repository'
$composedArchive = Join-Path $workingRoot 'composed-source.zip'
$legacyConfigurationPath = Join-Path $workingRoot 'legacy-sync-v2.json'

try {
    New-Item -ItemType Directory -Path $workingRoot, $instructionExtract, $sourceDownloads, $composedParent | Out-Null

    # Selection, source routing, download and validation all complete before target mutation starts.
    $resolvedArchivePaths = Get-SkillsSourceArchives `
        -Plan $plan `
        -DestinationRoot $sourceDownloads `
        -LocalArchiveOverrides $SourceArchivePaths

    $resolved = Expand-ValidatedSkillsSourceArchives `
        -Plan $plan `
        -SourceArchivePaths $resolvedArchivePaths `
        -WorkingRoot $sourceStaging

    $instructionArchive = Get-InstructionArchive `
        -ProvidedArchivePath $InstructionSourceArchivePath `
        -Repository $SourceRepository `
        -Ref $SourceRef `
        -DestinationPath $instructionArchiveDownload

    Expand-Archive -LiteralPath $instructionArchive -DestinationPath $instructionExtract
    $instructionRoots = @(Get-ChildItem -LiteralPath $instructionExtract -Directory)
    if ($instructionRoots.Count -ne 1) {
        throw "Instruction source archive must contain exactly one repository root; found $($instructionRoots.Count)."
    }

    New-ComposedBootstrapSource `
        -InstructionSourceRoot $instructionRoots[0].FullName `
        -ResolvedSkills $resolved.Skills `
        -DestinationRoot $composedRoot | Out-Null

    Compress-Archive -LiteralPath $composedRoot -DestinationPath $composedArchive -CompressionLevel Optimal

    # The legacy mutation engine only understands schema v2. Derive a temporary v2 view from v3
    # so its allowlist/exclusion/customization/stash behavior remains unchanged during migration.
    $legacyConfiguration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($configuration.autoCommitRepositoryUrls)
        excludedRepositoryUrls = @($configuration.excludedRepositoryUrls)
        excludedRepositoryPaths = @($configuration.excludedRepositoryPaths)
    }
    $legacyJson = ($legacyConfiguration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($legacyConfigurationPath, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))

    $legacyBootstrap = Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1'
    $arguments = @{
        SourceRepository = $SourceRepository
        SourceRef = $SourceRef
        SourceArchivePath = $composedArchive
        ConfigurationPath = $legacyConfigurationPath
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
        $arguments.TargetRoot = $TargetRoot
    }

    & $legacyBootstrap @arguments
}
finally {
    $resolvedWorkingRoot = [System.IO.Path]::GetFullPath($workingRoot)
    $expectedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe multi-source temporary cleanup path: $resolvedWorkingRoot"
    }
    Remove-Item -LiteralPath $resolvedWorkingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
