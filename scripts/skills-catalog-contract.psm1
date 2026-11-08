Set-StrictMode -Version 2.0
$script:CanonicalAiInstructionsRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Import-SkillsCatalogJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $DocumentName
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "$DocumentName does not exist: $fullPath" }
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $fullPath | ConvertFrom-Json }
    catch { throw "$DocumentName is not valid JSON: $fullPath. $($_.Exception.Message)" }
}

function Test-HasProperty {
    param([Parameter(Mandatory = $true)][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty {
    param([Parameter(Mandatory = $true)][object] $Object,[Parameter(Mandatory = $true)][string] $Name,[Parameter(Mandatory = $true)][string] $Context)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    $value = $property.Value
    if ($value -is [System.Array]) { return ,$value }
    return $value
}

function Assert-OnlyProperties {
    param([Parameter(Mandatory = $true)][object] $Object,[Parameter(Mandatory = $true)][string[]] $Allowed,[Parameter(Mandatory = $true)][string] $Context)
    foreach ($propertyName in @($Object.PSObject.Properties.Name)) {
        if ($propertyName -cnotin $Allowed) { throw "$Context contains unsupported property '$propertyName'." }
    }
}

function Assert-NonEmptyString {
    param([object] $Value,[string] $Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must be a non-empty string." }
}

function Assert-StableId {
    param([object] $Value,[string] $Context)
    Assert-NonEmptyString -Value $Value -Context $Context
    if ([string]$Value -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') { throw "$Context must be lowercase kebab-case and at most 64 characters: $Value" }
}

function Assert-StringArray {
    param([object] $Value,[string] $Context,[switch] $AllowEmpty)
    if ($null -eq $Value -or $Value -isnot [System.Array]) { throw "$Context must be an array." }
    $values = @($Value)
    if (-not $AllowEmpty -and $values.Count -eq 0) { throw "$Context must contain at least one value." }
    $seen = @{}
    foreach ($item in $values) {
        Assert-NonEmptyString -Value $item -Context $Context
        $key = ([string]$item).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw "$Context contains duplicate value '$item'." }
        $seen[$key] = $true
    }
}

function Assert-StableIdArray {
    param([object] $Value,[string] $Context,[switch] $AllowEmpty)
    Assert-StringArray -Value $Value -Context $Context -AllowEmpty:$AllowEmpty
    foreach ($item in @($Value)) { Assert-StableId -Value $item -Context "$Context item" }
}

function Assert-Capability {
    param([object] $Capability,[string] $Context)
    Assert-OnlyProperties -Object $Capability -Allowed @('kind','id','state') -Context $Context
    $kind = Get-RequiredProperty -Object $Capability -Name 'kind' -Context $Context
    Assert-NonEmptyString -Value $kind -Context "$Context kind"
    if (@('command','connector','environment') -cnotcontains [string]$kind) { throw "Unsupported $Context kind '$kind'." }
    Assert-StableId -Value (Get-RequiredProperty -Object $Capability -Name 'id' -Context $Context) -Context "$Context id"
    $state = Get-RequiredProperty -Object $Capability -Name 'state' -Context $Context
    Assert-NonEmptyString -Value $state -Context "$Context state"
    if (@('available','authenticated','configured') -cnotcontains [string]$state) { throw "Unsupported $Context state '$state'." }
}

function Assert-Array {
    param([object] $Value,[string] $Context,[switch] $AllowEmpty)
    if ($null -eq $Value -or $Value -isnot [System.Array]) { throw "$Context must be an array." }
    if (-not $AllowEmpty -and @($Value).Count -eq 0) { throw "$Context must contain at least one value." }
}

function Assert-Sha256 {
    param([object] $Value,[string] $Context)
    if ($Value -isnot [string]) { throw "$Context must be a string." }
    if ([string]$Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context must be a lowercase 64-character SHA-256 hash." }
}

function Get-RawFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha256.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function ConvertFrom-StrictUtf8JsonBytes {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $DocumentName
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "$DocumentName must be UTF-8 without a BOM."
    }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($Bytes)
        return $text | ConvertFrom-Json
    }
    catch { throw "$DocumentName must be valid UTF-8 JSON without a BOM. $($_.Exception.Message)" }
}

function Assert-FullCommitSha {
    param([object] $Value,[string] $Context)
    if ($Value -isnot [string]) { throw "$Context resolvedCommit must be a string." }
    if ([string]$Value -cnotmatch '^[0-9a-f]{40}$') { throw "$Context resolvedCommit must be a full 40-character commit SHA." }
}

function Test-IsSafeRepositoryPath {
    param([object] $Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $path = [string]$Value
    if ($path.StartsWith('/') -or $path.EndsWith('/') -or $path.Contains('\') -or $path.Contains('//') -or $path.Contains(':') -or
        $path -match '[\x00-\x1F\x7F-\x9F]') { return $false }
    foreach ($segment in $path.Split('/')) { if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') { return $false } }
    return $true
}

function Test-IsLicenseDeliverySourcePath {
    param([object] $Value)

    if (-not (Test-IsSafeRepositoryPath -Value $Value)) { return $false }
    $path = [string]$Value
    if ($path -ceq '.ai-instructions-generated/delivery.json') { return $false }

    $segments = @($path.Split('/'))
    $fileName = $segments[$segments.Count - 1]
    $isNamedLicenseDocument = $fileName -imatch '^(LICENSE|LICENCE|COPYING|NOTICE|THIRD_PARTY_NOTICES|THIRD_PARTY_LICENSES|PROVENANCE)([-_][^.]+)?(\.(md|txt|rst|html))?$' -or
        $fileName -ieq 'licensing-scope.json'
    $isInsideLicenseDirectory = @($segments | Where-Object { $_ -ieq 'LICENSES' }).Count -gt 0
    return $isNamedLicenseDocument -or $isInsideLicenseDirectory
}

function Get-UserSkillsLicenseNamespacePrefix {
    param([Parameter(Mandatory = $true)][string] $TargetPrefix)

    return "$TargetPrefix.ai-instructions-licenses/"
}

function Get-UserSkillsPayloadInventorySha256 {
    param(
        [Parameter(Mandatory = $true)][object[]] $Files,
        [Parameter(Mandatory = $true)][string] $SourcePathPrefix,
        [Parameter(Mandatory = $true)][string] $TargetPrefix
    )

    $inventoryLines = New-Object 'System.Collections.Generic.List[string]'
    $hashesByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $licenseNamespacePrefix = Get-UserSkillsLicenseNamespacePrefix -TargetPrefix $TargetPrefix
    foreach ($file in @($Files)) {
        $sourcePath = [string]$file.sourcePath
        $targetPath = [string]$file.targetPath
        if (-not $sourcePath.StartsWith($SourcePathPrefix,[System.StringComparison]::Ordinal) -or
            $sourcePath -ceq '.ai-instructions-generated/delivery.json' -or
            $targetPath.StartsWith($licenseNamespacePrefix,[System.StringComparison]::Ordinal)) {
            continue
        }
        $hashesByPath.Add($sourcePath,[string]$file.sha256)
    }

    [string[]]$orderedPaths = @($hashesByPath.Keys)
    [System.Array]::Sort($orderedPaths,[System.StringComparer]::Ordinal)
    foreach ($sourcePath in $orderedPaths) {
        $inventoryLines.Add("$sourcePath`t$($hashesByPath[$sourcePath])`n")
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]::Concat($inventoryLines.ToArray()))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Assert-HttpsRepositoryUrl {
    param([object] $Value,[string] $Context)
    Assert-NonEmptyString -Value $Value -Context $Context
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Value,[System.UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "$Context must be an absolute HTTPS repository URL."
    }
}

function Assert-GitHubRepositoryUrl {
    param([object] $Value,[string] $Context)
    Assert-HttpsRepositoryUrl -Value $Value -Context $Context
    $uri = [System.Uri]([string]$Value)
    $path = $uri.AbsolutePath.Trim('/')
    if ($path.EndsWith('.git',[System.StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring(0,$path.Length-4) }
    $parts = @($path.Split('/'))
    if (-not $uri.Host.Equals('github.com',[System.StringComparison]::OrdinalIgnoreCase) -or $parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "$Context must identify a github.com owner/repository HTTPS URL."
    }
}

function Assert-SchemaVersion {
    param([object] $Document,[int] $Expected,[string] $DocumentName)
    $schemaVersion = Get-RequiredProperty -Object $Document -Name 'schemaVersion' -Context $DocumentName
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) { throw "$DocumentName schemaVersion must be an integer." }
    if ($schemaVersion -ne $Expected) { throw "Unsupported $DocumentName schemaVersion '$schemaVersion'; expected $Expected." }
}

function Assert-SkillsCatalogCommon {
    param([Parameter(Mandatory = $true)][object] $Catalog,[Parameter(Mandatory = $true)][int] $SchemaVersion)
    $catalogId = Get-RequiredProperty -Object $Catalog -Name 'catalogId' -Context 'Skills Catalog'
    Assert-StableId -Value $catalogId -Context 'Skills Catalog catalogId'

    $sources = Get-RequiredProperty -Object $Catalog -Name 'sources' -Context 'Skills Catalog'
    Assert-Array -Value $sources -Context 'Skills Catalog sources'
    $sourceIds = @{}
    foreach ($source in @($sources)) {
        Assert-OnlyProperties -Object $source -Allowed @('id','repository') -Context 'Skills Catalog source'
        $sourceId = Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog source'
        Assert-StableId -Value $sourceId -Context 'Skills Catalog source id'
        if ($sourceIds.ContainsKey([string]$sourceId)) { throw "Duplicate Skills Catalog source ID: $sourceId" }
        $sourceIds[[string]$sourceId] = $true
        Assert-GitHubRepositoryUrl -Value (Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog source '$sourceId'") -Context "Skills Catalog source '$sourceId' repository"
    }
    if ($sourceIds.Count -eq 0) { throw 'Skills Catalog must contain at least one source.' }

    $profiles = Get-RequiredProperty -Object $Catalog -Name 'profiles' -Context 'Skills Catalog'
    Assert-Array -Value $profiles -Context 'Skills Catalog profiles'
    $profileIds = @{}; $profileDocuments = @{}
    foreach ($profile in @($profiles)) {
        Assert-OnlyProperties -Object $profile -Allowed @('id','description','default','includes','excludes') -Context 'Skills Catalog profile'
        $profileId = Get-RequiredProperty -Object $profile -Name 'id' -Context 'Skills Catalog profile'
        Assert-StableId -Value $profileId -Context 'Skills Catalog profile id'
        if ($profileIds.ContainsKey([string]$profileId)) { throw "Duplicate Skills Catalog profile ID: $profileId" }
        $profileIds[[string]$profileId] = $true; $profileDocuments[[string]$profileId] = $profile
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $profile -Name 'description' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' description"
        $defaultValue = Get-RequiredProperty -Object $profile -Name 'default' -Context "Skills Catalog profile '$profileId'"
        if ($defaultValue -isnot [bool]) { throw "Skills Catalog profile '$profileId' default must be boolean." }
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $profile -Name 'includes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' includes" -AllowEmpty
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $profile -Name 'excludes' -Context "Skills Catalog profile '$profileId'") -Context "Skills Catalog profile '$profileId' excludes" -AllowEmpty
        foreach ($excludedId in @($profile.excludes)) { if (@($profile.includes) -contains [string]$excludedId) { throw "Skills Catalog profile '$profileId' includes and excludes Skill '$excludedId'." } }
    }
    if ($profileIds.Count -eq 0) { throw 'Skills Catalog must contain at least one profile.' }

    $skills = Get-RequiredProperty -Object $Catalog -Name 'skills' -Context 'Skills Catalog'
    Assert-Array -Value $skills -Context 'Skills Catalog skills'
    $skillIds = @{}; $skillDocuments = @{}
    foreach ($skill in @($skills)) {
        Assert-OnlyProperties -Object $skill -Allowed @('id','group','source','profiles','compatibility','dependencies','lifecycle') -Context 'Skills Catalog Skill'
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog Skill id'
        if ($skillIds.ContainsKey([string]$skillId)) { throw "Duplicate stable Skill ID: $skillId" }
        $skillIds[[string]$skillId] = $true; $skillDocuments[[string]$skillId] = $skill
        Assert-StableId -Value (Get-RequiredProperty -Object $skill -Name 'group' -Context "Skills Catalog Skill '$skillId'") -Context "Skills Catalog Skill '$skillId' group"
        $source = Get-RequiredProperty -Object $skill -Name 'source' -Context "Skills Catalog Skill '$skillId'"
        $sourceProperties = if ($SchemaVersion -eq 1) { @('sourceId','path') } elseif ($SchemaVersion -eq 2) { @('sourceId','sourcePath','targetPath') } else { @('sourceId','sourcePath') }
        Assert-OnlyProperties -Object $source -Allowed $sourceProperties -Context "Skills Catalog Skill '$skillId' source"
        $sourceId = Get-RequiredProperty -Object $source -Name 'sourceId' -Context "Skills Catalog Skill '$skillId' source"
        Assert-StableId -Value $sourceId -Context "Skills Catalog Skill '$skillId' source sourceId"
        if (-not $sourceIds.ContainsKey([string]$sourceId)) { throw "Skills Catalog Skill '$skillId' references unknown source '$sourceId'." }
        if ($SchemaVersion -eq 1) {
            $sourcePath = Get-RequiredProperty -Object $source -Name 'path' -Context "Skills Catalog Skill '$skillId' source"
            if (-not (Test-IsSafeRepositoryPath -Value $sourcePath) -or [string]$sourcePath -cne ".agents/skills/$skillId") { throw "Unsafe Skill source path for '$skillId': $sourcePath" }
        }
        else {
            $sourcePath = Get-RequiredProperty -Object $source -Name 'sourcePath' -Context "Skills Catalog Skill '$skillId' source"
            if (-not (Test-IsSafeRepositoryPath -Value $sourcePath) -or [string]$sourcePath -cne "skills/$skillId") {
                throw "Skills Catalog v$SchemaVersion Skill '$skillId' must use canonical source path 'skills/$skillId'."
            }
            if ($SchemaVersion -eq 2) {
                $targetPath = Get-RequiredProperty -Object $source -Name 'targetPath' -Context "Skills Catalog Skill '$skillId' source"
                if (-not (Test-IsSafeRepositoryPath -Value $targetPath) -or [string]$targetPath -cne ".agents/skills/$skillId") {
                    throw "Skills Catalog v2 Skill '$skillId' must use runtime target path '.agents/skills/$skillId'."
                }
            }
        }
        Assert-StableIdArray -Value (Get-RequiredProperty -Object $skill -Name 'profiles' -Context "Skills Catalog Skill '$skillId'") -Context "Skills Catalog Skill '$skillId' profiles" -AllowEmpty
        foreach ($profileId in @($skill.profiles)) { if (-not $profileIds.ContainsKey([string]$profileId)) { throw "Skills Catalog Skill '$skillId' references unknown profile '$profileId'." } }

        $compatibility = Get-RequiredProperty -Object $skill -Name 'compatibility' -Context "Skills Catalog Skill '$skillId'"
        Assert-OnlyProperties -Object $compatibility -Allowed @('platforms','shells','requiredCapabilities','anyOfCapabilities') -Context "Skills Catalog Skill '$skillId' compatibility"
        $platforms = Get-RequiredProperty -Object $compatibility -Name 'platforms' -Context "Skills Catalog Skill '$skillId' compatibility"
        Assert-StringArray -Value $platforms -Context "Skills Catalog Skill '$skillId' compatibility platforms"
        foreach ($platform in @($platforms)) { if (@('any','linux','macos','windows') -cnotcontains [string]$platform) { throw "Unsupported Skills Catalog Skill '$skillId' compatibility platform '$platform'." } }
        Assert-StringArray -Value (Get-RequiredProperty -Object $compatibility -Name 'shells' -Context "Skills Catalog Skill '$skillId' compatibility") -Context "Skills Catalog Skill '$skillId' compatibility shells" -AllowEmpty
        $requiredCapabilities = Get-RequiredProperty -Object $compatibility -Name 'requiredCapabilities' -Context "Skills Catalog Skill '$skillId' compatibility"
        Assert-Array -Value $requiredCapabilities -Context "Skills Catalog Skill '$skillId' compatibility requiredCapabilities" -AllowEmpty
        foreach ($requirement in @($requiredCapabilities)) { Assert-Capability -Capability $requirement -Context "Skills Catalog Skill '$skillId' compatibility requirement" }
        $anyOfCapabilities = Get-RequiredProperty -Object $compatibility -Name 'anyOfCapabilities' -Context "Skills Catalog Skill '$skillId' compatibility"
        Assert-Array -Value $anyOfCapabilities -Context "Skills Catalog Skill '$skillId' compatibility anyOfCapabilities" -AllowEmpty
        foreach ($alternativeSet in @($anyOfCapabilities)) { Assert-Array -Value $alternativeSet -Context "Skills Catalog Skill '$skillId' compatibility alternative set"; foreach ($requirement in @($alternativeSet)) { Assert-Capability -Capability $requirement -Context "Skills Catalog Skill '$skillId' compatibility alternative" } }
        $capabilityRequirements = @($requiredCapabilities)
        foreach ($alternativeSet in @($anyOfCapabilities)) { $capabilityRequirements += @($alternativeSet) }

        $dependencies = Get-RequiredProperty -Object $skill -Name 'dependencies' -Context "Skills Catalog Skill '$skillId'"
        Assert-Array -Value $dependencies -Context "Skills Catalog Skill '$skillId' dependencies" -AllowEmpty
        foreach ($dependency in @($dependencies)) {
            Assert-OnlyProperties -Object $dependency -Allowed @('skillId','type','condition','fallback') -Context "Skills Catalog Skill '$skillId' dependency"
            $dependencySkillId = Get-RequiredProperty -Object $dependency -Name 'skillId' -Context "Skills Catalog Skill '$skillId' dependency"
            Assert-StableId -Value $dependencySkillId -Context "Skills Catalog Skill '$skillId' dependency skillId"
            $dependencyType = Get-RequiredProperty -Object $dependency -Name 'type' -Context "Skills Catalog Skill '$skillId' dependency '$dependencySkillId'"
            Assert-NonEmptyString -Value $dependencyType -Context "Skills Catalog Skill '$skillId' dependency '$dependencySkillId' type"
            if (@('hard','conditional','recommended') -cnotcontains [string]$dependencyType) { throw "Unsupported dependency type '$dependencyType' for Skill '$skillId'." }
            if ([string]$dependencySkillId -eq [string]$skillId) { throw "Skills Catalog Skill '$skillId' cannot depend on itself." }
            if ([string]$dependencyType -eq 'conditional') {
                $condition = Get-RequiredProperty -Object $dependency -Name 'condition' -Context "Conditional dependency '$skillId' -> '$dependencySkillId'"
                Assert-OnlyProperties -Object $condition -Allowed @('capability','operator') -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition"
                $conditionCapability = Get-RequiredProperty -Object $condition -Name 'capability' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition"
                Assert-StableId -Value $conditionCapability -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition capability"
                $operator = Get-RequiredProperty -Object $condition -Name 'operator' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition"
                Assert-NonEmptyString -Value $operator -Context "Conditional dependency '$skillId' -> '$dependencySkillId' condition operator"
                if (@('available','missing','missing-or-invalid','unavailable') -cnotcontains [string]$operator) { throw "Unsupported conditional dependency operator '$operator' for Skill '$skillId'." }
                $fallback = Get-RequiredProperty -Object $dependency -Name 'fallback' -Context "Conditional dependency '$skillId' -> '$dependencySkillId'"
                Assert-OnlyProperties -Object $fallback -Allowed @('capability','description') -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback"
                $fallbackCapability = Get-RequiredProperty -Object $fallback -Name 'capability' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback"
                Assert-StableId -Value $fallbackCapability -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback capability"
                Assert-NonEmptyString -Value (Get-RequiredProperty -Object $fallback -Name 'description' -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback") -Context "Conditional dependency '$skillId' -> '$dependencySkillId' fallback description"

                if ([string]$conditionCapability -ceq [string]$fallbackCapability) {
                    throw "Conditional dependency '$skillId' -> '$dependencySkillId' condition and fallback capabilities must be distinct."
                }
                foreach ($capabilityId in @([string]$conditionCapability,[string]$fallbackCapability)) {
                    $declarations = @($capabilityRequirements | Where-Object { [string]$_.id -ceq $capabilityId })
                    if ($declarations.Count -ne 1) {
                        throw "Conditional dependency '$skillId' -> '$dependencySkillId' capability '$capabilityId' must declare exactly one compatibility requirement with its required kind and state."
                    }
                }

                $pairedAlternativeSetCount = 0
                foreach ($alternativeSet in @($anyOfCapabilities)) {
                    $alternativeIds = @($alternativeSet | ForEach-Object { [string]$_.id })
                    if ($alternativeIds -ccontains [string]$conditionCapability -and
                        $alternativeIds -ccontains [string]$fallbackCapability) {
                        $pairedAlternativeSetCount++
                    }
                }
                if ($pairedAlternativeSetCount -ne 1) {
                    throw "Conditional dependency '$skillId' -> '$dependencySkillId' condition and fallback capabilities must be declared together in exactly one compatibility anyOfCapabilities set."
                }
            }
            elseif ((Test-HasProperty -Object $dependency -Name 'condition') -or (Test-HasProperty -Object $dependency -Name 'fallback')) {
                throw "Non-conditional dependency '$skillId' -> '$dependencySkillId' must not declare condition or fallback."
            }
        }

        $lifecycle = Get-RequiredProperty -Object $skill -Name 'lifecycle' -Context "Skills Catalog Skill '$skillId'"
        Assert-OnlyProperties -Object $lifecycle -Allowed @('status','aliases','replacementId') -Context "Skills Catalog Skill '$skillId' lifecycle"
        $status = Get-RequiredProperty -Object $lifecycle -Name 'status' -Context "Skills Catalog Skill '$skillId' lifecycle"
        Assert-NonEmptyString -Value $status -Context "Skills Catalog Skill '$skillId' lifecycle status"
        if (@('active','deprecated','removed') -cnotcontains [string]$status) { throw "Unsupported lifecycle status '$status' for Skill '$skillId'." }
        Assert-StringArray -Value (Get-RequiredProperty -Object $lifecycle -Name 'aliases' -Context "Skills Catalog Skill '$skillId' lifecycle") -Context "Skills Catalog Skill '$skillId' lifecycle aliases" -AllowEmpty
        if (Test-HasProperty -Object $lifecycle -Name 'replacementId') {
            Assert-StableId -Value $lifecycle.replacementId -Context "Skills Catalog Skill '$skillId' lifecycle replacementId"
            if ([string]$status -eq 'active') { throw "Active Skill '$skillId' cannot declare lifecycle replacementId." }
        }
    }
    if ($skillIds.Count -eq 0) { throw 'Skills Catalog must contain at least one Skill.' }

    foreach ($skillId in $skillDocuments.Keys) {
        $skill = $skillDocuments[$skillId]
        foreach ($alias in @($skill.lifecycle.aliases)) { Assert-StableId -Value $alias -Context "Skills Catalog Skill '$skillId' lifecycle alias" }
        foreach ($profileId in @($skill.profiles)) { if (@($profileDocuments[[string]$profileId].includes) -notcontains [string]$skillId) { throw "Skills Catalog Skill '$skillId' declares profile '$profileId', but that profile does not include it." } }
        foreach ($dependency in @($skill.dependencies)) { if (-not $skillIds.ContainsKey([string]$dependency.skillId)) { throw "Skills Catalog Skill '$skillId' references unknown dependency '$($dependency.skillId)'." } }
        if (Test-HasProperty -Object $skill.lifecycle -Name 'replacementId') {
            if (-not $skillIds.ContainsKey([string]$skill.lifecycle.replacementId)) { throw "Skills Catalog Skill '$skillId' references unknown lifecycle replacement '$($skill.lifecycle.replacementId)'." }
            $replacement = $skillDocuments[[string]$skill.lifecycle.replacementId]
            if ([string]$replacement.lifecycle.status -eq 'removed') { throw "Skills Catalog Skill '$skillId' lifecycle replacement '$($skill.lifecycle.replacementId)' is also removed." }
            if (@($replacement.lifecycle.aliases) -notcontains [string]$skillId) { throw "Skills Catalog replacement '$($skill.lifecycle.replacementId)' must list removed Skill '$skillId' as an alias." }
        }
    }

    $aliases = @{}
    foreach ($skillId in $skillDocuments.Keys) {
        $skill = $skillDocuments[$skillId]
        foreach ($alias in @($skill.lifecycle.aliases)) {
            if ($aliases.ContainsKey([string]$alias)) { throw "Duplicate lifecycle alias '$alias' is declared by Skills '$($aliases[[string]$alias])' and '$skillId'." }
            $aliases[[string]$alias] = $skillId
            if (-not $skillIds.ContainsKey([string]$alias)) { throw "Lifecycle alias '$alias' for Skill '$skillId' must reference a retained removed tombstone." }
            $aliasedSkill = $skillDocuments[[string]$alias]
            if ([string]$aliasedSkill.lifecycle.status -ne 'removed' -or -not (Test-HasProperty -Object $aliasedSkill.lifecycle -Name 'replacementId') -or [string]$aliasedSkill.lifecycle.replacementId -ne [string]$skillId) { throw "Lifecycle alias '$alias' does not point from a removed tombstone to replacement Skill '$skillId'." }
        }
    }

    foreach ($profileId in $profileDocuments.Keys) {
        $profile = $profileDocuments[$profileId]
        foreach ($skillId in @($profile.includes)+@($profile.excludes)) { if (-not $skillIds.ContainsKey([string]$skillId)) { throw "Skills Catalog profile '$profileId' references unknown Skill '$skillId'." } }
        foreach ($skillId in @($profile.includes)) {
            if (@($skillDocuments[[string]$skillId].profiles) -notcontains [string]$profileId) { throw "Skills Catalog profile '$profileId' includes Skill '$skillId', but the Skill does not declare that profile." }
            if ([string]$skillDocuments[[string]$skillId].lifecycle.status -eq 'removed') { throw "Skills Catalog profile '$profileId' cannot include removed Skill '$skillId'." }
        }
    }
}

function Assert-SkillsCatalogV1 {
    param([Parameter(Mandatory = $true)][object] $Catalog)
    Assert-OnlyProperties -Object $Catalog -Allowed @('schemaVersion','catalogId','sources','profiles','skills') -Context 'Skills Catalog'
    Assert-SchemaVersion -Document $Catalog -Expected 1 -DocumentName 'Skills Catalog'
    Assert-SkillsCatalogCommon -Catalog $Catalog -SchemaVersion 1
}

function Assert-SkillsCatalogV2 {
    param([Parameter(Mandatory = $true)][object] $Catalog)
    Assert-OnlyProperties -Object $Catalog -Allowed @('schemaVersion','catalogId','sources','profiles','skills') -Context 'Skills Catalog'
    Assert-SchemaVersion -Document $Catalog -Expected 2 -DocumentName 'Skills Catalog'
    Assert-SkillsCatalogCommon -Catalog $Catalog -SchemaVersion 2
}

function Get-SkillsCatalogProjectionMap {
    return @{
        'user-agents' = @('user','.agents/skills')
        'user-claude' = @('user','.claude/skills')
        'user-copilot' = @('user','.copilot/skills')
        'project-agents' = @('project','.agents/skills')
        'project-claude' = @('project','.claude/skills')
        'project-github' = @('project','.github/skills')
    }
}

function Get-SkillsCatalogUserProjectionRoots {
    $projectionMap = Get-SkillsCatalogProjectionMap
    return [string[]]@(
        $projectionMap.GetEnumerator() |
            Where-Object { [string]$_.Value[0] -ceq 'user' } |
            ForEach-Object { [string]$_.Value[1] } |
            Sort-Object
    )
}

function Assert-SkillsCatalogProjections {
    param([Parameter(Mandatory = $true)][object] $Projections)
    Assert-Array -Value $Projections -Context 'Skills Catalog projections'
    $allowed = Get-SkillsCatalogProjectionMap
    $seen = @{}
    foreach ($projection in @($Projections)) {
        Assert-OnlyProperties -Object $projection -Allowed @('id','scope','root') -Context 'Skills Catalog projection'
        $id = Get-RequiredProperty -Object $projection -Name 'id' -Context 'Skills Catalog projection'
        Assert-StableId -Value $id -Context 'Skills Catalog projection id'
        if ($seen.ContainsKey([string]$id)) { throw "Duplicate Skills Catalog projection ID: $id" }
        $seen[[string]$id] = $true
        if (-not $allowed.ContainsKey([string]$id)) { throw "Unknown Skills Catalog projection ID: $id" }
        $scope = Get-RequiredProperty -Object $projection -Name 'scope' -Context "Skills Catalog projection '$id'"
        $root = Get-RequiredProperty -Object $projection -Name 'root' -Context "Skills Catalog projection '$id'"
        Assert-NonEmptyString -Value $scope -Context "Skills Catalog projection '$id' scope"
        Assert-NonEmptyString -Value $root -Context "Skills Catalog projection '$id' root"
        if ([string]$scope -cne [string]$allowed[[string]$id][0] -or [string]$root -cne [string]$allowed[[string]$id][1]) {
            throw "Skills Catalog projection '$id' must use scope '$($allowed[[string]$id][0])' and root '$($allowed[[string]$id][1])'."
        }
    }
    if (-not $seen.ContainsKey('user-agents')) { throw "Skills Catalog projections must include 'user-agents'." }
}

function Assert-SkillsCatalogV3 {
    param([Parameter(Mandatory = $true)][object] $Catalog)
    Assert-OnlyProperties -Object $Catalog -Allowed @('schemaVersion','catalogId','sources','profiles','skills','projections') -Context 'Skills Catalog'
    Assert-SchemaVersion -Document $Catalog -Expected 3 -DocumentName 'Skills Catalog'
    Assert-SkillsCatalogProjections -Projections (Get-RequiredProperty -Object $Catalog -Name 'projections' -Context 'Skills Catalog')
    Assert-SkillsCatalogCommon -Catalog $Catalog -SchemaVersion 3
}

function Get-SkillsCatalogProjectionContractSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Projections)
    Assert-SkillsCatalogProjections -Projections $Projections
    $byId = @{}
    foreach ($projection in @($Projections)) { $byId[[string]$projection.id] = $projection }
    [string[]]$ids = @($byId.Keys)
    [System.Array]::Sort($ids,[System.StringComparer]::Ordinal)
    $canonical = [string]::Concat(@($ids | ForEach-Object { $projection = $byId[$_]; "$($_)`t$([string]$projection.scope)`t$([string]$projection.root)`n" }))
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($canonical)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-SkillsCatalogProjectionTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $ProjectionId
    )
    if ($null -eq $Catalog.PSObject.Properties['schemaVersion'] -or [int64]$Catalog.schemaVersion -ne 3) { throw 'Skills Catalog projection targets require schemaVersion 3.' }
    Assert-SkillsCatalogV3 -Catalog $Catalog
    $skill = @($Catalog.skills | Where-Object { [string]$_.id -ceq $SkillId })
    if ($skill.Count -ne 1) { throw "Skills Catalog v3 does not contain Skill '$SkillId'." }
    $projection = @($Catalog.projections | Where-Object { [string]$_.id -ceq $ProjectionId })
    if ($projection.Count -ne 1) { throw "Skills Catalog v3 does not contain projection '$ProjectionId'." }
    return "$([string]$projection[0].root)/$SkillId"
}

function Assert-SkillsCatalog {
    param([Parameter(Mandatory = $true)][object] $Catalog)
    $version = Get-RequiredProperty -Object $Catalog -Name 'schemaVersion' -Context 'Skills Catalog'
    if ($version -isnot [int] -and $version -isnot [long]) {
        throw 'Skills Catalog schemaVersion must be an integer.'
    }
    switch ([int64]$version) {
        1 { Assert-SkillsCatalogV1 -Catalog $Catalog; return }
        2 { Assert-SkillsCatalogV2 -Catalog $Catalog; return }
        3 { Assert-SkillsCatalogV3 -Catalog $Catalog; return }
        default { throw "Unsupported Skills Catalog schemaVersion '$version'; supported versions are 1, 2 and 3." }
    }
}

function Test-SkillsCatalogDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $CatalogPath)
    $catalog = Import-SkillsCatalogJson -Path $CatalogPath -DocumentName 'Skills Catalog'
    Assert-SkillsCatalog -Catalog $catalog
    return $catalog
}

function Assert-SkillsCatalogSourcePins {
    param([Parameter(Mandatory = $true)][object] $Pins,[Parameter(Mandatory = $true)][object] $Catalog)
    Assert-OnlyProperties -Object $Pins -Allowed @('schemaVersion','catalogId','sources') -Context 'Skills Catalog source pins'
    Assert-SchemaVersion -Document $Pins -Expected 1 -DocumentName 'Skills Catalog source pins'
    $pinsCatalogId = Get-RequiredProperty -Object $Pins -Name 'catalogId' -Context 'Skills Catalog source pins'; Assert-NonEmptyString -Value $pinsCatalogId -Context 'Skills Catalog source pins catalogId'
    if ([string]$pinsCatalogId -cne [string]$Catalog.catalogId) { throw 'Skills Catalog source pins catalogId does not match the Skills Catalog.' }
    $catalogSources = @{}; foreach ($source in @($Catalog.sources)) { $catalogSources[[string]$source.id] = $source }
    $sources = Get-RequiredProperty -Object $Pins -Name 'sources' -Context 'Skills Catalog source pins'; Assert-Array -Value $sources -Context 'Skills Catalog source pins sources'
    $pinsById = @{}
    foreach ($pin in @($sources)) {
        Assert-OnlyProperties -Object $pin -Allowed @('id','requestedRef','requestedRefType','resolvedCommit','resolvedVersion') -Context 'Skills Catalog source pin'
        $sourceId = Get-RequiredProperty -Object $pin -Name 'id' -Context 'Skills Catalog source pin'; Assert-StableId -Value $sourceId -Context 'Skills Catalog source pin id'
        if ($pinsById.ContainsKey([string]$sourceId)) { throw "Duplicate Skills Catalog source pin ID: $sourceId" }
        if (-not $catalogSources.ContainsKey([string]$sourceId)) { throw "Skills Catalog source pins reference unknown source '$sourceId'." }
        $requestedRef = Get-RequiredProperty -Object $pin -Name 'requestedRef' -Context "Skills Catalog source pin '$sourceId'"; Assert-NonEmptyString -Value $requestedRef -Context "Skills Catalog source pin '$sourceId' requestedRef"
        $requestedRefType = Get-RequiredProperty -Object $pin -Name 'requestedRefType' -Context "Skills Catalog source pin '$sourceId'"; Assert-NonEmptyString -Value $requestedRefType -Context "Skills Catalog source pin '$sourceId' requestedRefType"; if (@('branch','tag','commit') -cnotcontains [string]$requestedRefType) { throw "Unsupported requestedRefType '$requestedRefType' for Skills Catalog source pin '$sourceId'." }
        Assert-FullCommitSha -Value (Get-RequiredProperty -Object $pin -Name 'resolvedCommit' -Context "Skills Catalog source pin '$sourceId'") -Context "Skills Catalog source pin '$sourceId'"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $pin -Name 'resolvedVersion' -Context "Skills Catalog source pin '$sourceId'") -Context "Skills Catalog source pin '$sourceId' resolvedVersion"
        $pinsById[[string]$sourceId] = $pin
    }
    foreach ($sourceId in $catalogSources.Keys) { if (-not $pinsById.ContainsKey([string]$sourceId)) { throw "Skills Catalog source '$sourceId' has no source pin." } }
}

function Test-SkillsCatalogSourcePinsDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $SourcePinsPath,[Parameter(Mandatory = $true)][string] $CatalogPath)
    $catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
    $pins = Import-SkillsCatalogJson -Path $SourcePinsPath -DocumentName 'Skills Catalog source pins'
    Assert-SkillsCatalogSourcePins -Pins $pins -Catalog $catalog
    return $pins
}

