

Describe 'Pester shard plan contract' {
    # Scenario: The complete repository suite contains many non-isolated test files and one file can terminate its hosted PowerShell process.
    # Purpose: Give every bulk test file an independent owned process by default while retaining an exact, configurable partition for bounded diagnostics.
    It 'UnitT10_partitions_bulk_tests_into_independent_owned_processes_by_default' {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $shardPath = Join-Path $repositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'The shard executor must parse before shard-plan testing.' }
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'New-PesterShardPlan'
        }, $true)
        if ($null -eq $definition) { throw 'The shard executor must expose a testable deterministic shard planner.' }
        Invoke-Expression $definition.Extent.Text

        $testRoot = Join-Path $TestDrive 'shard-plan-tests'
        $allPaths = @(
            (Join-Path $testRoot 'alpha.Tests.ps1'),
            (Join-Path $testRoot 'standard-validation-runner.Tests.ps1'),
            (Join-Path $testRoot 'beta.Tests.ps1'),
            (Join-Path $testRoot 'syp101-production-smoke-contract.Tests.ps1'),
            (Join-Path $testRoot 'gamma.Tests.ps1')
        )
        $isolatedNames = @(
            'standard-validation-runner.Tests.ps1',
            'syp101-production-smoke-contract.Tests.ps1'
        )

        $defaultPlan = @(New-PesterShardPlan -AllTestPaths $allPaths -IsolatedTestFileNames $isolatedNames)
        if ($defaultPlan.Count -ne 5) { throw 'The default plan must create one owned process per discovered test file.' }
        if (@($defaultPlan | Where-Object { @($_.Paths).Count -ne 1 }).Count -ne 0) { throw 'Every default shard must contain exactly one test file.' }
        $defaultPartition = @($defaultPlan | ForEach-Object { @($_.Paths) })
        if ((($defaultPartition | Sort-Object) -join "`n") -cne (($allPaths | Sort-Object) -join "`n")) { throw 'The default shard plan must be an exact partition of the discovered inventory.' }
        if (@($defaultPartition | Group-Object | Where-Object { $_.Count -ne 1 }).Count -ne 0) { throw 'No test file may be duplicated across shards.' }
        if ([string]$defaultPlan[2].Name -notmatch '^bulk-001-alpha$') { throw 'A single-file bulk shard name must identify its deterministic ordinal and public test basename.' }

        $reversedPlan = @(New-PesterShardPlan -AllTestPaths @($allPaths[4], $allPaths[3], $allPaths[2], $allPaths[1], $allPaths[0]) -IsolatedTestFileNames $isolatedNames)
        if ((($reversedPlan | ForEach-Object { "{0}:{1}" -f $_.Name, (@($_.Paths) -join '|') }) -join "`n") -cne
            (($defaultPlan | ForEach-Object { "{0}:{1}" -f $_.Name, (@($_.Paths) -join '|') }) -join "`n")) {
            throw 'Shard identities and path order must be ordinally deterministic regardless of discovery order or host culture.'
        }

        $groupedPlan = @(New-PesterShardPlan -AllTestPaths $allPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 2)
        if ($groupedPlan.Count -ne 4) { throw 'An explicit group size must retain two isolated shards and two bounded bulk shards.' }
        if (@($groupedPlan[2].Paths).Count -ne 2) { throw 'The first configured bulk shard must contain at most the configured number of paths.' }
        if (@($groupedPlan[3].Paths).Count -ne 1) { throw 'The final configured bulk shard must retain the remainder without padding or omission.' }
        $groupedPartition = @($groupedPlan | ForEach-Object { @($_.Paths) })
        if ((($groupedPartition | Sort-Object) -join "`n") -cne (($allPaths | Sort-Object) -join "`n")) { throw 'A configured shard plan must remain an exact partition.' }
    }
}

