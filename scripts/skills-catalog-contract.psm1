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

    if (-not (Test-HasProperty -Object $Object -Name $Name)) {
        throw "$Context is missing required property '$Name'."
    }

    Write-Output -NoEnumerate $Object.$Name
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
        [object] $Capability,
        [string] $Context
    )

    $kind = Get-RequiredProperty -Object $Capability -Name 'kind' -Context $Context
    Assert-NonEmptyString -Value $kind -Context "$Context kind"
    if (@('command', 'connector', 'environment') -cnotcontains [string] $kind) {
        throw "Unsupported $Context kind '$kind'."
    }

    Assert-StableId -Value (Get-RequiredProperty -Object $Capability -Name 'id' -Context $Context) -Context "$Context id"

    $state = Get-RequiredProperty -Object $Capability -Name 'state' -Context $Context
    Assert-NonEmptyString -Value $state -Context "$Context state"
    if (@('available', 'authenticated', 'configured') -cnotcontains [string] $state) {
        throw "Unsupported $Context state '$state'."
    }
}

function Assert-Array {
    param(
        [object] $Value,
        [string] $Context,
        [switch] $AllowEmpty
    )

    if ($null -eq $Value -or $Value -isnot [System.Array]) {
        throw "$Context must be an array."
    }
    if (-not $AllowEmpty -and @($Value).Count -eq 0) {
        throw "$Context must contain at least one value."
    }
}