function Assert-SkillsCatalogLockV1 {
    param([object] $Lock,[object] $Catalog)
    Assert-OnlyProperties -Object $Lock -Allowed @('schemaVersion','catalogId','catalogSha256','sources','skills') -Context 'Skills Catalog lock'
    Assert-SchemaVersion -Document $Lock -Expected 1 -DocumentName 'Skills Catalog lock'
    $lockCatalogId = Get-RequiredProperty -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock'; Assert-NonEmptyString -Value $lockCatalogId -Context 'Skills Catalog lock catalogId'
    if ([string]$lockCatalogId -cne [string]$Catalog.catalogId) { throw 'Skills Catalog lock catalogId does not match the Skills Catalog.' }
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock') -Context 'Skills Catalog lock catalogSha256'
    $catalogSources=@{}; foreach ($source in @($Catalog.sources)) { $catalogSources[[string]$source.id]=$source }
    $sources=Get-RequiredProperty -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'; Assert-Array -Value $sources -Context 'Skills Catalog lock sources'
    $lockedSources=@{}
    foreach ($source in @($sources)) {
        Assert-OnlyProperties -Object $source -Allowed @('id','repository','requestedRef','requestedRefType','resolvedCommit','resolvedVersion','archiveSha256') -Context 'Skills Catalog lock source'
        $sourceId=Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog lock source'
        Assert-StableId -Value $sourceId -Context 'Skills Catalog lock source id'
        if ($lockedSources.ContainsKey([string]$sourceId)) { throw "Duplicate Skills Catalog lock source ID: $sourceId" }
        if (-not $catalogSources.ContainsKey([string]$sourceId)) { throw "Skills Catalog lock references unknown source '$sourceId'." }
        $lockedSources[[string]$sourceId]=$source
        $repository=Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog lock source '$sourceId'"
        Assert-HttpsRepositoryUrl -Value $repository -Context "Skills Catalog lock source '$sourceId' repository"
        if ([string]$repository -cne [string]$catalogSources[[string]$sourceId].repository) { throw "Skills Catalog lock source '$sourceId' repository does not match the catalog." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'requestedRef' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' requestedRef"
        $requestedRefType=Get-RequiredProperty -Object $source -Name 'requestedRefType' -Context "Skills Catalog lock source '$sourceId'"; Assert-NonEmptyString -Value $requestedRefType -Context "Skills Catalog lock source '$sourceId' requestedRefType"; if (@('branch','tag','commit') -cnotcontains [string]$requestedRefType) { throw "Unsupported requestedRefType '$requestedRefType' for Skills Catalog lock source '$sourceId'." }
        Assert-FullCommitSha -Value (Get-RequiredProperty -Object $source -Name 'resolvedCommit' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId'"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'resolvedVersion' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' resolvedVersion"
        Assert-Sha256 -Value (Get-RequiredProperty -Object $source -Name 'archiveSha256' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' archiveSha256"
    }
    foreach ($sourceId in $catalogSources.Keys) { if (-not $lockedSources.ContainsKey([string]$sourceId)) { throw "Skills Catalog source '$sourceId' has no resolved lock entry." } }
    $catalogSkills=@{}; foreach ($skill in @($Catalog.skills)) { if ([string]$skill.lifecycle.status -ne 'removed') { $catalogSkills[[string]$skill.id]=$skill } }
    $skills=Get-RequiredProperty -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'; Assert-Array -Value $skills -Context 'Skills Catalog lock skills' -AllowEmpty
    $lockedSkills=@{}
    foreach ($skill in @($skills)) {
        Assert-OnlyProperties -Object $skill -Allowed @('id','sourceId','sourcePath','contentSha256') -Context 'Skills Catalog lock Skill'
        $skillId=Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog lock Skill id'
        if ($lockedSkills.ContainsKey([string]$skillId)) { throw "Duplicate Skills Catalog lock Skill ID: $skillId" }
        if (-not $catalogSkills.ContainsKey([string]$skillId)) { throw "Skills Catalog lock references unknown or removed Skill '$skillId'." }
        $lockedSkills[[string]$skillId]=$skill
        $sourceId=Get-RequiredProperty -Object $skill -Name 'sourceId' -Context "Skills Catalog lock Skill '$skillId'"; Assert-StableId -Value $sourceId -Context "Skills Catalog lock Skill '$skillId' sourceId"; $sourcePath=Get-RequiredProperty -Object $skill -Name 'sourcePath' -Context "Skills Catalog lock Skill '$skillId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe Skills Catalog lock sourcePath for Skill '$skillId': $sourcePath" }
        if ([string]$sourceId -cne [string]$catalogSkills[[string]$skillId].source.sourceId -or [string]$sourcePath -cne [string]$catalogSkills[[string]$skillId].source.path) { throw "Skills Catalog lock source does not match catalog Skill '$skillId'." }
        Assert-Sha256 -Value (Get-RequiredProperty -Object $skill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$skillId'") -Context "Skills Catalog lock Skill '$skillId' contentSha256"
    }
    foreach ($skillId in $catalogSkills.Keys) { if (-not $lockedSkills.ContainsKey([string]$skillId)) { throw "Skills Catalog Skill '$skillId' has no content lock entry." } }
}

function Assert-SkillsCatalogLockCanonical {
    param(
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][ValidateSet(2,3)][int] $SchemaVersion
    )

    $lockProperties = @('schemaVersion','catalogId','catalogSha256','sources','skills')
    if ($SchemaVersion -eq 3) { $lockProperties += 'projectionContractSha256' }
    Assert-OnlyProperties -Object $Lock -Allowed $lockProperties -Context 'Skills Catalog lock'
    Assert-SchemaVersion -Document $Lock -Expected $SchemaVersion -DocumentName 'Skills Catalog lock'
    if ([int64]$Catalog.schemaVersion -ne $SchemaVersion) { throw "Skills Catalog lock schemaVersion $SchemaVersion requires Skills Catalog schemaVersion $SchemaVersion." }
    if ($SchemaVersion -eq 2) { Assert-SkillsCatalogV2 -Catalog $Catalog } else { Assert-SkillsCatalogV3 -Catalog $Catalog }

    $lockCatalogId = Get-RequiredProperty -Object $Lock -Name 'catalogId' -Context 'Skills Catalog lock'
    Assert-NonEmptyString -Value $lockCatalogId -Context 'Skills Catalog lock catalogId'
    if ([string]$lockCatalogId -cne [string]$Catalog.catalogId) { throw 'Skills Catalog lock catalogId does not match the Skills Catalog.' }
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Lock -Name 'catalogSha256' -Context 'Skills Catalog lock') -Context 'Skills Catalog lock catalogSha256'
    if ($SchemaVersion -eq 3) {
        $projectionContractSha256 = Get-RequiredProperty -Object $Lock -Name 'projectionContractSha256' -Context 'Skills Catalog lock'
        Assert-Sha256 -Value $projectionContractSha256 -Context 'Skills Catalog lock projectionContractSha256'
        $expectedProjectionContractSha256 = Get-SkillsCatalogProjectionContractSha256 -Projections $Catalog.projections
        if ([string]$projectionContractSha256 -cne $expectedProjectionContractSha256) {
            throw "Skills Catalog lock projectionContractSha256 does not match the Catalog projections: expected $expectedProjectionContractSha256."
        }
    }

    $catalogSources = @{}
    foreach ($source in @($Catalog.sources)) { $catalogSources[[string]$source.id] = $source }
    $lockedSources = @{}
    $sources = Get-RequiredProperty -Object $Lock -Name 'sources' -Context 'Skills Catalog lock'
    Assert-Array -Value $sources -Context 'Skills Catalog lock sources'
    foreach ($source in @($sources)) {
        Assert-OnlyProperties -Object $source -Allowed @('id','repository','requestedRef','requestedRefType','resolvedCommit','resolvedVersion','archiveSha256') -Context 'Skills Catalog lock source'
        $sourceId = Get-RequiredProperty -Object $source -Name 'id' -Context 'Skills Catalog lock source'
        Assert-StableId -Value $sourceId -Context 'Skills Catalog lock source id'
        if ($lockedSources.ContainsKey([string]$sourceId)) { throw "Duplicate Skills Catalog lock source ID: $sourceId" }
        if (-not $catalogSources.ContainsKey([string]$sourceId)) { throw "Skills Catalog lock references unknown source '$sourceId'." }
        $lockedSources[[string]$sourceId] = $source
        Assert-GitHubRepositoryUrl -Value (Get-RequiredProperty -Object $source -Name 'repository' -Context "Skills Catalog lock source '$sourceId' repository") -Context "Skills Catalog lock source '$sourceId' repository"
        if ([string]$source.repository -cne [string]$catalogSources[[string]$sourceId].repository) { throw "Skills Catalog lock source '$sourceId' repository does not match the catalog." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'requestedRef' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' requestedRef"
        $requestedRefType = Get-RequiredProperty -Object $source -Name 'requestedRefType' -Context "Skills Catalog lock source '$sourceId'"
        Assert-NonEmptyString -Value $requestedRefType -Context "Skills Catalog lock source '$sourceId' requestedRefType"
        if (@('branch','tag','commit') -cnotcontains [string]$requestedRefType) { throw "Unsupported requestedRefType '$requestedRefType' for Skills Catalog lock source '$sourceId'." }
        Assert-FullCommitSha -Value (Get-RequiredProperty -Object $source -Name 'resolvedCommit' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId'"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $source -Name 'resolvedVersion' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' resolvedVersion"
        Assert-Sha256 -Value (Get-RequiredProperty -Object $source -Name 'archiveSha256' -Context "Skills Catalog lock source '$sourceId'") -Context "Skills Catalog lock source '$sourceId' archiveSha256"
    }
    foreach ($sourceId in $catalogSources.Keys) { if (-not $lockedSources.ContainsKey([string]$sourceId)) { throw "Skills Catalog source '$sourceId' has no resolved lock entry." } }

    $catalogSkills = @{}
    foreach ($skill in @($Catalog.skills)) { if ([string]$skill.lifecycle.status -ne 'removed') { $catalogSkills[[string]$skill.id] = $skill } }
    $lockedSkills = @{}
    $skills = Get-RequiredProperty -Object $Lock -Name 'skills' -Context 'Skills Catalog lock'
    Assert-Array -Value $skills -Context 'Skills Catalog lock skills' -AllowEmpty
    foreach ($skill in @($skills)) {
        $skillProperties = @('id','sourceId','sourcePath','contentSha256')
        if ($SchemaVersion -eq 2) { $skillProperties += 'targetPath' }
        Assert-OnlyProperties -Object $skill -Allowed $skillProperties -Context 'Skills Catalog lock Skill'
        $skillId = Get-RequiredProperty -Object $skill -Name 'id' -Context 'Skills Catalog lock Skill'
        Assert-StableId -Value $skillId -Context 'Skills Catalog lock Skill id'
        if ($lockedSkills.ContainsKey([string]$skillId)) { throw "Duplicate Skills Catalog lock Skill ID: $skillId" }
        if (-not $catalogSkills.ContainsKey([string]$skillId)) { throw "Skills Catalog lock references unknown or removed Skill '$skillId'." }
        $lockedSkills[[string]$skillId] = $skill
        $sourceId = Get-RequiredProperty -Object $skill -Name 'sourceId' -Context "Skills Catalog lock Skill '$skillId'"
        Assert-StableId -Value $sourceId -Context "Skills Catalog lock Skill '$skillId' sourceId"
        $sourcePath = Get-RequiredProperty -Object $skill -Name 'sourcePath' -Context "Skills Catalog lock Skill '$skillId'"
        if ($sourcePath -isnot [string] -or [string]$sourcePath -cne "skills/$skillId") { throw "Unsafe Skills Catalog v$SchemaVersion lock sourcePath for Skill '$skillId': $sourcePath" }
        $catalogSource = $catalogSkills[[string]$skillId].source
        if ($SchemaVersion -eq 2) {
            $targetPath = Get-RequiredProperty -Object $skill -Name 'targetPath' -Context "Skills Catalog lock Skill '$skillId'"
            if ($targetPath -isnot [string] -or [string]$targetPath -cne ".agents/skills/$skillId") { throw "Unsafe Skills Catalog v2 lock targetPath for Skill '$skillId': $targetPath" }
            if ([string]$sourceId -cne [string]$catalogSource.sourceId -or [string]$sourcePath -cne [string]$catalogSource.sourcePath -or [string]$targetPath -cne [string]$catalogSource.targetPath) {
                throw "Skills Catalog lock source/target does not match catalog Skill '$skillId'."
            }
        }
        elseif ([string]$sourceId -cne [string]$catalogSource.sourceId -or [string]$sourcePath -cne [string]$catalogSource.sourcePath) {
            throw "Skills Catalog lock source does not match catalog Skill '$skillId'."
        }
        Assert-Sha256 -Value (Get-RequiredProperty -Object $skill -Name 'contentSha256' -Context "Skills Catalog lock Skill '$skillId'") -Context "Skills Catalog lock Skill '$skillId' contentSha256"
    }
    foreach ($skillId in $catalogSkills.Keys) { if (-not $lockedSkills.ContainsKey([string]$skillId)) { throw "Skills Catalog Skill '$skillId' has no content lock entry." } }
}

function Assert-SkillsCatalogLockV2 {
    param([Parameter(Mandatory = $true)][object] $Lock,[Parameter(Mandatory = $true)][object] $Catalog)
    Assert-SkillsCatalogLockCanonical -Lock $Lock -Catalog $Catalog -SchemaVersion 2
}

function Assert-SkillsCatalogLockV3 {
    param([Parameter(Mandatory = $true)][object] $Lock,[Parameter(Mandatory = $true)][object] $Catalog)
    Assert-SkillsCatalogLockCanonical -Lock $Lock -Catalog $Catalog -SchemaVersion 3
}

function Assert-SkillsCatalogLock {
    param([Parameter(Mandatory = $true)][object] $Lock,[Parameter(Mandatory = $true)][object] $Catalog)
    $catalogVersion = Get-RequiredProperty -Object $Catalog -Name 'schemaVersion' -Context 'Skills Catalog'
    $lockVersion = Get-RequiredProperty -Object $Lock -Name 'schemaVersion' -Context 'Skills Catalog lock'
    if ($catalogVersion -isnot [int] -and $catalogVersion -isnot [long]) { throw 'Skills Catalog schemaVersion must be an integer.' }
    if ($lockVersion -isnot [int] -and $lockVersion -isnot [long]) { throw 'Skills Catalog lock schemaVersion must be an integer.' }
    if ([int64]$catalogVersion -ne [int64]$lockVersion) { throw "Skills Catalog lock schemaVersion '$lockVersion' does not match Skills Catalog schemaVersion '$catalogVersion'." }
    switch ([int64]$lockVersion) {
        1 { Assert-SkillsCatalogLockV1 -Lock $Lock -Catalog $Catalog; return }
        2 { Assert-SkillsCatalogLockV2 -Lock $Lock -Catalog $Catalog; return }
        3 { Assert-SkillsCatalogLockV3 -Lock $Lock -Catalog $Catalog; return }
        default { throw "Unsupported Skills Catalog lock schemaVersion '$lockVersion'; supported versions are 1, 2 and 3." }
    }
}

function Test-SkillsCatalogLockDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $LockPath,[Parameter(Mandatory = $true)][string] $CatalogPath)
    $catalog=Test-SkillsCatalogDocument -CatalogPath $CatalogPath; $lock=Import-SkillsCatalogJson -Path $LockPath -DocumentName 'Skills Catalog lock'; Assert-SkillsCatalogLock -Lock $lock -Catalog $catalog
    $catalogFileSha256=Get-RawFileSha256 -Path $CatalogPath; if ([string]$lock.catalogSha256 -cne $catalogFileSha256) { throw "Skills Catalog lock catalogSha256 does not match the Catalog file: expected $catalogFileSha256." }
    return $lock
}

function Assert-ManagedManifestV2 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogId','lockSha256','files') -Context 'managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 2 -DocumentName 'managed manifest'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'managed manifest') -Context 'managed manifest catalogId'; Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'managed manifest') -Context 'managed manifest lockSha256'
    $files=Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'managed manifest'; Assert-Array -Value $files -Context 'managed manifest files' -AllowEmpty; $targetPaths=@{}
    foreach ($entry in @($files)) {
        Assert-OnlyProperties -Object $entry -Allowed @('artifactType','artifactId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','sourcePath','targetPath','sha256') -Context 'managed manifest file'
        $artifactType=Get-RequiredProperty -Object $entry -Name 'artifactType' -Context 'managed manifest file'; Assert-NonEmptyString -Value $artifactType -Context 'managed manifest file artifactType'; if (@('instruction','skill') -cnotcontains [string]$artifactType) { throw "Unsupported managed manifest artifactType '$artifactType'." }
        $artifactId=Get-RequiredProperty -Object $entry -Name 'artifactId' -Context 'managed manifest file'; Assert-StableId -Value $artifactId -Context 'managed manifest file artifactId'; Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRepository"; Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRef"
        $sourceCommit=Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "managed manifest file '$artifactId'"; if ($sourceCommit -isnot [string]) { throw "managed manifest file '$artifactId' sourceCommit must be a string." }; if ([string]$sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "managed manifest file '$artifactId' sourceCommit must be a full 40-character commit SHA." }; Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceVersion"
        $sourcePath=Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "managed manifest file '$artifactId'"; $targetPath=Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "managed manifest file '$artifactId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe source path in managed manifest: $sourcePath" }; if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) { throw "Unsafe target path in managed manifest: $targetPath" }; if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in managed manifest: $targetPath" }; $targetPaths[[string]$targetPath]=$true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sha256"
        if ([string]$artifactType -eq 'skill') {
            $skillPrefix=".agents/skills/$artifactId/"
            if (-not ([string]$sourcePath).StartsWith($skillPrefix,[System.StringComparison]::Ordinal) -or
                -not ([string]$targetPath).StartsWith($skillPrefix,[System.StringComparison]::Ordinal)) {
                throw "Managed Skill '$artifactId' must preserve the flat .agents/skills path."
            }
        }
        elseif (([string]$sourcePath).StartsWith('.agents/skills/',[System.StringComparison]::Ordinal) -or
                ([string]$targetPath).StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
            throw "Managed instruction '$artifactId' must not claim a .agents/skills path."
        }
    }
}