Describe 'source conformance projection' {
    BeforeAll {
        $script:SourceProjectionRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceProjectionRunnerPath = Join-Path $script:SourceProjectionRepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
        $script:SourceProjectionArtifactRoot = Join-Path $TestDrive 'source-projection-artifacts'
        [void](New-Item -ItemType Directory -Path $script:SourceProjectionArtifactRoot -Force)
        . $script:SourceProjectionRunnerPath `
            -CandidateRoot $script:SourceProjectionRepositoryRoot `
            -AdapterPath $script:SourceProjectionRunnerPath `
            -ArtifactsRoot $script:SourceProjectionRepositoryRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly

        function Assert-SourceProjectionEqual {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-SourceProjectionFailure {
            param($InputValue, [string] $ExpectedReason)
            try {
                $projection = New-StandardValidationSourceConformanceResult `
                    -Report $InputValue.report `
                    -ExpectedSourceRevision ('a' * 40) `
                    -RepositoryTestEvidence $InputValue.tests `
                    -RepositoryTestDispatches $InputValue.dispatches
            }
            catch {
                throw "Projection threw while testing '$ExpectedReason': $($_.Exception.Message) $($_.ScriptStackTrace)"
            }
            Assert-SourceProjectionEqual $projection.status 'failed' "Projection must reject '$ExpectedReason'."
            if (@($projection.failureReasons) -notcontains $ExpectedReason) { throw "Projection must identify '$ExpectedReason'." }
            if ([bool]$projection.releaseEligible) { throw 'A failed source projection must remain release-ineligible.' }
        }

        function New-SourceProjectionEvent {
            param([string] $StageId, [string] $ToolId, [AllowNull()] $SkillId, [string] $CandidateId)
            $eventId = [guid]::NewGuid().ToString()
            $stdout = 'source projection fixture output'
            $stderr = ''
            $outputPath = Join-Path (Join-Path $script:SourceProjectionArtifactRoot $StageId) "event-$eventId.json"
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force)
            $rawOutput = [ordered]@{
                schemaVersion = 1
                eventId = $eventId
                stageId = $StageId
                toolId = $ToolId
                skillId = $SkillId
                candidateId = $CandidateId
                process = [ordered]@{ exitCode = 0; status = 'passed'; stdout = $stdout; stderr = $stderr; cleanedUp = $true }
                stdout = $stdout
                stderr = $stderr
            }
            [IO.File]::WriteAllText($outputPath, ($rawOutput | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject][ordered]@{
                eventId = $eventId
                stageId = $StageId
                toolId = $ToolId
                skillId = $SkillId
                candidateId = $CandidateId
                commandSha256 = 'e' * 64
                exitCode = 0
                status = 'passed'
                outputSha256 = Get-StandardValidationOutputHash -Stdout $stdout -Stderr $stderr
                outputPath = $outputPath
                cleanedUp = $true
            }
        }

        function New-SourceProjectionRepositoryTestRecord {
            param(
                [Parameter(Mandatory = $true)] $Event,
                [Parameter(Mandatory = $true)][string] $ToolId,
                [Parameter(Mandatory = $true)][array] $Inventory,
                [Parameter(Mandatory = $true)] $TestResult,
                [ValidateSet('general', 'pester')][string] $Kind = 'pester'
            )
            $domainResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = "fixture:$ToolId" }
            $envelope = [ordered]@{
                schemaVersion = 1
                status = 'passed'
                decision = 'PASS'
                candidateIdentity = [string]$Event.candidateId
                testInventory = @($Inventory)
                testResult = $TestResult
                domainAdapterResult = $domainResult
            }
            $stdout = $envelope | ConvertTo-Json -Depth 20 -Compress
            $rawOutput = Get-Content -Raw -Encoding UTF8 -LiteralPath $Event.outputPath | ConvertFrom-Json
            $rawOutput.process.stdout = $stdout
            $rawOutput.stdout = $stdout
            [IO.File]::WriteAllText($Event.outputPath, ($rawOutput | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            $Event.outputSha256 = Get-StandardValidationOutputHash -Stdout $stdout -Stderr ''
            return [pscustomobject][ordered]@{
                toolRole = if ($Kind -ceq 'pester') { 'pester' } else { 'domain' }
                toolId = $ToolId
                eventId = [string]$Event.eventId
                candidateId = [string]$Event.candidateId
                outputSha256 = [string]$Event.outputSha256
                testInventory = @($Inventory)
                testResult = $TestResult
                domainAdapterResult = $domainResult
            }
        }

        function New-SourceProjectionInput {
            $sourceRevision = 'a' * 40
            $candidateId = 'b' * 64
            $contentSha256 = 'c' * 64
            $stageIds = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static', 'repository-tests', 'conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')
            $stages = @()
            for ($index = 0; $index -lt $stageIds.Count; $index++) {
                $status = if ($index -lt 5) { 'passed' } elseif ($index -eq 5) { 'blocked' } else { 'not-applicable' }
                $stages += [pscustomobject][ordered]@{ order = $index + 1; id = $stageIds[$index]; condition = 'fixture'; status = $status; startedAt = '2026-09-25T00:00:00Z'; endedAt = '2026-09-25T00:00:01Z'; reason = $null; events = @() }
            }
            $stages[2].events = @(
                (New-SourceProjectionEvent 'package-validation' 'package-adapter' $null $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-validator' 'alpha' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-tools' 'alpha' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-validator' 'beta' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-tools' 'beta' $candidateId)
            )
            $stages[3].events = @((New-SourceProjectionEvent 'skillspector-static' 'staticAnalyzer' $null $candidateId))
            $generalEvent = New-SourceProjectionEvent 'repository-tests' 'general.dispatch' $null $candidateId
            $pesterWindowsEvent = New-SourceProjectionEvent 'repository-tests' 'windows-pester' $null $candidateId
            $pesterLinuxEvent = New-SourceProjectionEvent 'repository-tests' 'linux.pester' $null $candidateId
            $stages[4].events = @($generalEvent, $pesterWindowsEvent, $pesterLinuxEvent)
            $report = [pscustomobject][ordered]@{
                schemaVersion = 1
                evidence = 'standard-validation-evidence-v1'
                contract = 'standard-validation-contract-v1'
                runId = [guid]::NewGuid().ToString()
                state = 'BLOCKED'
                exitCode = 10
                releaseEligible = $false
                artifacts = [pscustomobject][ordered]@{ root = $script:SourceProjectionArtifactRoot; lockPath = Join-Path $script:SourceProjectionArtifactRoot 'fixture.lock' }
                candidate = [pscustomobject][ordered]@{ sourceRepository = 'https://example.com/example/skills.git'; sourceRevision = $sourceRevision; baseRevision = 'b' * 40; eventName = 'pull_request'; candidateId = $candidateId; contentSha256 = $contentSha256; activeSkills = @('alpha', 'beta') }
                stages = $stages
            }
            $tests = @(
                (New-SourceProjectionRepositoryTestRecord -Event $generalEvent -ToolId 'general.dispatch' -Inventory @('tests/general.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' }) -Kind general)
                (New-SourceProjectionRepositoryTestRecord -Event $pesterWindowsEvent -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 3; passed = 2; skipped = 1 }))
                (New-SourceProjectionRepositoryTestRecord -Event $pesterLinuxEvent -ToolId 'linux.pester' -Inventory @('tests/linux.alpha.Tests.ps1', 'tests/linux.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 4; passed = 3; skipped = 1 }))
            )
            $dispatches = @(
                [pscustomobject]@{ id = 'general.dispatch'; kind = 'general' },
                [pscustomobject]@{ id = 'windows-pester'; kind = 'pester' },
                [pscustomobject]@{ id = 'linux.pester'; kind = 'pester' }
            )
            return [pscustomobject][ordered]@{ report = $report; tests = $tests; dispatches = $dispatches }
        }
    }

    # Scenario: The canonical report reaches a blocked Stage 6 after complete source checks.
    # Purpose: Prove the source projection preserves candidate and execution evidence without creating release authority.
    It 'InterT13_projects_candidate_bound_source_conformance_and_rejects_incomplete_evidence' {
        $sourceInput = New-SourceProjectionInput
        $sourceInput.tests = @($sourceInput.tests[2], $sourceInput.tests[0], $sourceInput.tests[1])
        $projection = New-StandardValidationSourceConformanceResult `
            -Report $sourceInput.report `
            -ExpectedSourceRevision ('a' * 40) `
            -RepositoryTestEvidence $sourceInput.tests `
            -RepositoryTestDispatches $sourceInput.dispatches
        if ($projection.status -cne 'passed') {
            throw "Complete source-stage evidence must pass. failureReasons='$(@($projection.failureReasons) -join ',')'."
        }
        Assert-SourceProjectionEqual $projection.status 'passed' 'Complete source-stage evidence must pass.'
        Assert-SourceProjectionEqual $projection.scope 'source-stages-1-5' 'The projection must declare its bounded scope.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.state 'BLOCKED' 'Canonical Stage 6 state must remain visible.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.exitCode 10 'Canonical exit code must remain BLOCKED=10.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.stage6Status 'blocked' 'Stage 6 must remain blocked.'
        Assert-SourceProjectionEqual $projection.pester.eventCount 2 'Both count-bearing dispatches must be represented.'
        Assert-SourceProjectionEqual @($projection.pester.events).Count 2 'The projection must enumerate every count-bearing dispatch.'
        Assert-SourceProjectionEqual $projection.pester.events[0].toolId 'windows-pester' 'The first custom adapter ID must remain bound in Stage 5 order.'
        Assert-SourceProjectionEqual $projection.pester.events[1].toolId 'linux.pester' 'The second custom adapter ID must remain bound in Stage 5 order.'
        Assert-SourceProjectionEqual $projection.pester.total 7 'Pester totals must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.passed 5 'Pester passed counts must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.skipped 2 'Pester skipped counts must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.testInventoryCount 4 'The Pester inventory count must aggregate count-bearing dispatches.'
        $case = New-SourceProjectionInput; $case.report.state = 'PASS'; $case.report.exitCode = 0
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        if ([bool]$projection.releaseEligible -or [bool]$sourceInput.report.releaseEligible) { throw 'Source-only conformance must not authorize release.' }
        Assert-SourceProjectionEqual $sourceInput.report.state 'BLOCKED' 'Projection must not mutate canonical state.'
        Assert-SourceProjectionEqual $sourceInput.report.exitCode 10 'Projection must not mutate canonical exit code.'

        $case = New-SourceProjectionInput; $case.report.candidate.candidateId = ('B' + ('b' * 63))
        Assert-SourceProjectionFailure $case 'candidate-id-invalid'
        $case = New-SourceProjectionInput; $case.report = $null
        Assert-SourceProjectionFailure $case 'report-missing'
        $case = New-SourceProjectionInput; $case.report.stages = @($case.report.stages | Select-Object -Skip 1)
        Assert-SourceProjectionFailure $case 'canonical-stage-count-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[3].status = 'failed'
        Assert-SourceProjectionFailure $case 'source-stage-4-not-passed'
        $case = New-SourceProjectionInput; $case.report.stages[4].status = 'failed'
        Assert-SourceProjectionFailure $case 'source-stage-5-not-passed'
        $case = New-SourceProjectionInput; $case.report.stages[2].events = @()
        Assert-SourceProjectionFailure $case 'package-validation-events-missing'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].candidateId = 'f' * 64
        Assert-SourceProjectionFailure $case 'repository-tests-event-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].cleanedUp = $false
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; [void]$case.report.stages[4].events[1].PSObject.Properties.Remove('cleanedUp')
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; [void]$case.report.stages[4].events[1].PSObject.Properties.Remove('outputPath')
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].outputPath = Join-Path $script:SourceProjectionArtifactRoot 'missing-event.json'
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].outputPath = Join-Path ([IO.Path]::GetTempPath()) 'outside-source-event.json'
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput
        $rawOutput = Get-Content -Raw -Encoding UTF8 -LiteralPath $case.report.stages[4].events[1].outputPath | ConvertFrom-Json
        $rawOutput.stdout = 'tampered source event output'
        [IO.File]::WriteAllText($case.report.stages[4].events[1].outputPath, ($rawOutput | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[5].status = 'not-applicable'
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        $case = New-SourceProjectionInput; $case.report.exitCode = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        $case = New-SourceProjectionInput; $case.report.schemaVersion = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'report-envelope-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[0].order = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'source-stage-1-identity-invalid'
        $case = New-SourceProjectionInput; $case.report.candidate.sourceRevision = 'f' * 40
        Assert-SourceProjectionFailure $case 'candidate-revision-mismatch'
        $case = New-SourceProjectionInput; $case.tests = @()
        Assert-SourceProjectionFailure $case 'pester-evidence-missing-or-ambiguous'
        # Scenario: A general dispatch reports counts while an actual Pester dispatch reports none.
        # Purpose: A different dispatch must not conceal an unexecuted Pester suite.
        $case = New-SourceProjectionInput
        $case.tests[0] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[0] -ToolId 'general.dispatch' -Inventory @('tests/general.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 1; passed = 1; skipped = 0 }) -Kind general
        $case.tests[1] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[1] -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' })
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput
        $case.tests[1] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[1] -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' })
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.dispatches[1].kind = 'unknown'
        Assert-SourceProjectionFailure $case 'repository-test-dispatch-kind-invalid'
        $case = New-SourceProjectionInput; $case.dispatches[1].kind = 'general'
        Assert-SourceProjectionFailure $case 'repository-test-role-or-id-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 0; $case.tests[1].testResult.passed = 0; $case.tests[1].testResult.skipped = 0
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 3; $case.tests[1].testResult.passed = 0; $case.tests[1].testResult.skipped = 3
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.Remove('passed')
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 4
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput
        foreach ($recordIndex in @(1, 2)) {
            $case.tests[$recordIndex].testResult.total = [int]::MaxValue
            $case.tests[$recordIndex].testResult.passed = [int]::MaxValue
            $case.tests[$recordIndex].testResult.skipped = 0
        }
        Assert-SourceProjectionFailure $case 'pester-aggregate-counts-out-of-range'
        $case = New-SourceProjectionInput; $case.tests[1].testInventory = @()
        Assert-SourceProjectionFailure $case 'pester-test-inventory-or-raw-event-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].outputSha256 = 'f' * 64
        Assert-SourceProjectionFailure $case 'pester-event-binding-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].toolRole = 'untrusted-role'
        Assert-SourceProjectionFailure $case 'repository-test-role-or-id-invalid'
        $case = New-SourceProjectionInput; $case.report.releaseEligible = $true
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'

        $earlyFailedReportPath = Join-Path $script:SourceProjectionArtifactRoot ('early-failed-' + [guid]::NewGuid().ToString('N') + '.json')
        $earlyFailedEvidence = New-StandardValidationCandidateEvidence `
            -RunId ([guid]::NewGuid()) `
            -State 'FAILED' `
            -ExitCode 20 `
            -ReleaseEligible $false `
            -Candidate $null `
            -Adapter $null `
            -Authority $null `
            -Stages (New-StandardValidationStages) `
            -FailureState 'FAILED' `
            -FailureMessage 'Synthetic early failure before candidate evidence was available.' `
            -ArtifactRoot $script:SourceProjectionArtifactRoot `
            -LockPath 'fixture.lock' `
            -DevelopmentHarness $true `
            -LaunchBinding $null
        $earlyFailedSource = New-StandardValidationSourceConformanceResult `
            -Report $earlyFailedEvidence `
            -ExpectedSourceRevision ('a' * 40) `
            -RepositoryTestEvidence @()
        $earlyFailedEvidence | Add-Member -NotePropertyName sourceConformance -NotePropertyValue $earlyFailedSource -Force
        [void](Write-StandardValidationJsonCreate -Path $earlyFailedReportPath -Value $earlyFailedEvidence -Context 'early failed finalization fixture')
        $persistedEarlyFailedEvidence = Get-StandardValidationJson -Path $earlyFailedReportPath -Context 'early failed finalization fixture'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.state 'FAILED' 'Source projection must not prevent canonical FAILED report writing when candidate evidence is unavailable.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.exitCode 20 'An early FAILED report must retain its canonical exit code.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.sourceConformance.status 'failed' 'Missing candidate evidence must fail only the source projection.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.sourceConformance.releaseEligible $false 'Early FAILED output must remain release-ineligible.'
    }
}




