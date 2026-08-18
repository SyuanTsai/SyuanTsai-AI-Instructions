$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:RoutingModule = Join-Path $script:RepositoryRoot 'scripts\skills-source-routing.psm1'

Import-Module $script:RoutingModule -Force

function New-TestSource {
    param(
        [string] $Id,
        [string] $Repository
    )

    return [pscustomobject]@{
        id = $Id
        repository = $Repository
    }
}

function New-TestLockedSource {
    param(
        [string] $Id,
        [string] $Repository,
        [string] $CommitSeed
    )

    return [pscustomobject]@{
        id = $Id
        repository = $Repository
        requestedRef = 'main'
        requestedRefType = 'branch'
        resolvedCommit = ($CommitSeed * 40).Substring(0, 40)
        resolvedVersion = 'test'
        archiveSha256 = ($CommitSeed * 64).Substring(0, 64)
    }
}

function New-TestSkill {
    param(
        [string] $Id,
        [string] $SourceId
    )

    return [pscustomobject]@{
        id = $Id
        source = [pscustomobject]@{
            sourceId = $SourceId
            path = ".agents/skills/$Id"
        }
        lifecycle = [pscustomobject]@{
            status = 'active'
        }
    }
}

function New-TestLockedSkill {
    param(
        [string] $Id,
        [string] $SourceId,
        [string] $HashSeed
    )

    return [pscustomobject]@{
        id = $Id
        sourceId = $SourceId
        sourcePath = ".agents/skills/$Id"
        contentSha256 = ($HashSeed * 64).Substring(0, 64)
    }
}

function New-MultiSourceFixture {
    $catalog = [pscustomobject]@{
        sources = @(
            (New-TestSource -Id 'alpha-source' -Repository 'https://example.test/alpha.git'),
            (New-TestSource -Id 'beta-source' -Repository 'https://example.test/beta.git'),
            (New-TestSource -Id 'unused-source' -Repository 'https://example.test/unused.git')
        )
        skills = @(
            (New-TestSkill -Id 'skill-alpha' -SourceId 'alpha-source'),
            (New-TestSkill -Id 'skill-beta' -SourceId 'beta-source'),
            (New-TestSkill -Id 'skill-unused' -SourceId 'unused-source')
        )
    }

    $lock = [pscustomobject]@{
        sources = @(
            (New-TestLockedSource -Id 'alpha-source' -Repository 'https://example.test/alpha.git' -CommitSeed 'a'),
            (New-TestLockedSource -Id 'beta-source' -Repository 'https://example.test/beta.git' -CommitSeed 'b'),
            (New-TestLockedSource -Id 'unused-source' -Repository 'https://example.test/unused.git' -CommitSeed 'c')
        )
        skills = @(
            (New-TestLockedSkill -Id 'skill-alpha' -SourceId 'alpha-source' -HashSeed '1'),
            (New-TestLockedSkill -Id 'skill-beta' -SourceId 'beta-source' -HashSeed '2'),
            (New-TestLockedSkill -Id 'skill-unused' -SourceId 'unused-source' -HashSeed '3')
        )
    }

    return [pscustomobject]@{
        Catalog = $catalog
        Lock = $lock
    }
}

