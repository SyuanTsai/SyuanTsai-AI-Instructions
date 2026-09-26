# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Proposed PR12 source merge exception' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -CandidateRoot $repositoryRoot -AdapterPath (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -ArtifactsRoot $repositoryRoot -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly

        function New-DraftFixture {
            param([string] $Root)
            $candidateRoot = Join-Path $Root 'candidate'
            $skillRoot = Join-Path $candidateRoot 'skills/manage-task-handoff'
            $artifactRoot = Join-Path $Root 'artifacts'
            [void](New-Item -ItemType Directory -Path $skillRoot, $artifactRoot -Force)
            $paths = @('SKILL.md', 'agents/openai.yaml', 'references/one.md', 'references/two.md',
                'references/three.md', 'references/four.md', 'references/five.md', 'scripts/GitRefHandoffAdapter.psm1',
                'scripts/one.ps1', 'scripts/two.ps1', 'scripts/three.ps1')
            foreach ($path in $paths) {
                $fullPath = Join-Path $skillRoot $path
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force)
                [IO.File]::WriteAllText($fullPath, "fixture:$path", [Text.UTF8Encoding]::new($false))
            }
            $activeSkills = @('investigate-datadog-logs', 'manage-notion-ai-memory', 'manage-task-handoff',
                'plan-production-change', 'review-agent-skills', 'verify-data-access-performance')
            $otherSkillIds = @($activeSkills | Where-Object { $_ -cne 'manage-task-handoff' })
            foreach ($id in $otherSkillIds) {
                foreach ($path in @('SKILL.md', 'agents/openai.yaml')) {
                    $fullPath = Join-Path $candidateRoot "skills/$id/$path"
                    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force)
                    [IO.File]::WriteAllText($fullPath, "fixture:$id/$path", [Text.UTF8Encoding]::new($false))
                }
            }
            $modulePath = Join-Path $skillRoot 'scripts/GitRefHandoffAdapter.psm1'
            $moduleSha256 = Get-StandardValidationFileSha256 -Path $modulePath -Context 'fixture module'
            $inventory = Get-StandardValidationInventory -Root $candidateRoot -Context 'fixture candidate'
            $contentSha256 = Get-StandardValidationInventorySha256 -Inventory $inventory
            $sourceRevision = 'a' * 40
            $candidateId = 'b' * 64
            $scannerExecutableSha256 = 'c' * 64
            $scannerReport = [ordered]@{
                skill = [ordered]@{ name = 'manage-task-handoff'; source = $skillRoot }
                execution_successful = $true
                components = @($paths | ForEach-Object { [ordered]@{ path = $_ } })
                issues = @()
                analysis_completeness = [ordered]@{
                    execution_successful = $true; is_complete = $false; status = 'partial'
                    total_components = 11; scanned_components = 10; coverage_percent = 90.9
                    ledger_exceptions = @([ordered]@{ path = 'scripts/GitRefHandoffAdapter.psm1'; reason_code = 'static_parse_limit'; analyzers = @('static_patterns_tool_misuse') })
                    scope_exclusions = @()
                    limitations = @('Analyzer static_patterns_tool_misuse status: degraded.')
                    analyzer_statuses = @([ordered]@{ analyzer_id = 'static_patterns_tool_misuse'; status = 'degraded'; planned_work = 11; completed = 10; partial = 1 })
                }
            }
            $scannerPath = Join-Path $Root 'official-scanner-report.json'
            [IO.File]::WriteAllText($scannerPath, ($scannerReport | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $scannerReportSha256 = Get-StandardValidationFileSha256 -Path $scannerPath -Context 'fixture scanner report'
            $otherScannerReportPaths = @()
            $otherPolicyReports = @()
            foreach ($id in $otherSkillIds) {
                $otherRoot = Join-Path $candidateRoot "skills/$id"
                $otherReport = [ordered]@{
                    skill = [ordered]@{ name = $id; source = $otherRoot }
                    execution_successful = $true
                    components = @([ordered]@{ path = 'SKILL.md' }, [ordered]@{ path = 'agents/openai.yaml' })
                    issues = @()
                    analysis_completeness = [ordered]@{ status = 'complete'; is_complete = $true;
                        total_components = 2; scanned_components = 2; coverage_percent = 100;
                        ledger_exceptions = @(); scope_exclusions = @(); limitations = @() }
                }
                $otherPath = Join-Path $Root "official-$id.json"
                [IO.File]::WriteAllText($otherPath, ($otherReport | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
                $otherScannerReportPaths += $otherPath
                $otherPolicyReports += [ordered]@{ skillId = $id; componentCount = 2;
                    sha256 = (Get-StandardValidationFileSha256 -Path $otherPath -Context "fixture $id report") }
            }
            $stages = @()
            $stageIds = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static',
                'repository-tests', 'conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')
            for ($index = 0; $index -lt $stageIds.Count; $index++) {
                $stageStatus = if ($index -lt 3) { 'passed' } elseif ($index -eq 3) { 'failed' } else { 'not-run' }
                $stages += [ordered]@{ id = $stageIds[$index]; order = $index + 1; status = $stageStatus; events = @() }
            }
            $report = [ordered]@{
                state = 'FAILED'; exitCode = 20; releaseEligible = $false
                candidate = [ordered]@{ sourceRepository = 'https://github.com/SyuanTsai/Skill-General.git'; sourceRevision = $sourceRevision;
                    candidateId = $candidateId; contentSha256 = $contentSha256; activeSkills = $activeSkills }
                artifacts = [ordered]@{ root = $artifactRoot }
                stages = $stages
                sourceConformance = [ordered]@{ status = 'failed'; releaseEligible = $false }
            }
            $supplemental = @()
            foreach ($dispatch in @([ordered]@{ id = 'repository-test-general'; kind = 'general' },
                    [ordered]@{ id = 'repository-test-pester'; kind = 'pester' })) {
                $eventId = [guid]::NewGuid().ToString()
                $testResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = $dispatch.id }
                if ($dispatch.kind -ceq 'pester') { $testResult.total = 1; $testResult.passed = 1; $testResult.skipped = 0; $testResult.failed = 0 }
                $domainResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = 'fixture' }
                $envelope = [ordered]@{ candidateIdentity = $candidateId; testInventory = @("case:$($dispatch.id)");
                    testResult = $testResult; domainAdapterResult = $domainResult }
                $stdout = $envelope | ConvertTo-Json -Depth 10 -Compress
                $outputPath = Join-Path $artifactRoot "$eventId.json"
                $raw = [ordered]@{ schemaVersion = 1; eventId = $eventId; stageId = 'supplemental-repository-tests';
                    toolId = $dispatch.id; skillId = $null; candidateId = $candidateId;
                    process = [ordered]@{ exitCode = 0; status = 'passed'; stdout = $stdout; stderr = ''; cleanedUp = $true };
                    stdout = $stdout; stderr = '' }
                [IO.File]::WriteAllText($outputPath, ($raw | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
                $outputSha256 = Get-StandardValidationOutputHash -Stdout $stdout -Stderr ''
                $event = [ordered]@{ eventId = $eventId; stageId = 'supplemental-repository-tests'; toolId = $dispatch.id;
                    skillId = $null; candidateId = $candidateId; status = 'passed'; exitCode = 0; cleanedUp = $true;
                    outputPath = $outputPath; outputSha256 = $outputSha256 }
                $record = [ordered]@{ toolRole = if ($dispatch.kind -ceq 'pester') { 'pester' } else { 'domain' };
                    toolId = $dispatch.id; eventId = $eventId; candidateId = $candidateId; outputSha256 = $outputSha256;
                    testInventory = @("case:$($dispatch.id)"); testResult = $testResult; domainAdapterResult = $domainResult }
                $supplemental += [ordered]@{ kind = $dispatch.kind; event = $event; record = $record }
            }
            $policy = [ordered]@{ status = 'proposed'; sourceRepository = 'https://github.com/SyuanTsai/Skill-General.git';
                pullRequest = 12; skillId = 'manage-task-handoff'; modulePath = 'skills/manage-task-handoff/scripts/GitRefHandoffAdapter.psm1';
                moduleSha256 = $moduleSha256; sourceRevision = $sourceRevision; contentSha256 = $contentSha256; activeSkills = $activeSkills;
                expectedInventoryCount = 11; scannerSource = 'NVIDIA/SkillSpector'; scannerReportSha256 = $scannerReportSha256;
                scannerVersion = '2.12.0'; scannerExecutableSha256 = $scannerExecutableSha256;
                otherSkillReports = $otherPolicyReports }
            $receipt = [ordered]@{ source = 'NVIDIA/SkillSpector'; version = '2.12.0'; executableSha256 = $scannerExecutableSha256 }
            return [pscustomobject]@{ Report = $report; Policy = $policy; Receipt = $receipt; Supplemental = $supplemental;
                CandidateRoot = $candidateRoot; ScannerReportPath = $scannerPath; ScannerReportSha256 = $scannerReportSha256;
                OtherScannerReportPaths = $otherScannerReportPaths;
                SourceRevision = $sourceRevision }
        }
        function Invoke-DraftDecision {
            param($Fixture)
            return New-StandardValidationProposedSourceMergeExceptionDecision -Report $Fixture.Report `
                -Policy $Fixture.Policy -CandidateRoot $Fixture.CandidateRoot -ExpectedSourceRevision $Fixture.SourceRevision `
                -PullRequestNumber 12 -ScannerReportPath $Fixture.ScannerReportPath -ExpectedScannerReportSha256 $Fixture.ScannerReportSha256 `
                -OtherScannerReportPaths $Fixture.OtherScannerReportPaths `
                -ScannerReceipt $Fixture.Receipt `
                -SupplementalEvidence $Fixture.Supplemental -DevelopmentHarness -TestOnlyFixtureScope
        }
        function Assert-Draft {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }
    }

    # Scenario: the machine-readable authority summary names an older source revision.
    # Purpose: keep the reviewed merge scope bound to the exact source revision in policy.
    It 'UnitT05_binds_contract_scope_to_exact_policy_revision' {
        $root = Split-Path -Parent $PSScriptRoot
        $contract = Get-Content -LiteralPath (Join-Path $root 'docs/standards/standard-validation-contract-v1.json') -Raw | ConvertFrom-Json
        $policy = Get-Content -LiteralPath (Join-Path $root 'docs/standards/pr12-source-merge-exception-proposal.json') -Raw | ConvertFrom-Json
        $scope = [string]$contract.evidence.sourceMergeExceptionProposal.scope
        Assert-Draft ($scope -cmatch ('PR12 exact candidate {0};' -f [regex]::Escape([string]$policy.sourceRevision))) `
            'The authority contract scope must name the exact proposed source revision.'
    }

    # Scenario: a bound scanner limitation and supplemental raw test records are present.
    # Purpose: preserve the failed canonical result while producing only a reviewable technical proposal.
    It 'UnitT10_keeps_exact_exception_eligible_for_review_without_approving_it' {
        $fixture = New-DraftFixture -Root (Join-Path $TestDrive 'positive')
        $result = Invoke-DraftDecision -Fixture $fixture
        Assert-Draft ($result.status -ceq 'eligible-for-policy-review') "Expected review eligibility; reasons: $($result.failureReasons -join ',')"
        Assert-Draft (-not [bool]$result.releaseEligible) 'Draft decision must never authorize release.'
        Assert-Draft ($fixture.Report.state -ceq 'FAILED') 'Canonical state must remain FAILED.'
        Assert-Draft ($fixture.Report.stages[3].status -ceq 'failed') 'Canonical Stage 4 must remain failed.'
        Assert-Draft ($fixture.Report.stages[4].status -ceq 'not-run') 'Canonical Stage 5 must remain not-run.'
        Assert-Draft ($fixture.Report.sourceConformance.status -ceq 'failed') 'Source conformance must remain failed.'
        $productionLike = New-StandardValidationProposedSourceMergeExceptionDecision -Report $fixture.Report `
            -Policy $fixture.Policy -CandidateRoot $fixture.CandidateRoot -ExpectedSourceRevision $fixture.SourceRevision `
            -PullRequestNumber 12 -ScannerReportPath $fixture.ScannerReportPath -ExpectedScannerReportSha256 $fixture.ScannerReportSha256 `
            -OtherScannerReportPaths $fixture.OtherScannerReportPaths -ScannerReceipt $fixture.Receipt `
            -SupplementalEvidence $fixture.Supplemental
        Assert-Draft ($productionLike.status -ceq 'rejected' -and
            @($productionLike.failureReasons) -contains 'exception-supplemental-execution-not-supervised') `
            'Caller-supplied supplemental records must not become production eligibility.'
    }

    # Scenario: the same technical evidence arrives for another repository, candidate, or module.
    # Purpose: prevent an exception from escaping its exact candidate and source scope.
    It 'UnitT20_rejects_scope_or_candidate_drift' {
        foreach ($drift in @('repository', 'revision', 'module', 'pr', 'skill-set')) {
            $fixture = New-DraftFixture -Root (Join-Path $TestDrive "scope-$drift")
            switch ($drift) {
                repository { $fixture.Report.candidate.sourceRepository = 'https://example.com/other.git' }
                revision { $fixture.Report.candidate.sourceRevision = 'd' * 40 }
                module { $fixture.Policy.moduleSha256 = 'f' * 64 }
                pr { $fixture.Policy.pullRequest = 11 }
                'skill-set' { $fixture.Report.candidate.activeSkills = @('manage-task-handoff') }
            }
            Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') "Scope drift '$drift' must be rejected."
        }
    }

    # Scenario: official scan evidence is incomplete in a different way or altered after writing.
    # Purpose: accept only the one declared parser limitation and verified report bytes.
    It 'UnitT30_rejects_extra_limitation_finding_or_report_drift' {
        foreach ($drift in @('second-exception', 'finding', 'duplicate-json', 'report-missing',
                'other-report-missing', 'other-report-partial', 'other-policy-drift', 'receipt')) {
            $fixture = New-DraftFixture -Root (Join-Path $TestDrive "scan-$drift")
            $scan = Get-Content -Raw -LiteralPath $fixture.ScannerReportPath | ConvertFrom-Json
            switch ($drift) {
                'second-exception' { $scan.analysis_completeness.ledger_exceptions += [ordered]@{ path = 'SKILL.md'; reason_code = 'static_parse_limit'; analyzers = @('static_patterns_tool_misuse') } }
                finding { $scan.issues = @([ordered]@{ severity = 'HIGH' }) }
                'duplicate-json' {
                    $raw = Get-Content -Raw -LiteralPath $fixture.ScannerReportPath
                    $mutated = $raw -replace '"execution_successful"\s*:\s*true', '"execution_successful": true, "execution_successful": true'
                    Assert-Draft ($mutated -cne $raw) 'Duplicate-JSON fixture must modify the report bytes.'
                    $raw = $mutated
                    [IO.File]::WriteAllText($fixture.ScannerReportPath, $raw, [Text.UTF8Encoding]::new($false))
                }
                'report-missing' { Remove-Item -LiteralPath $fixture.ScannerReportPath }
                'other-report-missing' { Remove-Item -LiteralPath $fixture.OtherScannerReportPaths[0] }
                'other-report-partial' {
                    $other = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
                    $other.analysis_completeness.status = 'partial'
                    [IO.File]::WriteAllText($fixture.OtherScannerReportPaths[0], ($other | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
                }
                'other-policy-drift' { $fixture.Policy.otherSkillReports[0].sha256 = 'f' * 64 }
                receipt { $fixture.Receipt.executableSha256 = 'e' * 64 }
            }
            if ($drift -in @('second-exception', 'finding')) {
                [IO.File]::WriteAllText($fixture.ScannerReportPath, ($scan | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            }
            Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') "Scan drift '$drift' must be rejected."
        }
    }

    # Scenario: supplemental test output is missing, failed, unbound, or countless.
    # Purpose: keep the extra lane from hiding failed or unexecuted repository tests.
    It 'UnitT40_rejects_invalid_supplemental_test_evidence' {
        foreach ($drift in @('no-counts', 'all-skipped', 'wrong-candidate', 'unclean', 'missing-raw')) {
            $fixture = New-DraftFixture -Root (Join-Path $TestDrive "tests-$drift")
            $pester = $fixture.Supplemental[1]
            switch ($drift) {
                'no-counts' { $pester.record.testResult.Remove('total') }
                'all-skipped' { $pester.record.testResult.passed = 0; $pester.record.testResult.skipped = 1 }
                'wrong-candidate' { $pester.event.candidateId = 'f' * 64 }
                unclean { $pester.event.cleanedUp = $false }
                'missing-raw' { Remove-Item -LiteralPath $pester.event.outputPath }
            }
            Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') "Supplemental drift '$drift' must be rejected."
        }
    }

    # Scenario: a caller changes canonical state or self-asserts human approval.
    # Purpose: make canonical failure immutable and prevent ordinary input from authorizing adoption.
    It 'UnitT50_rejects_canonical_rewrite_and_never_self_approves' {
        $fixture = New-DraftFixture -Root (Join-Path $TestDrive 'canonical')
        $fixture.Report.state = 'PASS'
        Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') 'Canonical PASS rewrite must be rejected.'
        $fixture = New-DraftFixture -Root (Join-Path $TestDrive 'self-approval')
        $fixture.Policy.status = 'approved'
        Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') 'Self-asserted policy approval must be rejected.'
        $fixture = New-DraftFixture -Root (Join-Path $TestDrive 'late-stage')
        $fixture.Report.stages[8].status = 'passed'
        Assert-Draft ((Invoke-DraftDecision -Fixture $fixture).status -ceq 'rejected') 'Publish/install cannot be marked passed after Static failed.'
    }

    # A caller cannot turn review observation into production authorization.
    It 'UnitT60_rejects_unsupervised_production_even_with_observation_claim' {
        $fixture = New-DraftFixture -Root (Join-Path $TestDrive 'observation-claim')
        $result = New-StandardValidationProposedSourceMergeExceptionDecision -Report $fixture.Report `
            -Policy $fixture.Policy -CandidateRoot $fixture.CandidateRoot -ExpectedSourceRevision $fixture.SourceRevision `
            -PullRequestNumber 12 -ScannerReportPath $fixture.ScannerReportPath `
            -ExpectedScannerReportSha256 $fixture.ScannerReportSha256 `
            -OtherScannerReportPaths $fixture.OtherScannerReportPaths -ScannerReceipt $fixture.Receipt `
            -SupplementalEvidence $fixture.Supplemental -ObservedSupervisorExecution
        Assert-Draft ($result.status -ceq 'rejected' -and
            @($result.failureReasons) -contains 'exception-supplemental-execution-not-supervised') `
            'A claimed observation cannot authorize a production exception.'
    }

    # The review runner must derive scanner identity from the frozen toolchain
    # and the executable bytes, not a caller-supplied receipt string.
    It 'UnitT70_binds_review_scanner_to_frozen_toolchain_and_executable' {
        $root = Join-Path $TestDrive 'toolchain'
        [void](New-Item -ItemType Directory -Path $root -Force)
        $scannerPath = Join-Path $root 'scanner.bin'
        [IO.File]::WriteAllText($scannerPath, 'official-fixture', [Text.UTF8Encoding]::new($false))
        $scannerSha256 = Get-StandardValidationFileSha256 -Path $scannerPath -Context 'fixture scanner'
        $receiptPath = Join-Path $root 'scanner-receipt.json'
        $identity = "github:NVIDIA/SkillSpector@v2.12.0#commit=c7958a3268d9498644b22edb75d0f051bbc8cbfc#asset=sha256:62973f6254d30c871480246869f88a01e17dff6f12e9d43010962eb0d7e305f4#executableSha256=$scannerSha256#"
        $resolverReceipt = [ordered]@{ toolName = 'skillspector'; source = 'NVIDIA/SkillSpector';
            resolvedVersion = '2.12.0'; frozenForRun = $true; offlineResolutionVerified = $true; channel = 'latest-stable';
            executablePath = $scannerPath; executableSha256 = $scannerSha256; resolvedIdentity = $identity }
        [IO.File]::WriteAllText($receiptPath, ($resolverReceipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $receiptSha256 = Get-StandardValidationFileSha256 -Path $receiptPath -Context 'fixture scanner receipt'
        $toolchainPath = Join-Path $root 'toolchain.json'
        $toolchain = [ordered]@{ skillSpectorPath = $scannerPath; skillSpectorSha256 = $scannerSha256;
            skillSpectorReceiptPath = $receiptPath; skillSpectorReceiptSha256 = $receiptSha256 }
        [IO.File]::WriteAllText($toolchainPath, ($toolchain | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $toolchainSha256 = Get-StandardValidationFileSha256 -Path $toolchainPath -Context 'fixture toolchain'
        $command = [ordered]@{ arguments = @('-ToolchainPath', $toolchainPath, '-ToolchainSha256', $toolchainSha256) }
        $receipt = Get-StandardValidationPr12ReviewScannerReceipt -StaticCommand $command
        Assert-Draft ($receipt.executableSha256 -ceq $scannerSha256) 'Review scanner hash was not bound to actual bytes.'
        [IO.File]::WriteAllText($scannerPath, 'changed-fixture', [Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { [void](Get-StandardValidationPr12ReviewScannerReceipt -StaticCommand $command) }
        catch { $rejected = $true }
        Assert-Draft $rejected 'Changed scanner bytes must reject the review receipt.'
    }

    It 'UnitT80_dispatches_review_only_for_the_exact_incomplete_static_event' {
        $path = Join-Path $TestDrive 'static-raw.json'
        $eventId = [guid]::NewGuid().ToString()
        $candidateId = 'a' * 64
        $raw = [ordered]@{
            eventId = $eventId; candidateId = $candidateId
            process = [ordered]@{
                status = 'failed'; cleanedUp = $true
                stderr = "SkillSpector did not prove complete static analysis for 'manage-task-handoff'.`n"
            }
        }
        [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $event = [ordered]@{ eventId = $eventId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'
            candidateId = $candidateId; status = 'failed'; exitCode = 1; cleanedUp = $true; outputPath = $path }
        $stage = [ordered]@{ events = @($event) }
        Assert-Draft (Test-StandardValidationPr12IncompleteStaticEvent -Stage $stage) 'The exact incomplete event should be reviewable.'
        $raw.process.stderr = 'A different scanner failure.'
        [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Assert-Draft (-not (Test-StandardValidationPr12IncompleteStaticEvent -Stage $stage)) 'Other Static failures must not dispatch supplemental tests.'
    }
}