function Assert-ManagedManifestV3 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogId','lockSha256','files') -Context 'managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 3 -DocumentName 'managed manifest'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'managed manifest') -Context 'managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'managed manifest') -Context 'managed manifest lockSha256'
    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'managed manifest'
    Assert-Array -Value $files -Context 'managed manifest files' -AllowEmpty
    $targetPaths = @{}
    foreach ($entry in @($files)) {
        Assert-OnlyProperties -Object $entry -Allowed @('artifactType','artifactId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','sourcePath','targetPath','sha256') -Context 'managed manifest file'
        $artifactType = Get-RequiredProperty -Object $entry -Name 'artifactType' -Context 'managed manifest file'
        Assert-NonEmptyString -Value $artifactType -Context 'managed manifest file artifactType'
        if (@('instruction','skill') -cnotcontains [string]$artifactType) { throw "Unsupported managed manifest artifactType '$artifactType'." }
        $artifactId = Get-RequiredProperty -Object $entry -Name 'artifactId' -Context 'managed manifest file'
        Assert-StableId -Value $artifactId -Context 'managed manifest file artifactId'
        Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRepository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRef"
        $sourceCommit = Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "managed manifest file '$artifactId'"
        if ($sourceCommit -isnot [string] -or [string]$sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "managed manifest file '$artifactId' sourceCommit must be a full 40-character commit SHA." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceVersion"
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "managed manifest file '$artifactId'"
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "managed manifest file '$artifactId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe source path in managed manifest: $sourcePath" }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) { throw "Unsafe target path in managed manifest: $targetPath" }
        if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in managed manifest: $targetPath" }
        $targetPaths[[string]$targetPath] = $true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sha256"
        if ([string]$artifactType -eq 'skill') {
            $sourcePrefix = "skills/$artifactId/"
            $targetPrefix = ".agents/skills/$artifactId/"
            if (-not ([string]$sourcePath).StartsWith($sourcePrefix,[System.StringComparison]::Ordinal) -or
                -not ([string]$targetPath).StartsWith($targetPrefix,[System.StringComparison]::Ordinal)) {
                throw "Managed Skill '$artifactId' must map canonical skills/$artifactId source files to the flat .agents/skills target."
            }
        }
        elseif (([string]$sourcePath).StartsWith('.agents/skills/',[System.StringComparison]::Ordinal) -or
                ([string]$targetPath).StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
            throw "Managed instruction '$artifactId' must not claim a .agents/skills path."
        }
    }
}

