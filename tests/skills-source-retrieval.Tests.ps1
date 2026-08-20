$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-retrieval.psm1') -Force

function Assert-ThrowsMessage {
    param([scriptblock] $Action, [string] $Pattern)
    $thrown = $false
    $message = $null
    try { & $Action } catch { $thrown = $true; $message = $_.Exception.Message }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

Describe 'Skills source retrieval' {
    # Scenario: A GitHub source repository and immutable full commit SHA are ready for retrieval.
    # Purpose: Download through a commit-pinned codeload URI rather than a mutable branch endpoint.
    It 'UnitT10_builds_a_commit_pinned_GitHub_codeload_URI' {
        $uri = Get-GitHubArchiveUri -Repository 'https://github.com/example/example-skills.git' -ResolvedCommit ('a' * 40)
        $uri | Should Be ('https://codeload.github.com/example/example-skills/zip/' + ('a' * 40))
    }

    # Scenario: A remote source uses a host that the current retrieval implementation does not support.
    # Purpose: Fail closed rather than silently falling back to an unpinned or differently authenticated path.
    It 'UnitT20_rejects_an_unsupported_remote_repository_host' {
        Assert-ThrowsMessage { Get-GitHubArchiveUri -Repository 'https://example.org/acme/skills.git' -ResolvedCommit ('a' * 40) } 'supports github.com repositories only'
    }

    # Scenario: The plan needs one local fixture archive while configuration also contains an unused override.
    # Purpose: Retrieve only routed sources so unused sources cannot block a valid sync.
    It 'UnitT30_uses_local_overrides_only_for_required_sources' {
        $archive = Join-Path $TestDrive 'source-a.zip'
        Set-Content -LiteralPath $archive -Value 'fixture'
        $plan = [pscustomobject]@{ Sources=@([pscustomobject]@{ id='source-a'; repository='https://github.com/example/source-a.git'; resolvedCommit=('a' * 40) }); Skills=@() }
        $result = Get-SkillsSourceArchives -Plan $plan -DestinationRoot (Join-Path $TestDrive 'download') -LocalArchiveOverrides @{ 'source-a'=$archive; 'unused-source'='does-not-matter.zip' }
        $result.Count | Should Be 1
        $result['source-a'] | Should Be ([System.IO.Path]::GetFullPath($archive))
    }

    # Scenario: A required source is routed to a local archive path that does not exist.
    # Purpose: Stop before acquisition rather than substituting another source or continuing with partial input.
    It 'UnitT40_rejects_a_missing_required_local_override' {
        $plan = [pscustomobject]@{ Sources=@([pscustomobject]@{ id='source-a'; repository='https://github.com/example/source-a.git'; resolvedCommit=('a' * 40) }); Skills=@() }
        Assert-ThrowsMessage { Get-SkillsSourceArchives -Plan $plan -DestinationRoot (Join-Path $TestDrive 'download') -LocalArchiveOverrides @{ 'source-a'=(Join-Path $TestDrive 'missing.zip') } } 'does not exist'
    }
}
