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

function New-TestCompatibility {
    param(
        [string[]]$Platforms = @('any'),
        [string[]]$Shells = @(),
        [object[]]$RequiredCapabilities = @(),
        [object[]]$AnyOfCapabilities = @()
    )
    return [pscustomobject]@{
        platforms = $Platforms
        shells = $Shells
        requiredCapabilities = $RequiredCapabilities
        anyOfCapabilities = $AnyOfCapabilities
    }
}

function New-TestSkill {
    param(
        [string]$Id,
        [object]$Compatibility = $null,
        [object[]]$Dependencies = @(),
        [string]$Status = 'active',
        [string[]]$Aliases = @(),
        [string]$ReplacementId
    )
    if ($null -eq $Compatibility) { $Compatibility = New-TestCompatibility }
    $lifecycle = [pscustomobject][ordered]@{ status=$Status; aliases=@($Aliases) }
    if (-not [string]::IsNullOrWhiteSpace($ReplacementId)) {
        $lifecycle | Add-Member -NotePropertyName replacementId -NotePropertyValue $ReplacementId
    }
    return [pscustomobject]@{
        id = $Id
        compatibility = $Compatibility
        dependencies = $Dependencies
        lifecycle = $lifecycle
    }
}

function New-SelectionCatalog {
    return [pscustomobject]@{
        profiles = @(
            [pscustomobject]@{ id='core'; default=$true; includes=@('skill-a'); excludes=@() },
            [pscustomobject]@{ id='team'; default=$false; includes=@('skill-b','skill-c'); excludes=@('skill-c') },
            [pscustomobject]@{ id='optional'; default=$false; includes=@('skill-optional'); excludes=@() }
        )
        skills = @(
            (New-TestSkill -Id 'skill-a'),
            (New-TestSkill -Id 'skill-b'),
            (New-TestSkill -Id 'skill-c'),
            (New-TestSkill -Id 'skill-optional'),
            (New-TestSkill -Id 'skill-old' -Status 'removed')
        )
    }
}

Describe 'Skills selection resolver' {
    BeforeEach {
        Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
    }

    It 'UnitT10_uses_default_profiles_when_no_profile_is_explicitly_selected' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@(); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    It 'UnitT20_unions_profile_and_personal_includes_then_applies_personal_excludes' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-a'); excludeSkills=@('skill-b') }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    It 'UnitT30_applies_profile_excludes_inside_the_profile_layer' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-b')
    }

    It 'UnitT40_allows_personal_includes_to_restore_a_profile_excluded_skill' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-c'); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-b','skill-c')
    }

    It 'UnitT50_rejects_an_unknown_profile' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('missing'); includeSkills=@(); excludeSkills=@() }
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'Unknown Skills Catalog profile'
    }

    It 'UnitT60_rejects_unknown_and_removed_explicit_skills_without_replacement' {
        $catalog = New-SelectionCatalog
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('missing'); excludeSkills=@() }) } 'does not exist'
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('skill-old'); excludeSkills=@() }) } 'is removed'
    }

    It 'UnitT65_migrates_removed_ids_and_aliases_to_the_replacement_skill' {
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{ id='core'; default=$true; includes=@('new-skill'); excludes=@() })
            skills=@(
                (New-TestSkill -Id 'old-skill' -Status 'removed' -ReplacementId 'new-skill'),
                (New-TestSkill -Id 'new-skill' -Aliases @('old-skill'))
            )
        }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('old-skill'); excludeSkills=@() })) | Should Be @('new-skill')
        @(Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@('old-skill') })).Count | Should Be 0
    }

    It 'UnitT70_filters_profile_selected_skills_when_required_capability_is_missing' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $selection = [pscustomobject]@{ profiles=@('optional'); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection).Count | Should Be 0
    }

    It 'UnitT80_fails_closed_when_an_explicitly_included_skill_is_incompatible' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $selection = [pscustomobject]@{ profiles=@(); includeSkills=@('skill-optional'); excludeSkills=@() }
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'incompatible'
    }

    It 'UnitT90_accepts_explicit_connector_capability_evidence' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE = '[{"kind":"connector","id":"datadog","state":"configured"}]'
        $selection = [pscustomobject]@{ profiles=@('optional'); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-optional')
    }

    It 'UnitT100_adds_a_hard_dependency_and_rejects_an_excluded_one' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @(
            (New-TestSkill -Id 'skill-a' -Dependencies @([pscustomobject]@{ skillId='skill-b'; type='hard' })),
            (New-TestSkill -Id 'skill-b')
        )
        $catalog.profiles = @([pscustomobject]@{ id='core'; default=$true; includes=@('skill-a'); excludes=@() })
        @(Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@() })) | Should Be @('skill-a','skill-b')
        Assert-ThrowsMessage {
            Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@('skill-b') })
        } 'Required dependency.*excluded'
    }

    It 'UnitT110_resolves_missing_or_invalid_dependency_from_capability_evidence' {
        $conditional = [pscustomobject]@{
            skillId='skill-b'
            type='conditional'
            condition=[pscustomobject]@{ capability='jira-cloud-api'; operator='missing-or-invalid' }
            fallback=[pscustomobject]@{ capability='jira-cloud-connector'; description='connector fallback' }
        }
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{ id='jira'; default=$false; includes=@('skill-a'); excludes=@() })
            skills=@((New-TestSkill -Id 'skill-a' -Dependencies @($conditional)),(New-TestSkill -Id 'skill-b'))
        }
        $selection=[pscustomobject]@{ profiles=@('jira'); includeSkills=@(); excludeSkills=@() }

        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a','skill-b')
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"jira-cloud-connector","state":"configured"}]'
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"jira-cloud-api","state":"configured"}]'
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    It 'UnitT115_supports_every_catalog_conditional_operator' {
        $cases = @(
            @{ Operator='available'; WithoutEvidence=@('skill-a'); WithEvidence=@('skill-a','skill-b') },
            @{ Operator='missing'; WithoutEvidence=@('skill-a','skill-b'); WithEvidence=@('skill-a') },
            @{ Operator='unavailable'; WithoutEvidence=@('skill-a','skill-b'); WithEvidence=@('skill-a') },
            @{ Operator='missing-or-invalid'; WithoutEvidence=@('skill-a','skill-b'); WithEvidence=@('skill-a') }
        )
        foreach ($case in $cases) {
            Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
            $conditional = [pscustomobject]@{
                skillId='skill-b'
                type='conditional'
                condition=[pscustomobject]@{ capability='condition-capability'; operator=$case.Operator }
                fallback=[pscustomobject]@{ capability='fallback-capability'; description='fallback' }
            }
            $catalog = [pscustomobject]@{
                profiles=@([pscustomobject]@{ id='test'; default=$false; includes=@('skill-a'); excludes=@() })
                skills=@((New-TestSkill -Id 'skill-a' -Dependencies @($conditional)),(New-TestSkill -Id 'skill-b'))
            }
            $selection=[pscustomobject]@{ profiles=@('test'); includeSkills=@(); excludeSkills=@() }
            @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be $case.WithoutEvidence

            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"condition-capability","state":"configured"}]'
            @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be $case.WithEvidence
        }
    }

    It 'UnitT120_rejects_invalid_capability_evidence_json' {
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='{invalid'
        $catalog=New-SelectionCatalog
        Assert-ThrowsMessage {
            Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@() })
        } 'not valid JSON'
    }
}
