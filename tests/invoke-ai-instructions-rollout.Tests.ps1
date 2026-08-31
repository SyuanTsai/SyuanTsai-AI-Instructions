$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RolloutModule = Join-Path $script:RepositoryRoot 'scripts\ai-instructions-rollout.psm1'

function Invoke-RolloutTestGit {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Set-RolloutTestText {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Value,(New-Object System.Text.UTF8Encoding($false)))
}

function New-RolloutTestRepository {
    param([Parameter(Mandatory = $true)][string] $Path,[string] $Origin='https://example.com/team/product.git')
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-RolloutTestGit -Repository $Path -Arguments @('init','--quiet') | Out-Null
    Invoke-RolloutTestGit -Repository $Path -Arguments @('config','user.name','Rollout Test') | Out-Null
    Invoke-RolloutTestGit -Repository $Path -Arguments @('config','user.email','rollout@example.test') | Out-Null
    Set-RolloutTestText -Path (Join-Path $Path 'product.txt') -Value "product`n"
    Invoke-RolloutTestGit -Repository $Path -Arguments @('add','--','product.txt') | Out-Null
    Invoke-RolloutTestGit -Repository $Path -Arguments @('commit','--quiet','-m','initial') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Origin)) {
        Invoke-RolloutTestGit -Repository $Path -Arguments @('remote','add','origin',$Origin) | Out-Null
    }
}

