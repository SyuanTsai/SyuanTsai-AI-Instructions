Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersionRule = 'latest-stable'
        $script:WorkflowExpectations = [ordered]@{
            '.github/workflows/pr8-powershell-validation.yml' = 4
            '.github/workflows/standards-conformance.yml' = 2
            '.github/workflows/syp101-production-smoke.yml' = 2
            '.github/workflows/syp86-production-lock.yml' = 2
        }
        $script:AuthorityTests = @(
            'skill-repository-standard.Tests.ps1'
            'skill-repository-workflows.Tests.ps1'
            'standard-validation-resolver-hardening.Tests.ps1'
            'standard-validation-runner.Tests.ps1'
            'source-merge-exception-draft.Tests.ps1'
        )
        $script:AuthorityWorkflowDependencies = @(
            'pr8-powershell-validation.yml'
            'syp101-production-smoke.yml'
            'syp86-production-lock.yml'
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
        Assert-Equal ([regex]::Matches($required, 'Import-Module \$pester\.Path -Force')).Count 2 'The dedicated Linux focused job and direct Linux composition step may import Pester in workflow scope; Windows full suites must stay behind the bounded executor.'
        Assert-Equal ([regex]::Matches($required, '& ./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 2 'Both Windows full-suite jobs must delegate module validation and import to the bounded executor.'
        Assert-Equal ([regex]::Matches($required, 'Executing Pester \$\(\$pester\.Version\) through the bounded shard executor\.')).Count 2 'Workflow logging must use discovery metadata without importing the module first.'
    }

    # Scenario: PR-controlled focused tests could mutate the checkout later consumed by the authority gate.
    # Purpose: Isolate the six-case Linux boundary suite from a fresh authority checkout and preserve one required summary status.
    It 'UnitT15_runs_linux_callback_containment_before_full_suites_and_authority_gate' {
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $focusedHelperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-FocusedLinuxContainment.ps1'
        $semanticTestsPath = Join-Path $script:RepositoryRoot 'tests/standard-semantic-bridge.Tests.ps1'
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $focusedHelper = Get-Content -Raw -Encoding UTF8 -LiteralPath $focusedHelperPath
        $semanticTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $semanticTestsPath
        $focusedDescribe = 'Unix callback containment boundary'

        Assert-Match $required ([regex]::Escape($focusedDescribe)) 'PowerShell Regression must run the Unix callback containment Describe.'
        Assert-Match $standards ([regex]::Escape($focusedDescribe)) 'Standards Conformance must run the Unix callback containment Describe.'
        $describeMarker = "Describe '$focusedDescribe' -Tags LinuxContainment"
        Assert-Equal ([regex]::Matches($semanticTests, [regex]::Escape($describeMarker))).Count 1 'The semantic bridge tests must define one focused containment Describe.'
        $describeStart = $semanticTests.IndexOf($describeMarker)
        $nextDescribe = $semanticTests.IndexOf("`nDescribe ", $describeStart + $describeMarker.Length)
        $focusedTests = if ($nextDescribe -ge 0) {
            $semanticTests.Substring($describeStart, $nextDescribe - $describeStart)
        }
        else {
            $semanticTests.Substring($describeStart)
        }
        $focusedItMatches = [regex]::Matches($focusedTests, "(?m)^\s*It\s+'([^']+)'")
        Assert-Equal $focusedItMatches.Count 6 'The focused containment Describe must contain exactly six independent It cases.'
        $focusedItNames = ($focusedItMatches | ForEach-Object { $_.Groups[1].Value }) -join "`n"
        foreach ($caseMarker in @('normal', 'timeout', 'setsid', 'late', 'secret', 'procfs')) {
            Assert-Match $focusedItNames $caseMarker "The focused containment It names must include the '$caseMarker' case."
        }
        foreach ($workflow in @($required, $standards)) {
            $setupMarker = 'Enable unprivileged user namespaces on GitHub-hosted Ubuntu'
            $setupIndex = $workflow.IndexOf($setupMarker)
            $probeIndex = $workflow.IndexOf('Probe Linux PID namespace containment capability')
            Assert-True ($setupIndex -ge 0) 'Every Linux focused workflow must configure user namespace sysctls on hosted Ubuntu.'
            Assert-True ($setupIndex -lt $probeIndex) 'Hosted user namespace setup must run before the exact PID namespace capability probe.'
            Assert-Match $workflow 'RUNNER_ENVIRONMENT.*github-hosted' 'User namespace sysctl setup must be limited to GitHub-hosted runners.'
            Assert-Match $workflow 'kernel\.apparmor_restrict_unprivileged_userns' 'Hosted setup must inspect and verify the AppArmor user namespace gate when available.'
            Assert-Match $workflow 'sudo -n sysctl -w "\$apparmor_key=0"' 'Hosted setup may clear the AppArmor gate only through non-interactive sudo.'
            Assert-Match $workflow 'apparmor_before"\s*==\s*''1''' 'Hosted setup may clear the AppArmor gate only when its recorded value is one.'
            Assert-Match $workflow 'kernel\.unprivileged_userns_clone' 'Hosted setup must inspect and verify userns_clone when available.'
            Assert-Match $workflow 'sudo -n sysctl -w "\$userns_clone_key=1"' 'Hosted setup may enable userns_clone only through non-interactive sudo.'
            Assert-Match $workflow 'userns_clone_before"\s*==\s*''0''' 'Hosted setup may enable userns_clone only when its recorded value is zero.'
            Assert-Match $workflow ([regex]::Escape('apparmor_after="$(sysctl -n "$apparmor_key")"')) 'Hosted setup must reread the AppArmor gate after any conditional change.'
            Assert-Match $workflow ([regex]::Escape('userns_clone_after="$(sysctl -n "$userns_clone_key")"')) 'Hosted setup must reread userns_clone after any conditional change.'
            Assert-Match $workflow 'exact probe arguments: --user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc' 'The exact private-procfs namespace preflight must remain after hosted setup.'
            Assert-Match $workflow 'Probe Linux PID namespace containment capability' 'Every Linux focused workflow must probe PID namespace support before callback tests.'
            Assert-Match $workflow 'exact probe command: \$unshare_path --user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc -- sh -c' 'Every Linux preflight must log the exact command used to create the PID namespace and mount a private procfs.'
            Assert-Match $workflow 'exec 9</proc/self/mountinfo' 'The namespace probe must open the visible procfs mount before reading its mount identity.'
            Assert-Match $workflow '/proc/self/fdinfo/9' 'The namespace probe must use the opened procfs descriptor identity instead of choosing a stacked mountinfo row.'
            Assert-Match $workflow 'parent procfs mount ID' 'The namespace probe must record the parent visible procfs mount identity.'
            Assert-Match $workflow 'private procfs mount ID' 'The namespace probe must record the child visible procfs mount identity.'
            Assert-Match $workflow 'probe_proc_mount_id.*parent_proc_mount_id' 'The namespace probe must reject a child whose visible procfs mount is not private.'
            Assert-True $workflow.Contains('probe_namespace="${probe_output%%$''\n''*}"') 'The namespace preflight must consume captured output without a head pipeline that can trigger SIGPIPE under pipefail.'
            Assert-NotMatch $workflow 'awk .*\$5 == "/proc".*print \$1' 'The namespace preflight must not select the first /proc row when mountinfo contains stacked procfs mounts.'
            Assert-Match $workflow 'uname -a' 'The Linux capability probe must record kernel/runtime identity.'
            Assert-Match $workflow '/proc/self/ns/pid' 'The Linux capability probe must record the parent PID namespace identity.'
            Assert-Match $workflow 'namespace probe exit' 'The Linux capability probe must record its exit status.'
            Assert-Match $workflow 'namespace probe result' 'The Linux capability probe must record its namespace result.'
            Assert-True ($workflow.IndexOf('Probe Linux PID namespace containment capability') -lt $workflow.IndexOf("Run required Unix callback containment boundary")) 'The Linux capability probe must fail before focused callback tests.'
        }

        Assert-Match $standards '& ./scripts/Invoke-FocusedLinuxContainment\.ps1' 'Standards Conformance must run the dedicated focused containment helper.'
        Assert-NotMatch $standards 'Install-Module\s+Pester' 'Standards Conformance must resolve Pester through the central resolver.'
        Assert-Match $focusedHelper 'Resolve-StandardValidationTool\.ps1' 'The focused helper must use the approved central tool resolver.'
        Assert-Match $focusedHelper '-ToolName pester -Install' 'The focused helper must install the latest stable Pester through the central resolver.'
        Assert-Match $focusedHelper 'ConvertFrom-Json' 'The focused helper must consume the resolver receipt.'
        Assert-Match $focusedHelper '\$modulePath\s*=\s*\[IO\.Path\]::GetFullPath\(\[string\]\$receipt\.modulePath\)' 'The focused helper must use the module path identified by the resolver receipt.'
        Assert-Match $focusedHelper 'Import-Module\s+-Name\s+\$modulePath' 'The focused helper must import the Pester module identified by the resolver receipt.'
        Assert-Match $focusedHelper 'Invoke-Pester -Path \$testPath -TagFilter ''LinuxContainment'' -PassThru' 'The focused helper must select the tagged containment cases only.'
        Assert-Match $focusedHelper '\[int64\]\$selectedCountFromDiscovery\s*-ne\s*6' 'The Pester 6 focused gate must require exactly six discovered selected tests.'
        Assert-Match $focusedHelper '\[int64\]\$selectedCount\s*-ne\s*6' 'The Pester 6 focused gate must require exactly six selected test results.'
        Assert-Match $focusedHelper '\[int64\]\$counts\.PassedCount\s*-ne\s*6' 'The Pester 6 focused gate must require six passed tests.'
        Assert-Match $focusedHelper '\[int64\]\$counts\.FailedCount\s*-ne\s*0' 'The focused boundary gate must reject failed tests.'
        Assert-Match $focusedHelper '\[int64\]\$counts\.SkippedCount\s*-ne\s*0' 'The focused boundary gate must reject skipped tests.'
        Assert-Match $focusedHelper '\[int64\]\$counts\.PendingCount\s*-ne\s*0' 'The focused boundary gate must reject pending tests.'
        Assert-Match $focusedHelper '\[int64\]\$counts\.InconclusiveCount\s*-ne\s*0' 'The focused boundary gate must reject inconclusive tests.'
        Assert-Match $focusedHelper 'NotRunCount' 'The focused gate must account for Pester results where TotalCount includes unselected tests.'
        Assert-Match $focusedHelper '\$selectedCountFromDiscovery\s*=\s*\[int64\]\$counts\.TotalCount\s*-\s*\[int64\]\$counts\.NotRunCount' 'The focused gate must subtract Pester 6 NotRun cases from TotalCount to determine the selected count.'

        Assert-Match $required '\[int64\]\$result\.TotalCount\s*-ne\s*6' 'PR8 required focused job must select exactly six Linux containment tests.'
        Assert-Match $required '\[int\]\$result\.PassedCount\s*-ne\s*6' 'PR8 required focused job must require six passing Linux containment tests.'
        Assert-Equal ([regex]::Matches($required, 'ExpectedTotalCount\s*=\s*617').Count) 2 'Both full-suite shard jobs must include the merged resolver regressions and proposed-exception review tests.'
        Assert-Equal ([regex]::Matches($required, 'ExpectedSkippedCount\s*=\s*13').Count) 1 'Windows PowerShell 5.1 must account for the additional skipped Linux procfs case.'
        Assert-Equal ([regex]::Matches($required, 'ExpectedSkippedCount\s*=\s*12').Count) 1 'Windows PowerShell 7 must account for the additional skipped Linux procfs case.'

        $standardsJobsMatch = [regex]::Match($standards, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        Assert-True $standardsJobsMatch.Success 'Standards Conformance must define its workflow jobs block.'
        $standardsJobs = $standardsJobsMatch.Groups['block'].Value
        $standardsJobIds = [regex]::Matches($standardsJobs, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        Assert-Equal $standardsJobIds.Count 3 'Standards Conformance must isolate focused tests, authority validation, and the required summary into three jobs.'
        $standardsJobNames = @($standardsJobIds | ForEach-Object { $_.Groups[1].Value })
        foreach ($jobName in @('linux-callback-focused', 'authority-gate', 'latest-stable-authority-regression')) {
            Assert-True ($standardsJobNames -contains $jobName) "Standards Conformance must define the '$jobName' job boundary."
        }
        $focusedJobMatch = [regex]::Match($standards, '(?ms)^  linux-callback-focused:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        $authorityJobMatch = [regex]::Match($standards, '(?ms)^  authority-gate:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        $summaryJobMatch = [regex]::Match($standards, '(?ms)^  latest-stable-authority-regression:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        $compositionJobMatch = [regex]::Match($required, '(?ms)^  powershell-7-unix-composition:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)')
        Assert-True $focusedJobMatch.Success 'Standards Conformance must define an isolated focused containment job.'
        Assert-True $authorityJobMatch.Success 'Standards Conformance must define an independent canonical authority job.'
        Assert-True $summaryJobMatch.Success 'Standards Conformance must preserve its required summary job.'
        Assert-True $compositionJobMatch.Success 'PowerShell Regression must define an independent Linux composition job.'
        $focusedJob = $focusedJobMatch.Groups['block'].Value
        $authorityJob = $authorityJobMatch.Groups['block'].Value
        $summaryJob = $summaryJobMatch.Groups['block'].Value
        $compositionJob = $compositionJobMatch.Groups['block'].Value
        $stackedProcMountInfoFixture = @'
70 43 0:123 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
80 70 0:123 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
'@
        $oldFirstProcMountId = [string](($stackedProcMountInfoFixture -split '\r?\n')[0] -split '\s+')[0]
        $visibleProcMountFdInfoFixture = @'
pos: 0
flags: 0100000
mnt_id: 80
ino: 1
'@
        $visibleProcMountFdInfoFixture = $visibleProcMountFdInfoFixture -replace '\r?\n', "`r`n"
        $visibleProcMountId = [regex]::Match($visibleProcMountFdInfoFixture, '(?m)^mnt_id:\s*(?<id>[0-9]+)\r?$').Groups['id'].Value
        Assert-Equal $oldFirstProcMountId '70' 'The previous first-row mountinfo probe selects the underlying procfs in a stacked mount fixture.'
        Assert-Equal $visibleProcMountId '80' 'fdinfo for a descriptor opened on /proc/mountinfo identifies the visible top procfs mount in a stacked fixture.'
        Assert-False ($oldFirstProcMountId -eq $visibleProcMountId) 'The stacked procfs fixture must distinguish the old first-entry probe from the visible-mount probe.'
        foreach ($job in @(@{ Name = 'focused'; Block = $focusedJob }, @{ Name = 'authority'; Block = $authorityJob })) {
            Assert-Equal ([regex]::Matches($job.Block, '(?m)^\s+uses:\s*actions/checkout@[0-9a-f]{40}\b')).Count 1 "The $($job.Name) job must perform its own pinned checkout."
            Assert-Match $job.Block 'persist-credentials:\s*false' "The $($job.Name) job checkout must not persist Git credentials."
        }
        Assert-NotMatch $summaryJob 'actions/checkout@' 'The required summary job must not check out or inspect mutable source files.'
        Assert-NotMatch $standards 'upload-artifact|download-artifact|artifact:' 'Standards Conformance must not transfer workspace state between jobs.'
        Assert-Match $standards '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$' 'Standards Conformance must retain read-only repository permissions.'
        Assert-NotMatch $focusedJob '(?m)^\s+needs:' 'The focused job must be independently runnable.'
        Assert-Match $focusedJob 'Enable unprivileged user namespaces on GitHub-hosted Ubuntu' 'The focused job must configure hosted Linux namespace support.'
        Assert-Match $focusedJob 'Probe Linux PID namespace containment capability' 'The focused job must retain the exact namespace capability preflight.'
        Assert-Match $focusedJob '& ./scripts/Invoke-FocusedLinuxContainment\.ps1' 'Only the focused job must run the tagged containment helper.'
        Assert-NotMatch $focusedJob 'Invoke-StandardAuthorityGate\.ps1|Run canonical Standard v1 authority gate|setup-go@' 'The focused job must not run the authority gate or its Go runtime setup.'
        Assert-Match $authorityJob 'Set up approved Go runtime' 'The authority job must set up the approved Go runtime after its fresh checkout.'
        Assert-Match $authorityJob 'Run canonical Standard v1 authority gate' 'The authority job must execute the canonical authority gate.'
        Assert-Match $authorityJob 'Check whitespace in the event range' 'The authority job must retain the event-range whitespace check.'
        Assert-NotMatch $authorityJob 'Invoke-FocusedLinuxContainment\.ps1' 'The authority job must not run PR-controlled focused tests in its fresh authority checkout.'
        Assert-Match $authorityJob '(?m)^\s+needs:\s*linux-callback-focused\s*$' 'The authority job must wait for the focused job while using its own runner and checkout.'
        foreach ($job in @(
            @{ Name = 'authority'; Block = $authorityJob; Suite = 'Run canonical Standard v1 authority gate' },
            @{ Name = 'composition'; Block = $compositionJob; Suite = 'Run required Standard v1 authority gate' }
        )) {
            $setupMarker = 'Enable unprivileged user namespaces on GitHub-hosted Ubuntu'
            $probeMarker = 'Probe Linux PID namespace containment capability'
            $setupIndex = $job.Block.IndexOf($setupMarker)
            $probeIndex = $job.Block.IndexOf($probeMarker)
            $checkoutIndex = $job.Block.IndexOf('name: Checkout')
            $suiteIndex = $job.Block.IndexOf($job.Suite)
            Assert-True ($setupIndex -ge 0) "The fresh $($job.Name) Linux runner must configure user namespaces locally."
            Assert-True ($probeIndex -gt $setupIndex) "The fresh $($job.Name) Linux runner must probe after its local namespace setup."
            Assert-True ($checkoutIndex -gt $probeIndex) "The $($job.Name) namespace preflight must run before checkout and before any PR-controlled repository code."
            Assert-True ($suiteIndex -gt $checkoutIndex) "The $($job.Name) complete suite must run only after its own runner preflight and checkout."
            $preCheckout = $job.Block.Substring(0, $checkoutIndex)
            Assert-NotMatch $preCheckout '\./scripts/|Invoke-StandardAuthorityGate\.ps1|Invoke-Pester|tests/' "The $($job.Name) preflight must not execute PR-controlled repository code before checkout."
            Assert-Match $job.Block 'RUNNER_ENVIRONMENT.*github-hosted' "The $($job.Name) user namespace setup must be restricted to hosted runners."
            Assert-Match $job.Block 'kernel\.apparmor_restrict_unprivileged_userns' "The $($job.Name) setup must inspect and verify the AppArmor user namespace gate."
            Assert-Match $job.Block 'sudo -n sysctl -w "\$apparmor_key=0"' "The $($job.Name) setup may clear the AppArmor gate only with non-interactive sudo."
            Assert-Match $job.Block 'apparmor_after="\$\(sysctl -n "\$apparmor_key"\)"' "The $($job.Name) setup must reread the AppArmor gate after a conditional change."
            Assert-Match $job.Block 'kernel\.unprivileged_userns_clone' "The $($job.Name) setup must inspect and verify userns_clone when available."
            Assert-Match $job.Block 'sudo -n sysctl -w "\$userns_clone_key=1"' "The $($job.Name) setup may enable userns_clone only with non-interactive sudo."
            Assert-Match $job.Block 'userns_clone_after="\$\(sysctl -n "\$userns_clone_key"\)"' "The $($job.Name) setup must reread userns_clone after a conditional change."
            Assert-Match $job.Block 'exact probe arguments: --user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc' "The $($job.Name) runner must probe the reviewed PID namespace and private procfs arguments."
            Assert-Match $job.Block 'exact probe command: \$unshare_path --user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc -- sh -c' "The $($job.Name) runner must log the exact command used for its PID namespace and private procfs probe."
            Assert-Match $job.Block '\$probe_command' "The $($job.Name) probe log must identify the actual child command text."
            Assert-Match $job.Block 'parent procfs mount ID' "The $($job.Name) probe must record the parent's procfs mount identity."
            Assert-Match $job.Block 'private procfs mount ID' "The $($job.Name) probe must record the child's procfs mount identity."
            Assert-Match $job.Block 'probe_proc_mount_id.*parent_proc_mount_id' "The $($job.Name) probe must reject a child that did not mount a private procfs."
            Assert-Match $job.Block 'parent_proc_mount_id="\$\(awk .*mnt_id:.*fdinfo/9\)"' "The $($job.Name) probe must get the parent mount ID from its opened visible procfs descriptor."
            Assert-Match $job.Block 'probe_command=.*fdinfo/9' "The $($job.Name) probe must get the child mount ID from its opened visible procfs descriptor."
            Assert-Match $job.Block '/proc/self/fdinfo/9' "The $($job.Name) probe must resolve the visible procfs mount from its opened mountinfo descriptor."
            Assert-NotMatch $job.Block 'awk .*\$5 == "/proc".*print \$1' "The $($job.Name) probe must not select the first stacked /proc row."
            Assert-Match $job.Block 'namespace probe stderr' "The $($job.Name) probe must retain stderr when namespace creation fails."
            Assert-Match $job.Block 'namespace probe exit' "The $($job.Name) probe must record its exit status."
            Assert-Match $job.Block 'namespace probe result' "The $($job.Name) probe must record its child PID namespace identity."
        }
        Assert-Match $compositionJob '(?m)^\s+needs:\s*linux-callback-focused\s*$' 'The Linux composition job must preserve its focused-job dependency and run on a fresh, separately provisioned runner.'
        Assert-Match $summaryJob '(?m)^\s+name:\s*Standard v1 \(latest stable tooling\)\s*$' 'The required status job must keep its established display name.'
        Assert-Match $summaryJob '(?m)^\s+needs:\s*\r?\n\s+- linux-callback-focused\s*\r?\n\s+- authority-gate\s*$' 'The required status job must wait for both independent jobs.'
        Assert-Match $summaryJob '(?m)^\s+if:\s*\$\{\{\s*always\(\)\s*\}\}\s*$' 'The required status job must run even when a dependency fails or is skipped.'
        Assert-Match $summaryJob 'FOCUSED_RESULT:\s*\$\{\{\s*needs\.linux-callback-focused\.result\s*\}\}' 'The summary must bind the focused job result.'
        Assert-Match $summaryJob 'AUTHORITY_RESULT:\s*\$\{\{\s*needs\.authority-gate\.result\s*\}\}' 'The summary must bind the authority job result.'
        Assert-Match $summaryJob '\$env:FOCUSED_RESULT\s*-ne\s*''success''' 'The summary must fail unless the focused job result is success, including skipped or cancelled.'
        Assert-Match $summaryJob '\$env:AUTHORITY_RESULT\s*-ne\s*''success''' 'The summary must fail unless the authority job result is success, including skipped or cancelled.'
        Assert-Match $summaryJob '(?i)(throw|exit\s+1)' 'The summary must return a failing status when either dependency is not successful.'

        Assert-Match $required 'windows-powershell-51:[\s\S]*?needs:\s*[^\r\n]*linux-callback-focused' 'Windows PowerShell 5.1 full suite must depend on the Linux focused job.'
        Assert-Match $required 'powershell-7:[\s\S]*?needs:\s*[^\r\n]*linux-callback-focused' 'PowerShell 7 full suite must depend on the Linux focused job.'
        Assert-Match $required 'powershell-7-unix-composition:[\s\S]*?needs:\s*[^\r\n]*linux-callback-focused' 'The Linux composition job must depend on the dedicated focused job.'

        $focusedStepIndex = $standards.IndexOf('Run required Unix callback containment boundary')
        $goSetupIndex = $standards.IndexOf('Set up approved Go runtime')
        $authorityGateIndex = $standards.IndexOf('Run canonical Standard v1 authority gate')
        Assert-True ($focusedStepIndex -ge 0) 'Standards Conformance must define the Linux focused boundary step.'
        Assert-True ($goSetupIndex -ge 0) 'Standards Conformance must retain approved Go setup.'
        Assert-True ($authorityGateIndex -ge 0) 'Standards Conformance must retain the canonical authority gate.'
        Assert-True ($focusedStepIndex -lt $goSetupIndex) 'Standards Conformance must run Linux focused cases before Go setup.'
        Assert-True ($focusedStepIndex -lt $authorityGateIndex) 'Standards Conformance must run Linux focused cases before the authority gate.'
    }

    # Scenario: An authority suite or the Ruleset-required bridge changes without running the complete shared gate.
    # Purpose: Keep both workflow evidence surfaces bound to one gate and all authority regressions.
    It 'UnitT20_runs_dedicated_authority_CI_for_every_authority_file_and_bridge_change' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardAuthorityGate.ps1'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath

        foreach ($workflow in @($standards, $required)) {
            Assert-NotMatch $workflow 'sourceMergeExceptionProposal|pr12-source-merge-exception-proposal' 'An unapproved proposal must not route a required source check.'
            Assert-NotMatch $workflow 'sourceMergeDecision|pr12-source-merge-adoption' 'The central regression workflows cannot publish General source checks from their own jobs.'
        }

        foreach ($workflow in @($standards, $required)) {
            $setupPattern = "actions/setup-go@$($script:SetupGoSha)\s+# v7\.0\.0"
            Assert-Equal ([regex]::Matches($workflow, $setupPattern)).Count 1 'Each authority workflow must use the reviewed immutable setup-go v7.0.0 commit exactly once.'
            Assert-Match $workflow "go-version:\s*'stable'" 'Each authority workflow must provision the latest stable Go runtime.'
            Assert-Match $workflow 'check-latest:\s*true' 'Authority Go setup must check for the latest stable runtime.'
            Assert-NotMatch $workflow "go-version:\s*'[0-9]+\.[0-9]+\.[0-9]+'" 'Authority workflows must not pin a Go patch version.'
            Assert-Match $workflow 'cache:\s*false' 'Authority Go setup must not restore a cross-run module or build cache.'
            Assert-NotMatch $workflow 'actions/setup-go@v[0-9]+' 'Authority workflows must not use a mutable setup-go tag.'
            Assert-Match $workflow 'STANDARD_GO_RUNTIME_VERSION=\$\(\$Matches\.version\)' 'Authority workflows must capture the exact Go runtime resolved by setup-go.'
            Assert-Match $workflow '& ./scripts/Invoke-StandardAuthorityGate\.ps1 -ArtifactsRoot \$env:RUNNER_TEMP -ExpectedGoRuntimeVersion \$env:STANDARD_GO_RUNTIME_VERSION -GoCommandPath \$env:STANDARD_GO_COMMAND_PATH' 'Authority workflows must pass the setup-go resolved runtime into the shared gate.'
            Assert-True ($workflow.IndexOf('actions/setup-go@') -lt $workflow.IndexOf('STANDARD_GO_RUNTIME_VERSION=')) 'The approved Go runtime must be provisioned before its version is captured.'
            Assert-True ($workflow.IndexOf('STANDARD_GO_RUNTIME_VERSION=') -lt $workflow.IndexOf('& ./scripts/Invoke-StandardAuthorityGate.ps1')) 'The resolved Go runtime must be captured before the authority gate starts.'
        }

        foreach ($workflowName in $script:AuthorityWorkflowDependencies) {
            $pattern = "'\.github/workflows/{0}'" -f [regex]::Escape($workflowName)
            Assert-Equal ([regex]::Matches($standards, $pattern)).Count 2 "Push and pull-request path filters must both include authority workflow '$workflowName'."
        }
        Assert-Equal ([regex]::Matches($standards, "'scripts/Invoke-FocusedLinuxContainment\.ps1'")).Count 2 'Push and pull-request path filters must both include the focused Linux containment helper.'
        Assert-Equal ([regex]::Matches($standards, 'Invoke-StandardAuthorityGate\.ps1')).Count 3 'Dedicated CI must watch and invoke the shared authority gate.'
        Assert-Equal ([regex]::Matches($required, 'Invoke-StandardAuthorityGate\.ps1')).Count 1 'Required Composition CI must invoke the shared authority gate.'
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($standards, [regex]::Escape($testName))).Count 2 "Dedicated authority workflow must watch '$testName' for push and pull request events."
            Assert-Equal ([regex]::Matches($gate, [regex]::Escape($testName))).Count 1 "Shared authority gate must execute '$testName'."
        }
        Assert-Match $gate 'ExpectedGoRuntimeVersion = \$env:STANDARD_GO_RUNTIME_VERSION' 'The shared authority gate must require the setup-go resolved runtime when invoked directly.'
        Assert-Match $gate '-ExpectedGoRuntimeVersion \$expectedGoRuntimeVersion' 'The shared authority gate must pass the resolved runtime into the resolver.'
        Assert-Match $gate '-GoCommandPath \$goCommandPath' 'The shared authority gate must pass the run-resolved Go executable path into the resolver.'
        Assert-Match $gate 'skill-validator receipt Go runtime.*does not match the setup-go run-resolved latest stable runtime' 'The shared authority gate must bind the resolver receipt to setup-go evidence.'
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

    # Scenario: The managed lifecycle contract changes without reaching the required authority workflow or its regression gate.
    # Purpose: Keep SYP-194 lifecycle semantics on the same central Standard CI path as every other authority change.
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

        Assert-Match $standardWorkflow "'docs/standards/\*\*'" 'Dedicated authority workflow must watch the complete central standards directory.'
        foreach ($workflow in @($standardWorkflow, $requiredWorkflow)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Every authority workflow must execute the shared authority gate.'
        }
        Assert-Match $standardTests 'UnitT70_binds_managed_lifecycle_to_the_central_standard_authority' 'The workflow gate must execute lifecycle-specific authority regression.'
    }

    # Scenario: An upstream interoperability decision changes without reaching the required authority workflow or regression gate.
    # Purpose: Keep SYP-193 Plugin/Agent Skills boundary changes under the same central Standard CI semantics.
    It 'UnitT50_routes_upstream_interoperability_changes_through_the_central_authority_gate' {
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
        Assert-Match $standards "'docs/standards/\*\*'" 'Dedicated authority workflow must watch the upstream interoperability record.'
        foreach ($workflow in @($standards, $required)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Every authority workflow must execute the shared gate for upstream changes.'
            Assert-Match $workflow 'scripts/Validate-UpstreamAdapter\.ps1' 'Every authority workflow must trigger when the upstream adapter validator changes.'
        }
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
        Assert-Match $gate 'Validate-UpstreamAdapter\.ps1' 'The authority gate must execute the upstream adapter validator.'
        Assert-Match $gate 'upstream-adapter\.json' 'The authority gate must load the upstream adapter policy.'
    }

    # Scenario: The canonical validation/security policy changes without reaching both authority workflows and its executable gate.
    # Purpose: Keep SYP-192 stage order and fail-closed semantics under the same merge-blocking authority path.
    It 'UnitT60_routes_validation_security_gate_changes_through_the_central_authority_gate' {
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

        Assert-Match $standards 'docs/standards/\*\*' 'Dedicated authority workflow must watch the central validation/security policy.'
        Assert-Match $standards 'scripts/StandardSemanticBridge\.psm1' 'Dedicated authority workflow must watch the semantic bridge implementation.'
        Assert-Match $standards 'tests/standard-semantic-bridge\.Tests\.ps1' 'Dedicated authority workflow must watch the semantic bridge behavior suite.'
        foreach ($workflow in @($standards, $required)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Authority workflows must execute the shared gate for validation/security changes.'
        }
        Assert-Match $gate 'validation-security-gate\.json' 'Shared authority gate must load the canonical validation/security policy.'
        Assert-Match $gate 'Assert-AuthorityValidationSecurityGate' 'Shared authority gate must enforce the canonical validation/security policy.'
        Assert-Match $gate 'semanticPreflight' 'Shared authority gate must enforce the semantic preflight policy.'
        Assert-Match $gate 'llm-input-equals-strict-utf8-decoding-of-verified-source-bytes' 'Shared authority gate must enforce the semantic provider-input binding.'
        Assert-Match $gate 'full-byte-manifest-plus-authenticated-provider-text-subset-with-strict-utf8-v1-digest' 'Shared authority gate must enforce the separate provider-text inventory binding.'
        Assert-Match $gate 'standard-semantic-inventory-probe\.Tests\.ps1' 'Shared authority gate must execute semantic inventory behavior regressions.'
        Assert-Match $gate 'standard-semantic-preflight\.Tests\.ps1' 'Shared authority gate must execute semantic preflight behavior regressions.'
        Assert-Match $gate 'standard-semantic-raw-graph\.Tests\.ps1' 'Shared authority gate must execute raw-graph behavior regressions.'
        Assert-Match $gate 'standard-semantic-bridge\.Tests\.ps1' 'Shared authority gate must execute semantic bridge behavior regressions.'
        Assert-Match $gate 'STANDARD_AUTHORITY_PYTHON' 'Shared authority gate must supply the frozen SkillSpector Python to semantic behavior suites.'
        foreach ($isolatedPythonSuite in @('standard-semantic-inventory-probe.Tests.ps1','standard-semantic-raw-graph.Tests.ps1')) {
            $suiteText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot $isolatedPythonSuite)
            Assert-Match $suiteText '& \$script:Python -I -B' "Semantic suite '$isolatedPythonSuite' must use isolated Python startup."
        }
        Assert-Match $gate 'one-successful-provider-call-per-planned-work-item-with-matching-analyzer-path-and-interval' 'Shared authority gate must enforce per-work provider-call binding.'
        Assert-Match $gate 'reject-decoded-duplicate-properties-with-ordinal-ignore-case-semantics-before-deserialization' 'Shared authority gate must enforce scanner JSON property-collision handling.'
        Assert-Match $standardTests 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' 'The workflow gate must execute SYP-192 validation/security regression.'
    }

    # Scenario: A consumer adds a renamed workflow, hook, release command, or duplicate trigger adapter around a component script.
    # Purpose: Enforce the central entry-point inventory contract while allowing non-authoritative components and status-only compatibility jobs.
    It 'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles' {
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
}
