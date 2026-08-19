Set-StrictMode -Version 2.0

function Import-SkillsCatalogJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $DocumentName
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$DocumentName does not exist: $fullPath"
    }

    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $fullPath | ConvertFrom-Json
    }
    catch {
        throw "$DocumentName is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
}

function Test-HasProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }

    Write-Output -NoEnumerate $property.Value
}

function Assert-NonEmptyString {
    param(
        [object] $Value,
        [string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        throw "$Context must be a non-empty string."
    }
}

function Assert-StableId {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    if ([string] $Value -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "$Context must be lowercase kebab-case and at most 64 characters: $Value"
    }
}

function Assert-StringArray {
    param(
        [object] $Value,
        [string] $Context,
        [switch] $AllowEmpty
    )

    if ($null -eq $Value -or $Value -isnot [System.Array]) {
        throw "$Context must be an array."
    }

    $values = @($Value)
    if (-not $AllowEmpty -and $values.Count -eq 0) {
        throw "$Context must contain at least one value."
    }

    $seen = @{}
    foreach ($item in $values) {
        Assert-NonEmptyString -Value $item -Context $Context
        $key = ([string] $item).ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "$Context contains duplicate value '$item'."
        }
        $seen[$key] = $true
    }
}

function Assert-StableIdArray {
    param(
        [object] $Value,
        [string] $Context,
        [switch] $AllowEmpty
    )

    Assert-StringArray -Value $Value -Context $Context -AllowEmpty:$AllowEmpty
    foreach ($item in @($Value)) {
        Assert-StableId -Value $item -Context "$Context item"
    }
}

function Assert-Capability {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    if ([string] $Value -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "$Context must be lowercase kebab-case and at most 64 characters: $Value"
    }
}

function Assert-CapabilityRequirement {
    param(
        [object] $Requirement,
        [string] $Context
    )

    if ($null -eq $Requirement) {
        throw "$Context must be an object."
    }

    $kind = Get-RequiredProperty -Object $Requirement -Name 'kind' -Context $Context
    Assert-NonEmptyString -Value $kind -Context "$Context kind"
    if (@('allOf', 'anyOf') -cnotcontains [string] $kind) {
        throw "Unsupported $Context kind '$kind'."
    }

    $capabilities = Get-RequiredProperty -Object $Requirement -Name 'capabilities' -Context $Context
    Assert-StringArray -Value $capabilities -Context "$Context capabilities"
    foreach ($capability in @($capabilities)) {
        Assert-Capability -Value $capability -Context "$Context capability"
    }
}

function Assert-ConditionalDependency {
    param(
        [object] $Dependency,
        [string] $Context
    )

    $condition = Get-RequiredProperty -Object $Dependency -Name 'condition' -Context $Context
    if ($null -eq $condition) {
        throw "$Context condition must be an object."
    }

    $capability = Get-RequiredProperty -Object $condition -Name 'capability' -Context "$Context condition"
    Assert-Capability -Value $capability -Context "$Context condition capability"

    $whenUnavailable = Get-RequiredProperty -Object $Dependency -Name 'whenUnavailable' -Context $Context
    if ($null -eq $whenUnavailable) {
        throw "$Context whenUnavailable must be an object."
    }

    $skillId = Get-RequiredProperty -Object $whenUnavailable -Name 'skillId' -Context "$Context whenUnavailable"
    Assert-StableId -Value $skillId -Context "$Context whenUnavailable skillId"
}

function Assert-Dependency {
    param(
        [object] $Dependency,
        [string] $Context
    )

    if ($null -eq $Dependency) {
        throw "$Context must be an object."
    }

    $type = Get-RequiredProperty -Object $Dependency -Name 'type' -Context $Context
    Assert-NonEmptyString -Value $type -Context "$Context type"
    if (@('required', 'optional', 'conditional') -cnotcontains [string] $type) {
        throw "Unsupported dependency type '$type' in $Context."
    }

    if ($type -eq 'conditional') {
        Assert-ConditionalDependency -Dependency $Dependency -Context $Context
        return
    }

    $skillId = Get-RequiredProperty -Object $Dependency -Name 'skillId' -Context $Context
    Assert-StableId -Value $skillId -Context "$Context skillId"
}

