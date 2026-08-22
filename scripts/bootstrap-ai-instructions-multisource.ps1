[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [Parameter(Mandatory = $true)][string] $LockPath,
    [Parameter(Mandatory = $true)][string] $ConfigurationPath,
    [hashtable] $SourceArchivePaths = @{},
    [string] $InstructionSourceArchivePath,
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

function Assert-StableIdArrayValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-StringArrayValue -Value $Value -Context $Context
    $seen = @{}
    foreach ($item in @($Value)) {
        if ([string]$item -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "$Context item must be a lowercase stable ID: $item"
        }
        if ($seen.ContainsKey([string]$item)) {
            throw "$Context contains duplicate value '$item'."
        }
        $seen[[string]$item] = $true
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
        Assert-StableIdArrayValue -Value $value -Context "AI instruction sync configuration catalog $name"
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
$routingConfigurationPath = Join-Path $workingRoot 'routing-v2.json'
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

    $routingConfiguration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($configuration.autoCommitRepositoryUrls)
        excludedRepositoryUrls = @($configuration.excludedRepositoryUrls)
        excludedRepositoryPaths = @($configuration.excludedRepositoryPaths)
    }
    $routingJson = ($routingConfiguration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($routingConfigurationPath, $routingJson, (New-Object System.Text.UTF8Encoding($false)))

    $arguments = @{
        SourceArchivePath = $composedArchive
        ConfigurationPath = $routingConfigurationPath
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