function Test-IsManagedManifestV4InstructionLicensePath {
    param([Parameter(Mandatory = $true)][string] $InstructionHost,[object] $Value)
    if (-not (Test-IsSafeRepositoryPath -Value $Value)) { return $false }
    $pattern = switch ($InstructionHost) {
        'codex' { '^\.codex/ai-instructions-licenses/(?:[0-9a-f]{40}/)?(?:delivery\.json|source/.+)$' }
        'copilot' { '^\.github/ai-instructions-licenses/(?:[0-9a-f]{40}/)?(?:delivery\.json|source/.+)$' }
        'claude' { '^\.claude/ai-instructions-licenses/[0-9a-f]{40}/(?:delivery\.json|source/.+)$' }
        default { return $false }
    }
    return [string]$Value -cmatch $pattern
}

function Test-IsManagedManifestV4InstructionTarget {
    param([Parameter(Mandatory = $true)][string] $InstructionHost,[Parameter(Mandatory = $true)][string] $TargetPath)
    if (Test-IsManagedManifestV4InstructionLicensePath -InstructionHost $InstructionHost -Value $TargetPath) { return $true }
    switch ($InstructionHost) {
        'codex' { return $TargetPath -ceq 'AGENTS.md' -or $TargetPath -cmatch '^\.codex/AI-Rules/[^/\\]+\.en\.md$' }
        'copilot' { return $TargetPath -ceq '.github/copilot-instructions.md' -or $TargetPath -cmatch '^\.github/AI-Rules/[^/\\]+\.en\.md$' }
        'claude' { return $TargetPath -ceq 'CLAUDE.md' -or $TargetPath -cmatch '^\.claude/AI-Rules/[^/\\]+\.en\.md$' }
        default { return $false }
    }
}

