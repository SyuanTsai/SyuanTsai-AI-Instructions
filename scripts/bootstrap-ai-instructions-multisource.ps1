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

function Get-RawFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }
    return $property.Value
}

function Assert-StringArrayValue {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [System.Array]) {
        throw "$Context must be an array."
    }
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $item)) {
            throw "$Context must contain only non-empty strings."
        }
    }
}

function Assert-MultiSourceConfiguration {
    param(
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][object] $Catalog
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Configuration -Name 'schemaVersion' -Context 'AI instruction sync configuration'
    if ($schemaVersion -ne 3) {
        throw "Multi-source bootstrap requires AI instruction sync configuration schemaVersion 3; actual: $schemaVersion"
    }

    foreach ($propertyName in @('autoCommitRepositoryUrls', 'excludedRepositoryUrls', 'excludedRepositoryPaths')) {
        Assert-StringArrayValue `
            -Value (Get-RequiredPropertyValue -Object $Configuration -Name $propertyName -Context 'AI instruction sync configuration') `
            -Context "AI instruction sync configuration $propertyName"
    }

    $selection = Get-RequiredPropertyValue -Object $Configuration -Name 'catalog' -Context 'AI instruction sync configuration'
    foreach ($propertyName in @('repository', 'ref')) {
        $value = Get-RequiredPropertyValue -Object $selection -Name $propertyName -Context 'AI instruction sync configuration catalog'
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $value)) {
            throw "AI instruction sync configuration catalog $propertyName must be a non-empty string."
        }
    }
    foreach ($propertyName in @('profiles', 'includeSkills', 'excludeSkills')) {
        Assert-StringArrayValue `
            -Value (Get-RequiredPropertyValue -Object $selection -Name $propertyName -Context 'AI instruction sync configuration catalog') `
            -Context "AI instruction sync configuration catalog $propertyName"
    }

    $profileIds = @{}
    foreach ($profile in @($Catalog.profiles)) {
        $profileIds[[string]$profile.id] = $true
    }
    $skillIds = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillIds[[string]$skill.id] = $true
    }
    foreach ($profileId in @($selection.profiles)) {
        if (-not $profileIds.ContainsKey([string]$profileId)) {
            throw "AI instruction sync configuration references unknown profile '$profileId'."
        }
    }
    foreach ($skillId in @($selection.includeSkills) + @($selection.excludeSkills)) {
        if (-not $skillIds.ContainsKey([string]$skillId)) {
            throw "AI instruction sync configuration references unknown Skill '$skillId'."
        }
    }
    foreach ($skillId in @($selection.includeSkills)) {
        if (@($selection.excludeSkills) -contains [string]$skillId) {
            throw "AI instruction sync configuration both includes and excludes Skill '$skillId'."
        }
    }
}

function Assert-MultiSourceLockIdentity {
    param(
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][string] $CatalogFilePath
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Lock -Name 'schemaVersion' -Context 'Skills Catalog lock'
    if ($schemaVersion -ne 1) {
        throw "Unsupported Skills Catalog lock schemaVersion '$schemaVersion'; expected 1."
    }

    $catalogId = [string](Get-RequiredPropertyValue -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock')
    if ($catalogId -ne [string]$Catalog.catalogId) {
        throw 'Skills Catalog lock catalogId does not match the Skills Catalog.'
    }

    $catalogSha256 = [string](Get-RequiredPropertyValue -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock')
    if ($catalogSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Skills Catalog lock catalogSha256 must be a lowercase 64-character SHA-256 hash.'
    }
    $actualCatalogSha256 = Get-RawFileSha256 -Path $CatalogFilePath
    if ($catalogSha256 -ne $actualCatalogSha256) {
        throw "Skills Catalog lock catalogSha256 does not match the Catalog file: expected $actualCatalogSha256."
    }

    $null = Get-RequiredPropertyValue -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'
    $null = Get-RequiredPropertyValue -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'
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

Assert-MultiSourceLockIdentity -Lock $lock -Catalog $catalog -CatalogFilePath $CatalogPath
Assert-MultiSourceConfiguration -Configuration $configuration -Catalog $catalog

$selectedSkillIds = Resolve-SkillsSelection -Catalog $catalog -Selection $configuration.catalog
$plan = Resolve-SkillsSourcePlan -Catalog $catalog -Lock $lock -SkillIds $selectedSkillIds

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
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
