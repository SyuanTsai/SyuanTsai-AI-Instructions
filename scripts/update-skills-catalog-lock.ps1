[CmdletBinding()]
param(
    [string] $CatalogPath,
    [string] $SourcePinsPath,
    [string] $OutputPath,
    [switch] $Check
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $scriptRoot

if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $CatalogPath = Join-Path $repositoryRoot 'catalog\skills-catalog.json'
}
if ([string]::IsNullOrWhiteSpace($SourcePinsPath)) {
    $SourcePinsPath = Join-Path $repositoryRoot 'catalog\skills-catalog.sources.json'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot 'catalog\skills-catalog-lock.json'
}

Import-Module (Join-Path $scriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-retrieval.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-acquisition.psm1') -Force

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

function Get-RawSha256 {
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Content
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $fullPath,
        $Content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Assert-SourcePins {
    param(
        [Parameter(Mandatory = $true)][object] $Pins,
        [Parameter(Mandatory = $true)][object] $Catalog
    )

    if ($Pins.schemaVersion -ne 1) {
        throw "Unsupported Skills Catalog source pins schemaVersion '$($Pins.schemaVersion)'; expected 1."
    }
    if ([string]$Pins.catalogId -ne [string]$Catalog.catalogId) {
        throw 'Skills Catalog source pins catalogId does not match the Catalog.'
    }

    $catalogSources = @{}
    foreach ($source in @($Catalog.sources)) {
        $catalogSources[[string]$source.id] = $source
    }

    $pinsById = @{}
    foreach ($pin in @($Pins.sources)) {
        $id = [string]$pin.id
        if ([string]::IsNullOrWhiteSpace($id) -or $pinsById.ContainsKey($id)) {
            throw "Duplicate or empty Skills Catalog source pin ID: $id"
        }
        if (-not $catalogSources.ContainsKey($id)) {
            throw "Skills Catalog source pins reference unknown source '$id'."
        }
        if ([string]$pin.requestedRefType -notin @('branch', 'tag', 'commit')) {
            throw "Unsupported requestedRefType '$($pin.requestedRefType)' for source '$id'."
        }
        if ([string]$pin.resolvedCommit -notmatch '^[0-9a-f]{40}$') {
            throw "Source '$id' resolvedCommit must be a full 40-character commit SHA."
        }
        if ([string]::IsNullOrWhiteSpace([string]$pin.requestedRef)) {
            throw "Source '$id' requestedRef must be non-empty."
        }
        if ([string]::IsNullOrWhiteSpace([string]$pin.resolvedVersion)) {
            throw "Source '$id' resolvedVersion must be non-empty."
        }
        $pinsById[$id] = $pin
    }

    foreach ($id in $catalogSources.Keys) {
        if (-not $pinsById.ContainsKey([string]$id)) {
            throw "Skills Catalog source '$id' has no source pin."
        }
    }

    return $pinsById
}

$catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
$pins = Read-JsonDocument -Path $SourcePinsPath -Name 'Skills Catalog source pins'
$pinsById = Assert-SourcePins -Pins $pins -Catalog $catalog

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
            resolvedCommit = [string]$pin.resolvedCommit
        }
    }

    $retrievalPlan = [pscustomobject][ordered]@{
        Sources = $retrievalSources
        Skills = @()
    }
    $archives = Get-SkillsSourceArchives -Plan $retrievalPlan -DestinationRoot $downloadRoot

    $sourceRoots = @{}
    $lockSources = @()
    foreach ($source in @($catalog.sources | Sort-Object id)) {
        $id = [string]$source.id
        $pin = $pinsById[$id]
        $archivePath = [string]$archives[$id]
        $archiveSha256 = Get-RawSha256 -Path $archivePath

        $destination = Join-Path $extractRoot $id
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $destination -ErrorAction Stop
        $roots = @(Get-ChildItem -LiteralPath $destination -Directory -Force)
        if ($roots.Count -ne 1) {
            throw "Source '$id' archive must contain exactly one repository root; found $($roots.Count)."
        }
        $sourceRoots[$id] = $roots[0].FullName

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
        $sourcePath = [string]$skill.source.path
        if (-not $sourceRoots.ContainsKey($sourceId)) {
            throw "Skill '$id' references source '$sourceId' that was not extracted."
        }

        $repositoryRootPath = [string]$sourceRoots[$sourceId]
        $skillRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRootPath $sourcePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
            throw "Skill '$id' is missing from source '$sourceId': $sourcePath"
        }
        $skillDefinition = Join-Path $skillRoot 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillDefinition -PathType Leaf)) {
            throw "Skill '$id' is missing SKILL.md in source '$sourceId'."
        }
        Assert-SkillDefinition -SkillDefinitionPath $skillDefinition -ExpectedSkillId $id

        $lockSkills += [ordered]@{
            id = $id
            sourceId = $sourceId
            sourcePath = $sourcePath
            contentSha256 = Get-SkillInventorySha256 -RepositoryRoot $repositoryRootPath -SkillRoot $skillRoot
        }
    }

    $lock = [ordered]@{
        schemaVersion = 1
        catalogId = [string]$catalog.catalogId
        catalogSha256 = Get-RawSha256 -Path $CatalogPath
        sources = @($lockSources)
        skills = @($lockSkills)
    }

    $json = ($lock | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n"
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

    if ($Check) {
        if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
            throw "Skills Catalog lock does not exist: $resolvedOutputPath"
        }
        $existing = [System.IO.File]::ReadAllText($resolvedOutputPath).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($existing -ne $json) {
            throw 'Skills Catalog lock is stale. Run scripts/update-skills-catalog-lock.ps1 and commit the result.'
        }
        Write-Output "Skills Catalog lock is current: $resolvedOutputPath"
    }
    else {
        Write-Utf8NoBom -Path $resolvedOutputPath -Content $json
        Write-Output "Updated Skills Catalog lock: $resolvedOutputPath"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
