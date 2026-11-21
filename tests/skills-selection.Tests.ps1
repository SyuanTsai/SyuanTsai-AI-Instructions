Describe 'Skills selection resolver' {
    BeforeAll {
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

function Assert-StringSequence {
    param([object[]] $Actual, [object[]] $Expected, [string] $Message = 'String sequences differ.')

    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) {
        throw "$Message Expected count '$($expectedValues.Count)', got '$($actualValues.Count)'."
    }
    for ($index = 0; $index -lt $expectedValues.Count; $index++) {
        if ($actualValues[$index] -cne $expectedValues[$index]) {
            throw "$Message Index '$index' expected '$($expectedValues[$index])', got '$($actualValues[$index])'."
        }
    }
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

    }

    BeforeEach {
        Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
    }

    It 'UnitT10_uses_default_profiles_when_no_profile_is_explicitly_selected' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@(); includeSkills=@(); excludeSkills=@() }
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')
    }

    It 'UnitT20_unions_profile_and_personal_includes_then_applies_personal_excludes' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-a'); excludeSkills=@('skill-b') }
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')
    }

    It 'UnitT30_applies_profile_excludes_inside_the_profile_layer' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@(); excludeSkills=@() }
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-b')
    }

    It 'UnitT40_allows_personal_includes_to_restore_a_profile_excluded_skill' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-c'); excludeSkills=@() }
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-b','skill-c')
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
        Assert-StringSequence `
            -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('old-skill'); excludeSkills=@() })) `
            -Expected @('new-skill')
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

    # Scenario: The same incompatible Skill is selected by an active profile and redundantly repeated in includeSkills.
    # Purpose: Keep the profile's soft compatibility semantics instead of turning a redundant selection into a global hard failure.
    It 'UnitT75_does_not_harden_a_redundant_profile_selected_Skill' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $selection = [pscustomobject]@{ profiles=@('optional'); includeSkills=@('skill-optional'); excludeSkills=@() }

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
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-optional')
    }

    # Scenario: A selected Skill has a hard dependency that is either available or explicitly excluded.
    # Purpose: Expand hard dependencies deterministically and reject selections that exclude required Skills.
    It 'UnitT91_adds_a_hard_dependency_and_rejects_an_excluded_one' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @(
            (New-TestSkill -Id 'skill-a' -Dependencies @([pscustomobject]@{ skillId='skill-b'; type='hard' })),
            (New-TestSkill -Id 'skill-b')
        )
        $catalog.profiles = @([pscustomobject]@{ id='core'; default=$true; includes=@('skill-a'); excludes=@() })
        Assert-StringSequence `
            -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@() })) `
            -Expected @('skill-a','skill-b')
        Assert-ThrowsMessage {
            Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@('skill-b') })
        } 'Required dependency.*excluded'
    }

    # Scenario: A conditional setup dependency is evaluated with no evidence, connector evidence, or API evidence.
    # Purpose: Install setup only when neither declared configured alternative satisfies the workflow.
    It 'UnitT92_resolves_missing_or_invalid_dependency_from_capability_evidence' {
        $alternatives = @(
            [pscustomobject]@{ kind='connector'; id='jira-cloud-connector'; state='configured' },
            [pscustomobject]@{ kind='environment'; id='jira-cloud-api'; state='configured' }
        )
        $compatibility = New-TestCompatibility -AnyOfCapabilities (,$alternatives)
        $conditional = [pscustomobject]@{
            skillId='skill-b'
            type='conditional'
            condition=[pscustomobject]@{ capability='jira-cloud-api'; operator='missing-or-invalid' }
            fallback=[pscustomobject]@{ capability='jira-cloud-connector'; description='connector fallback' }
        }
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{ id='jira'; default=$false; includes=@('skill-a'); excludes=@() })
            skills=@((New-TestSkill -Id 'skill-a' -Compatibility $compatibility -Dependencies @($conditional)),(New-TestSkill -Id 'skill-b'))
        }
        $selection=[pscustomobject]@{ profiles=@('jira'); includeSkills=@(); excludeSkills=@() }

        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a','skill-b')
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"jira-cloud-connector","state":"configured"}]'
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"jira-cloud-api","state":"configured"}]'
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')
    }

    # Scenario: Compatibility and conditional fallback refer to the same connector and API identifiers.
    # Purpose: Require the exact declared kind, ID, and state tuple before suppressing setup.
    It 'UnitT93_uses_one_connector_ID_for_compatibility_and_dependency_fallback' {
        $connectorId = 'product-cloud-connector'
        $apiId = 'product-cloud-api'
        $alternatives = @(
            [pscustomobject]@{ kind='connector'; id=$connectorId; state='configured' },
            [pscustomobject]@{ kind='environment'; id=$apiId; state='configured' }
        )
        $compatibility = [pscustomobject]@{
            platforms=@('any'); shells=@(); requiredCapabilities=@(); anyOfCapabilities=,$alternatives
        }
        $conditional = [pscustomobject]@{
            skillId='skill-b'; type='conditional'
            condition=[pscustomobject]@{ capability=$apiId; operator='missing-or-invalid' }
            fallback=[pscustomobject]@{ capability=$connectorId; description='connector fallback' }
        }
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{ id='product'; default=$false; includes=@('skill-a'); excludes=@() })
            skills=@(
                (New-TestSkill -Id 'skill-a' -Compatibility $compatibility -Dependencies @($conditional)),
                (New-TestSkill -Id 'skill-b')
            )
        }
        $selection=[pscustomobject]@{ profiles=@('product'); includeSkills=@(); excludeSkills=@() }

        try {
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a','skill-b')
            $explicitSelection=[pscustomobject]@{ profiles=@('product'); includeSkills=@('skill-a'); excludeSkills=@() }
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $explicitSelection) -Expected @('skill-a','skill-b')
            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"product-cloud-connector","state":"configured"}]'
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')
            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"product-cloud-api","state":"configured"}]'
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a')

            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"product-cloud-connector","state":"available"}]'
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a','skill-b')
            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"product-cloud-connector","state":"configured"}]'
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @('skill-a','skill-b')

            $conditional.condition.capability = 'undeclared-cloud-api'
            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"product-cloud-connector","state":"configured"}]'
            Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'must declare exactly one compatibility requirement'
        }
        finally { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }
    }

    # Scenario: An explicitly selected incompatible Skill has a conditional dependency unrelated to its declared alternatives.
    # Purpose: Fail closed instead of treating an unrelated conditional dependency as compatibility evidence.
    It 'UnitT94_does_not_relax_an_explicit_incompatible_Skill_with_an_unrelated_conditional_dependency' {
        $compatibility = [pscustomobject]@{
            platforms=@('any'); shells=@(); requiredCapabilities=@()
            anyOfCapabilities=,@(
                [pscustomobject]@{ kind='connector'; id='unrelated-cloud-connector'; state='configured' },
                [pscustomobject]@{ kind='environment'; id='unrelated-cloud-api'; state='configured' }
            )
        }
        $conditional = [pscustomobject]@{
            skillId='skill-b'; type='conditional'
            condition=[pscustomobject]@{ capability='product-cloud-api'; operator='missing-or-invalid' }
            fallback=[pscustomobject]@{ capability='product-cloud-connector'; description='connector fallback' }
        }
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{ id='product'; default=$false; includes=@(); excludes=@() })
            skills=@(
                (New-TestSkill -Id 'skill-a' -Compatibility $compatibility -Dependencies @($conditional)),
                (New-TestSkill -Id 'skill-b')
            )
        }
        $selection=[pscustomobject]@{ profiles=@('product'); includeSkills=@('skill-a'); excludeSkills=@() }

        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'incompatible'
    }

    # Scenario: Each supported conditional operator is evaluated with and without matching capability evidence.
    # Purpose: Preserve the catalog's documented conditional-dependency semantics across all operators.
    It 'UnitT95_supports_every_catalog_conditional_operator' {
        $cases = @(
            @{ Operator='available'; WithoutEvidence=@(); WithEvidence=@('skill-a','skill-b') },
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
            $alternatives = @(
                [pscustomobject]@{ kind='environment'; id='condition-capability'; state='configured' },
                [pscustomobject]@{ kind='connector'; id='fallback-capability'; state='configured' }
            )
            $compatibility = New-TestCompatibility -AnyOfCapabilities (,$alternatives)
            $catalog = [pscustomobject]@{
                profiles=@([pscustomobject]@{ id='test'; default=$false; includes=@('skill-a'); excludes=@() })
                skills=@((New-TestSkill -Id 'skill-a' -Compatibility $compatibility -Dependencies @($conditional)),(New-TestSkill -Id 'skill-b'))
            }
            $selection=[pscustomobject]@{ profiles=@('test'); includeSkills=@(); excludeSkills=@() }
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @($case.WithoutEvidence)

            $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"environment","id":"condition-capability","state":"configured"}]'
            Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) -Expected @($case.WithEvidence)
        }
    }

    # Scenario: Capability evidence is present but is not valid JSON.
    # Purpose: Reject malformed evidence rather than silently weakening compatibility checks.
    It 'UnitT96_rejects_invalid_capability_evidence_json' {
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='{invalid'
        $catalog=New-SelectionCatalog
        Assert-ThrowsMessage {
            Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@() })
        } 'not valid JSON'
    }

    # Scenario: A profile-selected connector-gated Skill is present in the managed USER manifest, but no current evidence exists for its capability.
    # Purpose: Preserve an installed Skill when connector state is unknown and emit actionable evidence guidance without changing fresh-install filtering.
    It 'UnitT99_preserves_an_installed_Skill_when_connector_evidence_is_unknown' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $selection = [pscustomobject]@{ profiles=@('optional'); includeSkills=@(); excludeSkills=@() }

        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection).Count | Should Be 0
        $warnings = @()
        $resolved = @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -InstalledSkillIds @('skill-optional') -WarningVariable warnings)

        Assert-StringSequence -Actual $resolved -Expected @('skill-optional')
        ($warnings -join "`n") | Should Match 'skill-optional'
        ($warnings -join "`n") | Should Match 'connector:datadog'
        ($warnings -join "`n") | Should Match '\-CapabilityEvidence'
        ($warnings -join "`n") | Should Match 'absent'
    }

    # Scenario: Stored configured evidence is overlaid by an environment declaration, including the explicit absent state in either source.
    # Purpose: Make the per-run environment declaration authoritative while keeping persisted evidence immutable at selection time.
    It 'UnitT100_merges_stored_evidence_with_environment_override_and_honors_absent' {
        $catalog = New-SelectionCatalog
        $catalog.skills = @($catalog.skills | Where-Object { $_.id -ne 'skill-optional' }) + @(
            (New-TestSkill -Id 'skill-optional' -Compatibility (New-TestCompatibility -RequiredCapabilities @(
                [pscustomobject]@{ kind='connector'; id='datadog'; state='configured' }
            )))
        )
        $selection = [pscustomobject]@{ profiles=@('optional'); includeSkills=@(); excludeSkills=@() }
        $configured = @([pscustomobject]@{kind='connector';id='datadog';state='configured'})
        $absent = @([pscustomobject]@{kind='connector';id='datadog';state='absent'})

        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -CapabilityEvidence $configured) -Expected @('skill-optional')
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -CapabilityEvidence $absent -InstalledSkillIds @('skill-optional')).Count | Should Be 0
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"datadog","state":"absent"}]'
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -CapabilityEvidence $configured -InstalledSkillIds @('skill-optional')).Count | Should Be 0
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"datadog","state":"configured"}]'
        Assert-StringSequence -Actual @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -CapabilityEvidence $absent) -Expected @('skill-optional')
    }

    # Scenario: Installed Skills fail command, platform, or explicit-exclusion checks while connector evidence is unknown.
    # Purpose: Limit unknown-state preservation to connector/environment capability gaps and retain all existing hard filters.
    It 'UnitT101_does_not_preserve_command_platform_or_explicitly_excluded_Skills' {
        $catalog = [pscustomobject]@{
            profiles=@([pscustomobject]@{id='core';default=$true;includes=@('connector-skill','command-skill','platform-skill');excludes=@()})
            skills=@(
                (New-TestSkill -Id 'connector-skill' -Compatibility (New-TestCompatibility -RequiredCapabilities @([pscustomobject]@{kind='connector';id='datadog';state='configured'}))),
                (New-TestSkill -Id 'command-skill' -Compatibility (New-TestCompatibility -RequiredCapabilities @([pscustomobject]@{kind='command';id='syp511-command-that-does-not-exist';state='available'}))),
                (New-TestSkill -Id 'platform-skill' -Compatibility (New-TestCompatibility -Platforms @('syp511-unsupported') -RequiredCapabilities @([pscustomobject]@{kind='connector';id='datadog';state='configured'})))
            )
        }
        $installed=@('connector-skill','command-skill','platform-skill')
        $selection=[pscustomobject]@{profiles=@('core');includeSkills=@();excludeSkills=@('connector-skill')}

        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection -InstalledSkillIds $installed).Count | Should Be 0
    }

    # Scenario: Stored or environment capability evidence repeats the same kind and ID tuple.
    # Purpose: Reject ambiguous precedence within one evidence source before selection can silently collapse it.
    It 'UnitT102_rejects_duplicate_capability_evidence_tuples' {
        $catalog=New-SelectionCatalog
        $selection=[pscustomobject]@{profiles=@('core');includeSkills=@();excludeSkills=@()}
        $duplicate=@(
            [pscustomobject]@{kind='connector';id='datadog';state='configured'},
            [pscustomobject]@{kind='connector';id='datadog';state='absent'}
        )
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection -CapabilityEvidence $duplicate } 'duplicate'
        $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE='[{"kind":"connector","id":"datadog","state":"configured"},{"kind":"connector","id":"datadog","state":"absent"}]'
        Assert-ThrowsMessage { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } 'duplicate'
    }

    # Scenario: The approved Atlassian profile resolves its existing setup fallback on Windows and filters platform-specific Skills elsewhere.
    # Purpose: Keep one-off publishing available when Git documentation synchronization is activated on supported platforms.
    It 'InterT97_keeps_publisher_and_docs_as_code_available_together' {
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') | ConvertFrom-Json
        $selection = [pscustomobject]@{ profiles=@('atlassian'); includeSkills=@(); excludeSkills=@() }
        $resolved = @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection)

        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $resolved -contains 'publish-requirements-to-confluence' | Should Be $true
            $resolved -contains 'manage-confluence-docs-as-code' | Should Be $true
            $resolved -contains 'configure-confluence-api-access' | Should Be $true
        }
        else {
            $currentPlatform = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
                'macos'
            }
            elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
                'linux'
            }
            else {
                'unix'
            }
            foreach ($skillId in @('publish-requirements-to-confluence','manage-confluence-docs-as-code','configure-confluence-api-access')) {
                $skill = @($catalog.skills | Where-Object { [string]$_.id -ceq $skillId })[0]
                $isSupported = (@($skill.compatibility.platforms) -contains 'any') -or (@($skill.compatibility.platforms) -contains $currentPlatform)
                $resolved -contains $skillId | Should Be $isSupported
            }
        }
        $resolved -contains 'operate-environment-authorized-sql' | Should Be $false
    }

    # Scenario: An adopter excludes only Git documentation synchronization from the shared profile.
    # Purpose: Preserve independent selection of the one-off publisher instead of treating it as a rename.
    It 'InterT98_excludes_docs_as_code_without_retiring_the_publisher' {
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') | ConvertFrom-Json
        $selection = [pscustomobject]@{ profiles=@('atlassian'); includeSkills=@(); excludeSkills=@('manage-confluence-docs-as-code') }
        $resolved = @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection)

        $resolved -contains 'publish-requirements-to-confluence' | Should Be $true
        $resolved -contains 'manage-confluence-docs-as-code' | Should Be $false
    }
}