function New-RolloutTestBootstrap {
    param([Parameter(Mandatory = $true)][string] $Path,[switch] $MutateProduct)
    $mutation = if ($MutateProduct) {
        "[System.IO.File]::AppendAllText((Join-Path `$TargetRoot 'product.txt'),'drift')"
    }
    else { '' }
    Set-RolloutTestText -Path $Path -Value @"
param([string]`$TargetRoot,[switch]`$SkipUpdateCheck)
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'fail.rollout')) { throw 'simulated repository failure' }
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'fail-after-drift.rollout')) {
    [System.IO.File]::AppendAllText((Join-Path `$TargetRoot 'product.txt'),'failed drift')
    throw 'simulated failure after product drift'
}
$mutation
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'remediate.rollout')) {
    Write-Output 'Backed up and migrated tracked Agent artifacts: AGENTS.md, .github/copilot-instructions.md. Backup: C:\safe-backup'
    Write-Output 'Agent artifact remediation commit created: 0123456789012345678901234567890123456789'
}
Write-Output 'AI instructions synchronized as local ignored runtime artifacts without Git commit: AGENTS.md'
"@
}

Describe 'AI instructions all-repository rollout' {
    BeforeAll { Import-Module $script:RolloutModule -Force }

    # Given: A fixed-drive-shaped search root includes a product, authority clone, dependency cache, temp fixture, and official global Skill clone.
    # When: Rollout discovers repositories with the production exclusions and authority URLs.
    # Then: Only the product is synchronized, authority is reported skipped, and system/cached repositories are untouched.
    It 'InterT10_discovers_products_and_excludes_authority_cache_temp_and_official_skill_roots' {
        $searchRoot = Join-Path $TestDrive 'drive'
        $productRoot = Join-Path $searchRoot 'work\product'
        $authorityRoot = Join-Path $searchRoot 'work\authority'
        New-RolloutTestRepository -Path $productRoot
        New-RolloutTestRepository -Path $authorityRoot -Origin 'https://github.com/example/ai-instructions.git'
        New-RolloutTestRepository -Path (Join-Path $searchRoot 'work\node_modules\cached')
        New-RolloutTestRepository -Path (Join-Path $searchRoot 'Temp\fixture')
        New-RolloutTestRepository -Path (Join-Path $searchRoot '.agents\skills\felo-search')
        $bootstrap = Join-Path $TestDrive 'bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($searchRoot) -BootstrapPath $bootstrap `
            -AuthorityRepositoryUrls @('https://github.com/example/ai-instructions.git')

        $result.RepositoriesDiscovered | Should Be 2
        $result.RepositoriesSynchronized | Should Be 1
        @($result.Skipped).Count | Should Be 1
        [string]$result.Skipped[0].Reason | Should Match 'authority'
        @($result.RepositoryResults | Where-Object { $_.Repository -eq [System.IO.Path]::GetFullPath($productRoot) }).Count | Should Be 1
    }

    # Given: Overlapping search roots resolve the same worktree and another repository fails bootstrap.
    # When: Rollout processes all unique identities.
    # Then: The repository is not duplicated and a failure does not prevent the next repository from synchronizing.
    It 'InterT20_deduplicates_overlapping_roots_and_continues_after_repository_failure' {
        $searchRoot = Join-Path $TestDrive 'continue'
        $failedRoot = Join-Path $searchRoot 'a-failed'
        $successRoot = Join-Path $searchRoot 'b-success'
        New-RolloutTestRepository -Path $failedRoot
        New-RolloutTestRepository -Path $successRoot
        Set-RolloutTestText -Path (Join-Path $failedRoot 'fail.rollout') -Value 'fail'
        $bootstrap = Join-Path $TestDrive 'continue-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($searchRoot,$failedRoot) -BootstrapPath $bootstrap

        $result.RepositoriesDiscovered | Should Be 2
        $result.RepositoriesSynchronized | Should Be 1
        @($result.Failed).Count | Should Be 1
        [string]$result.Failed[0].Reason | Should Match 'simulated repository failure'
    }

    # Given: Bootstrap reports two tracked artifacts, a remediation commit, and an external backup.
    # When: Rollout records the repository result.
    # Then: Aggregate remediation metrics retain the exact paths, commit, and backup evidence.
    It 'InterT30_aggregates_remediation_paths_commits_and_backups' {
        $repository = Join-Path $TestDrive 'remediated'
        New-RolloutTestRepository -Path $repository
        Set-RolloutTestText -Path (Join-Path $repository 'remediate.rollout') -Value 'remediate'
        $bootstrap = Join-Path $TestDrive 'remediation-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.TrackedArtifactsDetected | Should Be 2
        $result.TrackedArtifactsRemediated | Should Be 2
        @($result.RemediationCommits).Count | Should Be 1
        [string]$result.RemediationCommits[0].Commit | Should Be '0123456789012345678901234567890123456789'
        @($result.Backups).Count | Should Be 1
        [string]$result.Backups[0].Path | Should Be 'C:\safe-backup'
    }

    # Given: A bootstrap reports success but leaves custom FELO content and a tracked reserved artifact.
    # When: The required post-rollout scan runs.
    # Then: The repository is failed with both unsafe postconditions instead of being counted synchronized.
    It 'InterT40_fails_post_scan_when_custom_felo_or_tracked_reserved_artifacts_remain' {
        $repository = Join-Path $TestDrive 'unsafe-postcondition'
        New-RolloutTestRepository -Path $repository
        Set-RolloutTestText -Path (Join-Path $repository 'AGENTS.md') -Value "tracked agent`n"
        Set-RolloutTestText -Path (Join-Path $repository '.agents\skills\search-with-felo\SKILL.md') -Value "retired`n"
        Invoke-RolloutTestGit -Repository $repository -Arguments @('add','--','AGENTS.md') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('commit','--quiet','-m','tracked agent') | Out-Null
        $bootstrap = Join-Path $TestDrive 'unsafe-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.CustomFeloActiveArtifactsRemaining).Count | Should Be 1
        @($result.TrackedReservedArtifactsRemaining).Count | Should Be 1
        [string]$result.Failed[0].Reason | Should Match 'post-rollout verification'
    }

    # Given: A defective bootstrap changes a production file while synchronizing Agent content.
    # When: Rollout compares non-Agent Git state before and after the call.
    # Then: It records drift and fails the repository without attempting any push.
    It 'InterT50_detects_non_agent_git_drift' {
        $repository = Join-Path $TestDrive 'product-drift'
        New-RolloutTestRepository -Path $repository
        $bootstrap = Join-Path $TestDrive 'mutating-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap -MutateProduct

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.NonAgentGitDrift).Count | Should Be 1
        [string]$result.Failed[0].Reason | Should Match 'non-Agent Git state changed'
        (Get-Content -Raw -LiteralPath $script:RolloutModule) | Should Not Match '(?m)^\s*&?\s*git\s+push\b'
    }

    # Given: A defective bootstrap changes a production file, leaves retired FELO content, and then throws.
    # When: Rollout records the failed repository and continues.
    # Then: Failure-path verification still reports non-Agent drift and remaining custom FELO artifacts.
    It 'InterT60_verifies_repository_state_even_when_bootstrap_throws' {
        $repository = Join-Path $TestDrive 'failed-with-drift'
        New-RolloutTestRepository -Path $repository
        Set-RolloutTestText -Path (Join-Path $repository 'fail-after-drift.rollout') -Value 'fail'
        Set-RolloutTestText -Path (Join-Path $repository '.agents\skills\search-with-felo\SKILL.md') -Value "retired`n"
        $bootstrap = Join-Path $TestDrive 'failure-drift-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.NonAgentGitDrift).Count | Should Be 1
        @($result.CustomFeloActiveArtifactsRemaining).Count | Should Be 1
        [string]$result.Failed[0].Reason | Should Match 'simulated failure after product drift'
        [string]$result.Failed[0].Reason | Should Match 'non-Agent Git state changed'
    }

    # Given: The caller relies on rollout's default fixed-drive discovery.
    # When: The report is produced without an explicit SearchRoots argument.
    # Then: The effective roots are retained in the report instead of being emitted as null.
    It 'InterT70_reports_effective_default_search_roots' {
        $repository = Join-Path $TestDrive 'default-search-root'
        New-RolloutTestRepository -Path $repository
        $bootstrap = Join-Path $TestDrive 'default-root-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap
        $global:RolloutTestDefaultSearchRoot = $repository
        Mock Get-AiInstructionsFixedSearchRoots { @($global:RolloutTestDefaultSearchRoot) } -ModuleName ai-instructions-rollout

        try { $result = Invoke-AiInstructionsRollout -BootstrapPath $bootstrap }
        finally { Remove-Variable -Name RolloutTestDefaultSearchRoot -Scope Global -ErrorAction SilentlyContinue }

        @($result.SearchRoots).Count | Should Be 1
        [string]$result.SearchRoots[0] | Should Be ([System.IO.Path]::GetFullPath($repository))
    }

    # Given: A reserved Agent artifact remains tracked in HEAD but already has a staged index deletion.
    # When: Post-rollout verification checks for unresolved tracked artifacts.
    # Then: It inspects the HEAD/index union and does not mistake the staged deletion for completed remediation.
    It 'InterT80_detects_HEAD_only_tracked_reserved_artifacts' {
        $repository = Join-Path $TestDrive 'head-only-tracked-agent'
        New-RolloutTestRepository -Path $repository
        Set-RolloutTestText -Path (Join-Path $repository 'AGENTS.md') -Value "tracked agent`n"
        Invoke-RolloutTestGit -Repository $repository -Arguments @('add','--','AGENTS.md') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('commit','--quiet','-m','tracked agent') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('rm','--cached','--','AGENTS.md') | Out-Null
        $bootstrap = Join-Path $TestDrive 'head-only-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.TrackedReservedArtifactsRemaining).Count | Should Be 1
        [string]$result.TrackedReservedArtifactsRemaining[0].Path | Should Be 'AGENTS.md'
    }
}
