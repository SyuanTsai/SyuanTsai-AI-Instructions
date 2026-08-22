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
    }

    # Scenario: All active migrated Skills are resolved from the tracked production catalog.
    # Purpose: Detect missing, duplicated, or incorrectly routed production Skill assignments.
    It 'InterT15_maps_all_ten_migrated_Skills_to_external_sources' {
        @($script:catalog.skills | Where-Object { $_.lifecycle.status -eq 'active' }).Count | Should Be 10

        $expectedSourceBySkill = @{
            'plan-production-change' = 'general'
            'verify-data-access-performance' = 'general'
            'investigate-datadog-logs' = 'general'
            'search-with-felo' = 'general'
            'write-copilot-implementation-prompt' = 'code-collaboration'
            'capture-private-course-knowledge' = 'knowledge-content'
            'configure-jira-api-access' = 'atlassian-ecosystem'
            'publish-requirements-to-confluence' = 'atlassian-ecosystem'
            'review-bitbucket-pull-request' = 'atlassian-ecosystem'
            'work-with-jira' = 'atlassian-ecosystem'
        }

        foreach ($skill in @($script:catalog.skills)) {
            $expectedSourceBySkill.ContainsKey([string]$skill.id) | Should Be $true
            [string]$skill.source.sourceId | Should Be $expectedSourceBySkill[[string]$skill.id]
            [string]$skill.source.path | Should Be ".agents/skills/$($skill.id)"
        }
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
    }
}
