Set-StrictMode -Version 2.0

$script:ShellAvailabilityCache = @{}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [AllowNull()][object] $DefaultValue = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-CurrentPlatformId {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return 'windows'
    }

    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            return 'macos'
        }
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            return 'linux'
        }
    }
    catch {
    }

    return 'unix'
}

function Assert-CapabilityEvidenceItems {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in $evidence) {
        $kind = [string](Get-OptionalPropertyValue -Object $item -Name 'kind' -DefaultValue '')
        $id = [string](Get-OptionalPropertyValue -Object $item -Name 'id' -DefaultValue '')
        $state = [string](Get-OptionalPropertyValue -Object $item -Name 'state' -DefaultValue '')
        if (@('command','connector','environment') -cnotcontains $kind -or
            $id -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
            @('absent','available','authenticated','configured') -cnotcontains $state) {
            throw "$Context contains invalid capability evidence: kind='$kind' id='$id' state='$state'."
        }
        foreach ($propertyName in @($item.PSObject.Properties.Name)) {
            if ($propertyName -cnotin @('kind','id','state')) {
                throw "$Context contains unsupported capability evidence property '$propertyName'."
            }
        }
        if (-not $seen.Add("$kind`n$id")) {
            throw "$Context contains duplicate capability evidence for '$kind`:$id'."
        }
    }

    return $Evidence
}

function Get-ExplicitCapabilityEvidence {
    param([AllowEmptyCollection()][object[]] $ConfiguredEvidence = @())

    $configured = @(Assert-CapabilityEvidenceItems -Evidence @($ConfiguredEvidence) -Context 'Stored capability evidence')
    $raw = [string]$env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE
    $environmentEvidence = @()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed.StartsWith('[')) {
            try { [void]($raw | ConvertFrom-Json -ErrorAction Stop) }
            catch { throw "AI_INSTRUCTIONS_CAPABILITY_EVIDENCE is not valid JSON: $($_.Exception.Message)" }
            throw 'AI_INSTRUCTIONS_CAPABILITY_EVIDENCE must be a JSON array.'
        }
        try {
            $converted = $raw | ConvertFrom-Json -ErrorAction Stop
            $parsed = @($converted)
        }
        catch {
            throw "AI_INSTRUCTIONS_CAPABILITY_EVIDENCE is not valid JSON: $($_.Exception.Message)"
        }
        $environmentEvidence = @(Assert-CapabilityEvidenceItems -Evidence @($parsed) -Context 'AI_INSTRUCTIONS_CAPABILITY_EVIDENCE')
    }

    $effective = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($configured + $environmentEvidence)) {
        $effective["$([string]$item.kind)`n$([string]$item.id)"] = $item
    }

    return @($effective.Values | Sort-Object @{Expression={[string]$_.kind}},@{Expression={[string]$_.id}})
}

function Test-ExplicitCapabilityEvidence {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $State
    )

    foreach ($item in $Evidence) {
        if ([string]$item.kind -cne $Kind -or [string]$item.id -cne $Id) {
            continue
        }

        $actualState = [string]$item.state
        if ($State -eq 'available') {
            return $actualState -in @('available','authenticated','configured')
        }
        if ($actualState -ceq $State) {
            return $true
        }
    }
    return $false
}

function Test-ShellExpression {
    param([Parameter(Mandatory = $true)][string] $Expression)

    if ($script:ShellAvailabilityCache.ContainsKey($Expression)) {
        return [bool]$script:ShellAvailabilityCache[$Expression]
    }

    $available = $false
    if ($Expression -match '^pwsh>=(\d+)$') {
        $minimumMajor = [int]$Matches[1]
        if ([string]$PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge $minimumMajor) {
            $available = $true
        }
        else {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $pwsh) {
                try {
                    $majorText = (& $pwsh.Source -NoProfile -NonInteractive -Command '[Console]::Write($PSVersionTable.PSVersion.Major)' 2>$null | Select-Object -First 1)
                    $major = 0
                    if ([int]::TryParse(([string]$majorText).Trim(), [ref]$major)) {
                        $available = $major -ge $minimumMajor
                    }
                }
                catch {
                    $available = $false
                }
            }
        }
    }
    else {
        throw "Unsupported Skills Catalog shell compatibility expression '$Expression'."
    }

    $script:ShellAvailabilityCache[$Expression] = $available
    return $available
}