Describe 'S1B3 ordinary default adapter version' {
    # Scenario: The public CLI receives a v1 adapter without legacy mode switches.
    # Purpose: Capture the ordinary entry's actual exit and prove version rejection precedes legacy gates.
    It 'rejects_v1_adapter_before_supervisor_gate' {
        $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('standard-validation-v1-default-' + [guid]::NewGuid().ToString('N'))
        $candidate = Join-Path $testRoot 'candidate'
        $artifacts = Join-Path $testRoot 'artifacts'
        $adapter = Join-Path $testRoot 'adapter.json'
        [void](New-Item -ItemType Directory -Path $candidate -Force)
        [void](New-Item -ItemType Directory -Path $artifacts -Force)
        [IO.File]::WriteAllText($adapter, '{"schemaVersion":1}', (New-Object Text.UTF8Encoding($false)))
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $runnerPath = Join-Path $repoRoot 'scripts/Invoke-StandardValidation.ps1'
        $runtime = if ($PSVersionTable.PSEdition -eq 'Desktop') { Join-Path $PSHOME 'powershell.exe' } else { Join-Path $PSHOME 'pwsh.exe' }
        $scriptText = @"
`$ErrorActionPreference = 'Stop'
& '$runnerPath' -CandidateRoot '$candidate' -AdapterPath '$adapter' -ArtifactsRoot '$artifacts' -OutputPath '$artifacts/evidence.json' -SourceRepository 'https://example.com/example/skills.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -EventName local -TrustedToolRoot '$PSHOME'
if (`$null -eq `$LASTEXITCODE) { exit 0 }
exit ([int]`$LASTEXITCODE)
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $runtime
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $started = $false
        try {
            if (-not $process.Start()) { throw 'Ordinary v1 CLI fixture process did not start.' }
            $started = $true
            $processId = [int]$process.Id
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                try { $process.Kill() } catch { }
                [void]$process.WaitForExit(10000)
                throw "Ordinary v1 CLI fixture timed out; pid=$processId; cleaned=$($process.HasExited)."
            }
            $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            $stderr = [string]$stderrTask.GetAwaiter().GetResult()
            $output = $stdout + "`n" + $stderr
            if ([int]$process.ExitCode -ne 30) { throw "Ordinary v1 CLI expected exit 30, got $($process.ExitCode). Output: $output" }
            if ($output -notmatch '(?i)core.*v2|v1.*ordinary') { throw "Ordinary v1 CLI did not report the core-v2 version mismatch. Output: $output" }
            if ($output -match 'SupervisorLaunchBindingPath') { throw "Ordinary v1 CLI reached the retired supervisor gate before reporting version mismatch. Output: $output" }
        }
        finally {
            if ($started) {
                try { if (-not $process.HasExited) { $process.Kill() } } catch { }
                try { [void]$process.WaitForExit(10000) } catch { }
            }
            $process.Dispose()
            $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if ($resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedTestRoot -PathType Container)) {
                Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
            }
        }
    }
}