function ConvertFrom-GitWorktreePorcelainZ {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Output,
        [switch] $Strict
    )

    $raw = @($Output | ForEach-Object { [string]$_ }) -join "`n"
    if ([string]::IsNullOrEmpty($raw)) {
        if ($Strict) { throw 'Invalid git worktree porcelain output.' }
        return
    }
    if (-not $raw.EndsWith("`0`0",[System.StringComparison]::Ordinal)) {
        if ($Strict) { throw 'Invalid git worktree porcelain output.' }
        return
    }

    $recordCount = 0
    foreach ($recordText in @($raw.Split(@("`0`0"),[System.StringSplitOptions]::None))) {
        if ([string]::IsNullOrEmpty($recordText)) { continue }
        $fields = @($recordText.Split([char]0))
        if ($fields.Count -eq 0 -or -not ([string]$fields[0]).StartsWith('worktree ',[System.StringComparison]::Ordinal) -or
            ([string]$fields[0]).Length -eq 'worktree '.Length) {
            if ($Strict) { throw 'Invalid git worktree porcelain output.' }
            continue
        }

        $recordHasState = $false
        $prunable = $false
        for ($index = 1; $index -lt $fields.Count; $index++) {
            $field = [string]$fields[$index]
            $isLocked = $field.StartsWith('locked',[System.StringComparison]::Ordinal)
            $isPrunable = $field.StartsWith('prunable',[System.StringComparison]::Ordinal)
            $hasValidReason = {
                param([string] $Value,[string] $Prefix)
                $suffix = $Value.Substring($Prefix.Length)
                return $suffix.Length -eq 0 -or ($suffix.Length -gt 1 -and $suffix[0] -eq ' ')
            }
            if (
                $field -cnotmatch '^(?:HEAD (?:[0-9a-f]{40}|[0-9a-f]{64})|branch .+|detached|bare)$' -and
                (-not $isLocked -or -not (& $hasValidReason $field 'locked')) -and
                (-not $isPrunable -or -not (& $hasValidReason $field 'prunable'))
            ) {
                if ($Strict) { throw 'Invalid git worktree porcelain output.' }
                continue
            }
            if ($field -cmatch '^(?:HEAD (?:[0-9a-f]{40}|[0-9a-f]{64})|bare)$') { $recordHasState = $true }
            if ($isPrunable) { $prunable = $true }
        }
        if ($Strict -and -not $recordHasState) { throw 'Invalid git worktree porcelain output.' }
        $recordCount++
        [pscustomobject][ordered]@{
            Path = ([string]$fields[0]).Substring('worktree '.Length)
            Prunable = $prunable
        }
    }
    if ($Strict -and $recordCount -eq 0) { throw 'Invalid git worktree porcelain output.' }
}

