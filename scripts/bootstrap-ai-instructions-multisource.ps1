[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [Parameter(Mandatory = $true)][string] $LockPath,
    [Parameter(Mandatory = $true)][string] $ConfigurationPath,
    [hashtable] $SourceArchivePaths = @{},
    [string] $InstructionSourceArchivePath,
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $InstructionSourceCommit,
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
Import-Module (Join-Path $scriptRoot 'safe-zip.psm1') -Force

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
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
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

    $value = $property.Value
    if ($value -is [System.Array]) {
        return ,$value
    }

    return $value
}

function Assert-StringArrayValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object] $Value,
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

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $uri = $null
    if ($Value -isnot [string] -or
        -not [System.Uri]::TryCreate([string] $Value, [System.UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "$Context must be an absolute HTTPS URL."
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

    foreach ($name in @('autoCommitRepositoryUrls', 'excludedRepositoryUrls', 'excludedRepositoryPaths')) {
        $value = Get-RequiredPropertyValue -Object $Configuration -Name $name -Context 'AI instruction sync configuration'
        Assert-StringArrayValue -Value $value -Context "AI instruction sync configuration $name"
    }

    $selection = Get-RequiredPropertyValue -Object $Configuration -Name 'catalog' -Context 'AI instruction sync configuration'
    $catalogRepository = Get-RequiredPropertyValue -Object $selection -Name 'repository' -Context 'AI instruction sync configuration catalog'
    Assert-HttpsUrl -Value $catalogRepository -Context 'AI instruction sync configuration catalog repository'

    $ref = Get-RequiredPropertyValue -Object $selection -Name 'ref' -Context 'AI instruction sync configuration catalog'
    if ($ref -isnot [string] -or [string]$ref -cnotmatch '^[0-9a-f]{40}$') {
        throw 'AI instruction sync configuration catalog ref must be a full lowercase commit SHA.'
    }

    foreach ($name in @('profiles', 'includeSkills', 'excludeSkills')) {
        $value = Get-RequiredPropertyValue -Object $selection -Name $name -Context 'AI instruction sync configuration catalog'
        Assert-StringArrayValue -Value $value -Context "AI instruction sync configuration catalog $name"
    }

    $profileIds = @{}
    foreach ($profile in @($Catalog.profiles)) {
        $profileIds[[string] $profile.id] = $true
    }
    $skillIds = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillIds[[string] $skill.id] = $true
    }

    foreach ($id in @($selection.profiles)) {
        if (-not $profileIds.ContainsKey([string] $id)) {
            throw "AI instruction sync configuration references unknown profile '$id'."
        }
    }
    foreach ($id in @($selection.includeSkills) + @($selection.excludeSkills)) {
        if (-not $skillIds.ContainsKey([string] $id)) {
            throw "AI instruction sync configuration references unknown Skill '$id'."
        }
    }
    foreach ($id in @($selection.includeSkills)) {
        if (@($selection.excludeSkills) -contains [string] $id) {
            throw "AI instruction sync configuration both includes and excludes Skill '$id'."
        }
    }
}

function Assert-MultiSourceLockContract {
    param(
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][string] $CatalogFilePath
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Lock -Name 'schemaVersion' -Context 'Skills Catalog lock'
    if ($schemaVersion -ne 1) {
        throw "Unsupported Skills Catalog lock schemaVersion '$schemaVersion'; expected 1."
    }

    $catalogId = [string] (Get-RequiredPropertyValue -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock')
    if ($catalogId -ne [string] $Catalog.catalogId) {
        throw 'Skills Catalog lock catalogId does not match the Skills Catalog.'
    }

    $catalogHash = [string] (Get-RequiredPropertyValue -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock')
    if ($catalogHash -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Skills Catalog lock catalogSha256 must be a lowercase 64-character SHA-256 hash.'
    }
    $actualHash = Get-RawFileSha256 -Path $CatalogFilePath
    if ($catalogHash -ne $actualHash) {
        throw "Skills Catalog lock catalogSha256 does not match the Catalog file: expected $actualHash."
    }

    $catalogSources = @{}
    foreach ($source in @($Catalog.sources)) {
        $catalogSources[[string] $source.id] = $source
    }

    # Keep the JSON array object intact when reading the property, then enumerate it explicitly.
    # PowerShell 5.1 otherwise treats @(Write-Output -NoEnumerate <array>) as a single array object.
    $lockSources = Get-RequiredPropertyValue -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'
    if ($lockSources -isnot [System.Array]) {
        throw 'Skills Catalog lock sources must be an array.'
    }

    $lockedSources = @{}
    foreach ($source in $lockSources) {
        $id = [string] (Get-RequiredPropertyValue -Object $source -Name 'id' -Context 'Skills Catalog lock source')
        if ($lockedSources.ContainsKey($id)) {
            throw "Duplicate Skills Catalog lock source ID: $id"
        }
        if (-not $catalogSources.ContainsKey($id)) {
            throw "Skills Catalog lock references unknown source '$id'."
        }

        $repository = [string] (Get-RequiredPropertyValue -Object $source -Name 'repository' -Context "Skills Catalog lock source '$id'")
        if ($repository -ne [string] $catalogSources[$id].repository) {
            throw "Skills Catalog lock source '$id' repository does not match the catalog."
        }
        Assert-HttpsUrl -Value $repository -Context "Skills Catalog lock source '$id' repository"

        $requestedRef = [string] (Get-RequiredPropertyValue -Object $source -Name 'requestedRef' -Context "Skills Catalog lock source '$id'")
        if ([string]::IsNullOrWhiteSpace($requestedRef)) {
            throw "Skills Catalog lock source '$id' requestedRef must be non-empty."
        }

        $refType = [string] (Get-RequiredPropertyValue -Object $source -Name 'requestedRefType' -Context "Skills Catalog lock source '$id'")
        if (@('branch', 'tag', 'commit') -cnotcontains $refType) {
            throw "Unsupported requestedRefType '$refType' for Skills Catalog lock source '$id'."
        }

        $resolvedCommit = [string] (Get-RequiredPropertyValue -Object $source -Name 'resolvedCommit' -Context "Skills Catalog lock source '$id'")
        if ($resolvedCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw "Skills Catalog lock source '$id' resolvedCommit must be a full 40-character SHA."
        }

        $resolvedVersion = [string] (Get-RequiredPropertyValue -Object $source -Name 'resolvedVersion' -Context "Skills Catalog lock source '$id'")
        if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
            throw "Skills Catalog lock source '$id' resolvedVersion must be non-empty."
        }

        $archiveHash = [string] (Get-RequiredPropertyValue -Object $source -Name 'archiveSha256' -Context "Skills Catalog lock source '$id'")
        if ($archiveHash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Skills Catalog lock source '$id' archiveSha256 must be a lowercase SHA-256."
        }

        $lockedSources[$id] = $source
    }

    foreach ($id in $catalogSources.Keys) {
        if (-not $lockedSources.ContainsKey([string] $id)) {
            throw "Skills Catalog source '$id' has no resolved lock entry."
        }
    }

    $activeSkills = @{}
    foreach ($skill in @($Catalog.skills)) {
        if ([string] $skill.lifecycle.status -ne 'removed') {
            $activeSkills[[string] $skill.id] = $skill
        }
    }

    $lockSkills = Get-RequiredPropertyValue -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'
    if ($lockSkills -isnot [System.Array]) {
        throw 'Skills Catalog lock skills must be an array.'
    }

    $lockedSkills = @{}
    foreach ($skill in $lockSkills) {
        $id = [string] (Get-RequiredPropertyValue -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill')
        if ($lockedSkills.ContainsKey($id)) {
            throw "Duplicate Skills Catalog lock Skill ID: $id"
        }
        if (-not $activeSkills.ContainsKey($id)) {
            throw "Skills Catalog lock references unknown or removed Skill '$id'."
        }

        $sourceId = [string] (Get-RequiredPropertyValue -Object $skill -Name 'sourceId' -Context "Skills Catalog lock Skill '$id'")
        $sourcePath = [string] (Get-RequiredPropertyValue -Object $skill -Name 'sourcePath' -Context "Skills Catalog lock Skill '$id'")
        if ($sourceId -ne [string] $activeSkills[$id].source.sourceId -or
            $sourcePath -ne [string] $activeSkills[$id].source.path) {
            throw "Skills Catalog lock source does not match catalog Skill '$id'."
        }

        $contentHash = [string] (Get-RequiredPropertyValue -Object $skill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$id'")
        if ($contentHash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Skills Catalog lock Skill '$id' contentSha256 must be a lowercase SHA-256."
        }
        $lockedSkills[$id] = $skill
    }

    foreach ($id in $activeSkills.Keys) {
        if (-not $lockedSkills.ContainsKey([string] $id)) {
            throw "Skills Catalog Skill '$id' has no content lock entry."
        }
    }
}

function Get-InstructionArchive {
    param(
        [string] $ProvidedArchivePath,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Commit,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedArchivePath)) {
        $fullPath = [System.IO.Path]::GetFullPath($ProvidedArchivePath)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Instruction source archive does not exist: $fullPath"
        }
        return $fullPath
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Repository, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'github.com') {
        throw "Instruction source repository must be an HTTPS GitHub URL: $Repository"
    }
    $parts = @($uri.AbsolutePath.Trim('/').Split('/'))
    if ($parts.Count -ne 2) {
        throw "Instruction source repository must identify owner/repository: $Repository"
    }
    $owner = [System.Uri]::EscapeDataString($parts[0])
    $repositoryName = $parts[1]
    if ($repositoryName.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $repositoryName = $repositoryName.Substring(0, $repositoryName.Length - 4)
    }
    $repo = [System.Uri]::EscapeDataString($repositoryName)
    $escapedCommit = [System.Uri]::EscapeDataString($Commit)
    $archiveUri = "https://codeload.github.com/$owner/$repo/zip/$escapedCommit"
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{ 'User-Agent'='Codex-AI-Instructions-MultiSource-Bootstrap' } -OutFile $DestinationPath
    return $DestinationPath
}

$catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
$lock = Test-SkillsCatalogLockDocument -LockPath $LockPath -CatalogPath $CatalogPath
$configuration = Read-JsonDocument -Path $ConfigurationPath -Name 'AI instruction sync configuration'

Assert-MultiSourceConfiguration -Configuration $configuration -Catalog $catalog

$SourceRepository = [string]$configuration.catalog.repository
$SourceRef = [string]$configuration.catalog.ref
if ([string]::IsNullOrWhiteSpace($InstructionSourceCommit)) {
    $InstructionSourceCommit = $SourceRef
}
if ($InstructionSourceCommit -cnotmatch '^[0-9a-f]{40}$' -or $InstructionSourceCommit -cne $SourceRef) {
    throw 'AI instruction sync configuration catalog ref and InstructionSourceCommit must be the same full lowercase commit SHA.'
}

$selectedSkillIds = @(Resolve-SkillsSelection -Catalog $catalog -Selection $configuration.catalog)
$plan = Resolve-SkillsSourcePlan -Catalog $catalog -Lock $lock -SkillIds $selectedSkillIds

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
$workingRoot = Join-Path $tempRoot ('ai-' + [Guid]::NewGuid().ToString('N').Substring(0, 16))
$instructionExtract = Join-Path $workingRoot 'instruction-source'
$instructionArchiveDownload = Join-Path $workingRoot 'instruction-source.zip'
$sourceDownloads = Join-Path $workingRoot 'source-downloads'
$sourceStaging = Join-Path $workingRoot 'skill-sources'
$composedParent = Join-Path $workingRoot 'composed'
$composedRoot = Join-Path $composedParent 'repository'
$composedArchive = Join-Path $workingRoot 'composed-source.zip'
$legacyConfigurationPath = Join-Path $workingRoot 'legacy-sync-v2.json'
$provenancePath = Join-Path $workingRoot 'managed-source-provenance.json'

try {
    New-Item -ItemType Directory -Path $workingRoot, $instructionExtract, $sourceDownloads, $composedParent | Out-Null

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
        -Commit $InstructionSourceCommit `
        -DestinationPath $instructionArchiveDownload

    $instructionRoot = Expand-SafeZipRepository -ArchivePath $instructionArchive -DestinationRoot $instructionExtract

    New-ComposedBootstrapSource `
        -InstructionSourceRoot $instructionRoot `
        -ResolvedSkills $resolved.Skills `
        -DestinationRoot $composedRoot | Out-Null

    New-ComposedBootstrapArchive -SourceRoot $composedRoot -DestinationPath $composedArchive | Out-Null

    $sourcePlansById = @{}
    foreach ($sourcePlan in @($plan.Sources)) {
        $sourcePlansById[[string]$sourcePlan.id] = $sourcePlan
    }
    $skillProvenance = @(
        foreach ($skill in @($resolved.Skills | Sort-Object id)) {
            $sourcePlan = $sourcePlansById[[string]$skill.sourceId]
            [ordered]@{
                id = [string]$skill.id
                sourceId = [string]$sourcePlan.id
                sourceRepository = [string]$sourcePlan.repository
                sourceRef = [string]$sourcePlan.requestedRef
                sourceCommit = [string]$sourcePlan.resolvedCommit
                sourceVersion = [string]$sourcePlan.resolvedVersion
            }
        }
    )
    $provenance = [ordered]@{
        schemaVersion = 1
        catalogId = [string]$catalog.catalogId
        lockSha256 = Get-RawFileSha256 -Path $LockPath
        instruction = [ordered]@{
            sourceId = 'ai-instructions'
            sourceRepository = $SourceRepository
            sourceRef = $SourceRef
            sourceCommit = $InstructionSourceCommit
            sourceVersion = "commit@$($InstructionSourceCommit.Substring(0, 8))"
        }
        skills = $skillProvenance
    }
    $provenanceJson = ($provenance | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($provenancePath, $provenanceJson, (New-Object System.Text.UTF8Encoding($false)))

    $legacyConfiguration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($configuration.autoCommitRepositoryUrls)
        excludedRepositoryUrls = @($configuration.excludedRepositoryUrls)
        excludedRepositoryPaths = @($configuration.excludedRepositoryPaths)
    }
    $legacyJson = ($legacyConfiguration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($legacyConfigurationPath, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))

    $arguments = @{
        SourceRepository = $SourceRepository
        SourceRef = $SourceRef
        SourceArchivePath = $composedArchive
        ConfigurationPath = $legacyConfigurationPath
        ProvenancePath = $provenancePath
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
        $arguments.TargetRoot = $TargetRoot
    }

    & (Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1') @arguments
}
finally {
    $resolvedWorkingRoot = [System.IO.Path]::GetFullPath($workingRoot)
    $expectedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe multi-source temporary cleanup path: $resolvedWorkingRoot"
    }

    try {
        Remove-Item -LiteralPath $resolvedWorkingRoot -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to clean up multi-source working directory '$resolvedWorkingRoot': $($_.Exception.Message)"
    }
}
