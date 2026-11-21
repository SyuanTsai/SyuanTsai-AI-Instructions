[CmdletBinding()]
param(
    [string] $CatalogPath,
    [string] $SourcePinsPath,
    [string] $OutputPath,
    [string] $BaseLockPath,
    [hashtable] $SourceArchivePaths = @{},
    [switch] $Check
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $scriptRoot

if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $repositoryRoot 'catalog\skills-catalog.json' }
if ([string]::IsNullOrWhiteSpace($SourcePinsPath)) { $SourcePinsPath = Join-Path $repositoryRoot 'catalog\skills-catalog.sources.json' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repositoryRoot 'catalog\skills-catalog-lock.json' }

Import-Module (Join-Path $scriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-retrieval.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-acquisition.psm1') -Force
Import-Module (Join-Path $scriptRoot 'safe-zip.psm1') -Force

function Get-RawSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Content)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($fullPath,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function New-ProjectionLockFromExistingLock {
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Pins,
        [Parameter(Mandatory = $true)][string] $ExistingLockPath
    )

    if (-not (Test-Path -LiteralPath $ExistingLockPath -PathType Leaf)) {
        throw "Skills Catalog base Lock does not exist: $ExistingLockPath"
    }
    try { $existingLock = Get-Content -Raw -Encoding UTF8 -LiteralPath $ExistingLockPath | ConvertFrom-Json }
    catch { throw "Skills Catalog base Lock is not valid JSON: $ExistingLockPath" }
    if ($existingLock.schemaVersion -isnot [int] -and $existingLock.schemaVersion -isnot [long]) {
        throw 'Skills Catalog base Lock schemaVersion must be an integer.'
    }
    if ([int64]$existingLock.schemaVersion -notin @(2,3)) {
        throw 'Skills Catalog v3 conversion accepts only an existing v2 or v3 Lock.'
    }
    if ([string]$existingLock.catalogId -cne [string]$Catalog.catalogId) {
        throw 'Skills Catalog base Lock catalogId does not match the Catalog.'
    }

    $pinsById = @{}
    foreach ($pin in @($Pins.sources)) {
        if ($pinsById.ContainsKey([string]$pin.id)) { throw "Duplicate source pin '$([string]$pin.id)'." }
        $pinsById[[string]$pin.id] = $pin
    }
    $existingSourcesById = @{}
    foreach ($source in @($existingLock.sources)) {
        if ($existingSourcesById.ContainsKey([string]$source.id)) { throw "Duplicate source '$([string]$source.id)' in the base Lock." }
        $existingSourcesById[[string]$source.id] = $source
    }
    if ($existingSourcesById.Count -ne @($Catalog.sources).Count) {
        throw 'Skills Catalog base Lock source inventory does not match the Catalog.'
    }

    $lockSources = @()
    foreach ($source in @($Catalog.sources | Sort-Object id)) {
        $sourceId = [string]$source.id
        if (-not $pinsById.ContainsKey($sourceId) -or -not $existingSourcesById.ContainsKey($sourceId)) {
            throw "Skills Catalog base Lock is missing source '$sourceId'."
        }
        $pin = $pinsById[$sourceId]
        $existingSource = $existingSourcesById[$sourceId]
        foreach ($property in @('requestedRef','requestedRefType','resolvedCommit','resolvedVersion')) {
            if ([string]$existingSource.$property -cne [string]$pin.$property) {
                throw "Skills Catalog base Lock source '$sourceId' changed '$property'."
            }
        }
        if ([string]$existingSource.repository -cne [string]$source.repository) {
            throw "Skills Catalog base Lock source '$sourceId' changed repository."
        }
        if ([string]$existingSource.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Skills Catalog base Lock source '$sourceId' has an invalid archiveSha256."
        }
        $lockSources += [ordered]@{
            id = $sourceId
            repository = [string]$existingSource.repository
            requestedRef = [string]$existingSource.requestedRef
            requestedRefType = [string]$existingSource.requestedRefType
            resolvedCommit = [string]$existingSource.resolvedCommit
            resolvedVersion = [string]$existingSource.resolvedVersion
            archiveSha256 = [string]$existingSource.archiveSha256
        }
    }

    $activeSkills = @($Catalog.skills | Where-Object { [string]$_.lifecycle.status -ne 'removed' })
    $existingSkillsById = @{}
    foreach ($skill in @($existingLock.skills)) {
        if ($existingSkillsById.ContainsKey([string]$skill.id)) { throw "Duplicate Skill '$([string]$skill.id)' in the base Lock." }
        $existingSkillsById[[string]$skill.id] = $skill
    }
    if ($existingSkillsById.Count -ne $activeSkills.Count) {
        throw 'Skills Catalog base Lock Skill inventory does not match the Catalog.'
    }

    $lockSkills = @()
    foreach ($skill in @($activeSkills | Sort-Object id)) {
        $skillId = [string]$skill.id
        if (-not $existingSkillsById.ContainsKey($skillId)) { throw "Skills Catalog base Lock is missing Skill '$skillId'." }
        $existingSkill = $existingSkillsById[$skillId]
        if ([string]$existingSkill.sourceId -cne [string]$skill.source.sourceId -or
            [string]$existingSkill.sourcePath -cne [string]$skill.source.sourcePath) {
            throw "Skills Catalog base Lock source pin changed for Skill '$skillId'."
        }
        if ([string]$existingSkill.contentSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Skills Catalog base Lock Skill '$skillId' has an invalid contentSha256."
        }
        $lockSkills += [ordered]@{
            id = $skillId
            sourceId = [string]$existingSkill.sourceId
            sourcePath = [string]$existingSkill.sourcePath
            contentSha256 = [string]$existingSkill.contentSha256
        }
    }

    return [ordered]@{
        schemaVersion = 3
        catalogId = [string]$Catalog.catalogId
        catalogSha256 = Get-RawSha256 -Path $CatalogPath
        projectionContractSha256 = Get-SkillsCatalogProjectionContractSha256 -Projections $Catalog.projections
        sources = @($lockSources)
        skills = @($lockSkills)
    }
}

$catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
$pins = Test-SkillsCatalogSourcePinsDocument -SourcePinsPath $SourcePinsPath -CatalogPath $CatalogPath
$pinsById = @{}
foreach ($pin in @($pins.sources)) { $pinsById[[string]$pin.id] = $pin }

if ([int64]$catalog.schemaVersion -eq 3) {
    $conversionLockPath = if (-not [string]::IsNullOrWhiteSpace($BaseLockPath)) { [System.IO.Path]::GetFullPath($BaseLockPath) } else { $null }
    if ($null -ne $conversionLockPath) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
        $pathComparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else { [System.StringComparison]::Ordinal }
        if ([string]::Equals($conversionLockPath,$resolvedOutputPath,$pathComparison)) {
            throw 'Skills Catalog base Lock path must not equal the output path.'
        }
        $lock = New-ProjectionLockFromExistingLock -Catalog $catalog -Pins $pins -ExistingLockPath $conversionLockPath
        $json = ($lock | ConvertTo-Json -Depth 20 -Compress) + "`n"
        if ($Check) {
            if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) { throw "Skills Catalog lock does not exist: $resolvedOutputPath" }
            $existing = [System.IO.File]::ReadAllText($resolvedOutputPath).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($existing -ne $json) { throw 'Skills Catalog lock is stale. Run scripts/update-skills-catalog-lock.ps1 and commit the result.' }
            Write-Output "Skills Catalog lock is current: $resolvedOutputPath"
        }
        else {
            Write-Utf8NoBom -Path $resolvedOutputPath -Content $json
            Write-Output "Updated Skills Catalog lock from existing immutable pins: $resolvedOutputPath"
        }
        return
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skills-catalog-lock-' + [Guid]::NewGuid().ToString('N'))
$downloadRoot = Join-Path $tempRoot 'downloads'
$extractRoot = Join-Path $tempRoot 'sources'