function Assert-ProjectionSkillParity {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Validated,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object] $Projections,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $skillIds = @($Validated | ForEach-Object { $_.SkillId } | Sort-Object -Unique)
    foreach ($skillId in $skillIds) {
        $skillFiles = @($Validated | Where-Object { $_.SkillId -ceq $skillId })
        $identity = $null
        $sourcePathsByRelativePath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        foreach ($file in $skillFiles) {
            $entry = $file.Entry
            $currentIdentity = [pscustomobject][ordered]@{
                sourceId = [string]$entry.sourceId
                sourceRepository = [string]$entry.sourceRepository
                sourceRef = [string]$entry.sourceRef
                sourceCommit = [string]$entry.sourceCommit
                sourceVersion = [string]$entry.sourceVersion
            }
            if ($null -eq $identity) { $identity = $currentIdentity }
            elseif (
                $currentIdentity.sourceId -cne $identity.sourceId -or
                $currentIdentity.sourceRepository -cne $identity.sourceRepository -or
                $currentIdentity.sourceRef -cne $identity.sourceRef -or
                $currentIdentity.sourceCommit -cne $identity.sourceCommit -or
                $currentIdentity.sourceVersion -cne $identity.sourceVersion
            ) { throw "$Context '$skillId' has inconsistent source identity across projections." }
            if (-not $sourcePathsByRelativePath.ContainsKey([string]$file.RelativePath)) { $sourcePathsByRelativePath[[string]$file.RelativePath] = [string]$entry.sourcePath }
            elseif ([string]$sourcePathsByRelativePath[[string]$file.RelativePath] -cne [string]$entry.sourcePath) { throw "$Context '$skillId' has inconsistent sourcePath for '$($file.RelativePath)' across projections." }
        }
        $baseline = $null
        $baselineProjection = $null
        foreach ($projectionId in @($Projections)) {
            $projectionFiles = @($skillFiles | Where-Object { $_.ProjectionId -ceq [string]$projectionId })
            if ($projectionFiles.Count -eq 0) { throw "$Context '$skillId' is missing projection '$projectionId'." }
            $relativeHashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
            foreach ($file in $projectionFiles) { $relativeHashes[[string]$file.RelativePath] = [string]$file.Sha256 }
            if ($null -eq $baseline) { $baseline = $relativeHashes; $baselineProjection = [string]$projectionId; continue }
            $allPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($relativePath in $baseline.Keys) { [void]$allPaths.Add([string]$relativePath) }
            foreach ($relativePath in $relativeHashes.Keys) { [void]$allPaths.Add([string]$relativePath) }
            [string[]]$sortedPaths = @($allPaths)
            [System.Array]::Sort($sortedPaths,[System.StringComparer]::Ordinal)
            foreach ($relativePath in $sortedPaths) {
                if (-not $baseline.ContainsKey($relativePath) -or -not $relativeHashes.ContainsKey($relativePath) -or [string]$baseline[$relativePath] -cne [string]$relativeHashes[$relativePath]) {
                    throw "$Context '$skillId' projection parity differs between '$baselineProjection' and '$projectionId' at '$relativePath'."
                }
            }
        }
    }
}

function Assert-ManagedManifestV4 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogId','lockSha256','projectionContractSha256','generation','projections','files') -Context 'managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 4 -DocumentName 'managed manifest'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'managed manifest') -Context 'managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'managed manifest') -Context 'managed manifest lockSha256'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'projectionContractSha256' -Context 'managed manifest') -Context 'managed manifest projectionContractSha256'
    $generation = Get-RequiredProperty -Object $Manifest -Name 'generation' -Context 'managed manifest'
    if (($generation -isnot [int] -and $generation -isnot [long]) -or [int64]$generation -lt 1 -or [decimal]$generation -gt [int64]::MaxValue) { throw 'managed manifest generation must be an integer from 1 through Int64 maximum.' }

    $projections = Get-RequiredProperty -Object $Manifest -Name 'projections' -Context 'managed manifest'
    Assert-StableIdArray -Value $projections -Context 'managed manifest projections' -AllowEmpty
    $projectionMap = Get-SkillsCatalogProjectionMap
    $projectionIds = @{}
    $projectionRoots = @{}
    foreach ($projectionId in @($projections)) {
        if (-not $projectionMap.ContainsKey([string]$projectionId) -or [string]$projectionMap[[string]$projectionId][0] -cne 'project') {
            throw "Unsupported REPO managed manifest projection '$projectionId'."
        }
        $projectionIds[[string]$projectionId] = $true
        $projectionRoots[[string]$projectionId] = [string]$projectionMap[[string]$projectionId][1]
    }

    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'managed manifest'
    Assert-Array -Value $files -Context 'managed manifest files' -AllowEmpty
    $targetPaths = @{}
    $normalizedSkillFiles = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($files)) {
        $artifactType = Get-RequiredProperty -Object $entry -Name 'artifactType' -Context 'managed manifest file'
        Assert-NonEmptyString -Value $artifactType -Context 'managed manifest file artifactType'
        if (@('instruction','skill') -cnotcontains [string]$artifactType) { throw "Unsupported managed manifest artifactType '$artifactType'." }
        $allowed = @('artifactType','artifactId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','sourcePath','targetPath','sha256')
        if ([string]$artifactType -ceq 'instruction') { $allowed += @('host','rendererId','rendererSha256','retention') }
        else { $allowed += 'projectionId' }
        Assert-OnlyProperties -Object $entry -Allowed $allowed -Context 'managed manifest file'

        $artifactId = Get-RequiredProperty -Object $entry -Name 'artifactId' -Context 'managed manifest file'
        Assert-StableId -Value $artifactId -Context 'managed manifest file artifactId'
        Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRepository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceRef"
        $sourceCommit = Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "managed manifest file '$artifactId'"
        if ($sourceCommit -isnot [string] -or [string]$sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "managed manifest file '$artifactId' sourceCommit must be a full 40-character commit SHA." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sourceVersion"
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "managed manifest file '$artifactId'"
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "managed manifest file '$artifactId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe source path in managed manifest: $sourcePath" }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) { throw "Unsafe target path in managed manifest: $targetPath" }
        if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in managed manifest: $targetPath" }
        $targetPaths[[string]$targetPath] = $true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context "managed manifest file '$artifactId'") -Context "managed manifest file '$artifactId' sha256"

        if ([string]$artifactType -ceq 'instruction') {
            $instructionHost = Get-RequiredProperty -Object $entry -Name 'host' -Context "managed manifest instruction '$artifactId'"
            Assert-NonEmptyString -Value $instructionHost -Context "managed manifest instruction '$artifactId' host"
            if (@('codex','copilot','claude') -cnotcontains [string]$instructionHost) { throw "Unknown managed manifest instruction host '$instructionHost'." }
            $rendererId = Get-RequiredProperty -Object $entry -Name 'rendererId' -Context "managed manifest instruction '$artifactId'"
            Assert-StableId -Value $rendererId -Context "managed manifest instruction '$artifactId' rendererId"
            $rendererSha256 = Get-RequiredProperty -Object $entry -Name 'rendererSha256' -Context "managed manifest instruction '$artifactId'"
            $retentionProperty = $entry.PSObject.Properties['retention']
            if ($null -ne $retentionProperty -and $retentionProperty.Value -isnot [string]) {
                throw "Managed manifest instruction '$artifactId' retention must be a string."
            }
            if ([string]$rendererId -ceq 'legacy-unrendered') {
                if ($null -eq $retentionProperty -or [string]$retentionProperty.Value -cne 'legacy-preserved') {
                    throw "Managed manifest instruction '$artifactId' may use rendererId 'legacy-unrendered' only with retention 'legacy-preserved'."
                }
                if ($null -ne $rendererSha256) {
                    throw "Managed manifest instruction '$artifactId' with rendererId 'legacy-unrendered' must use a null rendererSha256."
                }
            }
            else {
                if ($null -ne $retentionProperty) {
                    throw "Managed manifest instruction '$artifactId' retention is only allowed for rendererId 'legacy-unrendered'."
                }
                if ($null -eq $rendererSha256) {
                    throw "Managed manifest instruction '$artifactId' with rendererId '$rendererId' must include rendererSha256."
                }
                Assert-Sha256 -Value $rendererSha256 -Context "managed manifest instruction '$artifactId' rendererSha256"
            }
            if (-not (Test-IsManagedManifestV4InstructionTarget -InstructionHost ([string]$instructionHost) -TargetPath ([string]$targetPath))) {
                throw "Managed instruction '$artifactId' target path is not allowed for host '$instructionHost': $targetPath"
            }
        }
        else {
            $normalizedSkillFiles.Add([pscustomobject][ordered]@{
                skillId=[string]$artifactId; sourceId=$entry.sourceId; sourceRepository=$entry.sourceRepository; sourceRef=$entry.sourceRef
                sourceCommit=$entry.sourceCommit; sourceVersion=$entry.sourceVersion; sourcePath=$entry.sourcePath
                projectionId=(Get-RequiredProperty -Object $entry -Name 'projectionId' -Context "managed manifest Skill '$artifactId'")
                targetPath=$entry.targetPath; sha256=$entry.sha256
            })
        }
    }
    $validated = @(Assert-UserSkillsManagedManifestFiles -Files ([object[]]$normalizedSkillFiles.ToArray()) -ProjectionRoot '.agents/skills' -HasProjectionId -ProjectionIds $projectionIds -ProjectionRoots $projectionRoots)
    Assert-ProjectionSkillParity -Validated $validated -Projections $projections -Context 'REPO-managed Skill'
}

function Assert-ManagedManifest {
    param([Parameter(Mandatory = $true)][object] $Manifest)
    $version = Get-RequiredProperty -Object $Manifest -Name 'schemaVersion' -Context 'managed manifest'
    if ($version -isnot [int] -and $version -isnot [long]) { throw 'managed manifest schemaVersion must be an integer.' }
    switch ([int64]$version) {
        2 { Assert-ManagedManifestV2 -Manifest $Manifest; return }
        3 { Assert-ManagedManifestV3 -Manifest $Manifest; return }
        4 { Assert-ManagedManifestV4 -Manifest $Manifest; return }
        default { throw "Unsupported managed manifest schemaVersion '$version'; supported versions are 2, 3 and 4." }
    }
}

function Assert-UserSkillsManagedManifestV1 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogRepository','catalogCommit','catalogId','lockSha256','files') -Context 'user Skills managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 1 -DocumentName 'user Skills managed manifest'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogRepository' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogRepository'
    $catalogCommit = Get-RequiredProperty -Object $Manifest -Name 'catalogCommit' -Context 'user Skills managed manifest'
    if ($catalogCommit -isnot [string] -or [string]$catalogCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'user Skills managed manifest catalogCommit must be a full 40-character commit SHA.' }
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest lockSha256'
    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'user Skills managed manifest'
    Assert-Array -Value $files -Context 'user Skills managed manifest files' -AllowEmpty
    $targetPaths = @{}
    foreach ($entry in @($files)) {
        Assert-OnlyProperties -Object $entry -Allowed @('skillId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','sourcePath','targetPath','sha256') -Context 'user Skills managed manifest file'
        $skillId = Get-RequiredProperty -Object $entry -Name 'skillId' -Context 'user Skills managed manifest file'
        Assert-StableId -Value $skillId -Context 'user Skills managed manifest file skillId'
        Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceRepository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceRef"
        $sourceCommit = Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "user Skills managed manifest file '$skillId'"
        if ($sourceCommit -isnot [string] -or [string]$sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "user Skills managed manifest file '$skillId' sourceCommit must be a full 40-character commit SHA." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceVersion"
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "user Skills managed manifest file '$skillId'"
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "user Skills managed manifest file '$skillId'"
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe source path in user Skills managed manifest: $sourcePath" }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath) -or -not ([string]$targetPath).StartsWith(".agents/skills/$skillId/",[System.StringComparison]::Ordinal)) { throw "User-managed Skill '$skillId' must preserve the flat .agents/skills path." }
        if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in user Skills managed manifest: $targetPath" }
        $targetPaths[[string]$targetPath] = $true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sha256"
    }
}

