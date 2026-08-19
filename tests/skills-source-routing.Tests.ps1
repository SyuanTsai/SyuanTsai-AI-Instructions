$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:RoutingModule = Join-Path $script:RepositoryRoot 'scripts\skills-source-routing.psm1'
Import-Module $script:RoutingModule -Force

function Assert-ThrowsMessage {
    param([scriptblock] $Action, [string] $Pattern)
    $thrown = $false
    $message = $null
    try { & $Action } catch { $thrown = $true; $message = $_.Exception.Message }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

function New-TestSource { param([string]$Id,[string]$Repository); [pscustomobject]@{ id=$Id; repository=$Repository } }
function New-TestLockedSource {
    param([string]$Id,[string]$Repository,[string]$CommitSeed)
    [pscustomobject]@{ id=$Id; repository=$Repository; requestedRef='main'; requestedRefType='branch'; resolvedCommit=($CommitSeed*40).Substring(0,40); resolvedVersion='test'; archiveSha256=($CommitSeed*64).Substring(0,64) }
}
function New-TestSkill {
    param([string]$Id,[string]$SourceId)
    [pscustomobject]@{ id=$Id; source=[pscustomobject]@{sourceId=$SourceId;path=".agents/skills/$Id"}; lifecycle=[pscustomobject]@{status='active'} }
}
function New-TestLockedSkill {
    param([string]$Id,[string]$SourceId,[string]$HashSeed)
    [pscustomobject]@{ id=$Id; sourceId=$SourceId; sourcePath=".agents/skills/$Id"; contentSha256=($HashSeed*64).Substring(0,64) }
}
function New-MultiSourceFixture {
    [pscustomobject]@{
        Catalog=[pscustomobject]@{
            sources=@(
                (New-TestSource 'alpha-source' 'https://example.test/alpha.git'),
                (New-TestSource 'beta-source' 'https://example.test/beta.git'),
                (New-TestSource 'unused-source' 'https://example.test/unused.git'))
            skills=@(
                (New-TestSkill 'skill-alpha' 'alpha-source'),
                (New-TestSkill 'skill-beta' 'beta-source'),
                (New-TestSkill 'skill-unused' 'unused-source'))
        }
        Lock=[pscustomobject]@{
            sources=@(
                (New-TestLockedSource 'alpha-source' 'https://example.test/alpha.git' 'a'),
                (New-TestLockedSource 'beta-source' 'https://example.test/beta.git' 'b'),
                (New-TestLockedSource 'unused-source' 'https://example.test/unused.git' 'c'))
            skills=@(
                (New-TestLockedSkill 'skill-alpha' 'alpha-source' '1'),
                (New-TestLockedSkill 'skill-beta' 'beta-source' '2'),
                (New-TestLockedSkill 'skill-unused' 'unused-source' '3'))
        }
    }
}

Describe 'Skills source routing plan' {
    It 'UnitT10_routes_selected_skills_to_two_independent_sources' {
        $fixture=New-MultiSourceFixture
        $plan=Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-beta','skill-alpha')
        @($plan.Sources).Count | Should Be 2
        (@($plan.Sources|Select-Object -ExpandProperty id)-join ',') | Should Be 'alpha-source,beta-source'
        @($plan.Skills).Count | Should Be 2
        (@($plan.Skills|ForEach-Object{"$($_.id):$($_.sourceId)"})-join ',') | Should Be 'skill-alpha:alpha-source,skill-beta:beta-source'
    }
    It 'UnitT20_excludes_unused_sources_from_the_acquisition_plan' {
        $fixture=New-MultiSourceFixture
        $plan=Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha')
        @($plan.Sources).Count | Should Be 1
        @($plan.Sources)[0].id | Should Be 'alpha-source'
    }
    It 'UnitT30_routes_arbitrary_source_ids_without_domain_specific_logic' {
        $fixture=New-MultiSourceFixture
        $fixture.Catalog.sources[0].id='custom-x'; $fixture.Catalog.skills[0].source.sourceId='custom-x'; $fixture.Lock.sources[0].id='custom-x'; $fixture.Lock.skills[0].sourceId='custom-x'
        $plan=Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha')
        @($plan.Sources)[0].id | Should Be 'custom-x'
        @($plan.Skills)[0].sourceId | Should Be 'custom-x'
    }
    It 'UnitT40_rejects_an_unknown_selected_skill' {
        $fixture=New-MultiSourceFixture
        Assert-ThrowsMessage { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('missing-skill') } 'does not exist in the Skills Catalog'
    }
    It 'UnitT50_rejects_an_unknown_source_id' {
        $fixture=New-MultiSourceFixture; $fixture.Catalog.skills[0].source.sourceId='missing-source'; $fixture.Lock.skills[0].sourceId='missing-source'
        Assert-ThrowsMessage { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } 'references unknown source'
    }
    It 'UnitT60_rejects_catalog_lock_routing_mismatch' {
        $fixture=New-MultiSourceFixture; $fixture.Lock.skills[0].sourceId='beta-source'
        Assert-ThrowsMessage { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } 'lock source does not match catalog Skill'
    }
    It 'UnitT70_rejects_unsafe_selected_skill_source_paths' {
        $fixture=New-MultiSourceFixture; $fixture.Catalog.skills[0].source.path='../skill-alpha'; $fixture.Lock.skills[0].sourcePath='../skill-alpha'
        Assert-ThrowsMessage { Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @('skill-alpha') } 'Unsafe repository path'
    }
    It 'UnitT80_returns_an_empty_source_plan_when_no_skills_are_selected' {
        $fixture=New-MultiSourceFixture
        $plan=Resolve-SkillsSourcePlan -Catalog $fixture.Catalog -Lock $fixture.Lock -SkillIds @()
        @($plan.Sources).Count | Should Be 0
        @($plan.Skills).Count | Should Be 0
    }
}
