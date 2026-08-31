$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalogPath = Join-Path $repositoryRoot 'catalog\skills-catalog.json'
$sourcePinsPath = Join-Path $repositoryRoot 'catalog\skills-catalog.sources.json'
$lockPath = Join-Path $repositoryRoot 'catalog\skills-catalog-lock.json'
$contractModule = Join-Path $repositoryRoot 'scripts\skills-catalog-contract.psm1'

Import-Module $contractModule -Force

Describe 'production Skills Catalog' {
    BeforeAll {
        $script:catalog = Test-SkillsCatalogDocument -CatalogPath $catalogPath
        $script:pins = Test-SkillsCatalogSourcePinsDocument -SourcePinsPath $sourcePinsPath -CatalogPath $catalogPath
        $script:lock = Test-SkillsCatalogLockDocument -LockPath $lockPath -CatalogPath $catalogPath
    }

    # Scenario: The tracked production catalog defines the repositories available to installed consumers.
    # Purpose: Prevent the bootstrap repository or an unapproved source from re-entering production routing.
    It 'InterT10_uses_the_four_external_Skill_repositories_as_the_only_production_sources' {
        $expected = @(
            'atlassian-ecosystem',
            'code-collaboration',
            'general',
            'knowledge-content'
        )
        @($script:catalog.sources.id | Sort-Object) | Should Be $expected
        @($script:catalog.sources | Where-Object { $_.repository -match 'SyuanTsai-AI-Instructions' }).Count | Should Be 0
        @($script:catalog.sources | Where-Object { $_.repository -match 'Skill-Darktide-Translate' }).Count | Should Be 0
    }

    # Scenario: The AI-Instructions repository has completed its cutover to externally owned shared Skills.
    # Purpose: Keep external repositories as the only shared Skill sources and prevent legacy copies from returning.
    It 'InterT12_contains_no_built_in_shared_Skill_source' {
        $builtInSkillRoot = Join-Path $repositoryRoot '.agents\skills'
        if (Test-Path -LiteralPath $builtInSkillRoot -PathType Container) {
            @(
                Get-ChildItem -LiteralPath $builtInSkillRoot -Recurse -Force -File |
                    Where-Object { $_.Name -ne '.gitkeep' }
            ).Count | Should Be 0
        }
        else {
            Test-Path -LiteralPath $builtInSkillRoot | Should Be $false
        }
    }

    # Scenario: Active migrated Skills remain routed while the retired FELO wrapper keeps only its stable-ID tombstone.
    # Purpose: Prevent the custom FELO Skill from re-entering profiles or the production lock without losing removal history.
    It 'InterT15_maps_eleven_active_Skills_and_keeps_the_removed_FELO_tombstone' {
        $activeSkills = @($script:catalog.skills | Where-Object { $_.lifecycle.status -eq 'active' })
        $activeSkills.Count | Should Be 11

        $expectedSourceBySkill = @{
            'plan-production-change' = 'general'
            'verify-data-access-performance' = 'general'
            'investigate-datadog-logs' = 'general'
            'write-copilot-implementation-prompt' = 'code-collaboration'
            'capture-private-course-knowledge' = 'knowledge-content'
            'configure-bitbucket-api-access' = 'atlassian-ecosystem'
            'configure-confluence-api-access' = 'atlassian-ecosystem'
            'configure-jira-api-access' = 'atlassian-ecosystem'
            'publish-requirements-to-confluence' = 'atlassian-ecosystem'
            'review-bitbucket-pull-request' = 'atlassian-ecosystem'
            'work-with-jira' = 'atlassian-ecosystem'
        }

        foreach ($skill in $activeSkills) {
            $expectedSourceBySkill.ContainsKey([string]$skill.id) | Should Be $true
            [string]$skill.source.sourceId | Should Be $expectedSourceBySkill[[string]$skill.id]
            [string]$skill.source.path | Should Be ".agents/skills/$($skill.id)"
        }

        $removedFelo = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'search-with-felo' })
        $removedFelo.Count | Should Be 1
        [string]$removedFelo[0].lifecycle.status | Should Be 'removed'
        @($removedFelo[0].lifecycle.aliases).Count | Should Be 0
        @($removedFelo[0].lifecycle.PSObject.Properties.Name | Where-Object { $_ -eq 'replacementId' }).Count | Should Be 0
        @($removedFelo[0].profiles).Count | Should Be 0

        $externalResearch = @($script:catalog.profiles | Where-Object { [string]$_.id -eq 'external-research' })
        $externalResearch.Count | Should Be 1
        @($externalResearch[0].includes | Where-Object { $_ -eq 'search-with-felo' }).Count | Should Be 0

        @($script:catalog.skills | Where-Object { [string]$_.id -match 'darktide' }).Count | Should Be 0
    }

    # Scenario: Both Codex and Copilot runtime Instructions publish the official FELO replacement routes.
    # Purpose: Keep system-level official Skills canonical and prevent any route back to the retired repository-local wrapper.
    It 'InterT16_routes_FELO_workflows_only_to_the_four_official_canonical_Skills' {
        $instructionPaths = @(
            '.codex/AGENTS.md',
            '.codex/AGENTS.en.md',
            '.github/copilot-instructions.md',
            '.github/copilot-instructions.en.md'
        )
        $officialPaths = @(
            '~/.agents/skills/felo-search/SKILL.md',
            '~/.agents/skills/felo-slides/SKILL.md',
            '~/.agents/skills/felo-x-search/SKILL.md',
            '~/.agents/skills/felo-landingpage/SKILL.md'
        )
        foreach ($instructionPath in $instructionPaths) {
            $content = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot $instructionPath)
            $content | Should Not Match '\.agents/skills/search-with-felo/SKILL\.md'
            foreach ($officialPath in $officialPaths) { $content | Should Match ([regex]::Escape($officialPath)) }
        }
    }

    # Scenario: Bitbucket PR review can repair missing or invalid API access without forcing setup when a connector is available.
    # Purpose: Keep API setup conditional and preserve the connector fallback boundary.
    It 'InterT17_routes_Bitbucket_API_failures_to_the_setup_Skill_conditionally' {
        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'review-bitbucket-pull-request' })[0]
        @($skill.dependencies).Count | Should Be 1
        [string]$skill.dependencies[0].skillId | Should Be 'configure-bitbucket-api-access'
        [string]$skill.dependencies[0].type | Should Be 'conditional'
        [string]$skill.dependencies[0].condition.capability | Should Be 'bitbucket-cloud-api'
        [string]$skill.dependencies[0].condition.operator | Should Be 'missing-or-invalid'
        [string]$skill.dependencies[0].fallback.capability | Should Be 'bitbucket-cloud-connector'
    }

    # Scenario: Confluence publishing can repair missing or invalid scoped API access without forcing setup when a connector is available.
    # Purpose: Keep API setup conditional and preserve the connector fallback boundary.
    It 'InterT18_routes_Confluence_API_failures_to_the_setup_Skill_conditionally' {
        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'publish-requirements-to-confluence' })[0]
        @($skill.dependencies).Count | Should Be 1
        [string]$skill.dependencies[0].skillId | Should Be 'configure-confluence-api-access'
        [string]$skill.dependencies[0].type | Should Be 'conditional'
        [string]$skill.dependencies[0].condition.capability | Should Be 'confluence-cloud-api'
        [string]$skill.dependencies[0].condition.operator | Should Be 'missing-or-invalid'
        [string]$skill.dependencies[0].fallback.capability | Should Be 'confluence-cloud-connector'
    }

    # Scenario: The production catalog contains the profiles used by a new installation.
    # Purpose: Keep installation defaults deterministic and limited to the intended core profile.
    It 'InterT20_keeps_core_as_the_only_default_profile' {
        @($script:catalog.profiles | Where-Object { $_.default -eq $true }).Count | Should Be 1
        [string]@($script:catalog.profiles | Where-Object { $_.default -eq $true })[0].id | Should Be 'core'
    }

    # Scenario: Production source pins are loaded together with the tracked catalog.
    # Purpose: Ensure every source resolves from an immutable commit while preserving its operator-facing branch metadata.
    It 'InterT25_pins_every_production_source_to_a_full_immutable_commit' {
        $script:pins.schemaVersion | Should Be 1
        ([string]$script:pins.catalogId) | Should Be ([string]$script:catalog.catalogId)
        @($script:pins.sources).Count | Should Be @($script:catalog.sources).Count

        foreach ($source in @($script:catalog.sources)) {
            $matches = @($script:pins.sources | Where-Object { [string]$_.id -eq [string]$source.id })
            $matches.Count | Should Be 1
            [string]$matches[0].requestedRef | Should Be 'main'
            [string]$matches[0].requestedRefType | Should Be 'branch'
            [string]$matches[0].resolvedCommit | Should Match '^[0-9a-f]{40}$'
            [string]$matches[0].resolvedVersion | Should Not BeNullOrEmpty
        }
    }

    # Scenario: The production catalog is distributed with its generated immutable lock.
    # Purpose: Make installation reproducible from tracked bytes and give CI a stale-lock gate.
    It 'InterT30_tracks_a_complete_lock_for_every_production_source_and_skill' {
        Test-Path -LiteralPath $lockPath -PathType Leaf | Should Be $true
        ([string]$script:lock.catalogId) | Should Be ([string]$script:catalog.catalogId)
        @($script:lock.sources).Count | Should Be @($script:catalog.sources).Count
        @($script:lock.skills).Count | Should Be @($script:catalog.skills | Where-Object { $_.lifecycle.status -ne 'removed' }).Count
        foreach ($source in @($script:lock.sources)) {
            [string]$source.resolvedCommit | Should Match '^[0-9a-f]{40}$'
            [string]$source.archiveSha256 | Should Match '^[0-9a-f]{64}$'
        }
        foreach ($skill in @($script:lock.skills)) {
            [string]$skill.contentSha256 | Should Match '^[0-9a-f]{64}$'
        }
        @($script:lock.skills | Where-Object { [string]$_.id -eq 'search-with-felo' }).Count | Should Be 0
    }
}
