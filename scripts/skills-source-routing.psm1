Set-StrictMode -Version 2.0

function Assert-RoutingStableId {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string] $Value) -or
        [string] $Value -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "$Context must be a lowercase stable ID."
    }
}

function Assert-RoutingSafeRepositoryPath {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        throw "$Context must be a non-empty repository-relative path."
    }

    $path = [string] $Value
    if ($path.StartsWith('/') -or
        $path.EndsWith('/') -or
        $path.Contains('\') -or
        $path.Contains('//') -or
        $path.Contains(':')) {
        throw "Unsafe repository path for ${Context}: $path"
    }

    foreach ($segment in $path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Unsafe repository path for ${Context}: $path"
        }
    }
}

function Get-RoutingProperty {
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

function Resolve-SkillsSourcePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $SkillIds
    )

    $catalogSourcesById = @{}
    foreach ($source in @(Get-RoutingProperty -Object $Catalog -Name 'sources' -Context 'Skills Catalog')) {
        $sourceId = [string] (Get-RoutingProperty -Object $source -Name 'id' -Context 'Skills Catalog source')
        Assert-RoutingStableId -Value $sourceId -Context 'Skills Catalog source id'
        if ($catalogSourcesById.ContainsKey($sourceId)) {
            throw "Duplicate Skills Catalog source ID: $sourceId"
        }
        $catalogSourcesById[$sourceId] = $source
    }

    $lockedSourcesById = @{}
    foreach ($source in @(Get-RoutingProperty -Object $Lock -Name 'sources' -Context 'Skills Catalog lock')) {
        $sourceId = [string] (Get-RoutingProperty -Object $source -Name 'id' -Context 'Skills Catalog lock source')
        Assert-RoutingStableId -Value $sourceId -Context 'Skills Catalog lock source id'
        if ($lockedSourcesById.ContainsKey($sourceId)) {
            throw "Duplicate Skills Catalog lock source ID: $sourceId"
        }
        if (-not $catalogSourcesById.ContainsKey($sourceId)) {
            throw "Skills Catalog lock references unknown source '$sourceId'."
        }
        $lockedSourcesById[$sourceId] = $source
    }

    $catalogSkillsById = @{}
    foreach ($skill in @(Get-RoutingProperty -Object $Catalog -Name 'skills' -Context 'Skills Catalog')) {
        $skillId = [string] (Get-RoutingProperty -Object $skill -Name 'id' -Context 'Skills Catalog Skill')
        Assert-RoutingStableId -Value $skillId -Context 'Skills Catalog Skill id'
        if ($catalogSkillsById.ContainsKey($skillId)) {
            throw "Duplicate stable Skill ID: $skillId"
        }
        $catalogSkillsById[$skillId] = $skill
    }

    $lockedSkillsById = @{}
    foreach ($skill in @(Get-RoutingProperty -Object $Lock -Name 'skills' -Context 'Skills Catalog lock')) {
        $skillId = [string] (Get-RoutingProperty -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill')
        if ($lockedSkillsById.ContainsKey($skillId)) {
            throw "Duplicate Skills Catalog lock Skill ID: $skillId"
        }
        $lockedSkillsById[$skillId] = $skill
    }

    $requestedSkillIds = @()
    $seenSkillIds = @{}
    foreach ($skillIdValue in @($SkillIds)) {
        $skillId = [string] $skillIdValue
        Assert-RoutingStableId -Value $skillId -Context 'Selected Skill id'
        if ($seenSkillIds.ContainsKey($skillId)) {
            continue
        }
        $seenSkillIds[$skillId] = $true
        $requestedSkillIds += $skillId
    }

    $selectedSkills = @()
    $requiredSourceIds = @{}

    foreach ($skillId in @($requestedSkillIds | Sort-Object)) {
        if (-not $catalogSkillsById.ContainsKey($skillId)) {
            throw "Selected Skill '$skillId' does not exist in the Skills Catalog."
        }
        if (-not $lockedSkillsById.ContainsKey($skillId)) {
            throw "Selected Skill '$skillId' has no lock entry."
        }

        $catalogSkill = $catalogSkillsById[$skillId]
        $lifecycle = Get-RoutingProperty -Object $catalogSkill -Name 'lifecycle' -Context "Skills Catalog Skill '$skillId'"
        if ([string] (Get-RoutingProperty -Object $lifecycle -Name 'status' -Context "Skills Catalog Skill '$skillId' lifecycle") -eq 'removed') {
            throw "Selected Skill '$skillId' is removed."
        }

        $catalogSource = Get-RoutingProperty -Object $catalogSkill -Name 'source' -Context "Skills Catalog Skill '$skillId'"
        $sourceId = [string] (Get-RoutingProperty -Object $catalogSource -Name 'sourceId' -Context "Skills Catalog Skill '$skillId' source")
        $sourcePath = [string] (Get-RoutingProperty -Object $catalogSource -Name 'path' -Context "Skills Catalog Skill '$skillId' source")
        Assert-RoutingStableId -Value $sourceId -Context "Skills Catalog Skill '$skillId' sourceId"
        Assert-RoutingSafeRepositoryPath -Value $sourcePath -Context "Skill '$skillId' source"

        if (-not $catalogSourcesById.ContainsKey($sourceId)) {
            throw "Skills Catalog Skill '$skillId' references unknown source '$sourceId'."
        }
        if (-not $lockedSourcesById.ContainsKey($sourceId)) {
            throw "Selected Skill '$skillId' source '$sourceId' has no lock entry."
        }

        $lockedSkill = $lockedSkillsById[$skillId]
        $lockedSourceId = [string] (Get-RoutingProperty -Object $lockedSkill -Name 'sourceId' -Context "Skills Catalog lock Skill '$skillId'")
        $lockedSourcePath = [string] (Get-RoutingProperty -Object $lockedSkill -Name 'sourcePath' -Context "Skills Catalog lock Skill '$skillId'")
        if ($lockedSourceId -cne $sourceId -or $lockedSourcePath -cne $sourcePath) {
            throw "Skills Catalog lock source does not match catalog Skill '$skillId'."
        }

        $requiredSourceIds[$sourceId] = $true
        $selectedSkills += [pscustomobject][ordered]@{
            id = $skillId
            sourceId = $sourceId
            sourcePath = $sourcePath
            contentSha256 = [string] (Get-RoutingProperty -Object $lockedSkill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$skillId'")
        }
    }

    $requiredSources = @()
    foreach ($sourceId in @($requiredSourceIds.Keys | Sort-Object)) {
        $catalogSource = $catalogSourcesById[$sourceId]
        $lockedSource = $lockedSourcesById[$sourceId]
        $catalogRepository = [string] (Get-RoutingProperty -Object $catalogSource -Name 'repository' -Context "Skills Catalog source '$sourceId'")
        $lockedRepository = [string] (Get-RoutingProperty -Object $lockedSource -Name 'repository' -Context "Skills Catalog lock source '$sourceId'")
        if ($catalogRepository -cne $lockedRepository) {
            throw "Skills Catalog lock source '$sourceId' repository does not match the catalog."
        }

        $requiredSources += [pscustomobject][ordered]@{
            id = $sourceId
            repository = $lockedRepository
            requestedRef = [string] (Get-RoutingProperty -Object $lockedSource -Name 'requestedRef' -Context "Skills Catalog lock source '$sourceId'")
            requestedRefType = [string] (Get-RoutingProperty -Object $lockedSource -Name 'requestedRefType' -Context "Skills Catalog lock source '$sourceId'")
            resolvedCommit = [string] (Get-RoutingProperty -Object $lockedSource -Name 'resolvedCommit' -Context "Skills Catalog lock source '$sourceId'")
            resolvedVersion = [string] (Get-RoutingProperty -Object $lockedSource -Name 'resolvedVersion' -Context "Skills Catalog lock source '$sourceId'")
            archiveSha256 = [string] (Get-RoutingProperty -Object $lockedSource -Name 'archiveSha256' -Context "Skills Catalog lock source '$sourceId'")
        }
    }

    return [pscustomobject][ordered]@{
        Sources = $requiredSources
        Skills = $selectedSkills
    }
}

Export-ModuleMember -Function Resolve-SkillsSourcePlan