function Test-CapabilityRequirement {
    param(
        [Parameter(Mandatory = $true)][object] $Requirement,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence
    )

    $kind = [string](Get-OptionalPropertyValue -Object $Requirement -Name 'kind' -DefaultValue '')
    $id = [string](Get-OptionalPropertyValue -Object $Requirement -Name 'id' -DefaultValue '')
    $state = [string](Get-OptionalPropertyValue -Object $Requirement -Name 'state' -DefaultValue '')
    if (@('command','connector','environment') -cnotcontains $kind -or
        $id -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        @('available','authenticated','configured') -cnotcontains $state) {
        throw "Invalid Skills Catalog capability requirement: kind='$kind' id='$id' state='$state'."
    }

    if (Test-ExplicitCapabilityEvidence -Evidence $Evidence -Kind $kind -Id $id -State $state) {
        return $true
    }

    if ($kind -eq 'command' -and $state -eq 'available') {
        return $null -ne (Get-Command $id -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    return $false
}

function Test-CapabilityIdAvailable {
    param(
        [Parameter(Mandatory = $true)][string] $CapabilityId,
        [Parameter(Mandatory = $true)][object] $Skill,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence
    )

    if ($CapabilityId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "Invalid dependency capability ID '$CapabilityId'."
    }

    $compatibility = Get-OptionalPropertyValue -Object $Skill -Name 'compatibility'
    $requirements = @()
    if ($null -ne $compatibility) {
        $requirements += @(Get-OptionalPropertyValue -Object $compatibility -Name 'requiredCapabilities' -DefaultValue @())
        foreach ($alternativeSet in @(Get-OptionalPropertyValue -Object $compatibility -Name 'anyOfCapabilities' -DefaultValue @())) {
            $requirements += @($alternativeSet)
        }
    }

    $matches = @($requirements | Where-Object {
        [string](Get-OptionalPropertyValue -Object $_ -Name 'id' -DefaultValue '') -ceq $CapabilityId
    })
    if ($matches.Count -ne 1) {
        throw "Conditional capability '$CapabilityId' for Skill '$([string]$Skill.id)' must declare exactly one compatibility requirement with its required kind and state."
    }

    return [bool](Test-CapabilityRequirement -Requirement $matches[0] -Evidence $Evidence)
}

function Test-SkillCompatibility {
    param(
        [Parameter(Mandatory = $true)][object] $Skill,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence
    )

    $compatibility = Get-OptionalPropertyValue -Object $Skill -Name 'compatibility'
    if ($null -eq $compatibility) {
        return $true
    }

    $platforms = @(Get-OptionalPropertyValue -Object $compatibility -Name 'platforms' -DefaultValue @('any'))
    $currentPlatform = Get-CurrentPlatformId
    if ($platforms.Count -gt 0 -and
        -not ($platforms -contains 'any') -and
        -not ($platforms -contains $currentPlatform)) {
        return $false
    }

    foreach ($shellExpression in @(Get-OptionalPropertyValue -Object $compatibility -Name 'shells' -DefaultValue @())) {
        if (-not (Test-ShellExpression -Expression ([string]$shellExpression))) {
            return $false
        }
    }

    foreach ($requirement in @(Get-OptionalPropertyValue -Object $compatibility -Name 'requiredCapabilities' -DefaultValue @())) {
        if (-not (Test-CapabilityRequirement -Requirement $requirement -Evidence $Evidence)) {
            return $false
        }
    }

    foreach ($alternativeSet in @(Get-OptionalPropertyValue -Object $compatibility -Name 'anyOfCapabilities' -DefaultValue @())) {
        $satisfied = $false
        foreach ($requirement in @($alternativeSet)) {
            if (Test-CapabilityRequirement -Requirement $requirement -Evidence $Evidence) {
                $satisfied = $true
                break
            }
        }
        if (-not $satisfied) {
            return $false
        }
    }

    return $true
}

function Get-SkillUnknownCapabilityState {
    param(
        [Parameter(Mandatory = $true)][object] $Skill,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence
    )

    $compatibility = Get-OptionalPropertyValue -Object $Skill -Name 'compatibility'
    if ($null -eq $compatibility) { return [pscustomobject]@{Preserve=$false;Missing=@()} }
    $nonCapabilityCompatibility = [pscustomobject]@{
        platforms = @(Get-OptionalPropertyValue -Object $compatibility -Name 'platforms' -DefaultValue @('any'))
        shells = @(Get-OptionalPropertyValue -Object $compatibility -Name 'shells' -DefaultValue @())
        requiredCapabilities = @()
        anyOfCapabilities = @()
    }
    if (-not (Test-SkillCompatibility -Skill ([pscustomobject]@{compatibility=$nonCapabilityCompatibility}) -Evidence $Evidence)) {
        return [pscustomobject]@{Preserve=$false;Missing=@()}
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($requirement in @(Get-OptionalPropertyValue -Object $compatibility -Name 'requiredCapabilities' -DefaultValue @())) {
        if (Test-CapabilityRequirement -Requirement $requirement -Evidence $Evidence) { continue }
        $kind = [string](Get-OptionalPropertyValue -Object $requirement -Name 'kind' -DefaultValue '')
        $id = [string](Get-OptionalPropertyValue -Object $requirement -Name 'id' -DefaultValue '')
        if ($kind -notin @('connector','environment') -or (Test-ExplicitCapabilityEvidence -Evidence $Evidence -Kind $kind -Id $id -State 'absent')) {
            return [pscustomobject]@{Preserve=$false;Missing=@()}
        }
        $missing.Add("$kind`:$id")
    }
    foreach ($alternativeSet in @(Get-OptionalPropertyValue -Object $compatibility -Name 'anyOfCapabilities' -DefaultValue @())) {
        $satisfied = $false
        $unknownAlternatives = New-Object System.Collections.Generic.List[string]
        foreach ($requirement in @($alternativeSet)) {
            if (Test-CapabilityRequirement -Requirement $requirement -Evidence $Evidence) { $satisfied=$true;break }
            $kind = [string](Get-OptionalPropertyValue -Object $requirement -Name 'kind' -DefaultValue '')
            $id = [string](Get-OptionalPropertyValue -Object $requirement -Name 'id' -DefaultValue '')
            if ($kind -in @('connector','environment') -and -not (Test-ExplicitCapabilityEvidence -Evidence $Evidence -Kind $kind -Id $id -State 'absent')) {
                $unknownAlternatives.Add("$kind`:$id")
            }
        }
        if ($satisfied) { continue }
        if ($unknownAlternatives.Count -eq 0) { return [pscustomobject]@{Preserve=$false;Missing=@()} }
        foreach ($value in $unknownAlternatives) { $missing.Add($value) }
    }
    $missingValues = @($missing.ToArray() | Sort-Object -Unique)
    return [pscustomobject]@{Preserve=($missingValues.Count -gt 0);Missing=$missingValues}
}

function Get-ConditionalDependencyState {
    param(
        [Parameter(Mandatory = $true)][object] $Dependency,
        [Parameter(Mandatory = $true)][object] $Skill,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $DependencyId
    )

    $condition = Get-OptionalPropertyValue -Object $Dependency -Name 'condition'
    $fallback = Get-OptionalPropertyValue -Object $Dependency -Name 'fallback'
    if ($null -eq $condition -or $null -eq $fallback) {
        throw "Conditional dependency '$SkillId' -> '$DependencyId' is missing condition or fallback metadata."
    }

    $operator = [string](Get-OptionalPropertyValue -Object $condition -Name 'operator' -DefaultValue '')
    $conditionCapability = [string](Get-OptionalPropertyValue -Object $condition -Name 'capability' -DefaultValue '')
    $fallbackCapability = [string](Get-OptionalPropertyValue -Object $fallback -Name 'capability' -DefaultValue '')
    $conditionAvailable = Test-CapabilityIdAvailable -CapabilityId $conditionCapability -Skill $Skill -Evidence $Evidence
    $fallbackAvailable = Test-CapabilityIdAvailable -CapabilityId $fallbackCapability -Skill $Skill -Evidence $Evidence

    switch ($operator) {
        'available' { $required = $conditionAvailable -and -not $fallbackAvailable }
        'missing' { $required = -not $conditionAvailable -and -not $fallbackAvailable }
        'unavailable' { $required = -not $conditionAvailable -and -not $fallbackAvailable }
        'missing-or-invalid' {
            # Invalid evidence is rejected when loaded, so an invalid capability is treated
            # as unavailable evidence at this layer.
            $required = -not $conditionAvailable -and -not $fallbackAvailable
        }
        default { throw "Unsupported conditional dependency operator '$operator' for '$SkillId'." }
    }

    return [pscustomobject]@{
        Required = [bool]$required
        ConditionCapability = $conditionCapability
        FallbackCapability = $fallbackCapability
    }
}

function Test-SkillCompatibilityRepairableByConditionalDependency {
    param(
        [Parameter(Mandatory = $true)][object] $Skill,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Evidence,
        [Parameter(Mandatory = $true)][hashtable] $SkillsById
    )

    $compatibility = Get-OptionalPropertyValue -Object $Skill -Name 'compatibility'
    if ($null -eq $compatibility) { return $false }

    # Platform, shell, and mandatory capability failures cannot be repaired by installing
    # an API-configuration dependency. Only an unsatisfied alternative capability set can.
    $baseCompatibility = [pscustomobject]@{
        platforms = @(Get-OptionalPropertyValue -Object $compatibility -Name 'platforms' -DefaultValue @('any'))
        shells = @(Get-OptionalPropertyValue -Object $compatibility -Name 'shells' -DefaultValue @())
        requiredCapabilities = @(Get-OptionalPropertyValue -Object $compatibility -Name 'requiredCapabilities' -DefaultValue @())
        anyOfCapabilities = @()
    }
    if (-not (Test-SkillCompatibility -Skill ([pscustomobject]@{ compatibility = $baseCompatibility }) -Evidence $Evidence)) {
        return $false
    }

    $hasRepairableGap = $false
    foreach ($alternativeSet in @(Get-OptionalPropertyValue -Object $compatibility -Name 'anyOfCapabilities' -DefaultValue @())) {
        $setSatisfied = $false
        foreach ($requirement in @($alternativeSet)) {
            if (Test-CapabilityRequirement -Requirement $requirement -Evidence $Evidence) {
                $setSatisfied = $true
                break
            }
        }
        if ($setSatisfied) { continue }

        $alternativeIds = @($alternativeSet | ForEach-Object {
            [string](Get-OptionalPropertyValue -Object $_ -Name 'id' -DefaultValue '')
        })
        $setRepairable = $false
        foreach ($dependency in @(Get-OptionalPropertyValue -Object $Skill -Name 'dependencies' -DefaultValue @())) {
            $dependencyId = [string](Get-OptionalPropertyValue -Object $dependency -Name 'skillId' -DefaultValue '')
            if ([string](Get-OptionalPropertyValue -Object $dependency -Name 'type' -DefaultValue '') -cne 'conditional' -or
                -not $SkillsById.ContainsKey($dependencyId)) {
                continue
            }

            $condition = Get-OptionalPropertyValue -Object $dependency -Name 'condition'
            $fallback = Get-OptionalPropertyValue -Object $dependency -Name 'fallback'
            $conditionCapability = [string](Get-OptionalPropertyValue -Object $condition -Name 'capability' -DefaultValue '')
            $fallbackCapability = [string](Get-OptionalPropertyValue -Object $fallback -Name 'capability' -DefaultValue '')
            if ($alternativeIds -cnotcontains $conditionCapability -or
                $alternativeIds -cnotcontains $fallbackCapability) {
                continue
            }

            $state = Get-ConditionalDependencyState -Dependency $dependency -Skill $Skill -Evidence $Evidence -SkillId ([string]$Skill.id) -DependencyId $dependencyId
            if (-not $state.Required) { continue }

            $dependencySkill = $SkillsById[$dependencyId]
            if ([string]$dependencySkill.lifecycle.status -eq 'removed' -or
                -not (Test-SkillCompatibility -Skill $dependencySkill -Evidence $Evidence)) {
                continue
            }
            $setRepairable = $true
            break
        }
        if (-not $setRepairable) { return $false }
        $hasRepairableGap = $true
    }

    return $hasRepairableGap
}

function Resolve-ConfiguredSkillId {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][hashtable] $SkillsById,
        [Parameter(Mandatory = $true)][hashtable] $AliasesById
    )

    if ($SkillsById.ContainsKey($SkillId)) {
        $skill = $SkillsById[$SkillId]
        if ([string]$skill.lifecycle.status -eq 'removed') {
            $replacement = [string](Get-OptionalPropertyValue -Object $skill.lifecycle -Name 'replacementId' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($replacement)) {
                return $replacement
            }
        }
        return $SkillId
    }

    if ($AliasesById.ContainsKey($SkillId)) {
        return [string]$AliasesById[$SkillId]
    }

    return $null
}

function Resolve-SkillsSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Selection,
        [AllowEmptyCollection()][object[]] $CapabilityEvidence = @(),
        [AllowEmptyCollection()][string[]] $InstalledSkillIds = @()
    )

    $profilesById = @{}
    foreach ($profile in @($Catalog.profiles)) {
        $profilesById[[string]$profile.id] = $profile
    }

    $skillsById = @{}
    $aliasesById = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillId = [string]$skill.id
        $skillsById[$skillId] = $skill
        if ([string]$skill.lifecycle.status -ne 'removed') {
            foreach ($aliasValue in @($skill.lifecycle.aliases)) {
                $alias = [string]$aliasValue
                if ($aliasesById.ContainsKey($alias) -and [string]$aliasesById[$alias] -cne $skillId) {
                    throw "Ambiguous Skills Catalog alias '$alias'."
                }
                $aliasesById[$alias] = $skillId
            }
        }
    }

    $evidence = @(Get-ExplicitCapabilityEvidence -ConfiguredEvidence $CapabilityEvidence)
    $installed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($installedSkillId in $InstalledSkillIds) {
        $normalizedInstalledId = Resolve-ConfiguredSkillId -SkillId ([string]$installedSkillId) -SkillsById $skillsById -AliasesById $aliasesById
        if ([string]::IsNullOrWhiteSpace($normalizedInstalledId) -or -not $skillsById.ContainsKey($normalizedInstalledId)) {
            continue
        }
        if ([string]$skillsById[$normalizedInstalledId].lifecycle.status -eq 'removed') {
            continue
        }
        [void]$installed.Add($normalizedInstalledId)
    }
    $requestedProfiles = @($Selection.profiles)
    if ($requestedProfiles.Count -eq 0) {
        $requestedProfiles = @(
            @($Catalog.profiles) |
                Where-Object { $_.default -eq $true } |
                Select-Object -ExpandProperty id
        )
    }

    $selected = @{}
    $profileSelected = @{}
    $profileExcludes = @{}
    $explicitIncludes = @{}
    $explicitExcludes = @{}

    foreach ($profileIdValue in $requestedProfiles) {
        $profileId = [string]$profileIdValue
        if (-not $profilesById.ContainsKey($profileId)) {
            throw "Unknown Skills Catalog profile '$profileId'."
        }

        $profile = $profilesById[$profileId]
        foreach ($skillIdValue in @($profile.includes)) {
            $configuredId = [string]$skillIdValue
            $skillId = Resolve-ConfiguredSkillId -SkillId $configuredId -SkillsById $skillsById -AliasesById $aliasesById
            if ([string]::IsNullOrWhiteSpace($skillId)) {
                throw "Skills Catalog profile '$profileId' references unknown Skill '$configuredId'."
            }
            $selected[$skillId] = $true
            $profileSelected[$skillId] = $true
        }
        foreach ($skillIdValue in @($profile.excludes)) {
            $configuredId = [string]$skillIdValue
            $skillId = Resolve-ConfiguredSkillId -SkillId $configuredId -SkillsById $skillsById -AliasesById $aliasesById
            if ([string]::IsNullOrWhiteSpace($skillId)) {
                throw "Skills Catalog profile '$profileId' excludes unknown Skill '$configuredId'."
            }
            $profileExcludes[$skillId] = $true
        }
    }

    foreach ($skillId in @($profileExcludes.Keys)) {
        $selected.Remove($skillId)
        $profileSelected.Remove($skillId)
    }

    foreach ($skillIdValue in @($Selection.includeSkills)) {
        $configuredId = [string]$skillIdValue
        $skillId = Resolve-ConfiguredSkillId -SkillId $configuredId -SkillsById $skillsById -AliasesById $aliasesById
        if ([string]::IsNullOrWhiteSpace($skillId)) {
            throw "Explicitly included Skill '$configuredId' does not exist in the Skills Catalog."
        }
        if (-not $profileSelected.ContainsKey($skillId)) {
            $explicitIncludes[$skillId] = $true
        }
        $selected[$skillId] = $true
    }

    foreach ($skillIdValue in @($Selection.excludeSkills)) {
        $configuredId = [string]$skillIdValue
        $skillId = Resolve-ConfiguredSkillId -SkillId $configuredId -SkillsById $skillsById -AliasesById $aliasesById
        if ([string]::IsNullOrWhiteSpace($skillId)) {
            throw "Explicitly excluded Skill '$configuredId' does not exist in the Skills Catalog."
        }
        $explicitExcludes[$skillId] = $true
        $selected.Remove($skillId)
    }

    foreach ($skillId in @($selected.Keys)) {
        $skill = $skillsById[$skillId]
        if ([string]$skill.lifecycle.status -eq 'removed') {
            throw "Selected Skill '$skillId' is removed."
        }
        if (-not (Test-SkillCompatibility -Skill $skill -Evidence $evidence) -and
            -not (Test-SkillCompatibilityRepairableByConditionalDependency -Skill $skill -Evidence $evidence -SkillsById $skillsById)) {
            $unknownState = Get-SkillUnknownCapabilityState -Skill $skill -Evidence $evidence
            if ($installed.Contains($skillId) -and [bool]$unknownState.Preserve) {
                $missingText = @($unknownState.Missing) -join ', '
                Write-Warning "Preserved installed Skill '$skillId' because these capability requirements are not satisfied but are not explicitly absent: $missingText. Declare or modify evidence with -CapabilityEvidence; declare state 'absent' to remove it."
                continue
            }
            if ($explicitIncludes.ContainsKey($skillId)) {
                throw "Explicitly included Skill '$skillId' is incompatible with the current platform, shell, or capability evidence."
            }
            $selected.Remove($skillId)
            Write-Verbose "Filtered incompatible profile-selected Skill '$skillId'."
        }
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($skillId in @($selected.Keys | Sort-Object)) {
            $skill = $skillsById[$skillId]
            foreach ($dependency in @(Get-OptionalPropertyValue -Object $skill -Name 'dependencies' -DefaultValue @())) {
                $dependencyId = [string](Get-OptionalPropertyValue -Object $dependency -Name 'skillId' -DefaultValue '')
                $dependencyType = [string](Get-OptionalPropertyValue -Object $dependency -Name 'type' -DefaultValue '')
                if (-not $skillsById.ContainsKey($dependencyId)) {
                    throw "Selected Skill '$skillId' references unknown dependency '$dependencyId'."
                }

                $required = $false
                switch ($dependencyType) {
                    'hard' {
                        $required = $true
                    }
                    'conditional' {
                        $required = (Get-ConditionalDependencyState -Dependency $dependency -Skill $skill -Evidence $evidence -SkillId $skillId -DependencyId $dependencyId).Required
                    }
                    'recommended' {
                        continue
                    }
                    default {
                        throw "Unsupported dependency type '$dependencyType' for selected Skill '$skillId'."
                    }
                }

                if (-not $required -or $selected.ContainsKey($dependencyId)) {
                    continue
                }
                if ($explicitExcludes.ContainsKey($dependencyId) -or
                    ($profileExcludes.ContainsKey($dependencyId) -and -not $explicitIncludes.ContainsKey($dependencyId))) {
                    throw "Required dependency '$dependencyId' for selected Skill '$skillId' is excluded."
                }

                $dependencySkill = $skillsById[$dependencyId]
                if ([string]$dependencySkill.lifecycle.status -eq 'removed') {
                    throw "Required dependency '$dependencyId' for selected Skill '$skillId' is removed."
                }
                if (-not (Test-SkillCompatibility -Skill $dependencySkill -Evidence $evidence)) {
                    $dependencyUnknownState = Get-SkillUnknownCapabilityState -Skill $dependencySkill -Evidence $evidence
                    if ($installed.Contains($dependencyId) -and [bool]$dependencyUnknownState.Preserve) {
                        $missingText = @($dependencyUnknownState.Missing) -join ', '
                        Write-Warning "Preserved installed Skill '$dependencyId' because these capability requirements are not satisfied but are not explicitly absent: $missingText. Declare or modify evidence with -CapabilityEvidence; declare state 'absent' to remove it."
                        $selected[$dependencyId] = $true
                        $changed = $true
                        continue
                    }
                    throw "Required dependency '$dependencyId' for selected Skill '$skillId' is incompatible with the current platform, shell, or capability evidence."
                }

                $selected[$dependencyId] = $true
                $changed = $true
            }
        }
    }

    return @($selected.Keys | Sort-Object)
}

Export-ModuleMember -Function Resolve-SkillsSelection, Test-SkillCompatibility