function Assert-HttpsRepositoryUrl {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    $uri = $null
    if (-not [System.Uri]::TryCreate([string] $Value, [System.UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -ne 'https') {
        throw "$Context must be an absolute HTTPS URL: $Value"
    }
}

function Assert-Array {
    param(
        [object] $Value,
        [string] $Context
    )

    if ($null -eq $Value -or $Value -isnot [System.Array]) {
        throw "$Context must be an array."
    }
}

function Assert-Boolean {
    param(
        [object] $Value,
        [string] $Context
    )

    if ($Value -isnot [bool]) {
        throw "$Context must be a boolean."
    }
}

function Assert-SafeSkillSourcePath {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    $normalized = ([string] $Value).Replace('\\', '/')
    if ($normalized -notmatch '^\.agents/skills/[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        $normalized.Contains('../') -or
        $normalized.Contains('/..') -or
        [System.IO.Path]::IsPathRooted($normalized)) {
        throw "Unsafe Skill source path '$Value' in $Context."
    }
}

function Assert-Sha256 {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    if ([string] $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase 64-character SHA-256 hash."
    }
}

function Assert-CommitSha {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    if ([string] $Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context resolvedCommit must be a full 40-character commit SHA."
    }
}

function Assert-SchemaVersion {
    param(
        [object] $Document,
        [int] $Expected,
        [string] $DocumentName
    )

    $schemaVersion = Get-RequiredProperty -Object $Document -Name 'schemaVersion' -Context $DocumentName
    if ($schemaVersion -ne $Expected) {
        throw "Unsupported $DocumentName schemaVersion '$schemaVersion'; expected $Expected."
    }
}

function Assert-SkillsCatalog {
    param([object] $Catalog)

    Assert-SchemaVersion -Document $Catalog -Expected 1 -DocumentName 'Skills Catalog'
    $catalogId = Get-RequiredProperty -Object $Catalog -Name 'catalogId' -Context 'Skills Catalog'
    Assert-StableId -Value $catalogId -Context 'Skills Catalog catalogId'

    $sources = Get-RequiredProperty -Object $Catalog -Name 'sources' -Context 'Skills Catalog'
    Assert-Array -Value $sources -Context 'Skills Catalog sources'
    $sourceIds = @{}
    foreach ($source in @($sources)) {
        $sourceId = Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog source'
        Assert-StableId -Value $sourceId -Context 'Skills Catalog source id'
        if ($sourceIds.ContainsKey([string] $sourceId)) {
            throw "Duplicate Skills Catalog source ID: $sourceId"
        }
        $sourceIds[[string] $sourceId] = $true
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog source '$sourceId'") -Context "Skills Catalog source '$sourceId' repository"
    }
    if ($sourceIds.Count -eq 0) {
        throw 'Skills Catalog must contain at least one source.'
    }

    $profiles = Get-RequiredProperty -Object $Catalog -Name 'profiles' -Context 'Skills Catalog'
    Assert-Array -Value $profiles -Context 'Skills Catalog profiles'
    $profileIds = @{}
    $profileDocuments = @{}
    foreach ($profile in @($profiles)) {
        $profileId = Get-RequiredProperty -Object $profile -Name 'id' -Context 'Skills Catalog profile'
        Assert-StableId -Value $profileId -Context 'Skills Catalog profile id'
        if ($profileIds.ContainsKey([string] $profileId)) {
            throw "Duplicate Skills Catalog profile ID: $profileId"
        }
        $profileIds[[string] $profileId] = $true
        $profileDocuments[[string] $profileId] = $profile
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $profile -Name 'description' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' description"
        Assert-Boolean -Value (Get-RequiredProperty -Object $profile -Name 'default' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' default"
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $profile -Name 'includes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' includes" -AllowEmpty
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $profile -Name 'excludes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' excludes" -AllowEmpty
    }

    $skills = Get-RequiredProperty -Object $Catalog -Name 'skills' -Context 'Skills Catalog'
    Assert-Array -Value $skills -Context 'Skills Catalog skills'
    $skillIds = @{}
    foreach ($skill in @($skills)) {
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog Skill id'
        if ($skillIds.ContainsKey([string] $skillId)) {
            throw "Duplicate stable Skill ID: $skillId"
        }
        $skillIds[[string] $skillId] = $true

        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $skill -Name 'group' -Context "Skills Catalog Skill '$skillId'") -Context "Skills Catalog Skill '$skillId' group"

        $source = Get-RequiredProperty -Object $skill -Name 'source' -Context "Skills Catalog Skill '$skillId'"
        $sourceId = Get-RequiredProperty -Object $source -Name 'sourceId' -Context "Skills Catalog Skill '$skillId' source"
        Assert-StableId -Value $sourceId -Context "Skills Catalog Skill '$skillId' sourceId"
        if (-not $sourceIds.ContainsKey([string] $sourceId)) {
            throw "Skills Catalog Skill '$skillId' references unknown source '$sourceId'."
        }
        Assert-SafeSkillSourcePath -Value (Get-RequiredProperty -Object $source -Name 'path' -Context "Skills Catalog Skill '$skillId' source") -Context "Skills Catalog Skill '$skillId' source path"

        Assert-StableIdArray -Value (Get-RequiredProperty -Object $skill -Name 'profiles' -Context "Skills Catalog Skill '$skillId'") -Context "Skills Catalog Skill '$skillId' profiles" -AllowEmpty

        $compatibility = Get-RequiredProperty -Object $skill -Name 'compatibility' -Context "Skills Catalog Skill '$skillId'"
        Assert-StringArray -Value (Get-RequiredProperty -Object $compatibility -Name 'platforms' -Context "Skills Catalog Skill '$skillId' compatibility") -Context "Skills Catalog Skill '$skillId' compatibility platforms"
        foreach ($platform in @($compatibility.platforms)) {
            if (@('any', 'windows', 'macos', 'linux') -cnotcontains [string] $platform) {
                throw "Unsupported Skills Catalog Skill '$skillId' compatibility platform '$platform'."
            }
        }
        Assert-StringArray -Value (Get-RequiredProperty -Object $compatibility -Name 'shells' -Context "Skills Catalog Skill '$skillId' compatibility") -Context "Skills Catalog Skill '$skillId' compatibility shells" -AllowEmpty
        foreach ($shell in @($compatibility.shells)) {
            if (@('any', 'powershell', 'pwsh', 'bash', 'zsh') -cnotcontains [string] $shell) {
                throw "Unsupported Skills Catalog Skill '$skillId' compatibility shell '$shell'."
            }
        }
        foreach ($requirementProperty in @('requiredCapabilities', 'anyOfCapabilities')) {
            $requirements = Get-RequiredProperty -Object $compatibility -Name $requirementProperty -Context "Skills Catalog Skill '$skillId' compatibility"
            Assert-Array -Value $requirements -Context "Skills Catalog Skill '$skillId' compatibility $requirementProperty"
            foreach ($requirement in @($requirements)) {
                Assert-CapabilityRequirement -Requirement $requirement -Context "Skills Catalog Skill '$skillId' compatibility requirement"
            }
        }

        $dependencies = Get-RequiredProperty -Object $skill -Name 'dependencies' -Context "Skills Catalog Skill '$skillId'"
        Assert-Array -Value $dependencies -Context "Skills Catalog Skill '$skillId' dependencies"
        foreach ($dependency in @($dependencies)) {
            Assert-Dependency -Dependency $dependency -Context "Skills Catalog Skill '$skillId' dependency"
        }

        $lifecycle = Get-RequiredProperty -Object $skill -Name 'lifecycle' -Context "Skills Catalog Skill '$skillId'"
        $status = Get-RequiredProperty -Object $lifecycle -Name 'status' -Context "Skills Catalog Skill '$skillId' lifecycle"
        Assert-NonEmptyString -Value $status -Context "Skills Catalog Skill '$skillId' lifecycle status"
        if (@('active', 'deprecated', 'removed') -cnotcontains [string] $status) {
            throw "Unsupported Skills Catalog Skill '$skillId' lifecycle status '$status'."
        }
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $lifecycle -Name 'aliases' -Context "Skills Catalog Skill '$skillId' lifecycle") -Context "Skills Catalog Skill '$skillId' lifecycle aliases" -AllowEmpty

        if ($status -eq 'removed') {
            $replacementId = if (Test-HasProperty -Object $lifecycle -Name 'replacementId') { $lifecycle.replacementId } else { $null }
            if ($null -ne $replacementId) {
                Assert-StableId -Value $replacementId -Context "Skills Catalog Skill '$skillId' lifecycle replacementId"
            }
        }
    }

    foreach ($profileId in $profileDocuments.Keys) {
        $profile = $profileDocuments[$profileId]
        foreach ($skillId in @($profile.includes) + @($profile.excludes)) {
            if (-not $skillIds.ContainsKey([string] $skillId)) {
                throw "Skills Catalog profile '$profileId' references unknown Skill '$skillId'."
            }
        }
    }

    foreach ($skill in @($skills)) {
        $skillId = [string] $skill.id
        foreach ($profileId in @($skill.profiles)) {
            if (-not $profileIds.ContainsKey([string] $profileId)) {
                throw "Skills Catalog Skill '$skillId' references unknown profile '$profileId'."
            }
        }
        foreach ($dependency in @($skill.dependencies)) {
            if ($dependency.type -eq 'conditional') {
                $dependencySkillId = [string] $dependency.whenUnavailable.skillId
                if (-not $skillIds.ContainsKey($dependencySkillId)) {
                    throw "Skills Catalog Skill '$skillId' conditional dependency references unknown Skill '$dependencySkillId'."
                }
            }
            else {
                $dependencySkillId = [string] $dependency.skillId
                if (-not $skillIds.ContainsKey($dependencySkillId)) {
                    throw "Skills Catalog Skill '$skillId' dependency references unknown Skill '$dependencySkillId'."
                }
            }
        }
    }
}

function Assert-SkillsCatalogLock {
    param([object] $Lock, [object] $Catalog)

    Assert-SchemaVersion -Document $Lock -Expected 1 -DocumentName 'Skills Catalog lock'
    $catalogId = Get-RequiredProperty -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock'
    Assert-StableId -Value $catalogId -Context 'Skills Catalog lock catalogId'
    if ([string] $catalogId -ne [string] $Catalog.catalogId) {
        throw 'Skills Catalog lock catalogId does not match the Skills Catalog.'
    }

    Assert-Sha256 -Value (Get-RequiredProperty -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock') -Context 'Skills Catalog lock catalogSha256'

    $sources = Get-RequiredProperty -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'
    Assert-Array -Value $sources -Context 'Skills Catalog lock sources'
    $catalogSources = @{}
    foreach ($source in @($Catalog.sources)) {
        $catalogSources[[string] $source.id] = $source
    }
    $sourceIds = @{}
    foreach ($source in @($sources)) {
        $sourceId = Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog lock source'
        Assert-StableId -Value $sourceId -Context 'Skills Catalog lock source id'
        if ($sourceIds.ContainsKey([string] $sourceId)) {
            throw "Duplicate Skills Catalog lock source ID: $sourceId"
        }
        if (-not $catalogSources.ContainsKey([string] $sourceId)) {
            throw "Skills Catalog lock references unknown source '$sourceId'."
        }
        $sourceIds[[string] $sourceId] = $true

        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' repository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'requestedRef' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' requestedRef"
        $requestedRefType = Get-RequiredProperty -Object $source -Name 'requestedRefType' -Context "Skills Catalog lock source '$sourceId'"
        if (@('branch', 'tag', 'commit') -cnotcontains [string] $requestedRefType) {
            throw "Unsupported Skills Catalog lock source '$sourceId' requestedRefType '$requestedRefType'."
        }
        Assert-CommitSha -Value (Get-RequiredProperty -Object $source -Name 'resolvedCommit' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId'"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'resolvedVersion' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' resolvedVersion"
        Assert-Sha256 -Value (Get-RequiredProperty -Object $source -Name 'archiveSha256' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' archiveSha256"
    }

    $skills = Get-RequiredProperty -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'
    Assert-Array -Value $skills -Context 'Skills Catalog lock skills'
    $catalogSkills = @{}
    foreach ($skill in @($Catalog.skills)) {
        $catalogSkills[[string] $skill.id] = $skill
    }
    $skillIds = @{}
    foreach ($skill in @($skills)) {
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog lock Skill id'
        if ($skillIds.ContainsKey([string] $skillId)) {
            throw "Duplicate Skills Catalog lock Skill ID: $skillId"
        }
        if (-not $catalogSkills.ContainsKey([string] $skillId)) {
            throw "Skills Catalog lock references unknown Skill '$skillId'."
        }
        $skillIds[[string] $skillId] = $true

        $sourceId = Get-RequiredProperty -Object $skill -Name 'sourceId' -Context "Skills Catalog lock Skill '$skillId'"
        $sourcePath = Get-RequiredProperty -Object $skill -Name 'sourcePath' -Context "Skills Catalog lock Skill '$skillId'"
        Assert-StableId -Value $sourceId -Context "Skills Catalog lock Skill '$skillId' sourceId"
        Assert-SafeSkillSourcePath -Value $sourcePath -Context "Skills Catalog lock Skill '$skillId' sourcePath"
        if ([string] $sourceId -ne [string] $catalogSkills[[string] $skillId].source.sourceId -or
            [string] $sourcePath -ne [string] $catalogSkills[[string] $skillId].source.path) {
            throw "Skills Catalog lock source does not match catalog Skill '$skillId'."
        }
        Assert-Sha256 -Value (Get-RequiredProperty -Object $skill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$skillId'") -Context "Skills Catalog lock Skill '$skillId' contentSha256"
    }
}

function Assert-ManagedManifest {
    param([object] $Manifest)

    Assert-SchemaVersion -Document $Manifest -Expected 2 -DocumentName 'Managed manifest'
    $catalogId = Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'Managed manifest'
    Assert-StableId -Value $catalogId -Context 'Managed manifest catalogId'

    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'Managed manifest'
    Assert-Array -Value $files -Context 'Managed manifest files'
    foreach ($file in @($files)) {
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $file -Name 'path' -Context 'Managed manifest file') -Context 'Managed manifest file path'
        Assert-StableId -Value (Get-RequiredProperty -Object $file -Name 'sourceId' -Context 'Managed manifest file') -Context 'Managed manifest file sourceId'
        Assert-StableId -Value (Get-RequiredProperty -Object $file -Name 'skillId' -Context 'Managed manifest file') -Context 'Managed manifest file skillId'
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $file -Name 'sourceVersion' -Context 'Managed manifest file') -Context 'Managed manifest file sourceVersion'
        Assert-CommitSha -Value (Get-RequiredProperty -Object $file -Name 'sourceCommit' -Context 'Managed manifest file') -Context 'Managed manifest file source'
        Assert-Sha256 -Value (Get-RequiredProperty -Object $file -Name 'contentSha256' -Context 'Managed manifest file') -Context 'Managed manifest file contentSha256'
    }
}

function Assert-SyncConfiguration {
    param([object] $Configuration)

    Assert-SchemaVersion -Document $Configuration -Expected 3 -DocumentName 'AI instruction sync configuration'
    foreach ($name in @('autoCommitRepositoryUrls', 'excludedRepositoryUrls', 'excludedRepositoryPaths')) {
        Assert-StringArray -Value (Get-RequiredProperty -Object $Configuration -Name $name -Context 'AI instruction sync configuration') -Context "AI instruction sync configuration $name" -AllowEmpty
    }

    $catalog = Get-RequiredProperty -Object $Configuration -Name 'catalog' -Context 'AI instruction sync configuration'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $catalog -Name 'repository' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog repository'
    Assert-NonEmptyString -Value (Get-RequiredProperty -Object $catalog -Name 'ref' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog ref'
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $catalog -Name 'profiles' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog profiles' -AllowEmpty
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $catalog -Name 'includeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog includeSkills' -AllowEmpty
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $catalog -Name 'excludeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog excludeSkills' -AllowEmpty
}

function Test-SkillsCatalogDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatalogPath
    )

    $catalog = Import-SkillsCatalogJson -Path $CatalogPath -DocumentName 'Skills Catalog'
    Assert-SkillsCatalog -Catalog $catalog
    return $catalog
}

function Test-SkillsCatalogContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,
        [Parameter(Mandatory = $true)]
        [string] $LockPath,
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,
        [Parameter(Mandatory = $true)]
        [string] $ConfigurationPath
    )

    $catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
    $lock = Import-SkillsCatalogJson -Path $LockPath -DocumentName 'Skills Catalog lock'
    $manifest = Import-SkillsCatalogJson -Path $ManifestPath -DocumentName 'Managed manifest'
    $configuration = Import-SkillsCatalogJson -Path $ConfigurationPath -DocumentName 'AI instruction sync configuration'

    Assert-SkillsCatalogLock -Lock $lock -Catalog $catalog
    Assert-ManagedManifest -Manifest $manifest
    Assert-SyncConfiguration -Configuration $configuration

    return [pscustomobject]@{
        SkillCount = @($catalog.skills).Count
        ProfileCount = @($catalog.profiles).Count
        SourceCount = @($catalog.sources).Count
        ManifestFileCount = @($manifest.files).Count
    }
}

Export-ModuleMember -Function @(
    'Import-SkillsCatalogJson',
    'Test-SkillsCatalogDocument',
    'Test-SkillsCatalogContract'
)
