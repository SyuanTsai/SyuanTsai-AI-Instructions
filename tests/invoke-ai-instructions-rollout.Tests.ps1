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
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $MutateProduct,
        [switch] $MutateClaudeRule
    )
    $mutation = if ($MutateProduct) {
        "[System.IO.File]::AppendAllText((Join-Path `$TargetRoot 'product.txt'),'drift')"
    }
    else { '' }
    $claudeMutation = if ($MutateClaudeRule) {
        "[System.IO.File]::AppendAllText((Join-Path `$TargetRoot '.claude\AI-Rules\Testing.md'),'drift')"
    }
    else { '' }
    Set-RolloutTestText -Path $Path -Value @"
param([string]`$TargetRoot,[switch]`$SkipUpdateCheck)
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'fail.rollout')) { throw 'simulated repository failure' }
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'fail-after-drift.rollout')) {
    [System.IO.File]::AppendAllText((Join-Path `$TargetRoot 'product.txt'),'failed drift')
    throw 'simulated failure after product drift'
}
if (-not (Test-Path -LiteralPath (Join-Path `$TargetRoot 'omit-claude-ownership-evidence.rollout'))) {
    & git -C `$TargetRoot ls-files --error-unmatch -- CLAUDE.md 2>&1 | Out-Null
    `$projectOwned = `$LASTEXITCODE -eq 0
    `$protectedPaths = @(if (`$projectOwned) { @('CLAUDE.md','.claude/AI-Rules','.claude/ai-instructions-licenses') })
    `$evidence = [ordered]@{
        schemaVersion = 1
        repository = [System.IO.Path]::GetFullPath(`$TargetRoot).TrimEnd([char[]]@('\','/'))
        projectOwned = `$projectOwned
        protectedPaths = `$protectedPaths
    }
    Write-Output ('AI instructions Claude ownership evidence: ' + (`$evidence | ConvertTo-Json -Compress))
}
$mutation
$claudeMutation
if (Test-Path -LiteralPath (Join-Path `$TargetRoot 'remediate.rollout')) {
    Write-Output 'Backed up and migrated tracked Agent artifacts: AGENTS.md, .github/copilot-instructions.md. Backup: C:\safe-backup'
    Write-Output 'Agent artifact remediation commit created: 0123456789012345678901234567890123456789'
}
Write-Output 'AI instructions synchronized as local ignored runtime artifacts without Git commit: AGENTS.md'
"@
}

function New-RolloutTestGitShim {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('inside_worktree','symbolic_HEAD','origin')][string] $FailurePoint,
        [Parameter(Mandatory = $true)][int] $ExitCode
    )
    if ($IsWindows) {
        $failureCommand = switch ($FailurePoint) {
            'inside_worktree' { 'if /I "%~3 %~4"=="rev-parse --is-inside-work-tree" exit /b {0}' -f $ExitCode }
            'symbolic_HEAD' { 'if /I "%~3 %~4 %~5 %~6"=="symbolic-ref -q --short HEAD" exit /b {0}' -f $ExitCode }
            'origin' { 'if /I "%~3 %~4 %~5"=="remote get-url origin" exit /b {0}' -f $ExitCode }
        }
        Set-RolloutTestText -Path $Path -Value @"
@echo off
$failureCommand
git %*
exit /b %ERRORLEVEL%
"@
        return
    }

    $failureCommand = switch ($FailurePoint) {
        'inside_worktree' { 'if [ "$3 $4" = "rev-parse --is-inside-work-tree" ]; then exit {0}; fi' -f $ExitCode }
        'symbolic_HEAD' { 'if [ "$3 $4 $5 $6" = "symbolic-ref -q --short HEAD" ]; then exit {0}; fi' -f $ExitCode }
        'origin' { 'if [ "$3 $4 $5" = "remote get-url origin" ]; then exit {0}; fi' -f $ExitCode }
    }
    Set-RolloutTestText -Path $Path -Value @"
#!/bin/sh
$failureCommand
exec git "`$@"
"@
    & chmod u+x -- $Path
    if ($LASTEXITCODE -ne 0) { throw "chmod failed for rollout test Git shim: $Path" }
}

Describe 'AI instructions all-repository rollout' {
    BeforeAll { Import-Module $script:RolloutModule -Force }

    # Scenario: Remediation and rollout classify the expanded multi-host reserved inventory.
    # Purpose: Keep Claude instruction namespaces reserved while all four project Skill roots remain protected.
    It 'UnitT90_keeps_rollout_and_remediation_reserved_path_classification_identical' {
        $remediationModule = Import-Module (Join-Path $script:RepositoryRoot 'scripts\agent-artifact-remediation.psm1') -Force -PassThru
        $rolloutModule = Get-Module ai-instructions-rollout
        $cases = @(
            @{ Path='AGENTS.md'; Expected=$true },
            @{ Path='CLAUDE.md'; Expected=$false },
            @{ Path='.claude/AI-Rules/Testing.en.md'; Expected=$true },
            @{ Path='.claude/ai-instructions-licenses/0123456789abcdef0123456789abcdef01234567/delivery.json'; Expected=$true },
            @{ Path='.agents/skills/example/SKILL.md'; Expected=$false },
            @{ Path='.codex/skills/example/SKILL.md'; Expected=$false },
            @{ Path='.claude/skills/example/SKILL.md'; Expected=$false },
            @{ Path='.github/skills/example/SKILL.md'; Expected=$false }
        )
        foreach ($case in $cases) {
            $remediation = & $remediationModule { param($path) Test-IsReservedAgentArtifactPath -Path $path } $case.Path
            $rollout = & $rolloutModule { param($path) Test-RolloutReservedAgentPath -Path $path } $case.Path
            $remediation | Should Be $case.Expected
            $rollout | Should Be $case.Expected
            $rollout | Should Be $remediation
        }
        $expectedRepository = Join-Path $TestDrive 'expected-repository'
        foreach ($mismatch in @(
            @{
                Line='AI instructions Claude ownership evidence: {"schemaVersion":1,"repository":"C:\\different-repository","projectOwned":true,"protectedPaths":["CLAUDE.md",".claude/AI-Rules",".claude/ai-instructions-licenses"]}'
                Reason='repository'
            },
            @{
                Line=('AI instructions Claude ownership evidence: {"schemaVersion":2,"repository":"' + ($expectedRepository.Replace('\','\\')) + '","projectOwned":false,"protectedPaths":[]}')
                Reason='schemaVersion'
            },
            @{
                Line=('AI instructions Claude ownership evidence: {"schemaVersion":1,"repository":"' + ($expectedRepository.Replace('\','\\')) + '","projectOwned":false,"protectedPaths":[".claude/AI-Rules"]}')
                Reason='protected paths'
            }
        )) {
            $parsed = & $rolloutModule {
                param($line,$repository)
                Get-RolloutClaudeOwnershipEvidence -OutputLines @($line) -ExpectedRepository $repository
            } $mismatch.Line $expectedRepository
            $parsed.Succeeded | Should Be $false
            [string]$parsed.FailureReason | Should Match $mismatch.Reason
        }
    }

    # Scenario: Rollout examines a valid v4 manifest against its bound v3 Lock projection identity.
    # Purpose: Accept current v4 state and reject projection or lock drift while retaining legacy v2/v3 reader behavior.
    It 'UnitT91_classifies_v4_rollout_current_by_lock_and_projection_identity' {
        $runtimeRoot=Join-Path $TestDrive 'v4-rollout-runtime'
        $scriptRoot=Join-Path $runtimeRoot 'scripts'
        New-Item -ItemType Directory -Force -Path $scriptRoot,(Join-Path $runtimeRoot 'catalog')|Out-Null
        foreach($leaf in @('ai-instructions-rollout.psm1','agent-artifact-remediation.psm1','skills-catalog-contract.psm1')){
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "scripts/$leaf") -Destination (Join-Path $scriptRoot $leaf)
        }
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/skills-catalog-lock-v3.example.json') -Destination (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json')
        $repository=Join-Path $TestDrive 'v4-rollout-repository';New-Item -ItemType Directory -Force -Path (Join-Path $repository '.codex')|Out-Null
        $manifestPath=Join-Path $repository '.codex/ai-instructions.manifest.json'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/managed-manifest-v4.example.json') -Destination $manifestPath
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $skillEntry=@($manifest.files|Where-Object artifactType -eq 'skill')[0]
        $skillPath=Join-Path $repository ([string]$skillEntry.targetPath)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath)|Out-Null
        [IO.File]::WriteAllBytes($skillPath,[byte[]]@(0,10,13,128,255))
        $skillEntry.sha256=(Get-FileHash -LiteralPath $skillPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-RolloutTestText -Path $manifestPath -Value (($manifest|ConvertTo-Json -Depth 20).Replace("`r`n","`n").TrimEnd())
        $expectedLock=[string]$manifest.lockSha256
        $fixtureModule=Import-Module (Join-Path $scriptRoot 'ai-instructions-rollout.psm1') -Force -PassThru
        try{
            (& $fixtureModule {param($repo,$lock) Test-RolloutManifestCurrent -Repository $repo -ExpectedLockSha256 $lock} $repository $expectedLock)|Should Be $true
            [IO.File]::WriteAllBytes($skillPath,[byte[]]@(1,2,3))
            (& $fixtureModule {param($repo,$lock) Test-RolloutManifestCurrent -Repository $repo -ExpectedLockSha256 $lock} $repository $expectedLock)|Should Be $false
            [IO.File]::WriteAllBytes($skillPath,[byte[]]@(0,10,13,128,255))
            (& $fixtureModule {param($repo) Test-RolloutManifestCurrent -Repository $repo -ExpectedLockSha256 ('0'*64)} $repository)|Should Be $false
            $manifest.projectionContractSha256='0'*64
            Set-RolloutTestText -Path $manifestPath -Value (($manifest|ConvertTo-Json -Depth 20).Replace("`r`n","`n").TrimEnd())
            (& $fixtureModule {param($repo,$lock) Test-RolloutManifestCurrent -Repository $repo -ExpectedLockSha256 $lock} $repository $expectedLock)|Should Be $false
        }
        finally{
            Remove-Module $fixtureModule -Force -ErrorAction SilentlyContinue
            Import-Module $script:RolloutModule -Force
        }
    }

    # Scenario: Repository discovery receives negative Windows process exit codes from each Git query that has a normal alternate result.
    # Purpose: Prevent launch failures and NTSTATUS values from being interpreted as non-repositories, detached or unborn HEADs, missing origins, or absent HEAD trees.
    It 'UnitT92_rejects_negative_<Case>_Git_exit_code_<ExitCodeLabel>' -TestCases @(
        foreach ($exitCase in @(
            @{ ExitCode=-1; ExitCodeLabel='minus_1' },
            @{ ExitCode=-1073741510; ExitCodeLabel='ntstatus_1073741510' }
        )) {
            foreach ($caseName in @('inside_worktree','symbolic_HEAD','verified_HEAD','origin','tracked_HEAD')) {
                @{ Case=$caseName; ExitCode=$exitCase.ExitCode; ExitCodeLabel=$exitCase.ExitCodeLabel }
            }
        }
    ) {
        param($Case,$ExitCode,$ExitCodeLabel)
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($script:RolloutModule,[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count | Should Be 0
        $functionName=if($Case-ceq'tracked_HEAD'){'Get-RolloutTrackedReservedPaths'}else{'Resolve-RolloutRepositoryIdentity'}
        $definition=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName},$true))[0].Extent.Text
        $message=& {
            param($text,$name,$caseName,$injectedExitCode,$repository)
            Invoke-Expression $text
            function Get-RolloutGitExitCode {
                param([string]$Repository,[string]$GitExecutable,[string[]]$Arguments)
                $query=$Arguments -join ' '
                if($caseName-ceq'inside_worktree'-and$query-ceq'rev-parse --is-inside-work-tree'){return $injectedExitCode}
                if($caseName-ceq'symbolic_HEAD'-and$query-ceq'symbolic-ref -q --short HEAD'){return $injectedExitCode}
                if($caseName-ceq'verified_HEAD'-and$query-ceq'rev-parse --verify --quiet HEAD'){return $injectedExitCode}
                if($caseName-ceq'origin'-and$query-ceq'remote get-url origin'){return $injectedExitCode}
                if($caseName-ceq'tracked_HEAD'-and$query-ceq'rev-parse --verify --quiet HEAD'){return $injectedExitCode}
                if($query-ceq'symbolic-ref -q --short HEAD' -and $caseName-ceq'verified_HEAD'){return 1}
                return 0
            }
            function Invoke-RolloutGit {
                param([string]$Repository,[string]$GitExecutable,[string[]]$Arguments)
                switch($Arguments -join ' '){
                    'rev-parse --is-inside-work-tree' { return 'true' }
                    'rev-parse --show-toplevel' { return $repository }
                    'rev-parse --git-common-dir' { return '.git' }
                    'symbolic-ref -q --short HEAD' { return 'main' }
                    'rev-parse --verify --quiet HEAD' { return ('a'*40) }
                    'remote get-url origin' { return 'https://example.com/team/product.git' }
                    '-c core.quotePath=true ls-files' { return 'AGENTS.md' }
                    default { return @() }
                }
            }
            function Get-RolloutFullPath { param([string]$Path);return [IO.Path]::GetFullPath($Path) }
            function ConvertFrom-RolloutGitPath { param([string]$Path);return $Path }
            function Test-RolloutReservedAgentPath { param([string]$Path,[string[]]$ProtectedPaths);return $true }
            try {
                if($name-ceq'Get-RolloutTrackedReservedPaths'){
                    Get-RolloutTrackedReservedPaths -Repository $repository -GitExecutable git -ProtectedPaths @() | Out-Null
                }
                else {
                    Resolve-RolloutRepositoryIdentity -Path $repository -GitExecutable git | Out-Null
                }
                $null
            }
            catch { $_.Exception.Message }
        } $definition $functionName $Case $ExitCode $TestDrive
        $message | Should Match ([regex]::Escape([string]$ExitCode))
    }

    # Scenario: Public repository discovery receives an undefined negative exit code from a Git identity query.
    # Purpose: Ensure discovery fails closed instead of reporting zero discovered repositories and zero failures.
    # Register only on the native host because negative and NTSTATUS native process exit codes are Windows semantics.
    if ($IsWindows) {
      It 'UnitT93_rethrows_discovery_<Case>_Git_exit_code_<ExitCodeLabel>' -TestCases @(
        foreach ($exitCase in @(
            @{ ExitCode=-1; ExitCodeLabel='minus_1' },
            @{ ExitCode=-1073741510; ExitCodeLabel='ntstatus_1073741510' }
        )) {
            foreach ($caseName in @('inside_worktree','symbolic_HEAD','origin')) {
                @{ Case=$caseName; ExitCode=$exitCase.ExitCode; ExitCodeLabel=$exitCase.ExitCodeLabel }
            }
        }
    ) {
        param($Case,$ExitCode,$ExitCodeLabel)
        $repository = Join-Path $TestDrive ("discovery-$Case-$ExitCodeLabel")
        New-RolloutTestRepository -Path $repository
        $fakeGit = Join-Path $TestDrive ("fake-git-$Case-$ExitCodeLabel.cmd")
        New-RolloutTestGitShim -Path $fakeGit -FailurePoint $Case -ExitCode $ExitCode

        $failure = $null
        try { Get-AiInstructionsRepositoryRoots -SearchRoots @($repository) -GitExecutable $fakeGit | Out-Null }
        catch { $failure = $_.Exception }

        $failure | Should Not BeNullOrEmpty
        [string]$failure.Message | Should Match ([regex]::Escape([string]$ExitCode))
      }
    }

    # Scenario: Public repository discovery finds a .git marker for which Git returns documented fatal exit code 128.
    # Purpose: Preserve the existing behavior that skips an unusable repository marker without failing rollout.
    It 'UnitT94_skips_discovery_marker_when_inside_worktree_returns_128' {
        $candidate = Join-Path $TestDrive 'invalid-git-marker'
        New-Item -ItemType Directory -Force -Path $candidate | Out-Null
        Set-RolloutTestText -Path (Join-Path $candidate '.git') -Value 'invalid marker'
        $fakeGit = Join-Path $TestDrive 'fake-git-fatal-128.cmd'
        New-RolloutTestGitShim -Path $fakeGit -FailurePoint inside_worktree -ExitCode 128

        $failure = $null
        try { $repositories = @(Get-AiInstructionsRepositoryRoots -SearchRoots @($candidate) -GitExecutable $fakeGit) }
        catch { $failure = $_.Exception }

        $failure | Should BeNullOrEmpty
        @($repositories).Count | Should Be 0
    }

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

    # Given: One bootstrap reports success but leaves custom FELO content and a tracked reserved artifact, while another repository owns its Claude family.
    # When: The required post-rollout scan runs.
    # Then: The unsafe repository fails, while project-owned Claude rules do not count as reserved pollution.
    It 'InterT40_fails_post_scan_when_custom_felo_or_tracked_reserved_artifacts_remain' {
        $searchRoot = Join-Path $TestDrive 'postconditions'
        $repository = Join-Path $searchRoot 'unsafe-postcondition'
        $projectOwnedRepository = Join-Path $searchRoot 'project-owned-claude'
        New-RolloutTestRepository -Path $repository
        New-RolloutTestRepository -Path $projectOwnedRepository
        Set-RolloutTestText -Path (Join-Path $repository 'AGENTS.md') -Value "tracked agent`n"
        Set-RolloutTestText -Path (Join-Path $repository '.agents\skills\search-with-felo\SKILL.md') -Value "retired`n"
        Invoke-RolloutTestGit -Repository $repository -Arguments @('add','--','AGENTS.md') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('commit','--quiet','-m','tracked agent') | Out-Null
        Set-RolloutTestText -Path (Join-Path $projectOwnedRepository 'CLAUDE.md') -Value "project-owned Claude`n"
        Set-RolloutTestText -Path (Join-Path $projectOwnedRepository '.claude\AI-Rules\Testing.md') -Value "project rule`n"
        Invoke-RolloutTestGit -Repository $projectOwnedRepository -Arguments @('add','--','CLAUDE.md','.claude/AI-Rules/Testing.md') | Out-Null
        Invoke-RolloutTestGit -Repository $projectOwnedRepository -Arguments @('commit','--quiet','-m','project-owned Claude') | Out-Null
        $bootstrap = Join-Path $TestDrive 'unsafe-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($searchRoot) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 1
        @($result.CustomFeloActiveArtifactsRemaining).Count | Should Be 1
        @($result.TrackedReservedArtifactsRemaining).Count | Should Be 1
        @($result.TrackedReservedArtifactsRemaining | Where-Object Repository -eq ([IO.Path]::GetFullPath($projectOwnedRepository))).Count | Should Be 0
        [string]$result.Failed[0].Reason | Should Match 'post-rollout verification'
    }

    # Given: A defective bootstrap changes a production file, and another changes a tracked project-owned Claude rule.
    # When: Rollout compares non-Agent Git state before and after the call.
    # Then: It records both kinds of drift and fails both repositories without attempting any push.
    It 'InterT50_detects_non_agent_git_drift' {
        $repository = Join-Path $TestDrive 'product-drift'
        New-RolloutTestRepository -Path $repository
        $bootstrap = Join-Path $TestDrive 'mutating-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap -MutateProduct

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.NonAgentGitDrift).Count | Should Be 1
        [string]$result.Failed[0].Reason | Should Match 'non-Agent Git state changed'

        $claudeRepository = Join-Path $TestDrive 'project-owned-claude-drift'
        New-RolloutTestRepository -Path $claudeRepository
        Set-RolloutTestText -Path (Join-Path $claudeRepository 'CLAUDE.md') -Value "project-owned Claude`n"
        Set-RolloutTestText -Path (Join-Path $claudeRepository '.claude\AI-Rules\Testing.md') -Value "project rule`n"
        Invoke-RolloutTestGit -Repository $claudeRepository -Arguments @('add','--','CLAUDE.md','.claude/AI-Rules/Testing.md') | Out-Null
        Invoke-RolloutTestGit -Repository $claudeRepository -Arguments @('commit','--quiet','-m','project-owned Claude') | Out-Null
        $claudeBootstrap = Join-Path $TestDrive 'mutating-claude-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $claudeBootstrap -MutateClaudeRule

        $claudeResult = Invoke-AiInstructionsRollout -SearchRoots @($claudeRepository) -BootstrapPath $claudeBootstrap

        $claudeResult.RepositoriesSynchronized | Should Be 0
        @($claudeResult.NonAgentGitDrift).Count | Should Be 1
        @($claudeResult.NonAgentGitDrift[0].After | Where-Object { $_ -match '\.claude/AI-Rules/Testing\.md' }).Count | Should Be 1
        @($claudeResult.TrackedReservedArtifactsRemaining).Count | Should Be 0
        [string]$claudeResult.Failed[0].Reason | Should Match 'non-Agent Git state changed'
        (Get-Content -Raw -LiteralPath $script:RolloutModule) | Should Not Match '(?m)^\s*&?\s*git\s+push\b'
    }

    # Given: A defective bootstrap changes a production file, leaves retired FELO content, and then throws.
    # When: Rollout records the failed repository and continues.
    # Then: Failure-path verification still reports non-Agent drift and remaining custom FELO artifacts.
    It 'InterT60_verifies_repository_state_even_when_bootstrap_throws' {
        $searchRoot = Join-Path $TestDrive 'failed-verification'
        $repository = Join-Path $searchRoot 'failed-with-drift'
        $missingEvidenceRepository = Join-Path $searchRoot 'missing-evidence'
        New-RolloutTestRepository -Path $repository
        New-RolloutTestRepository -Path $missingEvidenceRepository
        Set-RolloutTestText -Path (Join-Path $repository 'fail-after-drift.rollout') -Value 'fail'
        Set-RolloutTestText -Path (Join-Path $repository '.agents\skills\search-with-felo\SKILL.md') -Value "retired`n"
        Set-RolloutTestText -Path (Join-Path $missingEvidenceRepository 'omit-claude-ownership-evidence.rollout') -Value 'omit'
        $bootstrap = Join-Path $TestDrive 'failure-drift-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($searchRoot) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.NonAgentGitDrift).Count | Should Be 1
        @($result.CustomFeloActiveArtifactsRemaining).Count | Should Be 1
        @($result.Failed).Count | Should Be 2
        $bootstrapFailure = @($result.Failed | Where-Object Repository -eq ([IO.Path]::GetFullPath($repository)))[0]
        [string]$bootstrapFailure.Reason | Should Match 'simulated failure after product drift'
        [string]$bootstrapFailure.Reason | Should Match 'non-Agent Git state changed'
        [string]$bootstrapFailure.Reason | Should Match 'Claude ownership evidence'
        $evidenceFailure = @($result.Failed | Where-Object Repository -eq ([IO.Path]::GetFullPath($missingEvidenceRepository)))[0]
        [string]$evidenceFailure.Reason | Should Match 'Claude ownership evidence'
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

    # Given: Default discovery obtains ready fixed-drive roots from the operating system.
    # When: Those roots pass through rollout path canonicalization.
    # Then: Each value remains an absolute filesystem root instead of becoming drive-relative (for example, C:).
    # Register only on the native host because fixed-drive enumeration is a Windows drive model.
    if ($IsWindows) {
      It 'InterT75_preserves_absolute_fixed_drive_roots' {
        $roots = @(Get-AiInstructionsFixedSearchRoots)

        $roots.Count | Should BeGreaterThan 0
        foreach ($root in $roots) {
            $expectedRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath([string]$root))
            [string]$root | Should Be $expectedRoot
        }
      }
    }

    # Given: A reserved Agent artifact remains tracked in HEAD but already has a staged index deletion.
    # When: Post-rollout verification checks for unresolved tracked artifacts.
    # Then: It inspects the HEAD/index union and does not mistake the staged deletion for completed remediation.
    It 'InterT80_detects_HEAD_only_tracked_reserved_artifacts' {
        $repository = Join-Path $TestDrive 'head-only-tracked-agent'
        New-RolloutTestRepository -Path $repository
        Set-RolloutTestText -Path (Join-Path $repository 'AGENTS.md') -Value "tracked agent`n"
        Set-RolloutTestText -Path (Join-Path $repository '.claude\AI-Rules\Testing.md') -Value "unowned Claude rule`n"
        Invoke-RolloutTestGit -Repository $repository -Arguments @('add','--','AGENTS.md','.claude/AI-Rules/Testing.md') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('commit','--quiet','-m','tracked agent') | Out-Null
        Invoke-RolloutTestGit -Repository $repository -Arguments @('rm','--cached','--','AGENTS.md') | Out-Null
        $bootstrap = Join-Path $TestDrive 'head-only-bootstrap.ps1'
        New-RolloutTestBootstrap -Path $bootstrap

        $result = Invoke-AiInstructionsRollout -SearchRoots @($repository) -BootstrapPath $bootstrap

        $result.RepositoriesSynchronized | Should Be 0
        @($result.TrackedReservedArtifactsRemaining).Count | Should Be 2
        @($result.TrackedReservedArtifactsRemaining.Path) | Should Contain 'AGENTS.md'
        @($result.TrackedReservedArtifactsRemaining.Path) | Should Contain '.claude/AI-Rules/Testing.md'
        $rolloutModule = Get-Module ai-instructions-rollout
        $reservedWithExplicitUnownedEvidence = @(& $rolloutModule {
            param($repo)
            Get-RolloutTrackedReservedPaths -Repository $repo -GitExecutable 'git' -ProtectedPaths @()
        } $repository)
        @($reservedWithExplicitUnownedEvidence) | Should Contain '.claude/AI-Rules/Testing.md'
    }
}