function Assert-UserSkillsManagedManifestFiles {
    param(
        [Parameter(Mandatory = $true)][object] $Files,
        [Parameter(Mandatory = $true)][string] $ProjectionRoot,
        [switch] $HasProjectionId,
        [hashtable] $ProjectionIds,
        [hashtable] $ProjectionRoots
    )
    Assert-Array -Value $Files -Context 'user Skills managed manifest files' -AllowEmpty
    $targetPaths = @{}
    $validated = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Files)) {
        $allowed = @('skillId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','sourcePath','targetPath','sha256')
        if ($HasProjectionId) { $allowed += 'projectionId' }
        Assert-OnlyProperties -Object $entry -Allowed $allowed -Context 'user Skills managed manifest file'
        $skillId = Get-RequiredProperty -Object $entry -Name 'skillId' -Context 'user Skills managed manifest file'
        Assert-StableId -Value $skillId -Context 'user Skills managed manifest file skillId'
        Assert-StableId -Value (Get-RequiredProperty -Object $entry -Name 'sourceId' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceId"
        Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $entry -Name 'sourceRepository' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceRepository"
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceRef' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceRef"
        $sourceCommit = Get-RequiredProperty -Object $entry -Name 'sourceCommit' -Context "user Skills managed manifest file '$skillId'"
        if ($sourceCommit -isnot [string] -or [string]$sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "user Skills managed manifest file '$skillId' sourceCommit must be a full 40-character commit SHA." }
        Assert-NonEmptyString -Value (Get-RequiredProperty -Object $entry -Name 'sourceVersion' -Context "user Skills managed manifest file '$skillId'") -Context "user Skills managed manifest file '$skillId' sourceVersion"
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context "user Skills managed manifest file '$skillId'"
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context "user Skills managed manifest file '$skillId'"
        if ([string]$sourcePath -cne '.ai-instructions-generated/delivery.json' -and -not (Test-IsSafeRepositoryPath -Value $sourcePath)) {
            throw "User-managed Skill '$skillId' has unsafe source path: $sourcePath"
        }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) {
            throw "User-managed Skill '$skillId' has unsafe target path: $targetPath"
        }
        $projectionId = $null
        $root = $ProjectionRoot
        if ($HasProjectionId) {
            $projectionId = Get-RequiredProperty -Object $entry -Name 'projectionId' -Context "user Skills managed manifest file '$skillId'"
            Assert-StableId -Value $projectionId -Context "user Skills managed manifest file '$skillId' projectionId"
            if (-not $ProjectionIds.ContainsKey([string]$projectionId)) { throw "User-managed Skill '$skillId' projection '$projectionId' is not listed in projections." }
            $root = [string]$ProjectionRoots[[string]$projectionId]
        }
        if (-not ([string]$targetPath).StartsWith("$root/$skillId/",[System.StringComparison]::Ordinal)) {
            throw "User-managed Skill '$skillId' target path must be inside projection root '$root'."
        }
        $targetPrefix = "$root/$skillId/"
        $licenseNamespacePrefix = Get-UserSkillsLicenseNamespacePrefix -TargetPrefix $targetPrefix
        $licenseTargetPattern = '^' + [regex]::Escape($licenseNamespacePrefix) + '(?:source/.+|delivery\.json)$'
        if ([string]$targetPath -ceq ($licenseNamespacePrefix + 'delivery.json')) {
            if ([string]$sourcePath -cne '.ai-instructions-generated/delivery.json') {
                throw "User-managed Skill '$skillId' delivery receipt must use the synthetic source path '.ai-instructions-generated/delivery.json'."
            }
        }
        elseif ([string]$targetPath -cmatch $licenseTargetPattern) {
            if (-not (Test-IsLicenseDeliverySourcePath -Value $sourcePath)) {
                throw "User-managed Skill '$skillId' license delivery source must identify a license document or LICENSES path."
            }
        }
        elseif (([string]$targetPath).StartsWith($licenseNamespacePrefix,[System.StringComparison]::Ordinal)) {
            throw "User-managed Skill '$skillId' has an invalid license delivery target path."
        }
        elseif (-not ([string]$sourcePath).StartsWith("skills/$skillId/",[System.StringComparison]::Ordinal)) {
            throw "User-managed Skill '$skillId' must preserve the canonical skills source path."
        }
        else {
            $sourceRelativePath = ([string]$sourcePath).Substring(("skills/$skillId/").Length)
            $targetRelativePath = ([string]$targetPath).Substring($targetPrefix.Length)
            if ($sourceRelativePath -cne $targetRelativePath) {
                throw "User-managed Skill '$skillId' source and target paths must match."
            }
        }
        if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in user Skills managed manifest: $targetPath" }
        $targetPaths[[string]$targetPath] = $true
        $sha256 = Get-RequiredProperty -Object $entry -Name 'sha256' -Context "user Skills managed manifest file '$skillId'"
        Assert-Sha256 -Value $sha256 -Context "user Skills managed manifest file '$skillId' sha256"
        $validated.Add([pscustomobject][ordered]@{
            Entry=$entry; SkillId=[string]$skillId; ProjectionId=[string]$projectionId; Root=$root
            RelativePath=([string]$targetPath).Substring($targetPrefix.Length); Sha256=[string]$sha256
        })
    }
    return [object[]]$validated.ToArray()
}

function Assert-UserSkillsManagedManifestV2 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogRepository','catalogCommit','catalogId','lockSha256','files') -Context 'user Skills managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 2 -DocumentName 'user Skills managed manifest'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogRepository' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogRepository'
    Assert-FullCommitSha -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogCommit' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogCommit'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest lockSha256'
    Assert-UserSkillsManagedManifestFiles -Files (Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'user Skills managed manifest') -ProjectionRoot '.agents/skills' | Out-Null
}

function Assert-UserSkillsManagedManifestV3 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','catalogRepository','catalogCommit','catalogId','lockSha256','projectionContractSha256','generation','projections','files') -Context 'user Skills managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 3 -DocumentName 'user Skills managed manifest'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogRepository' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogRepository'
    Assert-FullCommitSha -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogCommit' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogCommit'
    Assert-StableId -Value (Get-RequiredProperty -Object $Manifest -Name 'catalogId' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest catalogId'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'lockSha256' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest lockSha256'
    Assert-Sha256 -Value (Get-RequiredProperty -Object $Manifest -Name 'projectionContractSha256' -Context 'user Skills managed manifest') -Context 'user Skills managed manifest projectionContractSha256'
    $generation = Get-RequiredProperty -Object $Manifest -Name 'generation' -Context 'user Skills managed manifest'
    if (($generation -isnot [int] -and $generation -isnot [long]) -or [int64]$generation -lt 1) { throw 'user Skills managed manifest generation must be an integer greater than or equal to 1.' }

    $projections = Get-RequiredProperty -Object $Manifest -Name 'projections' -Context 'user Skills managed manifest'
    Assert-StableIdArray -Value $projections -Context 'user Skills managed manifest projections'
    $projectionMap = Get-SkillsCatalogProjectionMap
    $projectionIds = @{}
    $projectionRoots = @{}
    foreach ($projectionId in @($projections)) {
        if (-not $projectionMap.ContainsKey([string]$projectionId) -or [string]$projectionMap[[string]$projectionId][0] -cne 'user') {
            throw "Unsupported USER managed manifest projection '$projectionId'."
        }
        $projectionIds[[string]$projectionId] = $true
        $projectionRoots[[string]$projectionId] = [string]$projectionMap[[string]$projectionId][1]
    }
    $validated = @(Assert-UserSkillsManagedManifestFiles -Files (Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'user Skills managed manifest') -ProjectionRoot '.agents/skills' -HasProjectionId -ProjectionIds $projectionIds -ProjectionRoots $projectionRoots)
    Assert-ProjectionSkillParity -Validated $validated -Projections $projections -Context 'User-managed Skill'
}

function Assert-UserSkillsManagedManifest {
    param([Parameter(Mandatory = $true)][object] $Manifest)
    $version = Get-RequiredProperty -Object $Manifest -Name 'schemaVersion' -Context 'user Skills managed manifest'
    if ($version -isnot [int] -and $version -isnot [long]) { throw 'user Skills managed manifest schemaVersion must be an integer.' }
    switch ([int64]$version) {
        1 { Assert-UserSkillsManagedManifestV1 -Manifest $Manifest; return }
        2 { Assert-UserSkillsManagedManifestV2 -Manifest $Manifest; return }
        3 { Assert-UserSkillsManagedManifestV3 -Manifest $Manifest; return }
        default { throw "Unsupported user Skills managed manifest schemaVersion '$version'; supported versions are 1, 2 and 3." }
    }
}

function Assert-UserSkillsManagedManifestBinding {
    # Binds ordinary Skill payload hashes, per-file provenance, and catalog/lock identity to the Lock.
    # License delivery entries are out of scope and require source-archive regeneration and comparison by a projection-aware installer.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $CatalogBytes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $LockBytes,
        [Parameter(Mandatory = $true)][string] $ExpectedCatalogRepository,
        [Parameter(Mandatory = $true)][string] $ExpectedCatalogCommit
    )

    $catalogSha256 = Get-BytesSha256 -Bytes $CatalogBytes
    $lockSha256 = Get-BytesSha256 -Bytes $LockBytes
    $catalog = ConvertFrom-StrictUtf8JsonBytes -Bytes $CatalogBytes -DocumentName 'Skills Catalog binding bytes'
    $lock = ConvertFrom-StrictUtf8JsonBytes -Bytes $LockBytes -DocumentName 'Skills Catalog lock binding bytes'

    Assert-UserSkillsManagedManifestV3 -Manifest $Manifest
    Assert-SkillsCatalog -Catalog $catalog
    Assert-SkillsCatalogLock -Lock $lock -Catalog $catalog
    Assert-HttpsRepositoryUrl -Value $ExpectedCatalogRepository -Context 'user Skills managed manifest binding expected catalog repository'
    Assert-FullCommitSha -Value $ExpectedCatalogCommit -Context 'user Skills managed manifest binding expected catalog commit'

    if ([string]$lock.catalogSha256 -cne $catalogSha256) {
        throw 'Skills Catalog lock catalogSha256 does not match the supplied Catalog bytes SHA-256.'
    }
    if ([string]$Manifest.lockSha256 -cne $lockSha256) {
        throw 'user Skills managed manifest lockSha256 does not match the supplied Lock bytes SHA-256.'
    }

    if ([string]$Manifest.catalogRepository -cne $ExpectedCatalogRepository) {
        throw 'user Skills managed manifest catalog repository does not match the trusted catalog repository.'
    }
    if ([string]$Manifest.catalogCommit -cne $ExpectedCatalogCommit) {
        throw 'user Skills managed manifest catalog commit does not match the trusted catalog commit.'
    }

    $expectedProjectionContractSha256 = Get-SkillsCatalogProjectionContractSha256 -Projections $Catalog.projections
    if ([string]$Manifest.projectionContractSha256 -cne $expectedProjectionContractSha256 -or [string]$Manifest.projectionContractSha256 -cne [string]$Lock.projectionContractSha256) {
        throw 'user Skills managed manifest projectionContractSha256 does not match the Catalog and Lock.'
    }
    if ([string]$Manifest.catalogId -cne [string]$Lock.catalogId -or [string]$Manifest.catalogId -cne [string]$Catalog.catalogId) {
        throw 'user Skills managed manifest catalogId does not match the Catalog and Lock.'
    }

    $catalogProjections = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($projection in @($Catalog.projections)) { $catalogProjections.Add([string]$projection.id,$projection) }
    foreach ($projectionId in @($Manifest.projections)) {
        if (-not $catalogProjections.ContainsKey([string]$projectionId) -or [string]$catalogProjections[[string]$projectionId].scope -cne 'user') {
            throw "user Skills managed manifest projection '$projectionId' is not a USER projection in the Catalog."
        }
    }

    $lockedSkills = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($lockedSkill in @($Lock.skills)) { $lockedSkills.Add([string]$lockedSkill.id,$lockedSkill) }
    $lockedSources = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($lockedSource in @($Lock.sources)) { $lockedSources.Add([string]$lockedSource.id,$lockedSource) }
    foreach ($file in @($Manifest.files)) {
        $skillId = [string]$file.skillId
        if (-not $lockedSkills.ContainsKey($skillId)) {
            throw "user Skills managed manifest Skill '$skillId' is not present in the Lock."
        }
        $lockedSkill = $lockedSkills[$skillId]
        if ([string]$file.sourceId -cne [string]$lockedSkill.sourceId) {
            throw "user Skills managed manifest Skill '$skillId' sourceId does not match the Lock."
        }
        if (-not $lockedSources.ContainsKey([string]$file.sourceId)) {
            throw "user Skills managed manifest Skill '$skillId' source '$($file.sourceId)' is not present in the Lock."
        }
        $lockedSource = $lockedSources[[string]$file.sourceId]
        if ([string]$file.sourceRepository -cne [string]$lockedSource.repository -or
            [string]$file.sourceRef -cne [string]$lockedSource.requestedRef -or
            [string]$file.sourceCommit -cne [string]$lockedSource.resolvedCommit -or
            [string]$file.sourceVersion -cne [string]$lockedSource.resolvedVersion) {
            throw "user Skills managed manifest Skill '$skillId' source provenance does not match the Lock."
        }
        $sourcePathPrefix = [string]$lockedSkill.sourcePath + '/'
        if (([string]$file.sourcePath).StartsWith("skills/$skillId/",[System.StringComparison]::Ordinal) -and -not ([string]$file.sourcePath).StartsWith($sourcePathPrefix,[System.StringComparison]::Ordinal)) {
            throw "user Skills managed manifest Skill '$skillId' sourcePath does not match the Lock."
        }
    }

    foreach ($skillId in @($lockedSkills.Keys)) {
        $skillFiles = @($Manifest.files | Where-Object { [string]$_.skillId -ceq $skillId })
        if ($skillFiles.Count -eq 0) { continue }
        [string[]]$projectionIds = @($skillFiles | ForEach-Object { [string]$_.projectionId } | Sort-Object -Unique)
        [System.Array]::Sort($projectionIds,[System.StringComparer]::Ordinal)
        $projectionFiles = @($skillFiles | Where-Object { [string]$_.projectionId -ceq $projectionIds[0] })
        $lockedSkill = $lockedSkills[$skillId]
        $projectionMap = Get-SkillsCatalogProjectionMap
        if (-not $projectionMap.ContainsKey($projectionIds[0])) {
            throw "user Skills managed manifest projection '$($projectionIds[0])' is not in the fixed projection map."
        }
        $projectionRoot = [string]$projectionMap[$projectionIds[0]][1]
        $targetPrefix = "$projectionRoot/$skillId/"
        $actualContentSha256 = Get-UserSkillsPayloadInventorySha256 -Files $projectionFiles -SourcePathPrefix (([string]$lockedSkill.sourcePath) + '/') -TargetPrefix $targetPrefix
        if ($actualContentSha256 -cne [string]$lockedSkill.contentSha256) {
            throw "user Skills managed manifest Skill '$skillId' content hash does not match the lock."
        }
    }
}

