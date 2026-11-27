$script:UnixScopeScript = Join-Path $PSScriptRoot '../scripts/Get-UnixCoreChangeScope.ps1'

Describe 'Unix Core change scope' {
    BeforeAll {
        . $script:UnixScopeScript -DefineFunctionsOnly

        function Invoke-ScopeFixtureGit {
            & git -C $scopeRoot -c core.hooksPath=.git/no-hooks -c user.name='Scope Fixture' `
                -c user.email=scope@example.test -c commit.gpgSign=false @args
            if ($LASTEXITCODE -ne 0) { throw "Fixture Git command failed: $args" }
        }

        function Set-ScopeFixtureFile([string] $Path, [string] $Text) {
            $destination = Join-Path $scopeRoot $Path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.File]::WriteAllText($destination, $Text)
        }
    }

    BeforeEach {
        $scopeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($scopeRoot) | Out-Null
        Invoke-ScopeFixtureGit init --quiet
        foreach ($path in @('README.md', 'docs/delivery/notes.md', 'delivery/notes.md')) {
            Set-ScopeFixtureFile $path 'base'
        }
        Invoke-ScopeFixtureGit add -- .
        Invoke-ScopeFixtureGit commit --quiet -m base
        $scopeBase = Invoke-ScopeFixtureGit rev-parse HEAD
    }

    # Scenario: A main push or manual run contains only an excluded edit.
    # Purpose: Reserve path-based skipping for PRs.
    It 'InterT10_runs_full_tests_for_<Event>' -TestCases @(
        @{ Event = 'push' }
        @{ Event = 'workflow_dispatch' }
    ) {
        param($Event)
        Set-ScopeFixtureFile 'docs/delivery/notes.md' 'edited'
        Invoke-ScopeFixtureGit commit -aqm head
        & $script:UnixScopeScript -EventName $Event -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
    }

    # Scenario: A PR edits existing Markdown under both excluded directories.
    # Purpose: Prove the skip decision and its GitHub output format.
    It 'InterT20_skips_delivery_edits_and_writes_the_GitHub_output' {
        Set-ScopeFixtureFile 'docs/delivery/notes.md' 'edited'
        Set-ScopeFixtureFile 'delivery/notes.md' 'also edited'
        Invoke-ScopeFixtureGit commit -aqm head
        $output = Join-Path $TestDrive 'github-output.txt'
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot `
            -OutputPath $output | Should Be $false
        [IO.File]::ReadAllText($output) | Should Be "relevant=false`n"
    }

    # Scenario: A PR modifies a relevant path on its own and alongside a delivery note.
    # Purpose: Verify that any one relevant path requires the full suite.
    It 'InterT30_runs_full_tests_when_<Path>_changes' -TestCases @(
        @{ Path = 'README.md' }
        @{ Path = 'scripts/check.ps1' }
        @{ Path = 'tests/check.Tests.ps1' }
        @{ Path = '.github/workflows/unix-core.yml' }
        @{ Path = 'docs/standards/policy.md' }
        @{ Path = 'docs/examples/example.md' }
        @{ Path = 'docs/plans/plan.md' }
        @{ Path = 'delivery/artifact.json' }
    ) {
        param($Path)
        Set-ScopeFixtureFile $Path 'reference'
        Invoke-ScopeFixtureGit add -- "$Path"
        Invoke-ScopeFixtureGit commit --quiet -m reference
        $scopeBase = Invoke-ScopeFixtureGit rev-parse HEAD
        Set-ScopeFixtureFile $Path 'changed'
        Invoke-ScopeFixtureGit commit -aqm head
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
        Set-ScopeFixtureFile 'docs/delivery/notes.md' 'edited'
        Invoke-ScopeFixtureGit commit -aqm mixed
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
    }

    # Scenario: A PR supplies no base, produces no paths, or encounters a Git/process failure.
    # Purpose: Run the full suite whenever the change scope cannot be determined.
    It 'InterT40_runs_full_tests_for_missing_empty_or_failed_diff' {
        & $script:UnixScopeScript -EventName pull_request -BaseSha '' -RepositoryRoot $scopeRoot | Should Be $true
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -HeadRef missing-ref `
            -RepositoryRoot $scopeRoot | Should Be $true
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase `
            -RepositoryRoot (Join-Path $scopeRoot 'missing-directory') | Should Be $true
    }

    # Scenario: A path uses Windows separators, different casing, or two dots.
    # Purpose: Normalize separators without widening the ordinal exclusion.
    It 'UnitT50_normalizes_separators_and_rejects_ambiguous_paths' {
        Test-UnixCoreRelevantPaths @('docs\delivery\notes.md') | Should Be $false
        Test-UnixCoreRelevantPaths @('Docs/delivery/notes.md') | Should Be $true
        Test-UnixCoreRelevantPaths @('docs/delivery/../notes.md') | Should Be $true
        Test-UnixCoreRelevantPaths @('docs/delivery/notes..md') | Should Be $true
    }

    # Scenario: A PR adds Markdown in an excluded directory.
    # Purpose: Validate the licensing inventory whenever the tracked paths change.
    It 'InterT60_runs_full_tests_for_an_added_delivery_document' {
        Set-ScopeFixtureFile 'docs/delivery/new.md' 'new'
        Invoke-ScopeFixtureGit add -- docs/delivery/new.md
        Invoke-ScopeFixtureGit commit --quiet -m head
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
    }

    # Scenario: A PR renames a file into, out of, or within an excluded directory.
    # Purpose: Evaluate both names and continue to verify tracked-path inventory.
    It 'InterT70_runs_full_tests_for_a_rename_from_<From>_to_<To>' -TestCases @(
        @{ From = 'README.md'; To = 'delivery/renamed.md' }
        @{ From = 'delivery/notes.md'; To = 'renamed.md' }
        @{ From = 'delivery/notes.md'; To = 'delivery/renamed.md' }
    ) {
        param($From, $To)
        Invoke-ScopeFixtureGit mv -- "$From" "$To"
        Invoke-ScopeFixtureGit commit --quiet -m head
        & $script:UnixScopeScript -EventName pull_request -BaseSha $scopeBase -RepositoryRoot $scopeRoot |
            Should Be $true
    }
}
