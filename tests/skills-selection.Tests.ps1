$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-selection.psm1') -Force

function Assert-ThrowsMessage {
    param([scriptblock] $Action, [string] $Pattern)
    $thrown = $false
    $message = $null
    try { & $Action } catch { $thrown = $true; $message = $_.Exception.Message }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

function New-SelectionCatalog {
    return [pscustomobject]@{
        profiles = @(
            [pscustomobject]@{ id='core'; default=$true; includes=@('skill-a'); excludes=@() },
            [pscustomobject]@{ id='team'; default=$false; includes=@('skill-b','skill-c'); excludes=@('skill-c') }
        )
        skills = @(
            [pscustomobject]@{ id='skill-a'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-b'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-c'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-old'; lifecycle=[pscustomobject]@{ status='removed' } }
        )
    }
}

Describe 'Skills selection resolver' {
    # Scenario: Personal selection contains no explicit profile IDs and the Catalog declares a default profile.
    # Purpose: Preserve the default-profile fallback for first-run and minimally configured installations.
    It 'UnitT10_uses_default_profiles_when_no_profile_is_explicitly_selected' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@(); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    # Scenario: Profile and personal include layers select Skills that are then removed by a personal exclusion.
    # Purpose: Guarantee that explicit personal exclusions have final precedence.
    It 'UnitT20_unions_profile_and_personal_includes_then_applies_personal_excludes' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-a'); excludeSkills=@('skill-b') }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    # Scenario: A selected profile includes and excludes one of the same Skills.
    # Purpose: Resolve profile-local exclusions before applying personal overrides.
    It 'UnitT30_applies_profile_excludes_inside_the_profile_layer' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-b')
    }

    # Scenario: A personal include explicitly selects a Skill excluded by the chosen profile.
    # Purpose: Allow personal configuration to opt back into a profile-excluded Skill.
    It 'UnitT40_allows_personal_includes_to_restore_a_profile_excluded_skill' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-c'); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-b','skill-c')
    }

    # Scenario: Personal configuration references a profile that is absent from the Catalog.
    # Purpose: Fail closed instead of silently changing the selected Skill set.
    It 'UnitT50_rejects_an_unknown_profile' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('missing'); includeSkills=@(); excludeSkills=@() }
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'Unknown Skills Catalog profile'
    }

    # Scenario: Personal configuration explicitly includes an unknown or removed Skill.
    # Purpose: Reject stale selections instead of installing an unintended or retired Skill.
    It 'UnitT60_rejects_unknown_and_removed_explicit_skills' {
        $catalog = New-SelectionCatalog
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('missing'); excludeSkills=@() }) } 'does not exist'
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('skill-old'); excludeSkills=@() }) } 'is removed'
    }
}
