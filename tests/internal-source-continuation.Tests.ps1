# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Internal source continuation policy' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -CandidateRoot $repositoryRoot -AdapterPath (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -ArtifactsRoot $repositoryRoot -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly

        function Assert-Continuation {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Write-ContinuationJson {
            param([string] $Path, $Value)
            [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        }

        function New-ContinuationFixture {
            param([string] $Root)

            $candidateRoot = Join-Path $Root 'candidate'
            $policyPath = Join-Path $repositoryRoot 'docs/standards/internal-source-continuation.json'
            $policyEntry = (Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json).entries[0]
            $skillRoot = Join-Path $candidateRoot 'skills/manage-confluence-docs-as-code'
            [void](New-Item -ItemType Directory -Path (Join-Path $skillRoot 'scripts') -Force)
            $paths = @('SKILL.md', 'scripts/ConfluencePlan.psm1', 'scripts/Pull-ConfluenceDocs.ps1', 'scripts/Push-ConfluenceDocs.ps1')
            foreach ($path in $paths) {
                $fullPath = Join-Path $skillRoot $path
                [IO.File]::WriteAllText($fullPath, "fixture:$path", [Text.UTF8Encoding]::new($false))
            }
            $inventory = Get-StandardValidationInventory -Root $candidateRoot -Context 'internal continuation fixture'
            $contentSha256 = Get-StandardValidationInventorySha256 -Inventory $inventory
            $allowedIssues = New-Object 'System.Collections.Generic.List[object]'
            foreach ($allowed in $policyEntry.allowedFindings) {
                foreach ($allowedLocation in $allowed.allowedLocations) {
                    $location = [ordered]@{
                        file = $allowedLocation.file
                        start_line = $allowedLocation.startLine
                        end_line = $allowedLocation.endLine
                    }
                    if ($null -ne $allowedLocation.startColumn) { $location.start_column = $allowedLocation.startColumn }
                    $evidence = if ($null -ne $allowed.targetPath) {
                        [ordered]@{
                            target_path = $allowed.targetPath
                            target_disposition = 'partial'
                            reasons = @([ordered]@{
                                reason_code = 'static_parse_limit'
                                message = $allowed.evidenceReasonMessage
                                phase = $allowed.evidencePhase
                                analyzers = @('static_patterns_tool_misuse')
                            })
                        }
                    }
                    else { [ordered]@{} }
                    [void]$allowedIssues.Add([ordered]@{
                        id = $allowed.id; category = $allowed.category; pattern = $allowed.pattern
                        severity = $allowed.severity; finding = $allowed.finding
                        match_fingerprint = $allowed.matchFingerprint
                        location = $location; occurrences = @($location); evidence = $evidence
                    })
                }
            }
            $sourceRevision = 'a' * 40
            $candidateId = 'b' * 64
            $stageIds = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static',
                'repository-tests', 'conditional-semantic-scan', 'ai-review', 'human-approval',
                'publish-or-install', 'post-install-verification')
            $stages = for ($index = 0; $index -lt $stageIds.Count; $index++) {
                [ordered]@{ order = $index + 1; id = $stageIds[$index]; status = if ($index -lt 3) { 'passed' } elseif ($index -eq 3) { 'failed' } else { 'not-run' } }
            }
            $report = [ordered]@{
                state = 'FAILED'; exitCode = 20; releaseEligible = $false
                candidate = [ordered]@{
                    sourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
                    sourceRevision = $sourceRevision; candidateId = $candidateId; contentSha256 = $contentSha256
                    activeSkills = @('manage-confluence-docs-as-code')
                }
                stages = @($stages)
                sourceConformance = [ordered]@{ status = 'failed'; releaseEligible = $false }
            }
            $scanner = [ordered]@{
                skill = [ordered]@{ name = 'manage-confluence-docs-as-code'; source = $skillRoot }
                metadata = [ordered]@{ skillspector_version = '2.12.0' }
                execution_successful = $true
                components = @($paths | ForEach-Object { [ordered]@{ path = $_ } })
                issues = $allowedIssues.ToArray(); suppressed_count = 0; suppressed = @()
                analysis_completeness = [ordered]@{
                    status = 'partial'; is_complete = $false; total_components = 4; scanned_components = 1
                    findings_before_filtering = $allowedIssues.Count; findings_after_filtering = $allowedIssues.Count
                    ledger_exceptions = @(
                        [ordered]@{ path = 'SKILL.md'; reason_code = 'static_parse_limit'; analyzers = @('static_patterns_tool_misuse') },
                        [ordered]@{ path = 'scripts/Pull-ConfluenceDocs.ps1'; reason_code = 'static_parse_limit'; analyzers = @('static_patterns_tool_misuse') },
                        [ordered]@{ path = 'scripts/Push-ConfluenceDocs.ps1'; reason_code = 'static_parse_limit'; analyzers = @('static_patterns_tool_misuse') }
                    )
                    scope_exclusions = @(); limitations = @('Analyzer static_patterns_tool_misuse status: degraded.')
                    analyzer_statuses = @($policyEntry.expectedAnalyzerIds | ForEach-Object {
                        if ($_ -ceq 'static_patterns_tool_misuse') {
                            [ordered]@{ analyzer_id = $_; status = 'degraded'; planned_work = 4; completed = 1; partial = 3; skipped = 0; failed = 0; unaccounted = 0 }
                        }
                        else {
                            [ordered]@{ analyzer_id = $_; status = 'completed'; planned_work = 4; completed = 4; partial = 0; skipped = 0; failed = 0; unaccounted = 0 }
                        }
                    })
                }
            }
            $scannerPath = Join-Path $Root 'scanner.json'
            Write-ContinuationJson -Path $scannerPath -Value $scanner
            $testsPath = Join-Path $Root 'repository-tests.json'
            $tests = [ordered]@{
                status = 'passed'; sourceRevision = $sourceRevision; contentSha256 = $contentSha256
                testResult = [ordered]@{ total = 55; passed = 55; failed = 0; skipped = 0 }
                suites = @('focused', 'canonical')
            }
            Write-ContinuationJson -Path $testsPath -Value $tests
            return [ordered]@{
                CandidateRoot = $candidateRoot; Report = $report; Scanner = $scanner; ScannerReportPath = $scannerPath
                RepositoryTests = $tests; RepositoryTestEvidencePath = $testsPath; SourceRevision = $sourceRevision
                PolicyPath = $policyPath
            }
        }

        function Invoke-ContinuationFixture {
            param($Fixture)
            return New-StandardValidationInternalSourceContinuationEligibility `
                -Report $Fixture.Report -PolicyPath $Fixture.PolicyPath -CandidateRoot $Fixture.CandidateRoot `
                -ExpectedSourceRevision $Fixture.SourceRevision -SkillId 'manage-confluence-docs-as-code' `
                -ScannerReportPath $Fixture.ScannerReportPath `
                -RepositoryTestEvidencePath $Fixture.RepositoryTestEvidencePath
        }
    }

    # Scenario: the central policy is the only authority that classifies an internal module.
    # Purpose: prevent a consumer from self-declaring an exception scope.
    It 'UnitT10_exposes_a_strict_central_internal_only_policy' {
        $policyPath = Join-Path $repositoryRoot 'docs/standards/internal-source-continuation.json'
        $schemaPath = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-continuation-v1.schema.json'
        Assert-Continuation (Test-Path -LiteralPath $policyPath) 'The central internal continuation policy is missing.'
        Assert-Continuation (Test-Path -LiteralPath $schemaPath) 'The internal continuation schema is missing.'
        $policyRaw = Get-Content -Raw -LiteralPath $policyPath
        Assert-Continuation ($policyRaw | Test-Json -SchemaFile $schemaPath) 'The central internal continuation policy does not match its strict schema.'
        $policy = $policyRaw | ConvertFrom-Json
        Assert-Continuation ($policy.authorityOwnership -ceq 'central-only') 'Internal classification must remain central-only.'
        Assert-Continuation (-not [bool]$policy.consumerSelfDeclaration) 'Consumers must not self-declare internal scope.'
        Assert-Continuation ([bool]$policy.protectedAdoptionRequired) 'Technical eligibility must require a protected adoption layer.'
        $retainedShapePath = Join-Path $repositoryRoot 'tests/fixtures/internal-source-continuation/syp171-skillspector-2.12.0-shape.json'
        Assert-Continuation (Test-Path -LiteralPath $retainedShapePath) 'The retained SYP171 scanner-shape fixture is missing.'
        $retainedShape = Get-Content -Raw -LiteralPath $retainedShapePath | ConvertFrom-Json
        Assert-Continuation ($policy.entries[0].scannerVersion -ceq $retainedShape.scannerVersion) 'The scanner version pin drifted from the retained SYP171 evidence.'
        Assert-Continuation (($policy.entries[0].expectedAnalyzerIds -join ',') -ceq ($retainedShape.analyzerIds -join ',')) 'The pinned SkillSpector analyzer inventory drifted from the retained SYP171 evidence.'
        Assert-Continuation (($policy.entries[0].allowedFindings.matchFingerprint -join ',') -ceq ($retainedShape.allowedFindingFingerprints -join ',')) 'The exact finding allowlist drifted from the retained SYP171 evidence.'
        $policyLocations = @($policy.entries[0].allowedFindings | Select-Object matchFingerprint, expectedOccurrences, allowedLocations) | ConvertTo-Json -Depth 10 -Compress
        $retainedLocations = @($retainedShape.allowedFindingLocations) | ConvertTo-Json -Depth 10 -Compress
        Assert-Continuation ($policyLocations -ceq $retainedLocations) 'The exact finding locations or occurrence counts drifted from the retained SYP171 evidence.'
        Assert-Continuation ($retainedShape.analyzerIds.Count -eq 28) 'The retained SkillSpector analyzer inventory must remain complete.'
        Assert-Continuation ($retainedShape.findingsBeforeFiltering -eq 7 -and $retainedShape.findingsAfterFiltering -eq 7 -and $retainedShape.suppressedCount -eq 0) 'The retained raw finding counts drifted.'
        Assert-Continuation (($policy.entries.sourceRepository -join ',') -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') 'Only the declared internal repository may use this policy.'
        $contract = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        Assert-Continuation (-not [bool]$contract.evidence.internalSourceContinuation.technicalPublishable) 'The central contract must keep technical eligibility non-publishable.'
        Assert-Continuation (($contract.evidence.internalSourceContinuation.protectedBindings -join ',') -ceq 'eventRepository,eventSourceRevision,canonicalRunId,launchBinding,candidateAcquisition,authorityRevision,scannerToolReceipt,staticRawEvent,supplementalTestInventory,supplementalRawEvents,cleanup,humanFindingDispositionReview,centralRevision,workflowRevision,authorityArchiveSha256') 'The protected adoption binding set drifted.'
    }

    # Scenario: one central-listed internal Skill is partial only because the approved parser analyzer degraded.
    # Purpose: let source work continue while keeping the canonical Static failure and release prohibition intact.
    It 'UnitT20_produces_only_non_publishable_internal_technical_eligibility' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'eligible')
        $decision = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($decision.status -ceq 'eligible-for-protected-review') ($decision.failureReasons -join ',')
        Assert-Continuation (-not $decision.publishable -and $decision.protectedAdoptionRequired) 'Technical eligibility must not be directly publishable.'
        Assert-Continuation ($decision.canonicalState -ceq 'FAILED' -and $decision.canonicalExitCode -eq 20) 'Canonical failure was rewritten.'
        Assert-Continuation (-not $decision.releaseEligible) 'Internal continuation must never authorize release.'
        Assert-Continuation (($decision.eligibleOperationAfterProtectedAdoption -join ',') -ceq 'source-merge') 'The later protected adoption must remain source-merge-only.'
        Assert-Continuation (($decision.forbiddenOperations -join ',') -ceq 'release,install,publish,catalog-adoption') 'Forbidden operation boundary drifted.'
        $decisionSchema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-continuation-eligibility-v1.schema.json'
        Assert-Continuation (($decision | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $decisionSchema) 'Eligible decision does not match its strict schema.'
    }

    # Scenario: the retained SYP171 report shape contains parser-derived coverage warnings and the declared Atlassian endpoint finding.
    # Purpose: accept only centrally dispositioned fingerprints while preserving the raw finding counts and evidence.
    It 'UnitT25_accepts_only_the_centrally_dispositioned_syp171_finding_shape' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'allowed-findings')
        $decision = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($decision.status -ceq 'eligible-for-protected-review') ($decision.failureReasons -join ',')
    }

    # Scenario: an external repository or an unlisted Skill presents otherwise identical evidence.
    # Purpose: keep the continuation route limited to centrally registered internal modules.
    It 'UnitT30_rejects_external_or_unlisted_modules' {
        foreach ($drift in @('external', 'skill')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            if ($drift -ceq 'external') { $fixture.Report.candidate.sourceRepository = 'https://example.com/external/skill.git' }
            else { $fixture.Report.candidate.activeSkills = @('other-skill') }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'rejected') "Scope drift '$drift' was accepted."
        }
    }

    # Scenario: evidence contains a finding, another degraded analyzer, another reason, or failed supplemental tests.
    # Purpose: allow only the named parser limitation and preserve all other blocking semantics.
    It 'UnitT40_rejects_findings_unapproved_incompleteness_and_test_failures' {
        foreach ($drift in @('finding', 'finding-location', 'finding-occurrence-count', 'endpoint-evidence', 'hidden-finding', 'suppressed-finding', 'analyzer', 'missing-analyzer', 'reason', 'duplicate-exception-path', 'tests', 'unverified-active-skill')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            switch ($drift) {
                finding { $fixture.Scanner.issues = @([ordered]@{ severity = 'HIGH'; message = 'blocked' }); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'finding-location' { $fixture.Scanner.issues[0].location.start_line = 20; $fixture.Scanner.issues[0].occurrences[0].start_line = 20; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'finding-occurrence-count' { $fixture.Scanner.issues = @($fixture.Scanner.issues | Select-Object -SkipLast 1); $fixture.Scanner.analysis_completeness.findings_before_filtering = 6; $fixture.Scanner.analysis_completeness.findings_after_filtering = 6; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'endpoint-evidence' { $fixture.Scanner.issues[-1].evidence = [ordered]@{ unreviewed = $true }; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'hidden-finding' { $fixture.Scanner.analysis_completeness.findings_before_filtering = 8; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'suppressed-finding' { $fixture.Scanner.suppressed_count = 1; $fixture.Scanner.suppressed = @([ordered]@{ id = 'hidden' }); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                analyzer { $fixture.Scanner.analysis_completeness.analyzer_statuses += [ordered]@{ analyzer_id = 'unknown'; status = 'degraded'; planned_work = 1; completed = 0; partial = 1; skipped = 0; failed = 0; unaccounted = 0 }; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'missing-analyzer' { $fixture.Scanner.analysis_completeness.analyzer_statuses = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Select-Object -Skip 1); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                reason { $fixture.Scanner.analysis_completeness.ledger_exceptions[0].reason_code = 'unknown'; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'duplicate-exception-path' { $fixture.Scanner.analysis_completeness.ledger_exceptions[1].path = 'SKILL.md'; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                tests { $fixture.RepositoryTests.status = 'failed'; $fixture.RepositoryTests.testResult.failed = 1; Write-ContinuationJson $fixture.RepositoryTestEvidencePath $fixture.RepositoryTests }
                'unverified-active-skill' { $fixture.Report.candidate.activeSkills += 'configure-jira-api-access' }
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'rejected') "Evidence drift '$drift' was accepted."
        }
    }

    # Scenario: candidate bytes, revision, or canonical failure state changes after evidence was produced.
    # Purpose: prevent stale continuation evidence from authorizing a different candidate.
    It 'UnitT50_rejects_candidate_revision_and_canonical_state_drift' {
        foreach ($drift in @('bytes', 'revision', 'canonical')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            switch ($drift) {
                bytes { [IO.File]::AppendAllText((Join-Path $fixture.CandidateRoot 'skills/manage-confluence-docs-as-code/SKILL.md'), 'changed') }
                revision { $fixture.Report.candidate.sourceRevision = 'c' * 40 }
                canonical { $fixture.Report.state = 'PASS'; $fixture.Report.exitCode = 0 }
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'rejected') "Candidate drift '$drift' was accepted."
        }
    }
}
