Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersionRule = 'latest-stable'
        $script:WorkflowExpectations = [ordered]@{
            '.github/workflows/pr8-powershell-validation.yml' = 1
            '.github/workflows/standards-conformance.yml' = 1
            '.github/workflows/syp101-production-smoke.yml' = 1
            '.github/workflows/syp86-production-lock.yml' = 1
            '.github/workflows/validator-maintenance-producer.yml' = 1
        }
        $script:AuthorityTests = @(
            'skill-repository-standard.Tests.ps1'
            'skill-repository-workflows.Tests.ps1'
            'standard-authority-entry-preflight.Tests.ps1'
            'standard-entry-point-binding.Tests.ps1'
            'standard-core-pester-adapter.Tests.ps1'
        )
        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Assert-NotMatch {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -match $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Get-PesterExecutorFunction {
            param([Parameter(Mandatory = $true)][string] $Name)

            $executorPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($executorPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) { throw "Could not parse the Pester shard executor: $($parseErrors[0].Message)" }
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                Where-Object { $_.Name -ceq $Name })
            if ($functions.Count -ne 1) { throw "Expected exactly one executor function named '$Name'; found $($functions.Count)." }
            return [scriptblock]::Create($functions[0].Extent.Text)
        }

        function Assert-Throws {
            param([Parameter(Mandatory = $true)][scriptblock] $Action, [Parameter(Mandatory = $true)][string] $Message)

            $threw = $false
            try { & $Action | Out-Null } catch { $threw = $true }
            if (-not $threw) { throw $Message }
        }

        function Write-TestUtf8File {
            param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-ConsumerEntryPointFixture {
            param([Parameter(Mandatory = $true)][string] $Root)

            [void](New-Item -ItemType Directory -Path $Root -Force)
            Write-TestUtf8File -Path (Join-Path $Root 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
            Write-TestUtf8File -Path (Join-Path $Root '.github/workflows/validate.yml') -Text @'
name: Canonical validation
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        }
    }

    # Scenario: A workflow checkout is changed back to a mutable tag or leaves its token in Git config.
    # Purpose: Bind every production and authority checkout to the reviewed action commit without ambient credentials.
    It 'UnitT10_pins_every_checkout_and_disables_persisted_credentials' {
        foreach ($entry in $script:WorkflowExpectations.GetEnumerator()) {
            $path = Join-Path $script:RepositoryRoot ([string]$entry.Key)
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing workflow '$($entry.Key)'."
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            $checkoutPattern = "actions/checkout@$($script:CheckoutSha)\s+# v7"
            Assert-Equal ([regex]::Matches($workflow, $checkoutPattern)).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must use the reviewed immutable v7 commit."
            Assert-Equal ([regex]::Matches($workflow, 'persist-credentials:\s*false')).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must disable persisted credentials."
            Assert-NotMatch $workflow 'actions/checkout@v[0-9]+' "Workflow '$($entry.Key)' must not use a mutable checkout tag."
        }
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        Assert-Equal ([regex]::Matches($required, 'Import-Module \$pester\.Path -Force')).Count 0 'Core must leave module execution inside the bounded child executor.'
        Assert-Equal ([regex]::Matches($required, '& ./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 1 'Core must run the retained Pester difference through the bounded executor once.'
        Assert-Match $required 'SelectedTestFileNames = \$selectedTestNames' 'Core must select the complete non-authority difference.'
    }

    # Scenario: The required workflow fans the suite across retired runtimes and duplicate platforms.
    # Purpose: Keep one Windows Core job, one Windows Install Smoke job, and verified PowerShell provenance.
    It 'UnitT15_ordinary_workflows_use_verified_Windows_PowerShell_only' {
        $workflowDirectory = Join-Path $script:RepositoryRoot '.github/workflows'
        $workflowPaths = @(Get-ChildItem -LiteralPath $workflowDirectory -File |
            Where-Object { $_.Extension -in @('.yml', '.yaml') } |
            ForEach-Object { [IO.Path]::GetRelativePath($script:RepositoryRoot, $_.FullName).Replace('\', '/') })
        $expectedWorkflowPaths = @(
            '.github/workflows/pr8-powershell-validation.yml',
            '.github/workflows/standards-conformance.yml',
            '.github/workflows/syp101-production-smoke.yml',
            '.github/workflows/syp86-production-lock.yml',
            '.github/workflows/validator-maintenance-producer.yml'
        )
        Assert-Equal $workflowPaths.Count $expectedWorkflowPaths.Count 'R4 must retain exactly the five registered active workflow files.'
        Assert-Equal (($workflowPaths | Sort-Object) -join '|') (($expectedWorkflowPaths | Sort-Object) -join '|') 'The workflow inventory must retire the unmatched protected maintenance consumer and reject unreviewed workflow additions.'
        $pullRequestWorkflows = New-Object 'System.Collections.Generic.List[string]'
        $pullRequestJobNames = New-Object 'System.Collections.Generic.List[string]'
        foreach ($relativePath in $workflowPaths) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot $relativePath)
            if ([regex]::IsMatch($workflow, '(?m)^  pull_request:\s*$')) {
                $pullRequestWorkflows.Add($relativePath)
                $jobsBlock = [regex]::Match($workflow, '(?ms)^jobs:\r?\n(?<block>.*)\z')
                Assert-True $jobsBlock.Success "Workflow '$relativePath' must define its jobs block."
                $jobMatches = [regex]::Matches($jobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
                Assert-Equal $jobMatches.Count 1 "Ordinary pull-request workflow '$relativePath' must have exactly one job."
                $pullRequestJobNames.Add($jobMatches[0].Groups[1].Value)
            }
            Assert-NotMatch $workflow 'windows-powershell-51|PowerShell 5\.1|Pester 3\.4\.0|shell:\s*powershell|runs-on:\s*ubuntu-latest|shell:\s*bash' "Workflow '$relativePath' must not retain a retired PowerShell 5.1 or Linux CI lane."
            Assert-NotMatch $workflow '(?ms)^\s*&\s+\./scripts/[^\r\n]+\.ps1[^\r\n]*\r?\n\s*if\s*\(\s*\$LASTEXITCODE' "Workflow '$relativePath' must use PowerShell success state or exceptions after PowerShell script calls, not a stale native exit code."
            Assert-NotMatch $workflow 'Get-Module Pester -ListAvailable -Name Pester' "Workflow '$relativePath' must not pass Pester both positionally and through -Name."
            Assert-Match $workflow 'runs-on:\s*windows-latest' "Workflow '$relativePath' must run on Windows."
            Assert-Match $workflow "version = '7\.6\.6'" "Workflow '$relativePath' must pin the reviewed latest stable PowerShell release."
            Assert-Match $workflow '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860' "Workflow '$relativePath' must verify the reviewed PowerShell ZIP SHA256."
            Assert-Match $workflow 'Get-FileHash -LiteralPath \$archivePath -Algorithm SHA256' "Workflow '$relativePath' must hash the archive before use."
            Assert-Match $workflow 'Expand-Archive -LiteralPath \$archivePath' "Workflow '$relativePath' must use the verified portable archive."
            Assert-Match $workflow 'GITHUB_PATH' "Workflow '$relativePath' must put portable pwsh first for later steps."
            Assert-Match $workflow 'MainModule\.FileName' "Workflow '$relativePath' must verify the actual shell process executable."
            Assert-Match $workflow '\$PSHOME' "Workflow '$relativePath' must verify the active PowerShell home."
            Assert-Match $workflow '\$PSVersionTable\.PSVersion' "Workflow '$relativePath' must verify the active runtime version."
        }
        Assert-Equal $pullRequestWorkflows.Count 2 'Exactly the Core and Install Smoke workflows may run for ordinary pull requests.'
        $expectedPullRequestWorkflows = @(
            '.github/workflows/pr8-powershell-validation.yml',
            '.github/workflows/syp101-production-smoke.yml'
        )
        Assert-Equal (($pullRequestWorkflows.ToArray() | Sort-Object) -join '|') (($expectedPullRequestWorkflows | Sort-Object) -join '|') 'No Linux, SYP86, Standards, or maintenance workflow may add an ordinary pull-request job.'
        $expectedPullRequestJobNames = @('windows-core', 'windows-install-smoke')
        Assert-Equal (($pullRequestJobNames.ToArray() | Sort-Object) -join '|') (($expectedPullRequestJobNames | Sort-Object) -join '|') 'Ordinary pull-request CI must aggregate to exactly Windows Core and Windows Install Smoke.'

        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml')
        $smoke = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/syp101-production-smoke.yml')
        $executor = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1')
        $coreJobsBlock = [regex]::Match($required, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        $smokeJobsBlock = [regex]::Match($smoke, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        Assert-True $coreJobsBlock.Success 'PowerShell Regression must define its jobs block.'
        Assert-True $smokeJobsBlock.Success 'SYP101 must define its jobs block.'
        $coreJobs = [regex]::Matches($coreJobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        $smokeJobs = [regex]::Matches($smokeJobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        Assert-Equal $coreJobs.Count 1 'PowerShell Regression must have one retained normal CI job.'
        Assert-Equal $coreJobs[0].Groups[1].Value 'windows-core' 'The sole PowerShell Regression job must be Windows Core.'
        Assert-Equal $smokeJobs.Count 1 'SYP101 must have one retained normal CI job.'
        Assert-Equal $smokeJobs[0].Groups[1].Value 'windows-install-smoke' 'The sole SYP101 job must be Windows Install Smoke.'
        Assert-NotMatch $required '(?m)^\s+needs:' 'Windows Core must not depend on a retired job.'
        Assert-NotMatch $smoke '(?m)^\s+needs:' 'Windows Install Smoke must not depend on a retired job.'
        Assert-Match $required 'timeout-minutes:\s*180' 'The sequential Core suite must have a bounded job-level timeout.'
        Assert-Match $required 'PesterVersion = ''4\.10\.1''' 'The retained suite must use the established Pester 4.10.1 engine.'
        Assert-Match $required '\$pester = Get-Module -ListAvailable -Name Pester' 'Core must discover the installed Pester module with a valid parameter binding.'
        Assert-Equal ([regex]::Matches($required, '& \./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 1 'Core must use the existing bounded executor exactly once.'
        Assert-Equal ([regex]::Matches($required, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Windows Core must execute the authority gate exactly once.'
        Assert-Match $required 'SelectedTestFileNames = \$selectedTestNames' 'Core must pass the dynamically discovered non-authority difference to the bounded executor.'
        Assert-Match $required 'ShardPartitionCount = 1' 'Core must execute the retained difference as one bounded schedule.'
        Assert-Match $required 'ExpectedSkippedCount = 5' 'Core must bind the five intentional Windows skips from the Unix-only source acquisition fixtures to the real Pester summary.'
        Assert-Match $executor "ValidateSet\('4\.10\.1'\)" 'The bounded executor must retire the Pester 3.4/Windows PowerShell 5.1 lane.'
        Assert-Match $executor 'requires Windows PowerShell 7' 'The bounded executor must fail closed outside Windows PowerShell 7.'
        Assert-Match $executor 'MainModule\.FileName' 'The bounded child must inherit the verified runner executable.'
        Assert-NotMatch $executor 'PlatformID\]::Unix|PesterShardLinux|/proc|Pester 3\.4\.0|Windows PowerShell 5\.1' 'The bounded executor must not retain retired Unix process or legacy Pester paths.'
        Assert-NotMatch $required 'Run cross-platform composition and acquisition tests' 'Source composition and acquisition must not run a second time outside full Core discovery.'
        foreach ($authorityTest in $script:AuthorityTests) {
            Assert-Match $required ([regex]::Escape("'tests/$authorityTest'")) "Core must exclude the authority-only test '$authorityTest' from its second execution."
        }
        Assert-Match $required 'Run offline routine semantic fixtures once' 'Core must retain offline semantic fixtures in the single Windows job.'
        Assert-Match $required "pattern='test_routine_semantic_\*\.py'" 'Core must keep exact offline fixture discovery.'
        Assert-Match $required 'Exact offline fixture count changed' 'Core must keep its fixture coverage count assertion.'
        Assert-Match $smoke 'update-skills-catalog-lock\.ps1 -Check' 'Install Smoke must absorb production lock validation.'
        Assert-Match $smoke 'test-syp101-production-smoke\.ps1' 'Install Smoke must keep the real pinned-archive installation and idempotence exercise.'
    }
    # Scenario: A new discovered Pester file is added while the isolated-file set remains stable.
    # Purpose: Prove the pure planner assigns every path exactly once, preserves exact coverage across logical partitions, and rejects duplicate or missing inventory entries.
    It 'UnitT16_plans_dynamic_inventory_with_exact_four_partition_coverage' {
        $plannerScript = Get-PesterExecutorFunction -Name 'New-PesterShardPlan'
        . $plannerScript

        $isolatedNames = @('standard-validation-runner.Tests.ps1', 'syp101-production-smoke-contract.Tests.ps1')
        $newBindingTest = Join-Path 'inventory-root' 'standard-entry-point-binding.Tests.ps1'
        $allTestPaths = @(
            (Join-Path 'inventory-root' 'standard-validation-runner.Tests.ps1')
            (Join-Path 'inventory-root' 'syp101-production-smoke-contract.Tests.ps1')
            (Join-Path 'inventory-root' 'bulk-alpha.Tests.ps1')
            (Join-Path 'inventory-root' 'bulk-omega.Tests.ps1')
            $newBindingTest
        )
        $plan = @(New-PesterShardPlan -AllTestPaths $allTestPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1)
        $plannedPaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($shard in $plan) { foreach ($path in @($shard.Paths)) { $plannedPaths.Add([string]$path) } }
        Assert-Equal $plannedPaths.Count $allTestPaths.Count 'The isolated and bulk plan must include each discovered path.'
        Assert-Equal @($plannedPaths.ToArray() | Select-Object -Unique).Count $allTestPaths.Count 'A path must appear in exactly one shard.'
        Assert-Equal @($plannedPaths.ToArray() | Where-Object { $_ -ceq $newBindingTest }).Count 1 'The added binding test must be planned exactly once.'
        [string[]]$plannedOrdinal = @($plannedPaths.ToArray())
        [Array]::Sort($plannedOrdinal, [StringComparer]::Ordinal)
        [string[]]$discoveredOrdinal = @($allTestPaths)
        [Array]::Sort($discoveredOrdinal, [StringComparer]::Ordinal)
        Assert-Equal ($plannedOrdinal -join '|') ($discoveredOrdinal -join '|') 'The planner union must equal complete discovery.'

        $partitionedPaths = New-Object 'System.Collections.Generic.List[string]'
        for ($partitionIndex = 0; $partitionIndex -lt 4; $partitionIndex++) {
            for ($shardIndex = 0; $shardIndex -lt $plan.Count; $shardIndex++) {
                if (($shardIndex % 4) -eq $partitionIndex) {
                    foreach ($path in @($plan[$shardIndex].Paths)) { $partitionedPaths.Add([string]$path) }
                }
            }
        }
        Assert-Equal $partitionedPaths.Count $allTestPaths.Count 'The four partitions must retain the complete file inventory.'
        Assert-Equal @($partitionedPaths.ToArray() | Select-Object -Unique).Count $allTestPaths.Count 'The four partitions must assign each discovered file exactly once.'
        [string[]]$partitionedOrdinal = @($partitionedPaths.ToArray())
        [Array]::Sort($partitionedOrdinal, [StringComparer]::Ordinal)
        Assert-Equal ($partitionedOrdinal -join '|') ($discoveredOrdinal -join '|') 'The four-partition union must equal complete discovery.'
        Assert-Equal @($partitionedPaths.ToArray() | Where-Object { $_ -ceq $newBindingTest }).Count 1 'The added binding test must appear in exactly one runtime partition.'

        $duplicatePaths = @($allTestPaths) + @($allTestPaths[2])
        Assert-Throws { New-PesterShardPlan -AllTestPaths $duplicatePaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1 } 'The planner must reject a duplicate discovered path.'
        $missingIsolatedPaths = @($allTestPaths | Where-Object { (Split-Path -Leaf $_) -cne $isolatedNames[1] })
        Assert-Throws { New-PesterShardPlan -AllTestPaths $missingIsolatedPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1 } 'The planner must reject a missing isolated test file.'
    }

    # Scenario: Pester returns shard and aggregate summaries that may be empty, malformed, failed, pending, or skipped.
    # Purpose: Accept truthful typed counts including platform skips, while refusing empty or incomplete results and a fully skipped aggregate.
    It 'UnitT17_rejects_empty_or_untruthful_summary_counts' {
        $assertCountsScript = Get-PesterExecutorFunction -Name 'Assert-PesterShardResultCounts'
        . $assertCountsScript

        $validSummary = [pscustomobject][ordered]@{
            TotalCount = [int]3
            PassedCount = [int]2
            FailedCount = [int]0
            SkippedCount = [int]1
            PendingCount = [int]0
            InconclusiveCount = [int]0
        }
        Assert-PesterShardResultCounts -Summary $validSummary -Context 'shard'
        $allSkippedSummary = [pscustomobject][ordered]@{
            TotalCount = [int]2
            PassedCount = [int]0
            FailedCount = [int]0
            SkippedCount = [int]2
            PendingCount = [int]0
            InconclusiveCount = [int]0
        }
        Assert-PesterShardResultCounts -Summary $allSkippedSummary -Context 'shard'
        Assert-Throws { Assert-PesterShardResultCounts -Summary $allSkippedSummary -Context 'aggregate' } 'An aggregate with no passed tests must be rejected.'

        $zeroSummary = [pscustomobject]@{ TotalCount = 0; PassedCount = 0; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $zeroSummary -Context 'shard' } 'A zero-test result must be rejected.'
        $stringSummary = [pscustomobject]@{ TotalCount = '1'; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $stringSummary -Context 'shard' } 'A string count must be rejected.'
        $negativeSummary = [pscustomobject]@{ TotalCount = 1; PassedCount = 2; FailedCount = 0; SkippedCount = -1; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $negativeSummary -Context 'shard' } 'A negative result count must be rejected.'
        foreach ($field in @('FailedCount', 'PendingCount', 'InconclusiveCount')) {
            $badSummary = [ordered]@{ TotalCount = 1; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
            $badSummary[$field] = [int]1
            Assert-Throws { Assert-PesterShardResultCounts -Summary ([pscustomobject]$badSummary) -Context 'shard' } "A nonzero $field must be rejected."
        }
        $incompleteSummary = [pscustomobject]@{ TotalCount = 2; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $incompleteSummary -Context 'shard' } 'Counts that do not cover total results must be rejected.'
    }

    # Scenario: Multiple workflows can silently add normal pull-request CI, duplicate the authority gate, or reuse an outdated platform lane.
    # Purpose: Keep exactly Core and Install Smoke automatic while retaining Windows-only manual and push diagnostics.
    It 'UnitT20_keeps_two_Windows_PR_jobs_and_single_authority_gate' {
        $paths = [ordered]@{
            Core = '.github/workflows/pr8-powershell-validation.yml'
            Standards = '.github/workflows/standards-conformance.yml'
            Smoke = '.github/workflows/syp101-production-smoke.yml'
            Lock = '.github/workflows/syp86-production-lock.yml'
            Maintenance = '.github/workflows/validator-maintenance-producer.yml'
        }
        $workflows = [ordered]@{}
        foreach ($entry in $paths.GetEnumerator()) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot $entry.Value)
            $workflows[$entry.Key] = $workflow
            Assert-Match $workflow 'permissions:\s*contents:\s*read' "$($entry.Key) workflow must use read-only repository permissions."
            Assert-NotMatch $workflow 'sourceMergeExceptionProposal|pr12-source-merge-exception-proposal|sourceMergeDecision|pr12-source-merge-adoption' "$($entry.Key) workflow must not route or publish unrelated source-adoption contexts."
            Assert-NotMatch $workflow 'actions/setup-go|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH|GITHUB_TOKEN' "$($entry.Key) workflow must not restore retired external resolver dependencies."
        }

        $coreEvents = [regex]::Match($workflows.Core, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $smokeEvents = [regex]::Match($workflows.Smoke, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $standardsEvents = [regex]::Match($workflows.Standards, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $lockEvents = [regex]::Match($workflows.Lock, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $maintenanceEvents = [regex]::Match($workflows.Maintenance, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        foreach ($pair in @(@{ Name='Core'; Events=$coreEvents }, @{ Name='Smoke'; Events=$smokeEvents })) {
            $pullRequest = [regex]::Match($pair.Events, '(?ms)^  pull_request:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
            $push = [regex]::Match($pair.Events, '(?ms)^  push:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
            Assert-True $pullRequest.Success "$($pair.Name) must run on ordinary pull requests."
            Assert-True $push.Success "$($pair.Name) must run on its configured push branches."
            Assert-Match $pullRequest.Groups['block'].Value '(?m)^\s*branches:\s*$' "$($pair.Name) pull requests must remain branch scoped."
            Assert-Match $pullRequest.Groups['block'].Value '(?m)^\s*-\s*main\s*$' "$($pair.Name) must cover main pull requests."
            Assert-NotMatch $pullRequest.Groups['block'].Value '(?m)^\s+paths(-ignore)?:\s*$' "$($pair.Name) must not filter the ordinary PR check."
            Assert-Match $workflows[$pair.Name] 'runs-on:\s*windows-latest' "$($pair.Name) must use Windows."
        }
        foreach ($entry in @(@{ Name='Standards'; Events=$standardsEvents }, @{ Name='Maintenance'; Events=$maintenanceEvents })) {
            $triggers = [regex]::Matches($entry.Events, '(?m)^  ([a-z_]+):\s*$')
            Assert-Equal $triggers.Count 1 "$($entry.Name) diagnostic must have exactly one manual trigger."
            Assert-Equal $triggers[0].Groups[1].Value 'workflow_dispatch' "$($entry.Name) diagnostic must be manual and outside ordinary PR CI."
        }
        $lockTriggers = [regex]::Matches($lockEvents, '(?m)^  ([a-z_]+):\s*$')
        $expectedLockTriggers = @('push', 'workflow_dispatch')
        Assert-Equal $lockTriggers.Count $expectedLockTriggers.Count 'SYP86 lock diagnostic must retain a push filter and manual trigger.'
        Assert-Equal (($lockTriggers | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join '|') (($expectedLockTriggers | Sort-Object) -join '|') 'SYP86 lock diagnostic may run only on path-filtered push or manual dispatch.'
        Assert-Match $lockEvents '(?ms)^  push:\r?\n.*?^    paths:\s*$' 'SYP86 lock diagnostics may remain path-filtered on push.'
        Assert-NotMatch $workflows.Lock '(?m)^  pull_request:\s*$' 'SYP86 lock must not add an ordinary PR job.'
        Assert-NotMatch $workflows.Maintenance '(?m)^  (pull_request|workflow_run|push|schedule):\s*$' 'Validator maintenance must remain an explicit manual diagnostic producer.'

        Assert-Equal ([regex]::Matches($workflows.Standards, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Manual Standards diagnostics must retain one real authority gate.'
        Assert-Equal ([regex]::Matches($workflows.Core, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Windows Core must invoke the authority gate exactly once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 0 'Install Smoke must not duplicate the authority gate.'
        Assert-Equal ([regex]::Matches($workflows.Lock, 'update-skills-catalog-lock\.ps1 -Check')).Count 1 'The path-filtered SYP86 diagnostic must validate the lock once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, 'update-skills-catalog-lock\.ps1 -Check')).Count 1 'Install Smoke must absorb the production lock check once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, 'test-syp101-production-smoke\.ps1')).Count 1 'Install Smoke must retain the pinned-archive installation and idempotence test once.'
        Assert-Match $workflows.Core 'Run the Standard v1 authority gate' 'Windows Core must execute the true authority gate.'
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($gate, [regex]::Escape($testName))).Count 1 "Shared authority gate must execute '$testName' exactly once."
        }
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'ExpectedGoRuntimeVersion|GoCommandPath|STANDARD_GO_|Resolve-StandardValidationTool|Resolve-PythonWheelClosure|New-AuthorityRunOwnedToolRoot|Invoke-AuthorityExternalCommand|skill-validator|skill-tools|SkillSpector|STANDARD_AUTHORITY_PYTHON|tenStageCompletionClaim' 'Normal authority gate must not require retired external dependencies.'
        Assert-Match $normalMain 'Invoke-Pester -Script \$authorityTestPaths -Strict -PassThru' 'Normal authority gate must execute the exact retained Pester paths.'
        Assert-Match $normalMain 'Get-AuthorityEntryPreflight @bindingParameters' 'Normal authority gate must rebind actual source hashes after execution.'
    }

    # Scenario: A pull request, push, or manual diagnostic is checked against an empty or unrelated revision range.
    # Purpose: Bind automatic whitespace checks to the event range and manual checks to the selected commit.
    It 'UnitT30_checks_the_actual_event_commit_range_and_manual_commit' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        Assert-Match $required 'PULL_REQUEST_BASE_SHA:\s*\$\{\{\s*github\.event\.pull_request\.base\.sha\s*\}\}' 'Core must bind the pull-request base SHA.'
        Assert-Match $required 'PUSH_BEFORE_SHA:\s*\$\{\{\s*github\.event\.before\s*\}\}' 'Core must bind the pre-push SHA.'
        Assert-Match $required 'GITHUB_EVENT_NAME' 'Core must select the commit range by event type.'
        Assert-Match $required 'git diff --check "\$env:PULL_REQUEST_BASE_SHA\.\.\.HEAD"' 'Core must check the pull-request merge-base range.'
        Assert-Match $required 'git diff --check "\$env:PUSH_BEFORE_SHA\.\.HEAD"' 'Core must check the exact push range.'
        Assert-Match $required 'git diff-tree --check --root -r HEAD' 'Core must support a root-commit fallback.'
        Assert-NotMatch $required 'git diff --check origin/main\.\.\.HEAD' 'Core must not use a range that becomes empty on a main-branch push.'
        Assert-Match $standards 'git diff --check ''HEAD\^\.\.HEAD''' 'Manual Standards diagnostics must check the selected commit against its parent.'
        Assert-Match $standards 'git diff-tree --check --root -r HEAD' 'Manual Standards diagnostics must support a root commit.'
        Assert-NotMatch $standards '(?m)^\s*(PULL_REQUEST_BASE_SHA|PUSH_BEFORE_SHA):' 'Manual Standards diagnostics must not depend on pull-request or push event payloads.'
    }

    # Scenario: The managed lifecycle contract changes while the manual diagnostic is the only workflow naming its files.
    # Purpose: Keep SYP-194 lifecycle semantics inside the required main Composition authority execution.
    It 'UnitT40_routes_managed_lifecycle_changes_through_the_central_authority_gate' {
        $standardsPath = Join-Path $script:RepositoryRoot 'docs/standards/managed-skill-lifecycle.md'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $standardsPath -PathType Leaf) 'Managed lifecycle authority document is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Managed lifecycle evidence schema is missing.'
        $standardWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath

        Assert-Match $standardWorkflow '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains available for manual authority diagnosis.'
        Assert-NotMatch $standardWorkflow '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not duplicate ordinary automatic authority execution.'
        Assert-Match $requiredWorkflow 'Run the Standard v1 authority gate' 'Windows Core must execute the authority gate for managed lifecycle changes.'
        Assert-NotMatch $requiredWorkflow '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Windows Core must run without automatic event path filters.'
        Assert-Match $standardTests 'UnitT70_binds_managed_lifecycle_to_the_central_standard_authority' 'The workflow gate must execute lifecycle-specific authority regression.'
    }

    # Scenario: Upstream adapter changes remain visible to source-contract regressions after the optional package validator leaves the ordinary gate.
    # Purpose: Preserve source and workflow coverage without restoring external tool execution to the authority gate.
    It 'UnitT50_keeps_upstream_interoperability_source_regressions_in_authority_ci' {
        $upstreamPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-interoperability.md'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $adapterPolicyPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-adapter.json'
        $adapterSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/upstream-adapter-v1.schema.json'
        $adapterValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate-UpstreamAdapter.ps1'

        Assert-True (Test-Path -LiteralPath $upstreamPath -PathType Leaf) 'Upstream interoperability authority document is missing.'
        Assert-True (Test-Path -LiteralPath $adapterPolicyPath -PathType Leaf) 'Upstream adapter policy is missing.'
        Assert-True (Test-Path -LiteralPath $adapterSchemaPath -PathType Leaf) 'Upstream adapter schema is missing.'
        Assert-True (Test-Path -LiteralPath $adapterValidatorPath -PathType Leaf) 'Upstream adapter validator is missing.'
        $upstream = Get-Content -Raw -Encoding UTF8 -LiteralPath $upstreamPath
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        Assert-Match $standards '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains an explicit manual diagnostic.'
        Assert-NotMatch $standards '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not rerun automatically for the same event.'
        Assert-Match $required 'Run the Standard v1 authority gate' 'Windows Core must execute the shared gate for upstream changes.'
        foreach ($sourceTestName in @('skills-source-composition.Tests.ps1', 'skills-source-acquisition.Tests.ps1')) {
            $sourceTestPath = Join-Path $script:RepositoryRoot "tests/$sourceTestName"
            Assert-True (Test-Path -LiteralPath $sourceTestPath -PathType Leaf) "Core source regression '$sourceTestName' must remain present."
            Assert-False ($script:AuthorityTests -contains $sourceTestName) "Core source regression '$sourceTestName' must run in the complete non-authority difference rather than be duplicated by the shared authority gate."
        }
        Assert-Match $required 'Get-ChildItem -LiteralPath \$testRoot -Filter ''\*\.Tests\.ps1'' -File -Recurse' 'Windows Core must discover every retained Pester test file once.'
        Assert-Match $required '\$authorityFullPaths -notcontains \$_.FullName' 'Windows Core must exclude only the exact shared authority test paths from its full discovery.'
        Assert-NotMatch $required '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Windows Core must cover ordinary events without path filtering.'
        Assert-Match $standardTests 'UnitT80_binds_upstream_interoperability_to_explicit_central_decisions' 'The workflow gate must execute the upstream interoperability regression.'
        Assert-Match $standardTests 'UnitT81_routes_upstream_negative_cases_through_the_executable_adapter' 'The workflow gate must execute the executable adapter regression.'
        foreach ($caseId in @(
            'package-missing-skill-md',
            'plugin-path-out-of-root',
            'plugin-path-backslash',
            'plugin-path-rooted-windows',
            'plugin-path-dot',
            'plugin-path-colon',
            'plugin-duplicate-field',
            'mcp-unapproved-endpoint',
            'app-unknown-mcp-server',
            'marketplace-mutable-ref',
            'marketplace-duplicate-name',
            'marketplace-duplicate-nested-field',
            'marketplace-unknown-field',
            'marketplace-source-subpath',
            'marketplace-unapproved-repository',
            'marketplace-repository-case-variant',
            'marketplace-unapproved-endpoint',
            'plugin-hook-bypass'
        )) {
            Assert-Match $standardTests ([regex]::Escape($caseId)) "The upstream authority regression must retain negative case '$caseId'."
        }
        Assert-Match $upstream 'SYP-192 Gate 1' 'The upstream decision must bind Plugin conformance to Gate 1.'
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-Match $normalMain 'tests/skill-repository-standard\.Tests\.ps1' 'The ordinary authority gate must retain upstream interoperability source regressions.'
        Assert-NotMatch $normalMain 'Validate-UpstreamAdapter\.ps1|upstream-adapter\.json' 'The ordinary authority gate must not invoke the external adapter validator or load its policy.'
    }

    # Scenario: The canonical validation/security policy changes while the ordinary gate remains source-focused.
    # Purpose: Validate the policy as data and keep consumer-stage regressions distinct from ordinary gate execution.
    It 'UnitT60_checks_validation_security_policy_without_restoring_external_gate_chain' {
        $policyPath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/validation-security-gate-v1.schema.json'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'Canonical validation/security policy is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Canonical validation/security policy schema is missing.'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        . $gatePath -DefineFunctionsOnly

        Assert-Match $standards '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains available as a manual authority diagnostic.'
        Assert-NotMatch $standards '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not repeat the automatic required gate.'
        Assert-Match $required 'Run the Standard v1 authority gate' 'Windows Core must execute the authority gate for policy and semantic contract changes.'
        Assert-NotMatch $required '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Required Composition must run on main events without path filtering.'
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
        Assert-AuthorityValidationSecurityGate -Policy $policy | Out-Null
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'validation-security-gate\.json|Assert-AuthorityValidationSecurityGate|semanticPreflight|llm-input-equals-strict-utf8-decoding-of-verified-source-bytes|full-byte-manifest-plus-authenticated-provider-text-subset|standard-semantic-(inventory-probe|preflight|raw-graph)\.Advanced\.ps1|standard-semantic-bridge\.Tests\.ps1|STANDARD_AUTHORITY_PYTHON|one-successful-provider-call-per-planned-work-item' 'The ordinary authority gate must not run policy-controlled external or semantic stages.'
        foreach ($isolatedPythonSuite in @('standard-semantic-inventory-probe.Advanced.ps1','standard-semantic-raw-graph.Advanced.ps1')) {
            $suiteText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot $isolatedPythonSuite)
            Assert-Match $suiteText '& \$script:Python -I -B' "Semantic suite '$isolatedPythonSuite' must use isolated Python startup."
        }
        Assert-Match $standardTests 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' 'The workflow gate must execute SYP-192 validation/security regression.'
    }

    # Scenario: A consumer adds a renamed workflow, hook, release command, or duplicate trigger adapter around a component script.
    # Purpose: Enforce the central entry-point inventory while keeping the unmatched maintenance consumer retired and its manual producer non-admitting.
    It 'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles' {
        $maintenanceConsumerPath = Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-protected-consumer.yml'
        $maintenanceProducer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-producer.yml')
        Assert-False (Test-Path -LiteralPath $maintenanceConsumerPath) 'The automatic protected consumer must be retired because workflow_run cannot pair its PR-bound producer identity with a manual diagnostic run.'
        Assert-Match $maintenanceProducer '(?m)^  workflow_dispatch:\s*$' 'The maintenance producer must remain manually dispatchable.'
        Assert-NotMatch $maintenanceProducer '(?m)^  (pull_request|workflow_run|push|schedule):\s*$' 'The maintenance producer must not run as normal CI or an automatic consumer input.'
        Assert-Match $maintenanceProducer 'CANDIDATE_REVISION:\s*\$\{\{\s*github\.sha\s*\}\}' 'The manual producer must bind candidate evidence to the actual workflow-dispatch checkout.'
        Assert-Match $maintenanceProducer '-CandidateRevision \$env:CANDIDATE_REVISION' 'The producer must pass the checked-out candidate revision.'
        Assert-Match $maintenanceProducer '-EventName \$env:GITHUB_EVENT_NAME' 'The producer must report the real workflow-dispatch event name.'
        Assert-Match $maintenanceProducer "ciAdmission\s+-cne\s+'BLOCKED'" 'Diagnostic data must never grant CI admission.'
        Assert-Match $maintenanceProducer 'releaseEligible\s+-ne\s*\$false' 'Diagnostic data must never grant release eligibility.'
        Assert-False ($maintenanceProducer -match '(?m)^\s*(actions|contents|pull-requests):\s*write') 'The diagnostic producer must use no write permissions.'
        $producerScript = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidatorMaintenanceProducer.ps1')
        Assert-Match $producerScript "ValidateSet\('workflow_dispatch'\).*EventName" 'The producer script must accept only the real manual diagnostic event.'
        Assert-Match $producerScript 'eventName = \$EventName' 'The diagnostic report must record the supplied event name.'
        Assert-Match $producerScript 'ciAdmission = ''BLOCKED''' 'The producer result must remain explicitly non-admitting.'
        Assert-Match $producerScript 'releaseEligible = \$false' 'The producer result must remain ineligible for release.'
        $workflowTestText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'tests/skill-repository-workflows.Tests.ps1')
        $maintenanceTestText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'tests/standard-validation-runner.Tests.ps1')
        foreach ($inventory in @(
            @{ Name='workflow'; Pattern='(?ms)^\$workflowIds = @\((.*?)^\)'; Source=$workflowTestText },
            @{ Name='maintenance'; Pattern='(?ms)^\$maintenanceIds = @\((.*?)^\)'; Source=$maintenanceTestText }
        )) {
            $inventoryMatch = [regex]::Match($producerScript, $inventory.Pattern)
            Assert-True $inventoryMatch.Success "Producer must declare its exact $($inventory.Name) diagnostic test inventory."
            $ids = @([regex]::Matches($inventoryMatch.Groups[1].Value, "'([^']+)'\s*,?\s*") | ForEach-Object { [string]$_.Groups[1].Value })
            Assert-True ($ids.Count -gt 0) "Producer $($inventory.Name) test inventory must not be empty."
            Assert-Equal @($ids | Select-Object -Unique).Count $ids.Count "Producer $($inventory.Name) test inventory must not contain duplicate IDs."
            foreach ($id in $ids) {
                $escapedId = [regex]::Escape($id)
                Assert-Equal ([regex]::Matches($inventory.Source, "(?m)^\s*It '$escapedId'\s*\{")).Count 1 "Producer $($inventory.Name) ID '$id' must match exactly one actual Pester test."
            }
        }
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $authorityGate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-True ($null -ne $policy.entryPointContract) 'Canonical validation/security policy must declare the entry-point contract.'
        Assert-Match $authorityGate 'Assert-AuthorityConsumerEntryPointContract' 'The shared authority gate must expose the consumer entry-point contract checker.'

        $canonicalFixture = Join-Path $TestDrive 'entry-point-valid'
        New-ConsumerEntryPointFixture -Root $canonicalFixture
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A single canonical workflow must satisfy the entry-point contract.'

        Write-TestUtf8File -Path (Join-Path $canonicalFixture 'scripts/check-domain.ps1') -Text "Invoke-Pester -Path tests/domain`n"
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A component script must not become an alternate gate merely because it exists.'

        $negativeCases = @(
            @{
                Name = 'arbitrary-workflow-name'
                RelativePath = '.github/workflows/domain-check.yaml'
                Text = "name: Domain check`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'pre-push-hook-bypass'
                RelativePath = '.githooks/pre-push'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'pre-commit-hook-bypass'
                RelativePath = '.githooks/pre-commit'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'authority-role-name-bypass'
                RelativePath = '.github/workflows/standards-conformance.yml'
                Text = "name: Fake authority role`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'public-release-command'
                RelativePath = 'README.md'
                Text = "Run ./scripts/run-domain-tests.ps1 as the release gate.`n"
            },
            @{
                Name = 'release-workflow-without-canonical'
                RelativePath = '.github/workflows/release.yml'
                Text = @'
name: Release
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-action-without-canonical'
                RelativePath = '.github/workflows/release-action.yml'
                Text = @'
name: Release action
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: softprops/action-gh-release@v2
'@
            },
            @{
                Name = 'release-workflow-step-name-only-canonical'
                RelativePath = '.github/workflows/release-step-name.yml'
                Text = @'
name: Release step metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - name: ./scripts/Validate.ps1
        run: gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-comment-only-canonical'
                RelativePath = '.github/workflows/release-comment.yml'
                Text = @'
name: Release comment metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - run: |
          # ./scripts/Validate.ps1
          gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-suppresses-canonical-failure'
                RelativePath = '.github/workflows/release-suppressed.yml'
                Text = @'
name: Release with suppressed validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: ./scripts/Validate.ps1 || true
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-disables-canonical-step'
                RelativePath = '.github/workflows/release-disabled-canonical.yml'
                Text = @'
name: Release with disabled canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: ${{ false }}
        run: ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-conditional-release'
                RelativePath = '.github/workflows/release-conditional.yml'
                Text = @'
name: Conditional release without canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: startsWith(github.ref, 'refs/tags/')
        run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-references-canonical-only'
                RelativePath = '.github/workflows/release-canonical-reference.yml'
                Text = @'
name: Release with canonical path reference only
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: Get-Item ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-same-step-without-success-gate'
                RelativePath = '.github/workflows/release-same-step.yml'
                Text = @'
name: Release with ungated same-step validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - shell: bash
        run: |
          ./scripts/Validate.ps1
          gh release create $GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-with-unbound-validation'
                RelativePath = '.github/workflows/release-unbound.yml'
                Text = @'
name: Release with unbound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-unrelated-list-item'
                RelativePath = '.github/workflows/release-unrelated-list.yml'
                Text = @'
name: Release with unrelated list item
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-opaque-local-helper'
                RelativePath = '.github/workflows/release-opaque-helper.yml'
                Text = @'
name: Release with opaque local helper
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs: canonical-validation
    steps:
      - run: ./ship
'@
                Files = @(
                    @{
                        RelativePath = 'ship'
                        Text = "gh release create `$env:GITHUB_REF_NAME`n"
                    }
                )
            },
            @{
                Name = 'release-workflow-opaque-action-delegate'
                RelativePath = '.github/workflows/release-opaque-action.yml'
                Text = @'
name: Release with opaque action delegate
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: acme/ship@0123456789012345678901234567890123456789
'@
            },
            @{
                Name = 'compatibility-independent-validation'
                RelativePath = '.github/workflows/compatibility-independent.yml'
                Text = @'
name: Compatibility status
on:
  workflow_dispatch:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: Invoke-Pester -Path tests/domain
'@
            }
        )
        foreach ($case in $negativeCases) {
            $root = Join-Path $TestDrive ("entry-point-negative-{0}" -f $case.Name)
            New-ConsumerEntryPointFixture -Root $root
            Write-TestUtf8File -Path (Join-Path $root $case.RelativePath) -Text $case.Text
            if ($case.ContainsKey('Files')) {
                foreach ($file in @($case.Files)) {
                    Write-TestUtf8File -Path (Join-Path $root $file.RelativePath) -Text $file.Text
                }
            }
            $errorMessage = $null
            try {
                Assert-AuthorityConsumerEntryPointContract `
                    -RepositoryRoot $root `
                    -CanonicalValidatorPath 'scripts/Validate.ps1' `
                    -Policy $policy | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'entry-point contract|alternate|canonical|opaque|release' "Consumer entry-point case '$($case.Name)' must fail closed."
        }

        $compatibilityRoot = Join-Path $TestDrive 'entry-point-compatibility-status'
        New-ConsumerEntryPointFixture -Root $compatibilityRoot
        Write-TestUtf8File -Path (Join-Path $compatibilityRoot '.github/workflows/compatibility-status.yml') -Text @'
name: Compatibility status
on:
  pull_request:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: echo canonical-validation.result
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $compatibilityRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A compatibility status job may depend on and mirror the canonical result.'

        $releaseBoundRoot = Join-Path $TestDrive 'entry-point-release-bound'
        [void](New-Item -ItemType Directory -Path $releaseBoundRoot -Force)
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot '.github/workflows/release-bound.yml') -Text @'
name: Release with bound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs:
      - canonical-validation
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $releaseBoundRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A release job must be allowed when it depends on the canonical validation job.'

        $duplicateRoot = Join-Path $TestDrive 'entry-point-duplicate-event'
        New-ConsumerEntryPointFixture -Root $duplicateRoot
        Write-TestUtf8File -Path (Join-Path $duplicateRoot '.github/workflows/duplicate-pr.yaml') -Text @'
name: Duplicate PR adapter
on:
  pull_request:
    branches:
      - main
jobs:
  duplicate:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $duplicateError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $duplicateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $duplicateError = $_.Exception.Message }
        Assert-Match $duplicateError 'duplicate|event|candidate' 'Two canonical executions for the same event/candidate must fail closed.'

        $splitRoot = Join-Path $TestDrive 'entry-point-split-triggers'
        [void](New-Item -ItemType Directory -Path $splitRoot -Force)
        Write-TestUtf8File -Path (Join-Path $splitRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/protected-pr.yml') -Text @'
name: Protected PR adapter
on:
  pull_request:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/trusted-push.yml') -Text @'
name: Trusted push adapter
on:
  push:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $splitRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'Protected PR and trusted push adapters may be separate when their events do not duplicate execution.'

        $disjointCandidateRoot = Join-Path $TestDrive 'entry-point-disjoint-candidates'
        [void](New-Item -ItemType Directory -Path (Join-Path $disjointCandidateRoot '.github/workflows') -Force)
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/main-pr.yml') -Text @'
name: Main pull request adapter
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/release-pr.yml') -Text @'
name: Release pull request adapter
on:
  pull_request:
    branches:
      - release
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $filterOverlapError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $disjointCandidateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $filterOverlapError = $_.Exception.Message }
        Assert-Match $filterOverlapError 'duplicate|event/candidate|overlap' 'Different path or branch filters must not be treated as proof of disjoint canonical execution.'

        $roles = @($policy.entryPointContract.authorityWorkflowRoles)
        Assert-Equal $roles.Count 4 'The authority repository must explicitly classify all four legitimate workflow roles.'
        foreach ($role in $roles) {
            Assert-False ([bool]$role.consumerAlternateGate) "Authority workflow '$($role.path)' must not be classified as a consumer alternate gate."
            Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $role.path) -PathType Leaf) "Authority workflow role '$($role.path)' must remain present."
        }
        Assert-Match $authorityGate 'standards-conformance\.yml|pr8-powershell-validation\.yml|syp86-production-lock\.yml|syp101-production-smoke\.yml' 'The authority gate contract must retain the explicit four-workflow role surface.'
    }

    # Scenario: Canonical release validation is documented beside optional hook setup and repository/API diagnostics.
    # Purpose: Keep non-admitting setup and diagnostic commands from becoming alternate release gates.
    It 'UnitT71_accepts_markdown_setup_and_diagnostics_outside_release_admission' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-markdown-setup-diagnostics'
        New-ConsumerEntryPointFixture -Root $root
        Write-TestUtf8File -Path (Join-Path $root 'README.md') -Text @'
## Repository validation
Run the canonical source gate:
```powershell
pwsh -File ./scripts/Validate.ps1
```
### Optional pre-push setup
Enable the optional hook:
```powershell
pwsh -File ./scripts/Set-PrePushHook.ps1 -Mode Enable
```
Disable the optional hook:
```powershell
pwsh -File ./scripts/Set-PrePushHook.ps1 -Mode Disable
```
Inspect repository and API diagnostics:
```powershell
pwsh -File ./tests/validate-repository.ps1
pwsh -File ./tests/validate-api-access.ps1
```
'@

        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json)) `
            'Optional hook setup and repository/API diagnostics must not be inferred as release gates.'
    }

    # Scenario: README places the canonical command under Diagnostics and a release command under Release.
    # Purpose: Require each release command section to document its own canonical validation dependency.
    It 'UnitT72_rejects_release_command_with_only_an_unrelated_canonical_section' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-markdown-unrelated-canonical'
        New-ConsumerEntryPointFixture -Root $root
        Write-TestUtf8File -Path (Join-Path $root 'README.md') -Text @'
## Diagnostics
```powershell
pwsh -File ./scripts/Validate.ps1
```
## Release
```powershell
gh release create v1.0.0
```
'@

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json) | Out-Null
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'without exactly one canonical' 'A canonical command in another Markdown section must not authorize a release command.'
    }

    # Scenario: A consumer workflow replaces its canonical validator invocation with a component check.
    # Purpose: Preserve executable workflow enforcement independently from Markdown documentation consistency.
    It 'UnitT73_rejects_workflow_replacement_of_the_canonical_validator' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-workflow-canonical-replaced'
        New-ConsumerEntryPointFixture -Root $root
        $workflowPath = Join-Path $root '.github/workflows/validate.yml'
        $workflow = [IO.File]::ReadAllText($workflowPath).Replace('./scripts/Validate.ps1', './scripts/check-domain.ps1')
        Write-TestUtf8File -Path $workflowPath -Text $workflow
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'alternate|non-canonical|bypass|canonical' 'A workflow that replaces the canonical validator with another check must fail closed.'
    }

    # Scenario: A fenced PowerShell release example contains a comment that begins with a Markdown heading marker.
    # Purpose: Keep literal code comments inside their section so the canonical validator remains documented with the release command.
    It 'UnitT74_accepts_release_example_with_fenced_comment' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $text = @'
## Release
```powershell
pwsh -File ./scripts/Validate.ps1
# Publish after validation
gh release create v1.0.0
```
'@

        $sections = @(Get-AuthorityMarkdownCommandSections -Text $text)
        Assert-Equal $sections.Count 1 'A heading-looking fenced comment must not create a second Markdown section.'
        Assert-AuthorityConsumerPublicCommandDocumentation `
            -Text $text `
            -PublicRelativePath 'README.md' `
            -CanonicalRelativePath 'scripts/Validate.ps1' `
            -RequiresFailurePropagation $true
    }

    # Scenario: README uses Setext headings to separate canonical diagnostics from a release command.
    # Purpose: Keep canonical validation in Diagnostics from authorizing an unrelated Release section.
    It 'UnitT75_rejects_release_command_with_only_an_unrelated_setext_canonical_section' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $text = @'
Diagnostics
===========
```powershell
pwsh -File ./scripts/Validate.ps1
```
Release
 =======
```powershell
gh release create v1.0.0
```
'@

        $sections = @(Get-AuthorityMarkdownCommandSections -Text $text)
        Assert-Equal $sections.Count 2 'Setext headings must delimit independent Markdown command sections.'

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerPublicCommandDocumentation `
                -Text $text `
                -PublicRelativePath 'README.md' `
                -CanonicalRelativePath 'scripts/Validate.ps1' `
                -RequiresFailurePropagation $true
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'without exactly one canonical' 'A canonical command in another Setext section must not authorize a release command.'
    }
}