function Assert-Sha256 {
    param(
        [object] $Value,
        [string] $Context
    )

    if ([string] $Value -notmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase 64-character SHA-256 hash."
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

function Assert-FullCommitSha {
    param(
        [object] $Value,
        [string] $Context
    )

    if ([string] $Value -notmatch '^[0-9a-f]{40}$') {
        throw "$Context resolvedCommit must be a full 40-character commit SHA."
    }
}

function Test-IsSafeRepositoryPath {
    param([object] $Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        return $false
    }

    $path = [string] $Value
    if ($path.StartsWith('/') -or $path.EndsWith('/') -or $path.Contains('\') -or $path.Contains('//') -or $path.Contains(':')) {
        return $false
    }

    foreach ($segment in $path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Assert-HttpsRepositoryUrl {
    param(
        [object] $Value,
        [string] $Context
    )

    Assert-NonEmptyString -Value $Value -Context $Context
    $uri = $null
    if (-not [System.Uri]::TryCreate([string] $Value, [System.UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "$Context must be an absolute HTTPS repository URL."
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
        $defaultValue = Get-RequiredProperty -Object $profile -Name 'default' -Context "Skills Catalog profile '$profileId'"
        if ($defaultValue -isnot [bool]) {
            throw "Skills Catalog profile '$profileId' default must be boolean."
        }
        Assert-StringArray -Value (Get-RequiredProperty -Object $profile -Name 'includes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' includes" -AllowEmpty
        Assert-StringArray -Value (Get-RequiredProperty -Object $profile -Name 'excludes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' excludes" -AllowEmpty
        foreach ($excludedId in @($profile.excludes)) {
            if (@($profile.includes) -contains [string] $excludedId) {
                throw "Skills Catalog profile '$profileId' includes and excludes Skill '$excludedId'."
            }
        }
    }
    if ($profileIds.Count -eq 0) {
        throw 'Skills Catalog must contain at least one profile.'
    }

    $skills = Get-RequiredProperty -Object $Catalog -Name 'skills' -Context 'Skills Catalog'
    Assert-Array -Value $skills -Context 'Skills Catalog skills'
    $skillIds = @{}
    $skillDocuments = @{}
    foreach ($skill in @($skills)) {
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog Skill id'
        if ($skillIds.ContainsKey([string] $skillId)) {
            throw "Duplicate stable Skill ID: $skillId"
        }
        $skillIds[[string] $skillId] = $true
        $skillDocuments[[string] $skillId] = $skill

        $group = Get-RequiredProperty -Object $skill -Name 'group' -Context "Skills Catalog Skill '$skillId'"
        Assert-StableId -Value $group -Context "Skills Catalog Skill '$skillId' group"

        $source = Get-RequiredProperty -Object $skill -Name 'source' -Context "Skills Catalog Skill '$skillId'"
        $sourceId = Get-RequiredProperty -Object $source -Name 'sourceId' -Context "Skills Catalog Skill '$skillId' source"
        if (-not $sourceIds.ContainsKey([string] $sourceId)) {
            throw "Skills Catalog Skill '$skillId' references unknown source '$sourceId'."
        }
        $sourcePath = Get-RequiredProperty -Object $source -Name 'path' -Context "Skills Catalog Skill '$skillId' source"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath) -or [string] $sourcePath -ne ".agents/skills/$skillId") {
            throw "Unsafe Skill source path for '$skillId': $sourcePath"
        }

        Assert-StringArray -Value (Get-RequiredProperty -Object $skill -Name 'profiles' -Context "Skills Catalog Skill '$skillId'") -Context "Skills Catalog Skill '$skillId' profiles" -AllowEmpty
        foreach ($profileId in @($skill.profiles)) {
            if (-not $profileIds.ContainsKey([string] $profileId)) {
                throw "Skills Catalog Skill '$skillId' references unknown profile '$profileId'."
            }
        }

        $compatibility = Get-RequiredProperty -Object $skill -Name 'compatibility' -Context "Skills Catalog Skill '$skillId'"
        Assert-StringArray -Value (Get-RequiredProperty -Object $compatibility -Name 'platforms' -Context "Skills Catalog Skill '$skillId' compatibility") -Context "Skills Catalog Skill '$skillId' compatibility platforms"
        Assert-StringArray -Value (Get-RequiredProperty -Object $compatibility -Name 'shells' -Context "Skills Catalog Skill '$skillId' compatibility") -Context "Skills Catalog Skill '$skillId' compatibility shells" -AllowEmpty
        $requiredCapabilities = Get-RequiredProperty -Object $compatibility -Name 'requiredCapabilities' -Context "Skills Catalog Skill '$skillId' compatibility"
        Assert-Array -Value $requiredCapabilities -Context "Skills Catalog Skill '$skillId' compatibility requiredCapabilities" -AllowEmpty
        foreach ($requirement in @($requiredCapabilities)) {
            Assert-Capability -Capability $requirement -Context "Skills Catalog Skill '$skillId' compatibility requirement"
        }
        $anyOfCapabilities = Get-RequiredProperty -Object $compatibility -Name 'anyOfCapabilities' -Context "Skills Catalog Skill '$skillId' compatibility"
        Assert-Array -Value $anyOfCapabilities -Context "Skills Catalog Skill '$skillId' compatibility anyOfCapabilities" -AllowEmpty
        foreach ($alternativeSet in @($anyOfCapabilities)) {
            Assert-Array -Value $alternativeSet -Context "Skills Catalog Skill '$skillId' compatibility alternative set"
            foreach ($requirement in @($alternativeSet)) {
                Assert-Capability -Capability $requirement -Context "Skills Catalog Skill '$skillId' compatibility alternative"
            }
        }

        $dependencies = Get-RequiredProperty -Object $skill -Name 'dependencies' -Context "Skills Catalog Skill '$skillId'"
        Assert-Array -Value $dependencies -Context "Skills Catalog Skill '$skillId' dependencies" -AllowEmpty
        foreach ($dependency in @($dependencies)) {
            $dependencySkillId = Get-RequiredProperty -Object $dependency -Name 'skillId' -Context "Skills Catalog Skill '$skillId' dependency"
            Assert-StableId -Value $dependencySkillId -Context "Skills Catalog Skill '$skillId' dependency skillId"
            $dependencyType = Get-RequiredProperty -Object $dependency -Name 'type' -Context "Skills Catalog Skill '$skillId' dependency '$dependencySkillId'"
            if (@('hard', 'conditional', 'recommended') -notcontains [string] $dependencyType) {
                throw "Unsupported dependency type '$dependencyType' for Skill '$skillId'."
            }
            if ([string] $dependencySkillId -eq [string] $skillId) {
                throw "Skills Catalog Skill '$skillId' cannot depend on itself."
            }
            if ([string] $dependencyType -eq 'conditional') {
                $condition = Get-RequiredProperty -Object $dependency -Name 'condition' -Context "Conditional dependency '$skillId' -> '$dependencySkillId'"
                Assert-StableId -Value (Get-RequiredProperty -Object $condition -Name 'capability' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition") -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition capability"
                $operator = Get-RequiredProperty -Object $condition -Name 'operator' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition"
                Assert-NonEmptyString -Value $operator -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition operator"
                if (@('available', 'missing', 'missing-or-invalid', 'unavailable') -cnotcontains [string] $operator) {
                    throw "Unsupported conditional dependency operator '$operator' for Skill '$skillId'."
                }
                $fallback = Get-RequiredProperty -Object $dependency -Name 'fallback' -Context "Conditional dependency '$skillId' -> '$dependencySkillId'"
                Assert-StableId -Value (Get-RequiredProperty -Object $fallback -Name 'capability' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback") -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback capability"
                Assert-NonEmptyString -Value (Get-RequiredProperty -Object $fallback -Name 'description' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback") -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback description"
            }
        }

        $lifecycle = Get-RequiredProperty -Object $skill -Name 'lifecycle' -Context "Skills Catalog Skill '$skillId'"
        $status = Get-RequiredProperty -Object $lifecycle -Name 'status' -Context "Skills Catalog Skill '$skillId' lifecycle"
        if (@('active', 'deprecated', 'removed') -notcontains [string] $status) {
            throw "Unsupported lifecycle status '$status' for Skill '$skillId'."
        }
        Assert-StringArray -Value (Get-RequiredProperty -Object $lifecycle -Name 'aliases' -Context "Skills Catalog Skill '$skillId' lifecycle") -Context "Skills Catalog Skill '$skillId' lifecycle aliases" -AllowEmpty
        if (Test-HasProperty -Object $lifecycle -Name 'replacementId') {
            Assert-StableId -Value $lifecycle.replacementId -Context "Skills Catalog Skill '$skillId' lifecycle replacementId"
            if ([string] $status -eq 'active') {
                throw "Active Skill '$skillId' cannot declare lifecycle replacementId."
            }
        }
    }
    if ($skillIds.Count -eq 0) {
        throw 'Skills Catalog must contain at least one Skill.'
    }

    foreach ($skillId in $skillDocuments.Keys) {
        $skill = $skillDocuments[$skillId]
        foreach ($alias in @($skill.lifecycle.aliases)) {
            Assert-StableId -Value $alias -Context "Skills Catalog Skill '$skillId' lifecycle alias"
        }
        foreach ($profileId in @($skill.profiles)) {
            if (@($profileDocuments[[string] $profileId].includes) -notcontains [string] $skillId) {
                throw "Skills Catalog Skill '$skillId' declares profile '$profileId', but that profile does not include it."
            }
        }
        foreach ($dependency in @($skill.dependencies)) {
            if (-not $skillIds.ContainsKey([string] $dependency.skillId)) {
                throw "Skills Catalog Skill '$skillId' references unknown dependency '$($dependency.skillId)'."
            }
        }
        if (Test-HasProperty -Object $skill.lifecycle -Name 'replacementId') {
            if (-not $skillIds.ContainsKey([string] $skill.lifecycle.replacementId)) {
                throw "Skills Catalog Skill '$skillId' references unknown lifecycle replacement '$($skill.lifecycle.replacementId)'."
            }
            $replacement = $skillDocuments[[string] $skill.lifecycle.replacementId]
            if ([string] $replacement.lifecycle.status -eq 'removed') {
                throw "Skills Catalog Skill '$skillId' lifecycle replacement '$($skill.lifecycle.replacementId)' is also removed."
            }
            if (@($replacement.lifecycle.aliases) -notcontains [string] $skillId) {
                throw "Skills Catalog replacement '$($skill.lifecycle.replacementId)' must list removed Skill '$skillId' as an alias."
            }
        }
    }

    $aliases = @{}
    foreach ($skillId in $skillDocuments.Keys) {
        $skill = $skillDocuments[$skillId]
        foreach ($alias in @($skill.lifecycle.aliases)) {
            if ($aliases.ContainsKey([string] $alias)) {
                throw "Duplicate lifecycle alias '$alias' is declared by Skills '$($aliases[[string] $alias])' and '$skillId'."
            }
            $aliases[[string] $alias] = $skillId
            if (-not $skillIds.ContainsKey([string] $alias)) {
                throw "Lifecycle alias '$alias' for Skill '$skillId' must reference a retained removed tombstone."
            }
            $aliasedSkill = $skillDocuments[[string] $alias]
            if ([string] $aliasedSkill.lifecycle.status -ne 'removed' -or
                -not (Test-HasProperty -Object $aliasedSkill.lifecycle -Name 'replacementId') -or
                [string] $aliasedSkill.lifecycle.replacementId -ne [string] $skillId) {
                throw "Lifecycle alias '$alias' does not point from a removed tombstone to replacement Skill '$skillId'."
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
        foreach ($skillId in @($profile.includes)) {
            if (@($skillDocuments[[string] $skillId].profiles) -notcontains [string] $profileId) {
                throw "Skills Catalog profile '$profileId' includes Skill '$skillId', but the Skill does not declare that profile."
            }
            if ([string] $skillDocuments[[string] $skillId].lifecycle.status -eq 'removed') {
                throw "Skills Catalog profile '$profileId' cannot include removed Skill '$skillId'."
            }
        }
    }
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

function Assert-SkillsCatalogLock {
    param(
        [object] $Lock,
        [object] $Catalog
    )

    Assert-SchemaVersion -Document $Lock -Expected 1 -DocumentName 'Skills Catalog lock'
    if ([string] (Get-RequiredProperty -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock') -ne [string] $Catalog.catalogId) {
        throw 'Skills Catalog lock catalogId does not match the Skills Catalog.'
    }
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock') -Context 'Skills Catalog lock catalogSha256'

    $catalogSources = @{}
    foreach ($source in @($Catalog.sources)) {
        $catalogSources[[string] $source.id] = $source
    }
    $sources = Get-RequiredProperty -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'
    Assert-Array -Value $sources -Context 'Skills Catalog lock sources'
    $lockedSources = @{}
    foreach ($source in @($sources)) {
        $sourceId = Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog lock source'
        if ($lockedSources.ContainsKey([string] $sourceId)) {
            throw "Duplicate Skills Catalog lock source ID: $sourceId"
        }
        if (-not $catalogSources.ContainsKey([string] $sourceId)) {
            throw "Skills Catalog lock references unknown source '$sourceId'."
        }
        $lockedSources[[string] $sourceId] = $source
        $repository = Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog lock source '$sourceId'"
        if ([string] $repository -ne [string] $catalogSources[[string] $sourceId].repository) {
            throw "Skills Catalog lock source '$sourceId' repository does not match the catalog."
        }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'requestedRef' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' requestedRef"
        $requestedRefType = Get-RequiredProperty -Object $source -Name 'requestedRefType' -Context "Skills Catalog lock source '$sourceId'"
        if (@('branch', 'tag', 'commit') -notcontains [string] $requestedRefType) {
            throw "Unsupported requestedRefType '$requestedRefType' for Skills Catalog lock source '$sourceId'."
        }
        Assert-FullCommitSha -Value (Get-RequiredProperty -Object $source -Name 'resolvedCommit' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId'"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'resolvedVersion' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' resolvedVersion"
        Assert-Sha256 -Value (Get-RequiredProperty -Object $source -Name 'archiveSha256' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' archiveSha256"
    }
    foreach ($sourceId in $catalogSources.Keys) {
        if (-not $lockedSources.ContainsKey([string] $sourceId)) {
            throw "Skills Catalog source '$sourceId' has no resolved lock entry."
        }
    }

    $catalogSkills = @{}
    foreach ($skill in @($Catalog.skills)) {
        if ([string] $skill.lifecycle.status -ne 'removed') {
            $catalogSkills[[string] $skill.id] = $skill
        }
    }
    $skills = Get-RequiredProperty -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'
    Assert-Array -Value $skills -Context 'Skills Catalog lock skills' -AllowEmpty
    $lockedSkills = @{}
    foreach ($skill in @($skills)) {
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill'
        if ($lockedSkills.ContainsKey([string] $skillId)) {
            throw "Duplicate Skills Catalog lock Skill ID: $skillId"
        }
        if (-not $catalogSkills.ContainsKey([string] $skillId)) {
            throw "Skills Catalog lock references unknown or removed Skill '$skillId'."
        }
        $lockedSkills[[string] $skillId] = $skill
        if ([string] $skill.sourceId -ne [string] $catalogSkills[[string] $skillId].source.sourceId -or
            [string] $skill.sourcePath -ne [string] $catalogSkills[[string] $skillId].source.path) {
            throw "Skills Catalog lock source does not match catalog Skill '$skillId'."
        }
        Assert-Sha256 -Value (Get-RequiredProperty -Object $skill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$skillId'") -Context "Skills Catalog lock Skill '$skillId' contentSha256"
    }
    foreach ($skillId in $catalogSkills.Keys) {
        if (-not $lockedSkills.ContainsKey([string] $skillId)) {
            throw "Skills Catalog Skill '$skillId' has no content lock entry."
        }
    }
}

function Assert-ManagedManifestV2 {
    param([object] $Manifest)

    Assert-SchemaVersion -Document $Manifest -Expected 2 -DocumentName 'managed manifest'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'managed manifest') -Context 'managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'managed manifest') -Context 'managed manifest lockSha256'

    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'managed manifest'
    Assert-Array -Value $files -Context 'managed manifest files' -AllowEmpty
    $targetPaths = @{}
    foreach ($entry in @($files)) {
        $artifactType = Get-RequiredProperty -Object $entry -Name 'artifactType' -Context 'managed manifest file'
        if (@('instruction', 'skill') -notcontains [string] $artifactType) {
            throw "Unsupported managed manifest artifactType '$artifactType'."
        }
        $artifactId = Get-RequiredProperty -Object $entry -Name 'artifactId' -Context 'managed manifest file'
        Assert-StableId -Value $artifactId -Context 'managed manifest file artifactId'
        Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRepository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRef"
        $sourceCommit = Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "managed manifest file '$artifactId'"
        if ([string] $sourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "managed manifest file '$artifactId' sourceCommit must be a full 40-character commit SHA."
        }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceVersion"
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "managed manifest file '$artifactId'"
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "managed manifest file '$artifactId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) {
            throw "Unsafe source path in managed manifest: $sourcePath"
        }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) {
            throw "Unsafe target path in managed manifest: $targetPath"
        }
        if ($targetPaths.ContainsKey([string] $targetPath)) {
            throw "Duplicate target path in managed manifest: $targetPath"
        }
        $targetPaths[[string] $targetPath] = $true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sha256"
        if ([string] $artifactType -eq 'skill') {
            $skillPrefix = ".agents/skills/$artifactId/"
            if (-not ([string] $sourcePath).StartsWith($skillPrefix) -or -not ([string] $targetPath).StartsWith($skillPrefix)) {
                throw "Managed Skill '$artifactId' must preserve the flat .agents/skills path."
            }
        }
    }
}

function Assert-SyncConfigurationV3 {
    param(
        [object] $Configuration,
        [object] $Catalog
    )

    Assert-SchemaVersion -Document $Configuration -Expected 3 -DocumentName 'AI instruction sync configuration'
    foreach ($propertyName in @('autoCommitRepositoryUrls', 'excludedRepositoryUrls', 'excludedRepositoryPaths')) {
        Assert-StringArray -Value (Get-RequiredProperty -Object $Configuration -Name $propertyName -Context 'AI instruction sync configuration') -Context "AI instruction sync configuration $propertyName" -AllowEmpty
    }

    $selection = Get-RequiredProperty -Object $Configuration -Name 'catalog' -Context 'AI instruction sync configuration'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $selection -Name 'repository' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog repository'
    Assert-NonEmptyString -Value (Get-RequiredProperty -Object $selection -Name 'ref' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog ref'
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'profiles' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog profiles' -AllowEmpty
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'includeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog includeSkills' -AllowEmpty
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'excludeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog excludeSkills' -AllowEmpty

    $profileIds = @{}
    foreach ($profile in @($Catalog.profiles)) {
        $profileIds[[string] $profile.id] = $true
    }
    $skillIds = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillIds[[string] $skill.id] = $true
    }
    foreach ($profileId in @($selection.profiles)) {
        if (-not $profileIds.ContainsKey([string] $profileId)) {
            throw "AI instruction sync configuration references unknown profile '$profileId'."
        }
    }
    foreach ($skillId in @($selection.includeSkills) + @($selection.excludeSkills)) {
        if (-not $skillIds.ContainsKey([string] $skillId)) {
            throw "AI instruction sync configuration references unknown Skill '$skillId'."
        }
    }
    foreach ($skillId in @($selection.includeSkills)) {
        if (@($selection.excludeSkills) -contains [string] $skillId) {
            throw "AI instruction sync configuration both includes and excludes Skill '$skillId'."
        }
    }
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
    Assert-SkillsCatalogLock -Lock $lock -Catalog $catalog
    $catalogFileSha256 = Get-RawFileSha256 -Path $CatalogPath
    if ([string] $lock.catalogSha256 -ne $catalogFileSha256) {
        throw "Skills Catalog lock catalogSha256 does not match the Catalog file: expected $catalogFileSha256."
    }

    $manifest = Import-SkillsCatalogJson -Path $ManifestPath -DocumentName 'managed manifest'
    Assert-ManagedManifestV2 -Manifest $manifest
    if ([string] $manifest.catalogId -ne [string] $catalog.catalogId) {
        throw 'managed manifest catalogId does not match the Skills Catalog.'
    }
    $lockFileSha256 = Get-RawFileSha256 -Path $LockPath
    if ([string] $manifest.lockSha256 -ne $lockFileSha256) {
        throw "managed manifest lockSha256 does not match the Catalog lock file: expected $lockFileSha256."
    }

    $configuration = Import-SkillsCatalogJson -Path $ConfigurationPath -DocumentName 'AI instruction sync configuration'
    Assert-SyncConfigurationV3 -Configuration $configuration -Catalog $catalog

    return [pscustomobject]@{
        CatalogId = [string] $catalog.catalogId
        SourceCount = @($catalog.sources).Count
        SkillCount = @($catalog.skills).Count
        ProfileCount = @($catalog.profiles).Count
        ManifestFileCount = @($manifest.files).Count
    }
}

Export-ModuleMember -Function Import-SkillsCatalogJson, Test-SkillsCatalogContract, Test-SkillsCatalogDocument
