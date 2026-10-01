Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersionRule = 'latest-stable'
        $script:WorkflowExpectations = [ordered]@{
            '.github/workflows/pr8-powershell-validation.yml' = 10
            '.github/workflows/standards-conformance.yml' = 1
            '.github/workflows/syp101-production-smoke.yml' = 2
            '.github/workflows/syp86-production-lock.yml' = 2
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
        Assert-Equal ([regex]::Matches($required, 'Import-Module \$pester\.Path -Force')).Count 1 'Only the Linux composition job may import Pester in workflow scope; Windows full suites must stay behind the bounded executor.'
        Assert-Equal ([regex]::Matches($required, '& ./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 8 'All eight Windows Pester partitions must use the bounded executor.'
        Assert-Equal ([regex]::Matches($required, 'Executing Pester \$\(\$pester\.Version\) through the bounded shard executor\.')).Count 8 'Workflow logging must use discovery metadata without importing the module first.'
    }

    # Scenario: Ordinary CI still depends on a custom Linux namespace and private-procfs job before retained validations can run.
    # Purpose: Remove that retired prerequisite while preserving the existing partition, authority, and strict failure contracts.
    It 'UnitT15_ordinary_workflows_do_not_require_custom_linux_sandbox' {
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath

        foreach ($workflow in @($required, $standards)) {
            Assert-NotMatch $workflow 'linux-callback-focused|Enable unprivileged user namespaces on GitHub-hosted Ubuntu|Probe Linux PID namespace containment capability' 'Ordinary workflow jobs must not require the retired Linux namespace/procfs preflight.'
        }
        Assert-NotMatch $standards 'Invoke-FocusedLinuxContainment\.ps1' 'Standards Conformance must not path-filter or invoke the retired focused helper.'

        $requiredJobsMatch = [regex]::Match($required, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        Assert-True $requiredJobsMatch.Success 'PowerShell Regression must define its jobs block.'
        $requiredJobs = [regex]::Matches($requiredJobsMatch.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        Assert-Equal $requiredJobs.Count 12 'PowerShell Regression must retain twelve ordinary jobs after the focused prerequisite retires.'
        $requiredNames = @($requiredJobs | ForEach-Object { $_.Groups[1].Value })
        foreach ($jobName in @(
            'windows-powershell-51-even', 'windows-powershell-51-even-b',
            'windows-powershell-51-odd', 'windows-powershell-51-odd-b',
            'windows-powershell-51', 'powershell-7-even', 'powershell-7-even-b',
            'powershell-7-odd', 'powershell-7-odd-b', 'powershell-7',
            'powershell-7-unix-composition', 'routine-semantic-offline'
        )) {
            Assert-True ($requiredNames -contains $jobName) "PowerShell Regression must retain '$jobName'."
        }
        Assert-Match $required '(?m)^permissions:\r?\n\s+contents:\s*read\s*$' 'PowerShell Regression must retain read-only repository permissions.'

        foreach ($definition in @(
            @{ Name = 'windows-powershell-51-even'; Version = '3.4.0'; Index = 0; Skipped = 1 },
            @{ Name = 'windows-powershell-51-even-b'; Version = '3.4.0'; Index = 2; Skipped = 5 },
            @{ Name = 'windows-powershell-51-odd'; Version = '3.4.0'; Index = 1; Skipped = 0 },
            @{ Name = 'windows-powershell-51-odd-b'; Version = '3.4.0'; Index = 3; Skipped = 0 },
            @{ Name = 'powershell-7-even'; Version = '4.10.1'; Index = 0; Skipped = 1 },
            @{ Name = 'powershell-7-even-b'; Version = '4.10.1'; Index = 2; Skipped = 5 },
            @{ Name = 'powershell-7-odd'; Version = '4.10.1'; Index = 1; Skipped = 0 },
            @{ Name = 'powershell-7-odd-b'; Version = '4.10.1'; Index = 3; Skipped = 0 }
        )) {
            $partitionMatch = [regex]::Match($required, ('(?ms)^  ' + [regex]::Escape($definition.Name) + ':\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)'))
            Assert-True $partitionMatch.Success "PowerShell Regression must retain partition '$($definition.Name)'."
            $partitionBlock = $partitionMatch.Groups['block'].Value
            Assert-Match $partitionBlock 'runs-on:\s*windows-latest' "Partition '$($definition.Name)' must retain its Windows runner."
            Assert-NotMatch $partitionBlock 'needs:\s*linux-callback-focused' "Partition '$($definition.Name)' must not depend on the retired Linux job."
            Assert-Match $partitionBlock ([regex]::Escape("PesterVersion = '$($definition.Version)'")) "Partition '$($definition.Name)' must retain its pinned Pester version."
            Assert-Match $partitionBlock ('ShardPartitionCount\s*=\s*4\b') "Partition '$($definition.Name)' must remain in the four-partition schedule."
            Assert-Match $partitionBlock ('ShardPartitionIndex\s*=\s*' + $definition.Index + '\b') "Partition '$($definition.Name)' must retain its assigned index."
            Assert-NotMatch $partitionBlock 'ExpectedFullShardCount\s*=' "Partition '$($definition.Name)' must use discovered shard capacity."
            Assert-Match $partitionBlock 'OuterTimeoutSeconds\s*=\s*2400\b' "Partition '$($definition.Name)' must retain its bounded timeout."
            Assert-NotMatch $partitionBlock 'ExpectedTotalCount\s*=' "Partition '$($definition.Name)' must rely on the actual discovered total."
            Assert-Match $partitionBlock ('ExpectedSkippedCount\s*=\s*' + $definition.Skipped + '\b') "Partition '$($definition.Name)' must verify its expected skip count."
            Assert-Match $partitionBlock '& \./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments' "Partition '$($definition.Name)' must use the bounded executor."
        }

        $ps51SummaryMatch = [regex]::Match($required, '(?ms)^  windows-powershell-51:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        $ps7SummaryMatch = [regex]::Match($required, '(?ms)^  powershell-7:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        Assert-True $ps51SummaryMatch.Success 'The required PowerShell 5.1 context must summarize its four partitions.'
        Assert-True $ps7SummaryMatch.Success 'The required PowerShell 7 context must summarize its four partitions.'
        $ps51Summary = $ps51SummaryMatch.Groups['block'].Value
        $ps7Summary = $ps7SummaryMatch.Groups['block'].Value
        Assert-Match $ps51Summary 'needs:\s*\[windows-powershell-51-even, windows-powershell-51-even-b, windows-powershell-51-odd, windows-powershell-51-odd-b\]' 'The PowerShell 5.1 summary must retain all four partition dependencies.'
        Assert-Match $ps7Summary 'needs:\s*\[powershell-7-even, powershell-7-even-b, powershell-7-odd, powershell-7-odd-b\]' 'The PowerShell 7 summary must retain all four partition dependencies.'
        foreach ($summary in @($ps51Summary, $ps7Summary)) {
            Assert-Match $summary 'if:\s*\$\{\{\s*always\(\)\s*\}\}' 'Each required partition summary must run when a dependency fails or is skipped.'
            Assert-Match $summary 'EVEN_RESULT.*-cne.*success' 'Each required partition summary must reject a non-success even partition.'
            Assert-Match $summary 'EVEN_B_RESULT.*-cne.*success' 'Each required partition summary must reject a non-success second even partition.'
            Assert-Match $summary 'ODD_RESULT.*-cne.*success' 'Each required partition summary must reject a non-success odd partition.'
            Assert-Match $summary 'ODD_B_RESULT.*-cne.*success' 'Each required partition summary must reject a non-success second odd partition.'
        }

        $compositionMatch = [regex]::Match($required, '(?ms)^  powershell-7-unix-composition:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        $routineMatch = [regex]::Match($required, '(?ms)^  routine-semantic-offline:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        Assert-True $compositionMatch.Success 'PowerShell Regression must retain its Linux composition job.'
        Assert-True $routineMatch.Success 'PowerShell Regression must retain its offline fixture job.'
        $compositionJob = $compositionMatch.Groups['block'].Value
        $routineJob = $routineMatch.Groups['block'].Value
        Assert-NotMatch $compositionJob '(?m)^\s+needs:' 'The Linux composition job must not wait on the retired prerequisite.'
        Assert-Match $compositionJob 'Run required Standard v1 authority gate' 'The composition job must retain the authority gate.'
        Assert-Match $compositionJob 'Run cross-platform composition and acquisition tests' 'The composition job must retain its existing tests.'
        Assert-Match $compositionJob 'skills-source-composition\.Tests\.ps1' 'The composition job must retain source composition coverage.'
        Assert-Match $compositionJob 'skills-source-acquisition\.Tests\.ps1' 'The composition job must retain source acquisition coverage.'
        Assert-Match $compositionJob '\$result\.TotalCount\s+-isnot\s+\[int\].*\$result\.TotalCount\s+-isnot\s+\[long\]' 'Composition must accept only integer Pester totals.'
        Assert-Match $compositionJob '\[int64\]\$result\.TotalCount\s*-le\s*0' 'Composition must reject zero or negative test discovery.'
        Assert-Match $compositionJob '\[int64\]\$result\.PassedCount\s*-ne\s*\[int64\]\$result\.TotalCount' 'Composition must require every discovered test to pass without narrowing counts.'
        foreach ($countName in @('FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount')) {
            Assert-Match $compositionJob ('\[int\]\$result\.{0}\s*-ne\s*0' -f $countName) "Composition must reject nonzero $countName."
        }
        Assert-NotMatch $compositionJob 'expectedTestCounts|TotalCount\s*-ne\s*\[int64\]?' 'Composition must validate actual results without fixed per-file totals.'
        Assert-NotMatch $routineJob 'needs:\s*linux-callback-focused' 'The offline fixture job must not depend on the retired Linux job.'
        Assert-Match $routineJob 'runs-on:\s*windows-latest' 'The offline fixture job must retain its Windows runner.'
        Assert-Match $routineJob 'timeout-minutes:\s*10' 'The offline fixture job must retain its fixed execution budget.'
        Assert-Match $routineJob 'test_routine_semantic_\*\.py' 'The offline job must continue to discover its Python fixtures.'
        Assert-Match $routineJob 'len\(result\.skipped\)\s*==\s*0' 'The offline job must continue to reject skipped fixtures.'

        $standardsJobsMatch = [regex]::Match($standards, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        Assert-True $standardsJobsMatch.Success 'Standards Conformance must define its jobs block.'
        $standardsJobs = [regex]::Matches($standardsJobsMatch.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        Assert-Equal $standardsJobs.Count 1 'Standards Conformance must retain only its manual diagnostic authority job.'
        $standardsNames = @($standardsJobs | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($standardsNames -contains 'authority-gate') 'Standards Conformance must retain its manual authority diagnostic.'
        Assert-False ($standardsNames -contains 'latest-stable-authority-regression') 'Standards Conformance must not retain a result-only latest-stable summary job.'
        $standardsEventsMatch = [regex]::Match($standards, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)')
        Assert-True $standardsEventsMatch.Success 'Standards Conformance must define its workflow triggers.'
        $standardsEvents = $standardsEventsMatch.Groups['block'].Value
        $standardsTriggerNames = [regex]::Matches($standardsEvents, '(?m)^  ([a-z_]+):\s*$')
        Assert-Equal $standardsTriggerNames.Count 1 'Standards Conformance must have one explicit trigger.'
        Assert-Equal $standardsTriggerNames[0].Groups[1].Value 'workflow_dispatch' 'Standards Conformance must be a manual diagnostic only.'
        Assert-NotMatch $standardsEvents '(?m)^\s+(push|pull_request|schedule|workflow_run):\s*$' 'Standards Conformance must not automatically duplicate the required workflow.'
        Assert-NotMatch $standardsEvents '(?m)^\s+paths(-ignore)?:\s*$' 'Manual Standards diagnostics do not need automatic path filters.'
        $authorityMatch = [regex]::Match($standards, '(?ms)^  authority-gate:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        Assert-True $authorityMatch.Success 'Standards Conformance must retain its canonical authority job.'
        $authorityJob = $authorityMatch.Groups['block'].Value
        Assert-NotMatch $authorityJob '(?m)^\s+needs:' 'The authority gate must run without the retired focused prerequisite.'
        Assert-NotMatch $authorityJob 'namespace|procfs|unshare' 'The authority gate must not provision custom namespace or procfs isolation.'
        Assert-Match $authorityJob 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' 'The authority job must retain its pinned fresh checkout.'
        Assert-Match $authorityJob 'persist-credentials:\s*false' 'The authority checkout must not persist Git credentials.'
        Assert-NotMatch $authorityJob 'actions/setup-go|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH|GITHUB_TOKEN' 'The authority job must not depend on Go or resolver credentials.'
        Assert-Match $authorityJob 'Ensure Pester 4.10.1' 'The authority job must provision only the pinned local test engine.'
        Assert-Match $authorityJob 'Run canonical Standard v1 authority gate' 'The authority job must execute the canonical gate.'
        Assert-Match $authorityJob 'Check whitespace in the event range' 'The authority job must retain event-range whitespace validation.'
    }

    # Scenario: A new discovered Pester file is added while the two isolated files and four runtime partitions remain stable.
    # Purpose: Prove the pure planner assigns every path exactly once, preserves exact coverage, and rejects duplicate or missing inventory entries.
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

    # Scenario: A main push or pull request reaches two automatic workflows that repeat the same authority gate.
    # Purpose: Keep one required automatic Composition gate while retaining Standards as a manual diagnostic.
    It 'UnitT20_keeps_required_Composition_automatic_and_Standards_manual' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardAuthorityGate.ps1'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath

        foreach ($workflow in @($standards, $required)) {
            Assert-NotMatch $workflow 'sourceMergeExceptionProposal|pr12-source-merge-exception-proposal' 'An unapproved proposal must not route a required source check.'
            Assert-NotMatch $workflow 'sourceMergeDecision|pr12-source-merge-adoption' 'The central regression workflows cannot publish General source checks from their own jobs.'
            Assert-NotMatch $workflow 'actions/setup-go|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH|GITHUB_TOKEN' 'Ordinary authority workflows must not set up Go or pass external resolver credentials.'
            Assert-Match $workflow "persist-credentials:\s*false" 'Authority checkout credentials must remain disabled.'
            Assert-Match $workflow 'Install-Module Pester -RequiredVersion 4\.10\.1 -Scope CurrentUser -Force -SkipPublisherCheck' 'Each authority workflow must provision the pinned Pester version when it is absent.'
            Assert-Match $workflow '-CandidateRoot \$candidateRoot -AuthorityRoot \$candidateRoot -CandidateRevision \$revision -AuthorityRevision \$revision -EventName \$env:GITHUB_EVENT_NAME -ResultArtifact ''[^'']+\.json''' 'Each ordinary workflow must pass full roots, revision identities, event name, and a checkout-external relative result name.'
        }

        $standardsEventsMatch = [regex]::Match($standards, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)')
        $requiredEventsMatch = [regex]::Match($required, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)')
        Assert-True $standardsEventsMatch.Success 'Standards Conformance must expose its manual trigger.'
        Assert-True $requiredEventsMatch.Success 'PowerShell Regression must declare its ordinary triggers.'
        $standardsEvents = $standardsEventsMatch.Groups['block'].Value
        $requiredEvents = $requiredEventsMatch.Groups['block'].Value
        $standardsTriggers = [regex]::Matches($standardsEvents, '(?m)^  ([a-z_]+):\s*$')
        Assert-Equal $standardsTriggers.Count 1 'Standards Conformance must have no duplicate automatic trigger.'
        Assert-Equal $standardsTriggers[0].Groups[1].Value 'workflow_dispatch' 'Standards Conformance must remain manually dispatched.'
        $requiredPushMatch = [regex]::Match($requiredEvents, '(?ms)^  push:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
        $requiredPullRequestMatch = [regex]::Match($requiredEvents, '(?ms)^  pull_request:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
        Assert-True $requiredPushMatch.Success 'PowerShell Regression must run on push.'
        Assert-True $requiredPullRequestMatch.Success 'PowerShell Regression must run on pull requests.'
        foreach ($eventBlock in @($requiredPushMatch.Groups['block'].Value, $requiredPullRequestMatch.Groups['block'].Value)) {
            Assert-Match $eventBlock '(?m)^\s*branches:\s*$' 'The required workflow must retain its branch scope.'
            Assert-Match $eventBlock '(?m)^\s*-\s*main\s*$' 'The required workflow must cover main pushes and pull requests.'
            Assert-NotMatch $eventBlock '(?m)^\s+paths(-ignore)?:\s*$' 'The required Composition context must not be skipped by path filters.'
        }
        Assert-NotMatch $standardsEvents '(?m)^\s+(push|pull_request|schedule|workflow_run):\s*$' 'Standards Conformance must not automatically repeat the required gate.'
        Assert-Equal ([regex]::Matches($standards, 'Invoke-StandardAuthorityGate\.ps1')).Count 1 'Manual Standards diagnostics must retain one real authority-gate invocation.'
        Assert-Equal ([regex]::Matches($required, 'Invoke-StandardAuthorityGate\.ps1')).Count 1 'Required Composition CI must invoke the shared authority gate exactly once.'
        Assert-NotMatch $standards 'latest-stable-authority-regression|Standard v1 \(latest stable tooling\)' 'Standards Conformance must not report a fake latest-stable execution result.'
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($gate, [regex]::Escape($testName))).Count 1 "Shared authority gate must execute '$testName'."
        }
        Assert-Match $required 'Run required Standard v1 authority gate' 'Required Composition must execute the true authority gate for every main event.'
        Assert-Match $required 'skills-source-composition\.Tests\.ps1' 'Required Composition must retain source composition tests.'
        Assert-Match $required 'skills-source-acquisition\.Tests\.ps1' 'Required Composition must retain source acquisition tests.'
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'ExpectedGoRuntimeVersion|GoCommandPath|STANDARD_GO_|Resolve-StandardValidationTool|Resolve-PythonWheelClosure|New-AuthorityRunOwnedToolRoot|Invoke-AuthorityExternalCommand|skill-validator|skill-tools|SkillSpector|STANDARD_AUTHORITY_PYTHON|tenStageCompletionClaim' 'Normal authority gate must not require retired external dependencies.'
        Assert-Match $normalMain 'Invoke-Pester -Script \$authorityTestPaths -Strict -PassThru' 'Normal authority gate must execute the exact retained Pester paths.'
        Assert-Match $normalMain 'Get-AuthorityEntryPreflight @bindingParameters' 'Normal authority gate must rebind actual source hashes after execution.'
    }

    # Scenario: A main push or pull request is checked against a fixed branch range that can be empty or incomplete.
    # Purpose: Make whitespace validation cover the actual event range, including a repository's root commit.
    It 'UnitT30_checks_the_actual_event_commit_range_instead_of_an_empty_main_range' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        foreach ($path in @($standardsPath, $requiredPath)) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            Assert-Match $workflow 'PULL_REQUEST_BASE_SHA' "Workflow '$path' must bind the pull-request base SHA."
            Assert-Match $workflow 'PUSH_BEFORE_SHA' "Workflow '$path' must bind the pre-push SHA."
            Assert-Match $workflow 'GITHUB_EVENT_NAME' "Workflow '$path' must select the commit range by event type."
            Assert-Match $workflow 'git diff --check "\$PULL_REQUEST_BASE_SHA\.\.\.HEAD"' "Workflow '$path' must check the pull-request merge-base range."
            Assert-Match $workflow 'git diff --check "\$PUSH_BEFORE_SHA\.\.HEAD"' "Workflow '$path' must check the exact push range."
            Assert-Match $workflow 'git diff-tree --check --root -r HEAD' "Workflow '$path' must support a root-commit fallback."
            Assert-NotMatch $workflow 'git diff --check origin/main\.\.\.HEAD' "Workflow '$path' must not use a range that becomes empty on a main-branch push."
        }
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
        Assert-Match $requiredWorkflow 'Run required Standard v1 authority gate' 'Required Composition must execute the authority gate for managed lifecycle changes.'
        Assert-NotMatch $requiredWorkflow '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Required Composition must run without automatic event path filters.'
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
        Assert-Match $required 'Run required Standard v1 authority gate' 'Required Composition must execute the shared gate for upstream changes.'
        Assert-Match $required 'skills-source-composition\.Tests\.ps1' 'Required Composition must retain the source composition regression.'
        Assert-Match $required 'skills-source-acquisition\.Tests\.ps1' 'Required Composition must retain the source acquisition regression.'
        Assert-NotMatch $required '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Required Composition must cover main events without path filtering.'
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
        Assert-Match $required 'Run required Standard v1 authority gate' 'Required Composition must execute the authority gate for policy and semantic contract changes.'
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
    # Purpose: Enforce the central entry-point inventory contract while allowing non-authoritative components and status-only compatibility jobs.
    It 'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles' {
        # Scenario: default-branch code reads one registered producer's diagnostic artifact.
        # Purpose: bind the numeric selector while retaining the non-admitting data-only boundary.
        $maintenanceConsumer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-protected-consumer.yml')
        $maintenanceProducer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-producer.yml')
        Assert-Match $maintenanceConsumer "PRODUCER_WORKFLOW_ID:\s*'368289188'" 'The diagnostic consumer must select the registered existing producer ID.'
        Assert-Match $maintenanceConsumer 'ref:\s*\$\{\{\s*github\.sha\s*\}\}' 'Only default-branch event code may execute.'
        Assert-Match $maintenanceConsumer 'actions:\s*read' 'Diagnostic acquisition must keep Actions read-only.'
        Assert-Match $maintenanceConsumer '-RepositoryId\s+1245177039' 'The registered producer must stay in the fixed repository.'
        foreach ($workflow in @($maintenanceConsumer, $maintenanceProducer)) {
            Assert-Match $workflow "-AuthorityRevision\s+'e69c453888db93e2d2697ea7f0b11df13cd1b8d2'" 'Diagnostic authority labels must not silently move to the executing main.'
            Assert-Match $workflow "ciAdmission\s+-cne\s+'BLOCKED'" 'Diagnostic data must never grant admission.'
            Assert-Match $workflow 'releaseEligible\s+-ne\s*\$false' 'Diagnostic data must never grant release eligibility.'
            Assert-False ($workflow -match '(?m)^\s*(actions|contents|pull-requests):\s*write') 'Producer registration must not expand token permissions.'
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
