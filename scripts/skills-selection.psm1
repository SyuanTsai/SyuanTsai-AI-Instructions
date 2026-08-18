Set-StrictMode -Version 2.0

function Resolve-SkillsSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Selection
    )

    $profilesById = @{}
    foreach ($profile in @($Catalog.profiles)) {
        $profilesById[[string]$profile.id] = $profile
    }

    $skillsById = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillsById[[string]$skill.id] = $skill
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
    $profileExcludes = @{}

    foreach ($profileIdValue in $requestedProfiles) {
        $profileId = [string]$profileIdValue
        if (-not $profilesById.ContainsKey($profileId)) {
            throw "Unknown Skills Catalog profile '$profileId'."
        }

        $profile = $profilesById[$profileId]
        foreach ($skillIdValue in @($profile.includes)) {
            $skillId = [string]$skillIdValue
            if (-not $skillsById.ContainsKey($skillId)) {
                throw "Skills Catalog profile '$profileId' references unknown Skill '$skillId'."
            }
            $selected[$skillId] = $true
        }
        foreach ($skillIdValue in @($profile.excludes)) {
            $profileExcludes[[string]$skillIdValue] = $true
        }
    }

    foreach ($skillIdValue in @($Selection.includeSkills)) {
        $skillId = [string]$skillIdValue
        if (-not $skillsById.ContainsKey($skillId)) {
            throw "Explicitly included Skill '$skillId' does not exist in the Skills Catalog."
        }
        $selected[$skillId] = $true
    }

    foreach ($skillId in @($profileExcludes.Keys)) {
        $selected.Remove($skillId)
    }

    foreach ($skillIdValue in @($Selection.excludeSkills)) {
        $skillId = [string]$skillIdValue
        if (-not $skillsById.ContainsKey($skillId)) {
            throw "Explicitly excluded Skill '$skillId' does not exist in the Skills Catalog."
        }
        $selected.Remove($skillId)
    }

    foreach ($skillId in @($selected.Keys)) {
        $skill = $skillsById[$skillId]
        if ([string]$skill.lifecycle.status -eq 'removed') {
            throw "Selected Skill '$skillId' is removed."
        }
    }

    return @($selected.Keys | Sort-Object)
}

Export-ModuleMember -Function Resolve-SkillsSelection