Describe 'S1B3 ordinary v2 retained refusal boundaries' {
    BeforeAll {
        $script:CoreBoundaryRunnerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1'
        $script:CoreBoundaryRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $authoritySafeDirectory = 'safe.directory=' + $script:CoreBoundaryRepositoryRoot
        $authorityRevisionOutput = & git -c $authoritySafeDirectory -C $script:CoreBoundaryRepositoryRoot rev-parse HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the authority fixture revision.' }
        $script:CoreBoundaryAuthorityRevision = ([string]$authorityRevisionOutput).Trim()
        $script:CoreBoundaryPowerShellPath = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -PathType Leaf) {
            Join-Path $PSHOME 'pwsh.exe'
        }
        else { Join-Path $PSHOME 'powershell.exe' }

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Write-CoreBoundaryUtf8 {
            param([string] $Path, [string] $Text)
            $parent = Split-Path -Parent $Path
            [void](New-Item -ItemType Directory -Path $parent -Force)
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function Quote-CoreBoundaryArgument {
            param([AllowEmptyString()][string] $Value)
            $builder = New-Object Text.StringBuilder
            [void]$builder.Append('"')
            $backslashCount = 0
            foreach ($character in $Value.ToCharArray()) {
                if ([char]$character -eq [char]92) { $backslashCount++; continue }
                if ([char]$character -eq [char]34) {
                    [void]$builder.Append(([char]92), (2 * $backslashCount + 1))
                    [void]$builder.Append([char]34)
                    $backslashCount = 0
                    continue
                }
                if ($backslashCount -gt 0) { [void]$builder.Append(([char]92), $backslashCount) }
                [void]$builder.Append([char]$character)
                $backslashCount = 0
            }
            if ($backslashCount -gt 0) { [void]$builder.Append(([char]92), (2 * $backslashCount)) }
            [void]$builder.Append('"')
            return $builder.ToString()
        }

        function Invoke-CoreBoundaryGit {
            param([string] $Path, [string[]] $GitArguments)
            $output = & git -c core.autocrlf=false -C $Path @GitArguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Core boundary fixture git failed: $($GitArguments -join ' ')`n$($output -join "`n")" }
            return (@($output | ForEach-Object { [string]$_ }) -join "`n")
        }

        function New-CoreBoundaryFixture {
            param(
                [string] $Root,
                [ValidateSet('pass', 'failed-child', 'timeout', 'source-mutate', 'zero-pester', 'slow-pester', 'slow-general')]
                [string] $Behavior = 'pass',
                [ValidateSet('general', 'pester')]
                [string] $Kind = 'general'
            )
            [void](New-Item -ItemType Directory -Path $Root -Force)
            $candidate = Join-Path $Root 'candidate'
            $skills = Join-Path $candidate 'skills/alpha'
            $checks = Join-Path $candidate 'checks'
            [void](New-Item -ItemType Directory -Path $skills -Force)
            [void](New-Item -ItemType Directory -Path $checks -Force)
            Write-CoreBoundaryUtf8 -Path (Join-Path $candidate '.gitignore') -Text "fixture-private.txt`n"
            $skillPath = Join-Path $skills 'SKILL.md'
            Write-CoreBoundaryUtf8 -Path $skillPath -Text "---`nname: alpha`ndescription: harmless core boundary fixture`n---`n`n# Alpha`n"
            $checkBody = switch ($Behavior) {
                'failed-child' { "Write-Output 'fixture child failure'; exit 7`n"; break }
                'timeout' { "Start-Sleep -Seconds 15`n"; break }
                'source-mutate' {
                    $quotedSkillPath = "'" + $skillPath.Replace("'", "''") + "'"
                    "Add-Content -LiteralPath $quotedSkillPath -Value '# mutated by trusted fixture child'`nWrite-Output 'fixture source mutation'`n"
                    break
                }
                'zero-pester' { "`$zeroReport = [ordered]@{schemaVersion=1;report='standard-core-pester-result-v1';total=0;passed=0;failed=0;skipped=0} | ConvertTo-Json -Compress`nWrite-Output `$zeroReport`n"; break }
                'slow-pester' { "Start-Sleep -Seconds 5`n`$oneReport = [ordered]@{schemaVersion=1;report='standard-core-pester-result-v1';total=1;passed=1;failed=0;skipped=0} | ConvertTo-Json -Compress`nWrite-Output `$oneReport`n"; break }
                'slow-general' { "Start-Sleep -Seconds 2`nWrite-Output 'fixture check passed'`n"; break }
                default { "Write-Output 'fixture check passed'`n" }
            }
            Write-CoreBoundaryUtf8 -Path (Join-Path $checks 'run.ps1') -Text $checkBody
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('init', '--quiet'))
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('config', 'user.name', 'SYP-226 Core Fixture'))
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('config', 'user.email', 'syp226-core-fixture@example.invalid'))
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('add', '--all'))
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('commit', '--quiet', '-m', 'trusted core boundary fixture'))
            [void](Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('remote', 'add', 'origin', 'https://example.com/example/skills.git'))
            $sourceRevisionOutput = Invoke-CoreBoundaryGit -Path $candidate -GitArguments @('rev-parse', 'HEAD')
            $sourceRevision = ([string]$sourceRevisionOutput).Trim()
            Write-CoreBoundaryUtf8 -Path (Join-Path $candidate 'fixture-private.txt') -Text 'fixture private content must not enter the core snapshot'

            $trustedToolsRoot = Join-Path $Root 'trusted-tools'
            [void](New-Item -ItemType Directory -Path $trustedToolsRoot -Force)
            $executable = $script:CoreBoundaryPowerShellPath
            $fixtureTrustedToolRoot = $PSHOME
            if ([IO.Path]::GetFileName($executable) -ieq 'powershell.exe') {
                # The Windows system host is hard-linked; copy it into the fixture trust root so path validation tests a regular file.
                $executable = Join-Path $trustedToolsRoot 'powershell.exe'
                [IO.File]::Copy($script:CoreBoundaryPowerShellPath, $executable)
                $fixtureTrustedToolRoot = $trustedToolsRoot
            }
            $toolSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash.ToLowerInvariant()
            $adapterValue = [ordered]@{
                schemaVersion = 2
                adapter = 'standard-core-adapter-v2'
                skillsRoot = 'skills'
                activeSkills = @('alpha')
                checks = @([ordered]@{
                    id = 'fixture-check'
                    kind = $Kind
                    executable = $executable
                    executableSha256 = $toolSha
                    arguments = @('-NoLogo', '-NoProfile', '-File', 'checks/run.ps1')
                })
            }
            $adapterPath = Join-Path $Root 'adapter.json'
            Write-CoreBoundaryUtf8 -Path $adapterPath -Text ($adapterValue | ConvertTo-Json -Depth 20)
            return [pscustomobject]@{
                Root = $Root; Candidate = $candidate; SkillPath = $skillPath; Adapter = $adapterPath
                AdapterValue = $adapterValue; SourceRevision = $sourceRevision; Artifacts = Join-Path $Root 'artifacts'
                Executable = $executable; TrustedToolRoot = $fixtureTrustedToolRoot
            }
        }

        function Invoke-CoreBoundaryCli {
            param(
                $Fixture,
                [string] $CaseName,
                [string] $SourceRevision,
                [string] $AuthorityRevision,
                [int] $TimeoutSeconds = 30,
                [switch] $PreexistingOutput,
                [switch] $PreexistingLock,
                [switch] $ObserveLiveStderr
            )
            $artifactRoot = Join-Path $Fixture.Root ($CaseName + '-artifacts')
            [void](New-Item -ItemType Directory -Path $artifactRoot -Force)
            $outputPath = Join-Path $artifactRoot 'evidence.json'
            $lockPath = Join-Path $artifactRoot '.standard-core-validation.lock'
            $lockSentinel = 'preserve-existing-core-lock-sentinel'
            if ($PreexistingOutput) { [IO.File]::WriteAllText($outputPath, 'preserve-existing-output', (New-Object Text.UTF8Encoding($false))) }
            if ($PreexistingLock) { [IO.File]::WriteAllText($lockPath, $lockSentinel, (New-Object Text.UTF8Encoding($false))) }
            $sourceValue = if ([string]::IsNullOrWhiteSpace($SourceRevision)) { $Fixture.SourceRevision } else { $SourceRevision }
            $authorityValue = if ([string]::IsNullOrWhiteSpace($AuthorityRevision)) { $script:CoreBoundaryAuthorityRevision } else { $AuthorityRevision }
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $Fixture.Executable
            if ([IO.Path]::GetFileName($Fixture.Executable) -ieq 'powershell.exe') {
                # Exclude pwsh-only module directories inherited from the host so Windows PowerShell resolves its own built-in Utility module.
                $windowsPowerShellModulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object {
                    $_ -like '*\WindowsPowerShell\Modules' -or $_ -like '*\WindowsPowerShell\v1.0\Modules'
                })
                if ($windowsPowerShellModulePaths.Count -eq 0) { throw 'No Windows PowerShell module paths are available to the fixture child.' }
                $startInfo.EnvironmentVariables['PSModulePath'] = $windowsPowerShellModulePaths -join [IO.Path]::PathSeparator
            }
            $argumentList = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:CoreBoundaryRunnerPath,
                '-CandidateRoot', $Fixture.Candidate, '-AdapterPath', $Fixture.Adapter,
                '-ArtifactsRoot', $artifactRoot, '-OutputPath', $outputPath,
                '-SourceRepository', 'https://example.com/example/skills.git',
                '-SourceRevision', $sourceValue, '-BaseRevision', $Fixture.SourceRevision,
                '-EventName', 'local', '-AuthorityRevision', $authorityValue,
                '-TimeoutSeconds', [string]$TimeoutSeconds, '-TrustedToolRoot', $Fixture.TrustedToolRoot
            )
            $startInfo.Arguments = (@($argumentList | ForEach-Object { Quote-CoreBoundaryArgument -Value ([string]$_) }) -join ' ')
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            $started = $false
            try {
                if (-not $process.Start()) { throw "Core boundary CLI '$CaseName' did not start." }
                $started = $true
                $processId = [int]$process.Id
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $firstStderrLine = $null
                $liveStderrBeforeExit = $false
                if ($ObserveLiveStderr) {
                    $firstStderrTask = $process.StandardError.ReadLineAsync()
                    $firstCompleted = [Threading.Tasks.Task]::WhenAny($firstStderrTask, [Threading.Tasks.Task]::Delay(20000)).GetAwaiter().GetResult()
                    if ($firstCompleted -ne $firstStderrTask) { throw "Core boundary CLI '$CaseName' emitted no live stderr within 20 seconds." }
                    $firstStderrLine = $firstStderrTask.GetAwaiter().GetResult()
                    $liveStderrBeforeExit = -not $process.HasExited
                }
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(60000)) {
                    try { $process.Kill() } catch { }
                    [void]$process.WaitForExit(10000)
                    throw "Core boundary CLI '$CaseName' timed out; pid=$processId; exited=$($process.HasExited)."
                }
                $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
                $stderr = if ($null -eq $firstStderrLine) { [string]$stderrTask.GetAwaiter().GetResult() } else {
                    [string]$firstStderrLine + [Environment]::NewLine + [string]$stderrTask.GetAwaiter().GetResult()
                }
                $evidence = $null
                if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                    try { $evidence = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { }
                }
                $outputAfter = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { [IO.File]::ReadAllText($outputPath) } else { $null }
                $lockAfter = if (Test-Path -LiteralPath $lockPath -PathType Leaf) { [IO.File]::ReadAllText($lockPath) } else { $null }
                $sha256 = [Security.Cryptography.SHA256]::Create()
                try {
                    $stdoutSha256 = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($stdout))) -replace '-', '').ToLowerInvariant()
                    $stderrSha256 = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($stderr))) -replace '-', '').ToLowerInvariant()
                }
                finally { $sha256.Dispose() }
                return [pscustomobject]@{
                    ProcessId = $processId; ExitCode = [int]$process.ExitCode; Stdout = $stdout; Stderr = $stderr
                    LiveStderrBeforeExit = $liveStderrBeforeExit
                    Evidence = $evidence; OutputPath = $outputPath; OutputAfter = $outputAfter; LockPath = $lockPath
                    LockSentinel = $lockSentinel; LockAfter = $lockAfter
                    StdoutSha256 = $stdoutSha256
                    StderrSha256 = $stderrSha256
                }
            }
            finally {
                if ($started) { try { if (-not $process.HasExited) { $process.Kill() } } catch { }; try { [void]$process.WaitForExit(10000) } catch { } }
                $process.Dispose()
            }
        }
    }

    # Scenario: Core checks cross the tracked snapshot and owned process boundary with both valid and invalid inputs.
    # Purpose: Preserve the retained refusal paths, true exits and cleanup while the Core runner changes.
    It 'InterT10_keeps_tracked_identity_safe_paths_and_failure_boundaries' {
        $root = Join-Path $TestDrive ('s1b3-core-boundaries-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $root -Force)
        try {
            $wrongCandidate = New-CoreBoundaryFixture -Root (Join-Path $root 'wrong-candidate')
            $candidateMismatch = Invoke-CoreBoundaryCli -Fixture $wrongCandidate -CaseName 'candidate-mismatch' -SourceRevision ('0' * 40)
            Assert-Equal $candidateMismatch.ExitCode 10 'A mismatched full candidate revision must return BLOCKED=10.'
            Assert-Equal $candidateMismatch.Evidence.state 'BLOCKED' 'A mismatched full candidate revision must not pass.'
            Assert-Equal @($candidateMismatch.Evidence.checks).Count 0 'A candidate revision mismatch must be rejected before child dispatch.'

            $wrongAuthority = New-CoreBoundaryFixture -Root (Join-Path $root 'wrong-authority')
            $authorityMismatch = Invoke-CoreBoundaryCli -Fixture $wrongAuthority -CaseName 'authority-mismatch' -AuthorityRevision ('0' * 40)
            Assert-Equal $authorityMismatch.ExitCode 10 'A mismatched full authority revision must return BLOCKED=10.'
            Assert-Equal $authorityMismatch.Evidence.state 'BLOCKED' 'A mismatched full authority revision must not pass.'
            Assert-Equal @($authorityMismatch.Evidence.checks).Count 0 'An authority revision mismatch must be rejected before child dispatch.'

            $unsafeFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'unsafe-skills-root')
            $unsafeAdapter = $unsafeFixture.AdapterValue
            $unsafeAdapter.skillsRoot = '../outside'
            Write-CoreBoundaryUtf8 -Path $unsafeFixture.Adapter -Text ($unsafeAdapter | ConvertTo-Json -Depth 20)
            $unsafePath = Invoke-CoreBoundaryCli -Fixture $unsafeFixture -CaseName 'unsafe-skills-root'
            Assert-Equal $unsafePath.ExitCode 30 'An unsafe adapter-relative Skills root must return INVALID=30.'
            Assert-Equal $unsafePath.Evidence.state 'INVALID' 'An unsafe adapter-relative Skills root must not pass.'
            Assert-Equal @($unsafePath.Evidence.checks).Count 0 'An unsafe Skills root must be rejected before child dispatch.'

            $privateFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'private-exclusion')
            $privateRun = Invoke-CoreBoundaryCli -Fixture $privateFixture -CaseName 'private-exclusion'
            Assert-Equal $privateRun.ExitCode 0 'A clean tracked fixture with an ignored private file must pass its declared check.'
            Assert-Equal $privateRun.Evidence.state 'PASS' 'The ignored private file must not block the tracked-source core.'
            Assert-False (@($privateRun.Evidence.candidate.inventory | Where-Object { $_.path -eq 'fixture-private.txt' }).Count -gt 0) 'Ignored private files must never enter candidate inventory.'
            Assert-False (Test-Path -LiteralPath (Join-Path $privateRun.Evidence.artifacts.snapshotRoot 'fixture-private.txt')) 'Ignored private files must never enter the core snapshot.'
            Assert-False (Test-Path -LiteralPath (Join-Path $privateRun.Evidence.artifacts.snapshotRoot '.git')) 'The core snapshot must not contain Git metadata.'
            Assert-Equal $privateRun.LockAfter $null 'A successfully owned lock must be removed after final evidence publication.'

            $preexistingLockFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'preexisting-lock')
            $preexistingLock = Invoke-CoreBoundaryCli -Fixture $preexistingLockFixture -CaseName 'preexisting-lock' -PreexistingLock
            Assert-Equal $preexistingLock.ExitCode 10 'A pre-existing artifact lock must return BLOCKED=10.'
            Assert-Equal $preexistingLock.Evidence.state 'BLOCKED' 'A pre-existing artifact lock must not pass.'
            Assert-Equal $preexistingLock.LockAfter $preexistingLock.LockSentinel 'A run that failed CreateNew must preserve the pre-existing lock sentinel.'
            Assert-Equal @($preexistingLock.Evidence.checks).Count 0 'A pre-existing lock must block before child dispatch.'

            $failedFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'failed-child') -Behavior 'failed-child'
            $failedChild = Invoke-CoreBoundaryCli -Fixture $failedFixture -CaseName 'failed-child'
            Assert-Equal $failedChild.ExitCode 20 'A nonzero check process must return FAILED=20.'
            Assert-Equal $failedChild.Evidence.state 'FAILED' 'A nonzero check process must not pass.'
            Assert-Equal $failedChild.Evidence.checks[0].exitCode 7 'Failure evidence must retain the actual child exit code.'
            Assert-Equal $failedChild.Evidence.checks[0].cleanedUp $true 'A failed child must be cleaned before failure evidence is finalized.'
            Assert-Match $failedChild.Evidence.checks[0].stdoutSha256 '^[a-f0-9]{64}$' 'Failure evidence must bind raw stdout bytes.'
            Assert-Match $failedChild.Evidence.checks[0].stderrSha256 '^[a-f0-9]{64}$' 'Failure evidence must bind raw stderr bytes.'
            Assert-Equal $failedChild.LockAfter $null 'A failed check must remove the owned lock after final evidence publication.'

            $timeoutFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'timeout-child') -Behavior 'timeout'
            $timeoutRun = Invoke-CoreBoundaryCli -Fixture $timeoutFixture -CaseName 'timeout-child' -TimeoutSeconds 1
            Assert-Equal $timeoutRun.ExitCode 20 'A timed-out check must return FAILED=20.'
            Assert-Equal $timeoutRun.Evidence.state 'FAILED' 'A timed-out check must not pass.'
            Assert-Equal $timeoutRun.Evidence.checks[0].status 'timeout' 'Timeout evidence must retain the timeout status.'
            Assert-Equal $timeoutRun.Evidence.checks[0].cleanedUp $true 'Timeout cannot be PASS unless owned cleanup is verified.'
            Assert-Match $timeoutRun.Evidence.checks[0].stderrSha256 '^[a-f0-9]{64}$' 'Timeout evidence must bind raw stderr bytes.'
            $timedOutChild = Get-Process -Id ([int]$timeoutRun.Evidence.checks[0].processId) -ErrorAction SilentlyContinue
            Assert-True ($null -eq $timedOutChild) 'A timed-out owned child PID must be absent after the CLI returns.'

            $mutationFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'source-mutation') -Behavior 'source-mutate'
            $mutationRun = Invoke-CoreBoundaryCli -Fixture $mutationFixture -CaseName 'source-mutation'
            Assert-False ($mutationRun.ExitCode -eq 0) 'A check that mutates tracked source during execution must not PASS.'
            Assert-False ($mutationRun.Evidence.state -eq 'PASS') 'A check that mutates tracked source during execution must not produce PASS evidence.'
            Assert-False ([bool]$mutationRun.Evidence.releaseEligible) 'Mutated-source evidence must remain release-ineligible.'

            $existingFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'existing-output')
            $existingOutput = Invoke-CoreBoundaryCli -Fixture $existingFixture -CaseName 'existing-output' -PreexistingOutput
            Assert-False ($existingOutput.ExitCode -eq 0) 'A pre-existing output reservation must fail closed.'
            Assert-Equal $existingOutput.OutputAfter 'preserve-existing-output' 'A pre-existing create-only result must never be overwritten.'

            $zeroFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'zero-pester') -Behavior 'zero-pester' -Kind 'pester'
            $zeroRun = Invoke-CoreBoundaryCli -Fixture $zeroFixture -CaseName 'zero-pester'
            Assert-Equal $zeroRun.ExitCode 20 'A Pester check reporting zero tests must return FAILED=20.'
            Assert-Equal $zeroRun.Evidence.checks[0].exitCode 0 'Zero-test rejection must preserve the child process exit code.'
            Assert-Equal $zeroRun.Evidence.checks[0].status 'failed' 'A zero-test report must fail the typed Pester check.'
        }
        finally {
            if (Test-Path -LiteralPath $root -PathType Container) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    # Scenario: The ordinary Core dispatcher executes a validated Pester check and then a general check.
    # Purpose: Verify only Pester emits trusted outer stderr while the child is still running, and both typed checks retain normal evidence.
    It 'InterT20_streams_supervisor_progress_only_for_core_pester_checks' {
        $root = Join-Path $TestDrive ('s1b3-core-progress-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $root -Force)
        try {
            $pesterFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'pester') -Behavior 'slow-pester' -Kind 'pester'
            $pesterRun = Invoke-CoreBoundaryCli -Fixture $pesterFixture -CaseName 'live-pester' -ObserveLiveStderr
            Assert-True $pesterRun.LiveStderrBeforeExit 'The Core Pester supervisor heartbeat must arrive before the check exits.'
            Assert-Match $pesterRun.Stderr '^Core Pester supervisor utc=.+ elapsedSeconds=\d+ remainingSeconds=\d+ state=running' 'The trusted Core Pester dispatcher must opt into fixed live progress.'
            Assert-Equal $pesterRun.ExitCode 0 'The valid typed Pester check must pass.'
            Assert-Equal $pesterRun.Evidence.state 'PASS' 'A valid Core Pester check must retain PASS evidence.'
            Assert-Equal $pesterRun.Evidence.checks[0].testCounts.total 1 'The Core parser must retain the one executed case.'
            Assert-Equal $pesterRun.Evidence.checks[0].cleanedUp $true 'The Core Pester child must be cleaned.'

            $generalFixture = New-CoreBoundaryFixture -Root (Join-Path $root 'general') -Behavior 'slow-general' -Kind 'general'
            $generalRun = Invoke-CoreBoundaryCli -Fixture $generalFixture -CaseName 'quiet-general'
            Assert-False ($generalRun.Stderr -match 'Core Pester supervisor') 'A general Core check must not emit the Pester heartbeat.'
            Assert-Equal $generalRun.ExitCode 0 'The valid general check must pass.'
            Assert-Equal $generalRun.Evidence.state 'PASS' 'A valid general Core check must retain PASS evidence.'
            Assert-Equal $generalRun.Evidence.checks[0].cleanedUp $true 'The Core general child must be cleaned.'
        }
        finally {
            if (Test-Path -LiteralPath $root -PathType Container) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}