function Assert-SyncConfigurationV4 {
    param([object] $Configuration,[object] $Catalog)
    Assert-OnlyProperties -Object $Configuration -Allowed @('schemaVersion','excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates') -Context 'AI instruction sync configuration'
    Assert-SchemaVersion -Document $Configuration -Expected 4 -DocumentName 'AI instruction sync configuration'
    foreach ($propertyName in @('excludedRepositoryUrls','excludedRepositoryPaths')) { Assert-StringArray -Value (Get-RequiredProperty -Object $Configuration -Name $propertyName -Context 'AI instruction sync configuration') -Context "AI instruction sync configuration $propertyName" -AllowEmpty }
    $selection=Get-RequiredProperty -Object $Configuration -Name 'catalog' -Context 'AI instruction sync configuration'; Assert-OnlyProperties -Object $selection -Allowed @('repository','ref','profiles','includeSkills','excludeSkills') -Context 'AI instruction sync configuration catalog'; Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $selection -Name 'repository' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog repository'
    if ([string]$selection.repository -cne $script:CanonicalAiInstructionsRepository) { throw "AI instruction sync configuration catalog repository must be the canonical repository '$script:CanonicalAiInstructionsRepository'." }
    $catalogRef=Get-RequiredProperty -Object $selection -Name 'ref' -Context 'AI instruction sync configuration catalog'; Assert-NonEmptyString -Value $catalogRef -Context 'AI instruction sync configuration catalog ref'; if ([string]$catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw 'AI instruction sync configuration catalog ref must be a full lowercase commit SHA.' }
    Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'profiles' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog profiles' -AllowEmpty; Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'includeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog includeSkills' -AllowEmpty; Assert-StableIdArray -Value (Get-RequiredProperty -Object $selection -Name 'excludeSkills' -Context 'AI instruction sync configuration catalog') -Context 'AI instruction sync configuration catalog excludeSkills' -AllowEmpty
    $profileIds=@{}; foreach ($profile in @($Catalog.profiles)) { $profileIds[[string]$profile.id]=$true }; $skillIds=@{}; foreach ($skill in @($Catalog.skills)) { $skillIds[[string]$skill.id]=$true }
    foreach ($profileId in @($selection.profiles)) { if (-not $profileIds.ContainsKey([string]$profileId)) { throw "AI instruction sync configuration references unknown profile '$profileId'." } }
    foreach ($skillId in @($selection.includeSkills)+@($selection.excludeSkills)) { if (-not $skillIds.ContainsKey([string]$skillId)) { throw "AI instruction sync configuration references unknown Skill '$skillId'." } }
    foreach ($skillId in @($selection.includeSkills)) { if (@($selection.excludeSkills) -contains [string]$skillId) { throw "AI instruction sync configuration both includes and excludes Skill '$skillId'." } }

    $updates=Get-RequiredProperty -Object $Configuration -Name 'updates' -Context 'AI instruction sync configuration'; Assert-OnlyProperties -Object $updates -Allowed @('mode','channel','ref','minimumCheckIntervalMinutes') -Context 'AI instruction sync configuration updates'
    $mode=Get-RequiredProperty -Object $updates -Name 'mode' -Context 'AI instruction sync configuration updates'; Assert-NonEmptyString -Value $mode -Context 'AI instruction sync configuration updates mode'; if (@('notify-only','auto-install-approved') -cnotcontains [string]$mode) { throw "Unsupported AI instruction update mode '$mode'." }
    $channel=Get-RequiredProperty -Object $updates -Name 'channel' -Context 'AI instruction sync configuration updates'; Assert-NonEmptyString -Value $channel -Context 'AI instruction sync configuration updates channel'; if (@('protected-branch','github-release') -cnotcontains [string]$channel) { throw "Unsupported AI instruction update channel '$channel'." }
    $updateRef=Get-RequiredProperty -Object $updates -Name 'ref' -Context 'AI instruction sync configuration updates'; Assert-NonEmptyString -Value $updateRef -Context 'AI instruction sync configuration updates ref'
    if ([string]$channel -eq 'protected-branch' -and [string]$updateRef -cne 'main') { throw "Protected-branch updates must use the canonical 'main' ref." }
    if ([string]$channel -eq 'github-release' -and [string]$updateRef -cne 'latest') { throw "GitHub release updates must use the canonical 'latest' ref." }
    $minimumCheckIntervalMinutes=Get-RequiredProperty -Object $updates -Name 'minimumCheckIntervalMinutes' -Context 'AI instruction sync configuration updates'
    if ($minimumCheckIntervalMinutes -isnot [int] -and $minimumCheckIntervalMinutes -isnot [long]) { throw 'AI instruction sync configuration updates minimumCheckIntervalMinutes must be an integer.' }
    if ([long]$minimumCheckIntervalMinutes -lt 1) { throw 'AI instruction sync configuration updates minimumCheckIntervalMinutes must be at least 1.' }
    if ([long]$minimumCheckIntervalMinutes -gt [int]::MaxValue) { throw "AI instruction sync configuration updates minimumCheckIntervalMinutes must be at most $([int]::MaxValue)." }
}

function Assert-LegacyManagedManifestV1 {
    param([object] $Manifest)
    Assert-OnlyProperties -Object $Manifest -Allowed @('schemaVersion','sourceRepository','sourceRef','files') -Context 'legacy managed manifest'
    Assert-SchemaVersion -Document $Manifest -Expected 1 -DocumentName 'legacy managed manifest'
    Assert-HttpsRepositoryUrl -Value (Get-RequiredProperty -Object $Manifest -Name 'sourceRepository' -Context 'legacy managed manifest') -Context 'legacy managed manifest sourceRepository'
    Assert-NonEmptyString -Value (Get-RequiredProperty -Object $Manifest -Name 'sourceRef' -Context 'legacy managed manifest') -Context 'legacy managed manifest sourceRef'
    $files = Get-RequiredProperty -Object $Manifest -Name 'files' -Context 'legacy managed manifest'; Assert-Array -Value $files -Context 'legacy managed manifest files' -AllowEmpty
    $targetPaths = @{}
    foreach ($entry in @($files)) {
        Assert-OnlyProperties -Object $entry -Allowed @('sourcePath','targetPath','sha256') -Context 'legacy managed manifest file'
        $sourcePath = Get-RequiredProperty -Object $entry -Name 'sourcePath' -Context 'legacy managed manifest file'
        $targetPath = Get-RequiredProperty -Object $entry -Name 'targetPath' -Context 'legacy managed manifest file'
        if (-not (Test-IsSafeRepositoryPath -Value $sourcePath)) { throw "Unsafe source path in legacy managed manifest: $sourcePath" }
        if (-not (Test-IsSafeRepositoryPath -Value $targetPath)) { throw "Unsafe target path in legacy managed manifest: $targetPath" }
        if ($targetPaths.ContainsKey([string]$targetPath)) { throw "Duplicate target path in legacy managed manifest: $targetPath" }
        $targetPaths[[string]$targetPath] = $true
        Assert-Sha256 -Value (Get-RequiredProperty -Object $entry -Name 'sha256' -Context 'legacy managed manifest file') -Context "legacy managed manifest file '$targetPath' sha256"
    }
}

function Test-SkillsCatalogContract {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$CatalogPath,[Parameter(Mandatory=$true)][string]$LockPath,[Parameter(Mandatory=$true)][string]$ManifestPath,[Parameter(Mandatory=$true)][string]$ConfigurationPath)
    $catalog=Test-SkillsCatalogDocument -CatalogPath $CatalogPath
    $lock=Import-SkillsCatalogJson -Path $LockPath -DocumentName 'Skills Catalog lock'; Assert-SkillsCatalogLock -Lock $lock -Catalog $catalog; $catalogFileSha256=Get-RawFileSha256 -Path $CatalogPath; if ([string]$lock.catalogSha256 -cne $catalogFileSha256) { throw "Skills Catalog lock catalogSha256 does not match the Catalog file: expected $catalogFileSha256." }
    $manifest=Import-SkillsCatalogJson -Path $ManifestPath -DocumentName 'managed manifest'; Assert-ManagedManifest -Manifest $manifest; if ([string]$manifest.catalogId -cne [string]$catalog.catalogId) { throw 'managed manifest catalogId does not match the Skills Catalog.' }; $lockFileSha256=Get-RawFileSha256 -Path $LockPath; if ([string]$manifest.lockSha256 -cne $lockFileSha256) { throw "managed manifest lockSha256 does not match the Catalog lock file: expected $lockFileSha256." }
    $configuration=Import-SkillsCatalogJson -Path $ConfigurationPath -DocumentName 'AI instruction sync configuration'; Assert-SyncConfigurationV4 -Configuration $configuration -Catalog $catalog
    return [pscustomobject]@{CatalogId=[string]$catalog.catalogId;SourceCount=@($catalog.sources).Count;SkillCount=@($catalog.skills).Count;ProfileCount=@($catalog.profiles).Count;ManifestFileCount=@($manifest.files).Count}
}

Export-ModuleMember -Function Assert-LegacyManagedManifestV1, Assert-ManagedManifest, Assert-ManagedManifestV2, Assert-ManagedManifestV3, Assert-ManagedManifestV4, Assert-SkillsCatalogV2, Assert-SkillsCatalogV3, Assert-SkillsCatalogLockV2, Assert-SkillsCatalogLockV3, Assert-UserSkillsManagedManifest, Assert-UserSkillsManagedManifestBinding, Assert-UserSkillsManagedManifestV1, Assert-UserSkillsManagedManifestV2, Assert-UserSkillsManagedManifestV3, ConvertFrom-GitWorktreePorcelainZ, Get-SkillsCatalogProjectionContractSha256, Get-SkillsCatalogProjectionTargetPath, Get-SkillsCatalogUserProjectionRoots, Import-SkillsCatalogJson, Test-SkillsCatalogContract, Test-SkillsCatalogDocument, Test-SkillsCatalogSourcePinsDocument, Test-SkillsCatalogLockDocument