Describe 'Skills source routing plan' {
    # Scenario: Two selected Skills belong to two unrelated source IDs.
    # Purpose: Prove routing is data-driven and can compose multiple sources in one sync plan.
    It 'UnitT10_routes_selected_skills_to_two_independent_sources' {
        $fixture = New-MultiSourceFixture

        $plan = Resolve-SkillsSourcePlan `
            -Catalog $fixture.Catalog `
            -Lock $fixture.Lock `
            -SkillIds @('skill-beta', 'skill-alpha')

        @($plan.Sources).Count | Should Be 2
        (@($plan.Sources | Select-Object -ExpandProperty id) -join ',') | Should Be 'alpha-source,beta-source'
        @($plan.Skills).Count | Should Be 2
        (@($plan.Skills | ForEach-Object { "$($_.id):$($_.sourceId)" }) -join ',') |
            Should Be 'skill-alpha:alpha-source,skill-beta:beta-source'
    }

    # Scenario: The catalog contains an additional source that no selected Skill uses.
    # Purpose: Ensure unused sources are not acquisition dependencies for the current sync.
    It 'UnitT20_excludes_unused_sources_from_the_acquisition_plan' {
        $fixture = New-MultiSourceFixture

        $plan = Resolve-SkillsSourcePlan `
            -Catalog $fixture.Catalog `
            -Lock $fixture.Lock `
            -SkillIds @('skill-alpha')

        @($plan.Sources).Count | Should Be 1
        @($plan.Sources)[0].id | Should Be 'alpha-source'
        @($plan.Sources | Where-Object { $_.id -eq 'unused-source' }).Count | Should Be 0
    }

    # Scenario: Source IDs are arbitrary and do not match any known domain names.
    # Purpose: Protect the runtime from hard-coded general/atlassian/etc. routing branches.
    It 'UnitT30_routes_arbitrary_source_ids_without_domain_specific_logic' {
        $fixture = New-MultiSourceFixture
        $fixture.Catalog.sources[0].id = 'custom-x'
        $fixture.Catalog.skills[0].source.sourceId = 'custom-x'
        $fixture.Lock.sources[0].id = 'custom-x'
        $fixture.Lock.skills[0].sourceId = 'custom-x'

        $plan = Resolve-SkillsSourcePlan `
            -Catalog $fixture.Catalog `
            -Lock $fixture.Lock `
            -SkillIds @('skill-alpha')

        @($plan.Sources)[0].id | Should Be 'custom-x'
        @($plan.Skills)[0].sourceId | Should Be 'custom-x'
    }

    # Scenario: A selected Skill ID is absent from the catalog.
    # Purpose: Fail closed instead of silently skipping an explicitly requested Skill.
    It 'UnitT40_rejects_an_unknown_selected_skill' {
        $fixture = New-MultiSourceFixture

        { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('missing-skill') } |
            Should Throw '*does not exist in the Skills Catalog*'
    }

    # Scenario: A selected Skill points at a source that is not declared.
    # Purpose: Prevent source routing from falling back to the instruction repository.
    It 'UnitT50_rejects_an_unknown_source_id' {
        $fixture = New-MultiSourceFixture
        $fixture.Catalog.skills[0].source.sourceId = 'missing-source'
        $fixture.Lock.skills[0].sourceId = 'missing-source'

        { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } |
            Should Throw '*references unknown source*'
    }

    # Scenario: The lock routes a Skill differently from the catalog.
    # Purpose: Prevent an altered lock from redirecting content to another repository or path.
    It 'UnitT60_rejects_catalog_lock_routing_mismatch' {
        $fixture = New-MultiSourceFixture
        $fixture.Lock.skills[0].sourceId = 'beta-source'

        { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } |
            Should Throw '*lock source does not match catalog Skill*'
    }

    # Scenario: A selected Skill uses a traversal path.
    # Purpose: Fail closed before any archive content is read or target mutation occurs.
    It 'UnitT70_rejects_unsafe_selected_skill_source_paths' {
        $fixture = New-MultiSourceFixture
        $fixture.Catalog.skills[0].source.path = '../skill-alpha'
        $fixture.Lock.skills[0].sourcePath = '../skill-alpha'

        { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } |
            Should Throw '*Unsafe repository path*'
    }

    # Scenario: No Skill is selected.
    # Purpose: Allow instruction-only synchronization without downloading any Skills source.
    It 'UnitT80_returns_an_empty_source_plan_when_no_skills_are_selected' {
        $fixture = New-MultiSourceFixture

        $plan = Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @()

        @($plan.Sources).Count | Should Be 0
        @($plan.Skills).Count | Should Be 0
    }
}