try {
    New-Item -ItemType Directory -Path $downloadRoot, $extractRoot -Force | Out-Null

    $retrievalSources = @()
    foreach ($source in @($catalog.sources)) {
        $pin = $pinsById[[string]$source.id]
        $retrievalSources += [pscustomobject][ordered]@{
            id = [string]$source.id
            repository = [string]$source.repository
            requestedRef = [string]$pin.requestedRef
            requestedRefType = [string]$pin.requestedRefType
            resolvedCommit = [string]$pin.resolvedCommit
        }
    }

    $retrievalPlan = [pscustomobject][ordered]@{ Sources = $retrievalSources; Skills = @() }
    $archives = Get-SkillsSourceArchives -Plan $retrievalPlan -DestinationRoot $downloadRoot -LocalArchiveOverrides $SourceArchivePaths

    $sourceRoots = @{}
    $lockSources = @()
    foreach ($source in @($catalog.sources | Sort-Object id)) {
        $id = [string]$source.id
        $pin = $pinsById[$id]
        $archivePath = [string]$archives[$id]
        $archiveSha256 = Get-RawSha256 -Path $archivePath
        $destination = Join-Path $extractRoot $id
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $sourceRoots[$id] = Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot $destination
        $lockSources += [ordered]@{
            id = $id
            repository = [string]$source.repository
            requestedRef = [string]$pin.requestedRef
            requestedRefType = [string]$pin.requestedRefType
            resolvedCommit = [string]$pin.resolvedCommit
            resolvedVersion = [string]$pin.resolvedVersion
            archiveSha256 = $archiveSha256
        }
    }

    $lockSkills = @()
    foreach ($skill in @($catalog.skills | Where-Object { [string]$_.lifecycle.status -ne 'removed' } | Sort-Object id)) {
        $id = [string]$skill.id
        $sourceId = [string]$skill.source.sourceId
        $sourcePath = if ([int64]$catalog.schemaVersion -in @(2,3)) { [string]$skill.source.sourcePath } else { [string]$skill.source.path }
        $targetPath = if ([int64]$catalog.schemaVersion -eq 2) { [string]$skill.source.targetPath } elseif ([int64]$catalog.schemaVersion -eq 1) { ".agents/skills/$id" } else { $null }
        if (-not $sourceRoots.ContainsKey($sourceId)) { throw "Skill '$id' references source '$sourceId' that was not extracted." }
        $repositoryRootPath = [string]$sourceRoots[$sourceId]
        $skillRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRootPath $sourcePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) { throw "Skill '$id' is missing from source '$sourceId': $sourcePath" }
        $skillDefinition = Join-Path $skillRoot 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillDefinition -PathType Leaf)) { throw "Skill '$id' is missing SKILL.md in source '$sourceId'." }
        Assert-SkillDefinition -SkillDefinitionPath $skillDefinition -ExpectedSkillId $id
        $lockSkill = [ordered]@{
            id = $id
            sourceId = $sourceId
            sourcePath = $sourcePath
            contentSha256 = Get-SkillInventorySha256 -RepositoryRoot $repositoryRootPath -SkillRoot $skillRoot
        }
        if ([int64]$catalog.schemaVersion -eq 2) { $lockSkill.targetPath = $targetPath }
        $lockSkills += $lockSkill
    }

    $lock = [ordered]@{
        schemaVersion = [int64]$catalog.schemaVersion
        catalogId = [string]$catalog.catalogId
        catalogSha256 = Get-RawSha256 -Path $CatalogPath
    }
    if ([int64]$catalog.schemaVersion -eq 3) {
        $lock.projectionContractSha256 = Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections
    }
    $lock.sources = @($lockSources)
    $lock.skills = @($lockSkills)
    $json = ($lock | ConvertTo-Json -Depth 20 -Compress) + "`n"
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

    if ($Check) {
        if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) { throw "Skills Catalog lock does not exist: $resolvedOutputPath" }
        $existing = [System.IO.File]::ReadAllText($resolvedOutputPath).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($existing -ne $json) { throw 'Skills Catalog lock is stale. Run scripts/update-skills-catalog-lock.ps1 and commit the result.' }
        Write-Output "Skills Catalog lock is current: $resolvedOutputPath"
    }
    else {
        Write-Utf8NoBom -Path $resolvedOutputPath -Content $json
        Write-Output "Updated Skills Catalog lock: $resolvedOutputPath"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
