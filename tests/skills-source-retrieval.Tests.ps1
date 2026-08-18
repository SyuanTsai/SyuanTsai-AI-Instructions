$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-retrieval.psm1') -Force

Describe 'Skills source retrieval' {
    It 'builds a commit-pinned GitHub codeload URI' {
        $uri = Get-GitHubArchiveUri `
            -Repository 'https://github.com/example/example-skills.git' `
            -ResolvedCommit ('a' * 40)
        $uri | Should Be ('https://codeload.github.com/example/example-skills/zip/' + ('a' * 40))
    }

    It 'rejects non-GitHub remote repositories instead of silently using an unpinned fallback' {
        { Get-GitHubArchiveUri -Repository 'https://example.org/acme/skills.git' -ResolvedCommit ('a' * 40) } | Should Throw '*supports github.com repositories only*'
    }

    It 'uses local overrides only for required sources and does not require unused source inputs' {
        $archive = Join-Path $TestDrive 'source-a.zip'
        Set-Content -LiteralPath $archive -Value 'fixture'
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{ id='source-a'; repository='https://github.com/example/source-a.git'; resolvedCommit=('a' * 40) })
            Skills = @()
        }

        $result = Get-SkillsSourceArchives -Plan $plan -DestinationRoot (Join-Path $TestDrive 'download') -LocalArchiveOverrides @{ 'source-a'=$archive; 'unused-source'='does-not-matter.zip' }
        $result.Count | Should Be 1
        $result['source-a'] | Should Be ([System.IO.Path]::GetFullPath($archive))
    }

    It 'fails closed when a required local override is missing' {
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{ id='source-a'; repository='https://github.com/example/source-a.git'; resolvedCommit=('a' * 40) })
            Skills = @()
        }
        { Get-SkillsSourceArchives -Plan $plan -DestinationRoot (Join-Path $TestDrive 'download') -LocalArchiveOverrides @{ 'source-a'=(Join-Path $TestDrive 'missing.zip') } } | Should Throw '*does not exist*'
    }
}
