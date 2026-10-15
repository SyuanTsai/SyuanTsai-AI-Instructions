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
            param([string] $Root, [switch] $IncludeOtherSkill)

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
            $activeSkills = @('manage-confluence-docs-as-code')
            $otherSkillId = 'configure-jira-api-access'
            $otherSkillRoot = Join-Path $candidateRoot "skills/$otherSkillId"
            $otherPaths = @('SKILL.md')
            if ($IncludeOtherSkill) {
                [void](New-Item -ItemType Directory -Path $otherSkillRoot -Force)
                [IO.File]::WriteAllText((Join-Path $otherSkillRoot 'SKILL.md'), 'fixture:other-skill', [Text.UTF8Encoding]::new($false))
                $activeSkills += $otherSkillId
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
                    activeSkills = @($activeSkills)
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
            $artifactRoot = Join-Path $Root 'run-artifacts'
            $nativeReportRoot = Join-Path $artifactRoot 'native-reports'
            [void](New-Item -ItemType Directory -Path $nativeReportRoot -Force)
            $scannerPath = Join-Path $nativeReportRoot 'manage-confluence-docs-as-code.json'
            Write-ContinuationJson -Path $scannerPath -Value $scanner
            $otherScannerReportPaths = @()
            if ($IncludeOtherSkill) {
                $otherScanner = [ordered]@{
                    skill = [ordered]@{ name = $otherSkillId; source = $otherSkillRoot }
                    metadata = [ordered]@{ skillspector_version = '2.12.0' }
                    execution_successful = $true
                    components = @($otherPaths | ForEach-Object { [ordered]@{ path = $_ } })
                    issues = @(); suppressed_count = 0; suppressed = @()
                    analysis_completeness = [ordered]@{
                        status = 'complete'; is_complete = $true; total_components = 1; scanned_components = 1
                        findings_before_filtering = 0; findings_after_filtering = 0
                        ledger_exceptions = @(); scope_exclusions = @(); limitations = @()
                        analyzer_statuses = @($policyEntry.expectedAnalyzerIds | ForEach-Object {
                            [ordered]@{ analyzer_id = $_; status = 'completed'; planned_work = 1; completed = 1; partial = 0; skipped = 0; failed = 0; unaccounted = 0 }
                        })
                    }
                }
                $otherScannerPath = Join-Path $nativeReportRoot "$otherSkillId.json"
                Write-ContinuationJson -Path $otherScannerPath -Value $otherScanner
                $otherScannerReportPaths = @($otherScannerPath)
            }
            $nativeReports = @(
                [ordered]@{
                    skillId = 'manage-confluence-docs-as-code'; path = $scannerPath
                    sha256 = Get-StandardValidationFileSha256 -Path $scannerPath -Context 'internal continuation target native report'
                    exitCode = 0; command = 'skillspector'; commandSha256 = ('c' * 64); arguments = @('--source', $skillRoot)
                }
            )
            if ($IncludeOtherSkill) {
                $nativeReports += [ordered]@{
                    skillId = $otherSkillId; path = $otherScannerReportPaths[0]
                    sha256 = Get-StandardValidationFileSha256 -Path $otherScannerReportPaths[0] -Context 'internal continuation other native report'
                    exitCode = 0; command = 'skillspector'; commandSha256 = ('c' * 64); arguments = @('--source', $otherSkillRoot)
                }
            }
            $eventId = [guid]::NewGuid().ToString()
            $eventStdout = [string]([ordered]@{
                    candidateIdentity = $candidateId; activeSkills = @($activeSkills)
                    analyzerCompleteness = 'incomplete'; nativeReports = @($nativeReports)
                } | ConvertTo-Json -Depth 20 -Compress)
            $eventStderr = "SkillSpector did not prove complete static analysis for 'manage-confluence-docs-as-code'.`n"
            $eventRaw = [ordered]@{
                schemaVersion = 1; eventId = $eventId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'
                skillId = $null; candidateId = $candidateId
                process = [ordered]@{ exitCode = 1; status = 'failed'; cleanedUp = $true; stdout = $eventStdout; stderr = $eventStderr }
                stdout = $eventStdout; stderr = $eventStderr
            }
            $eventPath = Join-Path $artifactRoot 'static-event.json'
            Write-ContinuationJson -Path $eventPath -Value $eventRaw
            $stages[3].events = @([ordered]@{
                    eventId = $eventId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'; skillId = $null
                    candidateId = $candidateId; commandSha256 = ('c' * 64); exitCode = 1; status = 'failed'
                    outputSha256 = Get-StandardValidationOutputHash -Stdout $eventStdout -Stderr $eventStderr
                    outputPath = $eventPath; cleanedUp = $true
                })
            $report.artifacts = [ordered]@{ root = $artifactRoot }
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
                PolicyPath = $policyPath; OtherScannerReportPaths = @($otherScannerReportPaths)
                AuthorityArtifactsRoot = (Join-Path $Root 'authority-artifacts')
            }
        }

        function Invoke-ContinuationFixture {
            param($Fixture)
            return New-StandardValidationInternalSourceContinuationEligibility `
                -Report $Fixture.Report -PolicyPath $Fixture.PolicyPath -CandidateRoot $Fixture.CandidateRoot `
                -ExpectedSourceRevision $Fixture.SourceRevision -SkillId 'manage-confluence-docs-as-code' `
                -ScannerReportPath $Fixture.ScannerReportPath `
                -OtherScannerReportPaths $Fixture.OtherScannerReportPaths `
                -AuthorityArtifactsRoot $Fixture.AuthorityArtifactsRoot `
                -RepositoryTestEvidencePath $Fixture.RepositoryTestEvidencePath
        }

        $continuationAuthorityPaths = @(
            'docs/standards/internal-source-continuation.json',
            'docs/standards/schemas/internal-source-continuation-eligibility-v1.schema.json',
            'docs/standards/schemas/internal-source-continuation-v1.schema.json'
        )
        $script:StandardValidationAuthorityEvidence = [pscustomobject][ordered]@{
            binding = [pscustomobject][ordered]@{
                verified = $true
                revision = ('d' * 40)
                archivePath = 'authenticated-authority.zip'
                snapshotEvidencePath = 'authenticated-authority-receipt.json'
                selectedFiles = @($continuationAuthorityPaths | ForEach-Object {
                        [pscustomobject][ordered]@{
                            path = $_
                            sha256 = Get-StandardValidationFileSha256 -Path (Join-Path $repositoryRoot $_) -Context "internal continuation test authority file $_"
                        }
                    })
            }
        }
    }

    BeforeEach {
        Mock Assert-StandardValidationAuthoritySnapshot {
            param($RepositoryRoot, $AuthorityRevision, $AuthorityArchivePath, $AuthoritySnapshotEvidencePath,
                $TrustAnchorRoot, $ArtifactsRoot, $StagingRoot, $Context)
            if ($AuthorityRevision -cne ('d' * 40) -or
                $AuthorityArchivePath -cne 'authenticated-authority.zip' -or
                $AuthoritySnapshotEvidencePath -cne 'authenticated-authority-receipt.json') {
                throw 'BLOCKED|Test authority snapshot is not authenticated.'
            }
            return [pscustomobject][ordered]@{
                verified = $true; revision = $AuthorityRevision
                archivePath = $AuthorityArchivePath; snapshotEvidencePath = $AuthoritySnapshotEvidencePath
                selectedFiles = @($continuationAuthorityPaths | ForEach-Object {
                        [pscustomobject][ordered]@{
                            path = $_
                            sha256 = Get-StandardValidationFileSha256 -Path (Join-Path $repositoryRoot $_) -Context "authenticated continuation authority file $_"
                        }
                    })
            }
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
        Assert-Continuation (($policy.entries[0].expectedLimitations -join "`n") -ceq ($retainedShape.expectedLimitations -join "`n")) 'The exact SkillSpector limitations inventory drifted from the retained SYP171 evidence.'
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

    # Scenario: production authority evidence is missing, unverified, or binds different continuation-policy bytes.
    # Purpose: require authenticated central authority before any eligibility can be emitted and prevent local allowlist widening.
    It 'UnitT15_rejects_policy_bytes_outside_the_authenticated_authority_snapshot' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'authority-policy-binding')
        $previousAuthorityEvidence = $script:StandardValidationAuthorityEvidence
        try {
            $script:StandardValidationAuthorityEvidence = $null
            $missing = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($missing.status -ceq 'rejected') 'Eligibility was emitted without authority evidence.'
            Assert-Continuation (@($missing.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') 'The missing authority binding failure was not reported.'

            $script:StandardValidationAuthorityEvidence = [pscustomobject][ordered]@{
                binding = [pscustomobject][ordered]@{ verified = $false; selectedFiles = @() }
            }
            $unverified = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($unverified.status -ceq 'rejected') 'Eligibility was emitted with unverified authority evidence.'
            Assert-Continuation (@($unverified.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') 'The unverified authority binding failure was not reported.'

            $script:StandardValidationAuthorityEvidence = [pscustomobject][ordered]@{
                binding = [pscustomobject][ordered]@{
                    verified = $true
                    revision = ('e' * 40)
                    archivePath = 'caller-selected-authority.zip'
                    snapshotEvidencePath = 'caller-selected-authority-receipt.json'
                    selectedFiles = @(
                        $continuationAuthorityPaths | ForEach-Object {
                            [pscustomobject][ordered]@{
                                path = $_
                                sha256 = Get-StandardValidationFileSha256 -Path (Join-Path $repositoryRoot $_) -Context "self-asserted continuation authority file $_"
                            }
                        }
                    )
                }
            }
            $rejected = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($rejected.status -ceq 'rejected') 'A caller-authored verified flag and local file hashes were accepted as authenticated authority.'
            Assert-Continuation (@($rejected.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') 'The forged authority binding failure was not reported.'

            $script:StandardValidationAuthorityEvidence = $previousAuthorityEvidence
            $accepted = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($accepted.status -ceq 'eligible-for-protected-review') ($accepted.failureReasons -join ',')
            Assert-MockCalled Assert-StandardValidationAuthoritySnapshot -Scope It
        }
        finally {
            $script:StandardValidationAuthorityEvidence = $previousAuthorityEvidence
        }
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

    # Scenario: scanner JSON is copied from another checkout or bound to a different candidate event.
    # Purpose: require both target and other-Skill reports to be the native reports emitted by this candidate's Stage 4 process.
    It 'UnitT35_rejects_scanner_reports_not_bound_to_the_evaluated_candidate' {
        foreach ($drift in @('target-report-path', 'target-source', 'event-candidate', 'other-report-path', 'other-source')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "candidate-binding-$drift") -IncludeOtherSkill
            switch ($drift) {
                'target-report-path' {
                    $stalePath = Join-Path (Split-Path -Parent $fixture.ScannerReportPath) 'copied-target.json'
                    Copy-Item -LiteralPath $fixture.ScannerReportPath -Destination $stalePath
                    $fixture.ScannerReportPath = $stalePath
                }
                'target-source' {
                    $fixture.Scanner.skill.source = Join-Path $TestDrive 'another-checkout/manage-confluence-docs-as-code'
                    Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
                }
                'event-candidate' { $fixture.Report.stages[3].events[0].candidateId = ('f' * 64) }
                'other-report-path' {
                    $stalePath = Join-Path (Split-Path -Parent $fixture.OtherScannerReportPaths[0]) 'copied-other.json'
                    Copy-Item -LiteralPath $fixture.OtherScannerReportPaths[0] -Destination $stalePath
                    $fixture.OtherScannerReportPaths[0] = $stalePath
                }
                'other-source' {
                    $other = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
                    $other.skill.source = Join-Path $TestDrive 'another-checkout/configure-jira-api-access'
                    Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $other
                }
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'rejected') "Scanner candidate-binding drift '$drift' was accepted."
            Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-scanner-candidate-binding-invalid') "Scanner candidate-binding drift '$drift' did not report its binding failure."
        }
    }

    # Scenario: evidence contains a finding, another degraded analyzer, another reason, or failed supplemental tests.
    # Purpose: allow only the named parser limitation and preserve all other blocking semantics.
    It 'UnitT40_rejects_findings_unapproved_incompleteness_and_test_failures' {
        foreach ($drift in @('finding', 'finding-location', 'finding-occurrence-count', 'endpoint-evidence', 'hidden-finding', 'suppressed-finding', 'analyzer', 'missing-analyzer', 'reason', 'duplicate-exception-path', 'missing-limitation', 'extra-limitation', 'changed-limitation', 'tests', 'unverified-active-skill')) {
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
                'missing-limitation' { $fixture.Scanner.analysis_completeness.limitations = @(); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'extra-limitation' { $fixture.Scanner.analysis_completeness.limitations += 'Analyzer static_patterns_tool_misuse status: degraded for an unregistered reason.'; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'changed-limitation' { $fixture.Scanner.analysis_completeness.limitations = @('Unexpected static_patterns_tool_misuse limitation.'); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
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
