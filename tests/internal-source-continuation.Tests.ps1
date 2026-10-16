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

        function Assert-ReviewOnly {
            param($Assessment)
            Assert-Continuation ($Assessment.contract -ceq 'internal-source-review-assessment-v1') 'Wrong review contract.'
            Assert-Continuation ($Assessment.assessmentKind -ceq 'evidence-consistency-only') 'Wrong assessment kind.'
            Assert-Continuation ($Assessment.applicabilityStatus -ceq 'not-verified') 'Applicability assurance was upgraded.'
            Assert-Continuation ($Assessment.executionProvenanceStatus -ceq 'not-verified') 'Execution provenance assurance was upgraded.'
            Assert-Continuation ($Assessment.authorizationGranted -is [bool] -and -not $Assessment.authorizationGranted) 'Authorization must be Boolean false.'
            Assert-Continuation ($Assessment.authorizedOperations -is [array] -and $Assessment.authorizedOperations.Count -eq 0) 'Review cannot authorize operations.'
            Assert-Continuation (-not $Assessment.publishable -and -not $Assessment.releaseEligible) 'Review cannot be publishable or release eligible.'
            Assert-Continuation (($Assessment.forbiddenOperations -join ',') -ceq 'source-merge,release,install,publish,catalog-adoption') 'Forbidden operations drifted.'
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
            $testEvents = @()
            foreach ($suite in @('focused', 'canonical')) {
                $testEventId = [guid]::NewGuid().ToString()
                $toolId = "internal-continuation-$suite"
                $arguments = @('--suite', $suite)
                $commandSha256 = Get-StandardValidationTextSha256 -Value ("pester`n" + ($arguments -join "`n"))
                $suiteTotal = if ($suite -ceq 'focused') { 30 } else { 25 }
                $testInventory = @("${suite}:repository-tests")
                $suiteResult = [ordered]@{ status = 'passed'; decision = 'PASS'; total = $suiteTotal; passed = $suiteTotal; failed = 0; skipped = 0 }
                $testEnvelope = [ordered]@{
                    candidateIdentity = $candidateId; sourceRevision = $sourceRevision; contentSha256 = $contentSha256
                    suite = $suite; testInventory = @($testInventory); testResult = $suiteResult
                }
                $testStdout = $testEnvelope | ConvertTo-Json -Depth 10 -Compress
                $testOutputPath = Join-Path $artifactRoot "$testEventId.json"
                $testRaw = [ordered]@{
                    schemaVersion = 1; eventId = $testEventId; stageId = 'supplemental-repository-tests'
                    toolId = $toolId; skillId = $null; candidateId = $candidateId
                    command = 'pester'; commandSha256 = $commandSha256; arguments = @($arguments)
                    process = [ordered]@{ exitCode = 0; status = 'passed'; stdout = $testStdout; stderr = ''; cleanedUp = $true }
                    stdout = $testStdout; stderr = ''
                }
                Write-ContinuationJson $testOutputPath $testRaw
                $testOutputSha256 = Get-StandardValidationOutputHash -Stdout $testStdout -Stderr ''
                $testEvent = [ordered]@{
                    eventId = $testEventId; stageId = 'supplemental-repository-tests'; toolId = $toolId
                    skillId = $null; candidateId = $candidateId; status = 'passed'; exitCode = 0; cleanedUp = $true
                    command = 'pester'; commandSha256 = $commandSha256; arguments = @($arguments)
                    outputPath = $testOutputPath; outputSha256 = $testOutputSha256
                }
                $testEvents += [ordered]@{
                    suite = $suite; toolId = $toolId; eventId = $testEventId; candidateId = $candidateId
                    sourceRevision = $sourceRevision; contentSha256 = $contentSha256
                    command = 'pester'; commandSha256 = $commandSha256; arguments = @($arguments)
                    outputSha256 = $testOutputSha256; testInventory = @($testInventory)
                    testResult = $suiteResult; event = $testEvent
                }
            }
            $testsPath = Join-Path $Root 'repository-tests.json'
            $tests = [ordered]@{
                schemaVersion = 1; status = 'passed'; decision = 'PASS'; candidateId = $candidateId
                sourceRevision = $sourceRevision; contentSha256 = $contentSha256
                testResult = [ordered]@{ status = 'passed'; decision = 'PASS'; total = 55; passed = 55; failed = 0; skipped = 0 }
                suites = @('focused', 'canonical'); events = @($testEvents)
            }
            Write-ContinuationJson -Path $testsPath -Value $tests
            return [ordered]@{
                CandidateRoot = $candidateRoot; Report = $report; Scanner = $scanner; ScannerReportPath = $scannerPath
                RepositoryTests = $tests; RepositoryTestEvidencePath = $testsPath; SourceRevision = $sourceRevision
                PolicyPath = $policyPath; OtherScannerReportPaths = @($otherScannerReportPaths)
                AuthorityArtifactsRoot = (Join-Path $Root 'authority-artifacts')
            }
        }

        function Sync-ContinuationScannerBinding {
            param($Fixture)
            # Synthetic fixture helper: synchronize actual native-report bytes only;
            # never update expected authority or imply execution provenance.
            $event = $Fixture.Report.stages[3].events[0]
            $raw = Get-Content -LiteralPath $event.outputPath -Raw | ConvertFrom-Json
            $envelope = $raw.process.stdout | ConvertFrom-Json
            foreach ($native in $envelope.nativeReports) {
                $native.sha256 = Get-StandardValidationFileSha256 -Path $native.path -Context 'synthetic scanner binding'
            }
            $raw.stdout = $envelope | ConvertTo-Json -Depth 20 -Compress
            $raw.process.stdout = $raw.stdout
            Write-ContinuationJson $event.outputPath $raw
            $event.outputSha256 = Get-StandardValidationOutputHash -Stdout $raw.stdout -Stderr $raw.stderr
        }

        function Invoke-ContinuationFixture {
            param($Fixture, [string] $SkillId = 'manage-confluence-docs-as-code')
            $assessment = New-StandardValidationInternalSourceReviewAssessment `
                -Report $Fixture.Report -PolicyPath $Fixture.PolicyPath -CandidateRoot $Fixture.CandidateRoot `
                -ExpectedSourceRevision $Fixture.SourceRevision -SkillId $SkillId `
                -ScannerReportPath $Fixture.ScannerReportPath `
                -OtherScannerReportPaths $Fixture.OtherScannerReportPaths `
                -AuthorityArtifactsRoot $Fixture.AuthorityArtifactsRoot `
                -RepositoryTestEvidencePath $Fixture.RepositoryTestEvidencePath
            Assert-ReviewOnly $assessment
            return $assessment
        }

        $continuationAuthorityPaths = @(
            'docs/standards/internal-source-continuation.json',
            'docs/standards/schemas/internal-source-review-assessment-v1.schema.json',
            'docs/standards/schemas/internal-source-continuation-v1.schema.json'
        )
        $script:ContinuationExpectedAuthorityFiles = @($continuationAuthorityPaths | ForEach-Object {
            [pscustomobject][ordered]@{ path = $_; sha256 = Get-StandardValidationFileSha256 -Path (Join-Path $repositoryRoot $_) -Context 'frozen synthetic authority fixture' }
        })
        $script:StandardValidationAuthorityEvidence = [pscustomobject][ordered]@{
            binding = [pscustomobject][ordered]@{
                verified = $true
                revision = ('d' * 40)
                archivePath = 'authenticated-authority.zip'
                snapshotEvidencePath = 'authenticated-authority-receipt.json'
                selectedFiles = @($script:ContinuationExpectedAuthorityFiles)
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
                selectedFiles = @($script:ContinuationExpectedAuthorityFiles)
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
        Assert-Continuation ($policy.scope -ceq 'internal-review-only' -and $policy.permittedOperations.Count -eq 0) 'Review assessment must not authorize operations.'
        Assert-Continuation ($policy.entries[0].applicabilityAssessment.status -ceq 'not-verified') 'Missing applicability evidence must be explicit in the authority-bound policy.'
        $unsupportedProfile = $policy | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $unsupportedProfile.entries[0].applicabilityAssessment.status = 'verified'
        Assert-Continuation (-not (($unsupportedProfile | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'A caller-supplied ready profile must not satisfy the policy schema.'
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
        Assert-Continuation ($contract.evidence.internalSourceContinuation.deferredIntegration.status -ceq 'inactive' -and -not $contract.evidence.internalSourceContinuation.deferredIntegration.consumerAuthority) 'Deferred integration must have no consumer authority.'
        Assert-Continuation (-not [bool]$contract.evidence.internalSourceContinuation.technicalPublishable) 'The central contract must keep review assessment non-publishable.'
        Assert-Continuation (($contract.evidence.internalSourceContinuation.deferredIntegration.protectedBindings -join ',') -ceq 'eventRepository,eventSourceRevision,canonicalRunId,launchBinding,candidateAcquisition,authorityRevision,scannerToolReceipt,staticRawEvent,supplementalTestInventory,supplementalRawEvents,cleanup,humanFindingDispositionReview,centralRevision,workflowRevision,authorityArchiveSha256') 'The inactive deferred binding inventory drifted.'
    }

    # Scenario: production authority evidence is missing, unverified, or binds different continuation-policy bytes.
    # Purpose: require authenticated central authority before any assessment can be consistent and prevent local allowlist widening.
    It 'UnitT15_rejects_policy_bytes_outside_the_authenticated_authority_snapshot' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'authority-policy-binding')
        $previousAuthorityEvidence = $script:StandardValidationAuthorityEvidence
        try {
            $script:StandardValidationAuthorityEvidence = $null
            $missing = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($missing.status -ceq 'inconsistent') 'Eligibility was emitted without authority evidence.'
            Assert-Continuation (@($missing.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') 'The missing authority binding failure was not reported.'

            $script:StandardValidationAuthorityEvidence = [pscustomobject][ordered]@{
                binding = [pscustomobject][ordered]@{ verified = $false; selectedFiles = @() }
            }
            $unverified = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($unverified.status -ceq 'inconsistent') 'Eligibility was emitted with unverified authority evidence.'
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
            Assert-Continuation ($rejected.status -ceq 'inconsistent') 'A caller-authored verified flag and local file hashes were accepted as authenticated authority.'
            Assert-Continuation (@($rejected.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') 'The forged authority binding failure was not reported.'

            $script:StandardValidationAuthorityEvidence = $previousAuthorityEvidence
            $boundButPending = Invoke-ContinuationFixture -Fixture $fixture
            Assert-ReviewOnly $boundButPending
            Assert-Continuation ($boundButPending.status -ceq 'consistent' -and $boundButPending.failureReasons.Count -eq 0) ($boundButPending.failureReasons -join ',')
            Assert-MockCalled Assert-StandardValidationAuthoritySnapshot -Scope It
        }
        finally {
            $script:StandardValidationAuthorityEvidence = $previousAuthorityEvidence
        }
    }

    # Scenario: the continuation evaluator consumes reports and the canonical runner retains its existing routes.
    # Purpose: prevent execution parameters, supplemental registration, or hidden dispatch fallback from returning.
    It 'UnitT18_exposes_only_the_report_based_evaluator_without_execution_entrypoints' {
        Assert-Continuation ($null -eq (Get-Command 'New-StandardValidationInternalSourceContinuationEligibility' -ErrorAction SilentlyContinue)) 'Legacy eligibility API must not remain callable.'
        $evaluator = Get-Command New-StandardValidationInternalSourceReviewAssessment
        Assert-Continuation $evaluator.Parameters.ContainsKey('Report') 'The evaluator must consume an existing report.'
        foreach ($removed in @('ReportPath', 'ReportObject', 'PreDispatch')) {
            Assert-Continuation (-not $evaluator.Parameters.ContainsKey($removed)) "Removed evaluator parameter '$removed' remains callable."
        }
        $runner = Get-Command Invoke-StandardValidationRun
        Assert-Continuation (-not $runner.Parameters.ContainsKey('InternalSourceContinuationReview')) 'The continuation execution route remains callable.'
        Assert-Continuation $runner.Parameters.ContainsKey('SourceMergeExceptionReview') 'The existing PR12 route was removed.'
        $producer = Get-Command New-StandardValidationCandidateEvidence
        Assert-Continuation (-not $producer.Parameters.ContainsKey('SupplementalRepositoryTests')) 'Canonical supplemental registration remains callable.'
        foreach ($removed in @('Test-StandardValidationInternalContinuationReviewScope', 'New-StandardValidationInternalContinuationSupplementalEvidence', 'Assert-StandardValidationInternalContinuationRunnerEvidence')) {
            Assert-Continuation ($null -eq (Get-Command $removed -ErrorAction SilentlyContinue)) "Removed execution function '$removed' remains callable."
        }
    }

    # Scenario: a synthetic summary matches all existing consistency checks but lacks independent applicability evidence.
    # Purpose: reach consistent while preserving canonical failure, unverifiable applicability/provenance and zero authorization.
    It 'UnitT20_returns_consistent_without_authorizing_operations_or_mutating_canonical_failure' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'eligible')
        $beforeReport = $fixture.Report | ConvertTo-Json -Depth 30 -Compress
        Mock Invoke-StandardValidationCommandAndRecord { throw 'Evaluator dispatched a command.' }
        $decision = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($decision.status -ceq 'consistent') ($decision.failureReasons -join ',')
        Assert-Continuation ($decision.failureReasons.Count -eq 0) ($decision.failureReasons -join ',')
        Assert-ReviewOnly $decision
        Assert-Continuation (-not $decision.publishable) 'Review assessment must not be publishable.'
        Assert-Continuation ($decision.canonicalState -ceq 'FAILED' -and $decision.canonicalExitCode -eq 20) 'Canonical failure was rewritten.'
        Assert-Continuation (-not $decision.releaseEligible) 'Internal continuation must never authorize release.'
        Assert-Continuation ($decision.authorizedOperations.Count -eq 0) 'Review assessment cannot authorize source merge.'
        Assert-Continuation (($decision.forbiddenOperations -join ',') -ceq 'source-merge,release,install,publish,catalog-adoption') 'Forbidden operation boundary drifted.'
        $decisionSchema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
        Assert-Continuation (($decision | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $decisionSchema) 'Review assessment does not match its strict schema.'
        Assert-Continuation (($fixture.Report | ConvertTo-Json -Depth 30 -Compress) -ceq $beforeReport) 'The evaluator rewrote the canonical report.'
        Assert-MockCalled Invoke-StandardValidationCommandAndRecord -Times 0 -Exactly -Scope It
    }

    # Scenario: the retained SYP171 report shape contains parser-derived coverage warnings and the declared Atlassian endpoint finding.
    # Purpose: validate the retained exact finding scope without claiming applicability verification.
    It 'UnitT25_accepts_the_exact_synthetic_finding_scope_for_review' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'allowed-findings')
        $decision = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($decision.status -ceq 'consistent') ($decision.failureReasons -join ',')
        Assert-Continuation ($decision.failureReasons.Count -eq 0) ($decision.failureReasons -join ',')
        Assert-ReviewOnly $decision
    }


    # Scenario: a consistent synthetic result is changed to claim authority or an obsolete eligibility shape.
    # Purpose: enforce strict schema boundaries for positive and negative review results.
    It 'UnitT21_schema_rejects_authorization_legacy_contracts_and_invalid_result_shapes' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'schema-boundary') -IncludeOtherSkill
        $result = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($result.status -ceq 'consistent') ($result.failureReasons -join ',')
        $schema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
        foreach ($field in @('authorizationGranted', 'publishable', 'releaseEligible', 'authorizedOperations', 'forbiddenOperations', 'assessmentKind', 'applicabilityStatus', 'executionProvenanceStatus')) {
            foreach ($mutation in @('missing', 'upgrade', 'string')) {
                $changed = $result | ConvertTo-Json -Depth 25 | ConvertFrom-Json
                switch ($mutation) {
                    'missing' { $changed.PSObject.Properties.Remove($field) }
                    'string' { $changed.$field = 'false' }
                    'upgrade' {
                        $changed.$field = switch ($field) {
                            { $_ -in @('authorizationGranted', 'publishable', 'releaseEligible') } { $true }
                            'authorizedOperations' { ,@('source-merge') }
                            'forbiddenOperations' { ,@('release') }
                            default { 'verified' }
                        }
                    }
                }
                Assert-Continuation (-not (($changed | ConvertTo-Json -Depth 25) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) "Schema accepted $field/$mutation."
            }
        }
        foreach ($mutation in @('old-contract', 'old-status', 'extra-property', 'consistent-reason', 'inconsistent-empty', 'non-array-reasons', 'duplicate-reasons', 'duplicate-hashes')) {
            $changed = $result | ConvertTo-Json -Depth 25 | ConvertFrom-Json
            switch ($mutation) {
                'old-contract' { $changed.contract = 'internal-source-continuation-eligibility-v1' }
                'old-status' { $changed.status = 'eligible-for-protected-review' }
                'extra-property' { $changed | Add-Member -NotePropertyName protectedAdoptionRequired -NotePropertyValue $true }
                'consistent-reason' { $changed.failureReasons = @('unexpected') }
                'inconsistent-empty' { $changed.status = 'inconsistent'; $changed.failureReasons = @() }
                'non-array-reasons' { $changed.status = 'inconsistent'; $changed.failureReasons = 'invalid' }
                'duplicate-reasons' { $changed.status = 'inconsistent'; $changed.failureReasons = @('invalid', 'invalid') }
                'duplicate-hashes' { $changed.otherScannerReportSha256 = @($changed.otherScannerReportSha256[0], $changed.otherScannerReportSha256[0]) }
            }
            Assert-Continuation (-not (($changed | ConvertTo-Json -Depth 25) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) "Schema accepted $mutation."
        }
    }

    # Scenario: report bytes change without synchronizing the native digest.
    # Purpose: a real binding failure must be inconsistent, read-only and unable to dispatch commands.
    It 'UnitT22_reports_a_specific_binding_failure_without_mutating_or_dispatching' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'negative-read-only')
        $fixture.Scanner.metadata.claim = 'changed bytes'
        Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
        $before = $fixture.Report | ConvertTo-Json -Depth 30 -Compress
        Mock Invoke-StandardValidationCommandAndRecord { throw 'Assessment dispatched a command.' }
        $result = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($result.status -ceq 'inconsistent') 'Stale native digest was accepted.'
        Assert-Continuation (@($result.failureReasons) -contains 'internal-continuation-scanner-candidate-binding-invalid') ($result.failureReasons -join ',')
        Assert-Continuation (($fixture.Report | ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'Negative assessment mutated canonical report.'
        Assert-MockCalled Invoke-StandardValidationCommandAndRecord -Times 0 -Exactly -Scope It
        $schema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
        Assert-Continuation (($result | ConvertTo-Json -Depth 25) | Test-Json -SchemaFile $schema) 'Negative assessment must be schema-valid.'
    }

    # Scenario: one non-degraded analyzer declares less work than the component inventory and all bindings match.
    # Purpose: distinguish local consistency from independent workload completeness without needing caller claims.
    It 'UnitT26_accepts_analyzer_specific_smaller_workload_only_as_unverified_consistency' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'smaller-workload') -IncludeOtherSkill
        $analyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.analyzer_id -ceq 'mcp_tool_poisoning' })[0]
        $analyzer.planned_work = 1; $analyzer.completed = 1
        Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
        Sync-ContinuationScannerBinding $fixture
        $result = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($result.status -ceq 'consistent' -and $result.failureReasons.Count -eq 0) ($result.failureReasons -join ',')
    }

    # Scenario: active and inactive statuses contradict their typed counters in either Skill report.
    # Purpose: preserve arithmetic checks even with synchronized digests and explicitly unverified applicability.
    It 'UnitT28_rejects_counter_status_contradictions_in_target_and_other_skills' {
        foreach ($scope in @('target', 'other')) {
            foreach ($status in @('completed', 'disabled', 'not_applicable')) {
                foreach ($counter in @('planned_work', 'completed', 'partial', 'skipped', 'failed', 'unaccounted')) {
                    $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "status-$scope-$status-$counter") -IncludeOtherSkill
                    $report = if ($scope -ceq 'target') { $fixture.Scanner } else { Get-Content $fixture.OtherScannerReportPaths[0] -Raw | ConvertFrom-Json }
                    $analyzer = @($report.analysis_completeness.analyzer_statuses | Where-Object { $_.analyzer_id -ceq 'mcp_tool_poisoning' })[0]
                    $analyzer.status = $status
                    foreach ($field in @('planned_work', 'completed', 'partial', 'skipped', 'failed', 'unaccounted')) { $analyzer.$field = 0 }
                    if ($status -ceq 'completed') {
                        $analyzer.planned_work = 1; $analyzer.completed = 1
                        $analyzer.$counter = if ($counter -in @('planned_work', 'completed')) { 0 } else { 1 }
                    }
                    else { $analyzer.$counter = 1 }
                    $path = if ($scope -ceq 'target') { $fixture.ScannerReportPath } else { $fixture.OtherScannerReportPaths[0] }
                    Write-ContinuationJson $path $report
                    Sync-ContinuationScannerBinding $fixture
                    $result = Invoke-ContinuationFixture -Fixture $fixture
                    $expected = if ($scope -ceq 'target') { 'internal-continuation-analyzer-status-invalid' } else { 'internal-continuation-other-skill-report-invalid' }
                    Assert-Continuation ($result.status -ceq 'inconsistent' -and @($result.failureReasons) -contains $expected) "$scope/$status/$counter : $($result.failureReasons -join ',')"
                }
            }
        }
    }

    # Scenario: a canonical report supplies a valid integer exit code other than 20.
    # Purpose: preserve the actual diagnostic value while rejecting canonical state drift.
    It 'UnitT29_preserves_actual_integer_exit_codes_in_inconsistent_results' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'actual-exit')
        $fixture.Report.exitCode = 0
        $result = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($result.status -ceq 'inconsistent' -and $result.canonicalExitCode -eq 0) 'Actual integer exit code was lost.'
        Assert-Continuation (@($result.failureReasons) -contains 'internal-continuation-canonical-state-invalid') 'Wrong diagnostic.'
    }

    # Scenario: synthetic scanner, canonical and supplemental files use the frozen authority fixture boundary.
    # Purpose: integrate actual file/digest validators and prove stale policy/schema inventory cannot be silently rebound; this is not protected trust-chain certification.
    It 'InterT10_checks_real_file_consistency_with_the_existing_synthetic_authority_fixture' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'integrated-synthetic') -IncludeOtherSkill
        $result = Invoke-ContinuationFixture -Fixture $fixture
        Assert-Continuation ($result.status -ceq 'consistent') ($result.failureReasons -join ',')
        $savedExpected = $script:ContinuationExpectedAuthorityFiles
        try {
            foreach ($drift in @('policy-bytes', 'old-schema')) {
                $script:ContinuationExpectedAuthorityFiles = $savedExpected | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                if ($drift -ceq 'policy-bytes') { $script:ContinuationExpectedAuthorityFiles[0].sha256 = 'f' * 64 }
                else { $script:ContinuationExpectedAuthorityFiles[1].path = 'docs/standards/schemas/internal-source-continuation-eligibility-v1.schema.json' }
                $rejected = Invoke-ContinuationFixture -Fixture $fixture
                Assert-Continuation ($rejected.status -ceq 'inconsistent' -and @($rejected.failureReasons) -contains 'internal-continuation-policy-not-authority-bound') "Authority drift $drift was accepted."
            }
        }
        finally { $script:ContinuationExpectedAuthorityFiles = $savedExpected }
    }

    # Scenario: an external repository or an unlisted Skill presents otherwise identical evidence.
    # Purpose: keep the continuation route limited to centrally registered internal modules.
    It 'UnitT30_rejects_external_or_unlisted_modules' {
        foreach ($drift in @('external', 'skill')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            if ($drift -ceq 'external') { $fixture.Report.candidate.sourceRepository = 'https://example.com/external/skill.git' }
            else { $fixture.Report.candidate.activeSkills = @('other-skill') }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Scope drift '$drift' was accepted."
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
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Scanner candidate-binding drift '$drift' was accepted."
            Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-scanner-candidate-binding-invalid') "Scanner candidate-binding drift '$drift' did not report its binding failure."
        }
    }


    # Scenario: a completed analyzer appears twice or uses an unknown ID while byte bindings match.
    # Purpose: retain exact analyzer identity/cardinality checks separately from digest validation.
    It 'UnitT37_rejects_duplicate_and_unknown_analyzer_ids_with_current_bindings' {
        foreach ($scope in @('target', 'other')) {
            foreach ($mutation in @('duplicate', 'unknown')) {
                $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "analyzer-id-$scope-$mutation") -IncludeOtherSkill
                $report = if ($scope -ceq 'target') { $fixture.Scanner } else { Get-Content $fixture.OtherScannerReportPaths[0] -Raw | ConvertFrom-Json }
                $row = @($report.analysis_completeness.analyzer_statuses | Where-Object { $_.status -ceq 'completed' })[0]
                if ($mutation -ceq 'duplicate') { $report.analysis_completeness.analyzer_statuses += $row }
                else { $row.analyzer_id = 'unknown_analyzer' }
                $path = if ($scope -ceq 'target') { $fixture.ScannerReportPath } else { $fixture.OtherScannerReportPaths[0] }
                Write-ContinuationJson $path $report
                Sync-ContinuationScannerBinding $fixture
                $result = Invoke-ContinuationFixture -Fixture $fixture
                $reason = if ($scope -ceq 'target') { 'internal-continuation-analyzer-inventory-invalid' } else { 'internal-continuation-other-skill-report-invalid' }
                Assert-Continuation ($result.status -ceq 'inconsistent' -and @($result.failureReasons) -contains $reason) "$scope/$mutation : $($result.failureReasons -join ',')"
                Assert-Continuation (@($result.failureReasons) -notcontains 'internal-continuation-scanner-candidate-binding-invalid') 'This case must reach analyzer identity validation with consistent bindings.'
            }
        }
    }

    # Scenario: evidence contains a finding, another degraded analyzer, another reason, or failed supplemental tests.
    # Purpose: allow only the named parser limitation and preserve all other blocking semantics.
    It 'UnitT40_rejects_findings_unapproved_incompleteness_and_test_failures' {
        foreach ($drift in @('finding', 'finding-location', 'finding-occurrence-count', 'endpoint-evidence', 'hidden-finding', 'suppressed-finding', 'analyzer', 'completed-work-mismatch', 'non-boolean-execution-success', 'missing-analyzer', 'reason', 'duplicate-exception-path', 'missing-limitation', 'extra-limitation', 'changed-limitation', 'tests', 'unverified-active-skill')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            switch ($drift) {
                finding { $fixture.Scanner.issues = @([ordered]@{ severity = 'HIGH'; message = 'blocked' }); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'finding-location' { $fixture.Scanner.issues[0].location.start_line = 20; $fixture.Scanner.issues[0].occurrences[0].start_line = 20; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'finding-occurrence-count' { $fixture.Scanner.issues = @($fixture.Scanner.issues | Select-Object -SkipLast 1); $fixture.Scanner.analysis_completeness.findings_before_filtering = 6; $fixture.Scanner.analysis_completeness.findings_after_filtering = 6; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'endpoint-evidence' { $fixture.Scanner.issues[-1].evidence = [ordered]@{ unreviewed = $true }; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'hidden-finding' { $fixture.Scanner.analysis_completeness.findings_before_filtering = 8; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'suppressed-finding' { $fixture.Scanner.suppressed_count = 1; $fixture.Scanner.suppressed = @([ordered]@{ id = 'hidden' }); Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                analyzer { $fixture.Scanner.analysis_completeness.analyzer_statuses += [ordered]@{ analyzer_id = 'unknown'; status = 'degraded'; planned_work = 1; completed = 0; partial = 1; skipped = 0; failed = 0; unaccounted = 0 }; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
                'completed-work-mismatch' {
                    $completedAnalyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.status -ceq 'completed' })[0]
                    $completedAnalyzer.planned_work = 1
                    $completedAnalyzer.completed = 0
                    Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
                }
                'non-boolean-execution-success' { $fixture.Scanner.execution_successful = 'false'; Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner }
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
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Evidence drift '$drift' was accepted."
            if ($drift -ceq 'completed-work-mismatch') {
                Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-analyzer-status-invalid') 'Target-Skill analyzer workload mismatch did not report an invalid analyzer status.'
            }
            if ($drift -ceq 'non-boolean-execution-success') {
                Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-scanner-identity-invalid') 'A non-Boolean target-Skill execution success flag did not report invalid scanner identity.'
            }
        }
    }

    # Scenario: existing supplemental raw envelopes match the candidate, then lose or change revision/content.
    # Purpose: retain a real consistency positive case and reject missing or mismatched raw identity independently of applicability.
    It 'UnitT41_checks_raw_revision_and_content_before_accepting_test_consistency' {
        foreach ($field in @('sourceRevision', 'contentSha256')) {
            foreach ($drift in @('missing', 'null', 'mismatch')) {
                $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "raw-$field-$drift")
                $parameters = @{
                    Report = $fixture.Report; Evidence = $fixture.RepositoryTests; PolicyEntry = (Get-Content $fixture.PolicyPath -Raw | ConvertFrom-Json).entries[0]
                    CandidateId = $fixture.Report.candidate.candidateId; SourceRevision = $fixture.SourceRevision
                    ContentSha256 = $fixture.Report.candidate.contentSha256
                }
                Assert-Continuation ([bool](Assert-StandardValidationInternalContinuationRepositoryTestEvidence @parameters)) 'Consistent raw envelopes must pass the technical consistency check.'
                $record = $fixture.RepositoryTests.events[0]
                $event = $record.event
                $raw = Get-Content $event.outputPath -Raw | ConvertFrom-Json
                $envelope = $raw.process.stdout | ConvertFrom-Json
                switch ($drift) {
                    'missing' { $envelope.PSObject.Properties.Remove($field) }
                    'null' { $envelope.$field = $null }
                    'mismatch' { $envelope.$field = if ($field -ceq 'sourceRevision') { 'f' * 40 } else { 'f' * 64 } }
                }
                $raw.stdout = $envelope | ConvertTo-Json -Depth 15 -Compress
                $raw.process.stdout = $raw.stdout
                Write-ContinuationJson $event.outputPath $raw
                $event.outputSha256 = Get-StandardValidationOutputHash -Stdout $raw.stdout -Stderr $raw.stderr
                $record.outputSha256 = $event.outputSha256
                $failure = $null
                try { [void](Assert-StandardValidationInternalContinuationRepositoryTestEvidence @parameters) }
                catch { $failure = $_.Exception.Message }
                Assert-Continuation ($failure -like '*raw event identity is invalid*') "Raw '$field' '$drift' did not fail its identity check: $failure"
            }
        }
    }

    # Scenario: each target or other-Skill counter is missing, null, coerced, non-integral, or outside its range.
    # Purpose: retain typed-counter diagnostics independently of the typed consistency checks.
    It 'UnitT42_rejects_missing_or_untyped_analyzer_workload_counters' {
        $counterNames = @('planned_work', 'completed', 'partial', 'skipped', 'failed', 'unaccounted')
        foreach ($scope in @('target', 'other')) {
            foreach ($counterName in $counterNames) {
                $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "$scope-missing-$counterName") -IncludeOtherSkill:($scope -ceq 'other')
                if ($scope -ceq 'target') {
                    $completedAnalyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.status -ceq 'completed' })[0]
                    [void]$completedAnalyzer.Remove($counterName)
                    Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
                }
                else {
                    $otherReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
                    $otherReport.analysis_completeness.analyzer_statuses[0].PSObject.Properties.Remove($counterName)
                    Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $otherReport
                }
                $decision = Invoke-ContinuationFixture -Fixture $fixture
                Assert-Continuation ($decision.status -ceq 'inconsistent') "$scope analyzer accepted a missing '$counterName' counter."
                $expectedReason = if ($scope -ceq 'target') { 'internal-continuation-analyzer-counter-invalid' } else { 'internal-continuation-other-skill-report-invalid' }
                Assert-Continuation (@($decision.failureReasons) -contains $expectedReason) "Missing '$counterName' did not produce its independent counter failure."
            }
        }
        foreach ($scope in @('target', 'other')) {
            foreach ($counterName in $counterNames) {
                foreach ($invalid in @(
                        @{ name = 'null'; value = $null }, @{ name = 'string'; value = '1' },
                        @{ name = 'boolean'; value = $true }, @{ name = 'fraction'; value = 0.5 },
                        @{ name = 'integral-float'; value = [double]1 },
                        @{ name = 'negative'; value = -1 }, @{ name = 'overflow'; value = [long]2147483648 })) {
                    $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "$scope-$counterName-$($invalid.name)") -IncludeOtherSkill:($scope -ceq 'other')
                    if ($scope -ceq 'target') {
                        $analyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.status -ceq 'completed' })[0]
                        $analyzer[$counterName] = $invalid.value
                        Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
                    }
                    else {
                        $other = Get-Content $fixture.OtherScannerReportPaths[0] -Raw | ConvertFrom-Json
                        $other.analysis_completeness.analyzer_statuses[0].$counterName = $invalid.value
                        Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $other
                    }
                    $decision = Invoke-ContinuationFixture -Fixture $fixture
                    $reason = if ($scope -ceq 'target') { 'internal-continuation-analyzer-counter-invalid' } else { 'internal-continuation-other-skill-report-invalid' }
                    Assert-Continuation (@($decision.failureReasons) -contains $reason) "$scope '$counterName' '$($invalid.name)' was hidden by the typed consistency checks."
                }
            }
        }
        foreach ($drift in @('target-string', 'other-string')) {
            $scope = if ($drift.StartsWith('target-')) { 'target' } else { 'other' }
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift) -IncludeOtherSkill:($scope -ceq 'other')
            if ($scope -ceq 'target') {
                $completedAnalyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.status -ceq 'completed' })[0]
                $completedAnalyzer.planned_work = '4'
                Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
            }
            else {
                $otherReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
                $otherReport.analysis_completeness.analyzer_statuses[0].planned_work = '1'
                Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $otherReport
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "$scope analyzer accepted a non-integer planned_work value for '$drift'."
        }
    }

    # Scenario: the caller supplies an unsafe primary Skill ID that is not the centrally registered entry.
    # Purpose: reject it before composing or traversing a candidate-relative Skill path.
    It 'UnitT43_rejects_unsafe_primary_skill_ids_before_inventory_traversal' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'unsafe-primary-skill-id')
        $fixture.Report.candidate.activeSkills = @('../../outside-skill')
        Mock Get-StandardValidationInventory { throw 'Unsafe primary Skill inventory traversal.' } -ParameterFilter { $Context -ceq 'internal source continuation Skill' -and $Root -like '*unsafe-primary-skill-id*' }

        $decision = Invoke-ContinuationFixture -Fixture $fixture -SkillId '../../outside-skill'

        Assert-Continuation ($decision.status -ceq 'inconsistent') 'A traversal-like primary Skill ID was accepted.'
        Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-primary-skill-id-invalid') 'The unsafe primary Skill ID did not fail before inventory traversal.'
        Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-scope-not-registered') 'The unsafe primary Skill ID was not rejected by the central registration boundary.'
        Assert-MockCalled Get-StandardValidationInventory -Times 0 -Exactly -Scope It -ParameterFilter { $Context -ceq 'internal source continuation Skill' -and $Root -like '*unsafe-primary-skill-id*' }
    }

    # Scenario: the caller reduces a plan and recomputes every scanner and raw-event hash.
    # Purpose: a consistent caller-controlled summary may satisfy consistency but must never upgrade applicability or grant authorization.
    It 'UnitT44_accepts_consistent_workload_rewrites_without_upgrading_assurance' {
        foreach ($drift in @('smaller-plan', 'disabled', 'not-applicable', 'invented-targets', 'substituted-target', 'narrowed-range', 'duplicate-terminal')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "applicability-$drift") -IncludeOtherSkill
            $analyzer = @($fixture.Scanner.analysis_completeness.analyzer_statuses | Where-Object { $_.analyzer_id -ceq 'mcp_tool_poisoning' })[0]
            $analyzer.planned_work = 1
            $analyzer.completed = 1
            if ($drift -in @('disabled', 'not-applicable')) {
                $analyzer.status = if ($drift -ceq 'disabled') { 'disabled' } else { 'not_applicable' }
                $analyzer.planned_work = 0
                $analyzer.completed = 0
            }
            # These are explicitly untrusted additions, not a producer or an accepted profile.
            $fixture.Scanner.metadata.approved_configuration = @{ use_llm = $false }
            $fixture.Scanner.metadata.scanner_receipt = @{ verified = $true }
            $fixture.Scanner.metadata.applicability_profile = @{ status = 'verified'; authorizedOperations = @('source-merge') }
            $fixture.Scanner.applicabilityStatus = 'verified'
            $fixture.Scanner.executionProvenanceStatus = 'verified'
            $fixture.Scanner.authorizationGranted = $true
            $fixture.Scanner.planned_targets = @(@{ work_id = 'caller'; path = 'SKILL.md'; start_line = 1; end_line = 50 })
            if ($drift -ceq 'substituted-target') { $fixture.Scanner.planned_targets[0].path = 'scripts/ConfluencePlan.psm1' }
            if ($drift -ceq 'narrowed-range') { $fixture.Scanner.planned_targets[0].end_line = 1 }
            $fixture.Scanner.terminal_events = @($fixture.Scanner.planned_targets)
            if ($drift -ceq 'duplicate-terminal') { $fixture.Scanner.terminal_events += $fixture.Scanner.terminal_events[0] }
            Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
            $event = $fixture.Report.stages[3].events[0]
            $raw = Get-Content -Raw -LiteralPath $event.outputPath | ConvertFrom-Json
            $envelope = $raw.process.stdout | ConvertFrom-Json
            $envelope.nativeReports[0].sha256 = Get-StandardValidationFileSha256 -Path $fixture.ScannerReportPath -Context 'caller rewritten scanner'
            $raw.stdout = $envelope | ConvertTo-Json -Depth 20 -Compress
            $raw.process.stdout = $raw.stdout
            Write-ContinuationJson $event.outputPath $raw
            $event.outputSha256 = Get-StandardValidationOutputHash -Stdout $raw.stdout -Stderr $raw.stderr

            $decision = Invoke-ContinuationFixture -Fixture $fixture

            Assert-Continuation ($decision.status -ceq 'consistent') ($decision.failureReasons -join ',')
            Assert-Continuation ($decision.failureReasons.Count -eq 0) ($decision.failureReasons -join ',')
            Assert-ReviewOnly $decision
            Assert-Continuation (@($decision.failureReasons) -notcontains 'internal-continuation-scanner-candidate-binding-invalid') 'This scenario must pass the byte-binding check to exercise the authority gap.'
            $schema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
            Assert-Continuation (($decision | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schema) 'The assessment must remain schema-valid.'
        }
    }

    # Scenario: a completed analyzer in another active Skill does not complete its own planned workload.
    # Purpose: require every completed analyzer to finish its authenticated analyzer-specific plan.
    It 'UnitT45_rejects_other_skill_workload_mismatch_and_non_boolean_success_flags' {
        foreach ($drift in @('completed-work-mismatch', 'non-boolean-execution-success', 'non-boolean-completeness')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "other-$drift") -IncludeOtherSkill
            $otherReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
            switch ($drift) {
                'completed-work-mismatch' {
                    $otherReport.analysis_completeness.analyzer_statuses[0].planned_work = 1
                    $otherReport.analysis_completeness.analyzer_statuses[0].completed = 0
                }
                'non-boolean-execution-success' { $otherReport.execution_successful = 'false' }
                'non-boolean-completeness' { $otherReport.analysis_completeness.is_complete = 'false' }
            }
            Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $otherReport
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Other-Skill drift '$drift' was accepted."
            Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-other-skill-report-invalid') "Other-Skill drift '$drift' did not report an invalid scanner report."
        }
    }

    # Scenario: another scanner report names a traversal-like Skill ID that resolves outside the candidate Skill root.
    # Purpose: reject unsafe or unexpected Skill IDs before constructing or enumerating an inventory path from them.
    It 'UnitT46_rejects_unsafe_other_skill_ids_before_inventory_traversal' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'unsafe-other-skill-id') -IncludeOtherSkill
        $outsideRoot = Join-Path (Split-Path -Parent $fixture.CandidateRoot) 'outside-skill'
        [void](New-Item -ItemType Directory -Path $outsideRoot -Force)
        [IO.File]::WriteAllText((Join-Path $outsideRoot 'SENTINEL.md'), 'must-not-be-inventoried', [Text.UTF8Encoding]::new($false))
        $otherReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
        $otherReport.skill.name = '../../outside-skill'
        $otherReport.skill.source = $outsideRoot
        Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $otherReport

        Mock Get-StandardValidationInventory { throw 'Unsafe other Skill inventory traversal.' } -ParameterFilter { $Context -eq 'internal source continuation ../../outside-skill' }
        $decision = Invoke-ContinuationFixture -Fixture $fixture
        Assert-MockCalled Get-StandardValidationInventory -Times 0 -Exactly -Scope It -ParameterFilter { $Context -eq 'internal source continuation ../../outside-skill' }
        Assert-Continuation ($decision.status -ceq 'inconsistent') 'A traversal-like other-Skill ID was accepted.'
        Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-other-skill-id-invalid') 'The unsafe other-Skill ID did not fail before inventory traversal.'
    }

    # Scenario: the same invalid other-Skill report path is supplied more than once in one decision.
    # Purpose: keep every repeated output collection unique so rejected evidence still matches its strict schema.
    It 'UnitT47_emits_unique_failure_reasons_and_report_hashes_for_repeated_invalid_other_skill_reports' {
        $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive 'multiple-invalid-other-reports') -IncludeOtherSkill
        $firstReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
        $firstReport.execution_successful = $false
        Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $firstReport

        $fixture.OtherScannerReportPaths = @($fixture.OtherScannerReportPaths[0], $fixture.OtherScannerReportPaths[0])
        $fixture.Report.candidate.activeSkills += 'configure-jira-api-access'

        $decision = Invoke-ContinuationFixture -Fixture $fixture
        $failureReasons = @($decision.failureReasons)
        $otherScannerReportSha256 = @($decision.otherScannerReportSha256)
        Assert-Continuation ($decision.status -ceq 'inconsistent') 'Multiple invalid other-Skill reports did not reject consistency.'
        Assert-Continuation ($failureReasons.Count -eq @($failureReasons | Select-Object -Unique).Count) 'Inconsistent assessment emitted duplicate failure reasons.'
        Assert-Continuation ($otherScannerReportSha256.Count -eq @($otherScannerReportSha256 | Select-Object -Unique).Count) 'Inconsistent assessment emitted duplicate other-Skill report hashes.'
        $decisionSchema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
        Assert-Continuation (($decision | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $decisionSchema) 'Inconsistent assessment with multiple invalid other-Skill reports does not match its strict schema.'
    }

    # Scenario: a target or other-Skill scanner report omits an array-valued collection that would otherwise count as empty.
    # Purpose: require typed scanner collections so missing or null evidence cannot satisfy zero-count checks.
    It 'UnitT48_rejects_missing_or_non_array_scanner_collections' {
        foreach ($drift in @(
                'target-missing-issues', 'target-null-suppressed', 'target-missing-scope-exclusions',
                'target-null-limitations', 'other-missing-issues', 'other-null-suppressed',
                'other-missing-ledger-exceptions', 'other-null-scope-exclusions', 'other-missing-limitations')) {
            $includeOther = $drift.StartsWith('other-')
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift) -IncludeOtherSkill:$includeOther
            if ($includeOther) {
                $otherReport = Get-Content -Raw -LiteralPath $fixture.OtherScannerReportPaths[0] | ConvertFrom-Json
                switch ($drift) {
                    'other-missing-issues' { $otherReport.PSObject.Properties.Remove('issues') }
                    'other-null-suppressed' { $otherReport.suppressed = $null }
                    'other-missing-ledger-exceptions' { $otherReport.analysis_completeness.PSObject.Properties.Remove('ledger_exceptions') }
                    'other-null-scope-exclusions' { $otherReport.analysis_completeness.scope_exclusions = $null }
                    'other-missing-limitations' { $otherReport.analysis_completeness.PSObject.Properties.Remove('limitations') }
                }
                Write-ContinuationJson $fixture.OtherScannerReportPaths[0] $otherReport
            }
            else {
                switch ($drift) {
                    'target-missing-issues' { [void]$fixture.Scanner.Remove('issues') }
                    'target-null-suppressed' { $fixture.Scanner.suppressed = $null }
                    'target-missing-scope-exclusions' { [void]$fixture.Scanner.analysis_completeness.Remove('scope_exclusions') }
                    'target-null-limitations' { $fixture.Scanner.analysis_completeness.limitations = $null }
                }
                Write-ContinuationJson $fixture.ScannerReportPath $fixture.Scanner
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Scanner collection drift '$drift' was accepted."
            $expectedReason = if ($includeOther) { 'internal-continuation-other-skill-report-invalid' } else { 'internal-continuation-scanner-report-invalid' }
            Assert-Continuation (@($decision.failureReasons) -contains $expectedReason) "Scanner collection drift '$drift' did not report an invalid scanner report."
        }
    }

    # Scenario: supplemental test aggregates are missing or drift from their candidate-bound raw process events.
    # Purpose: require executed test inventory, command/result binding, and cleanup proof instead of trusting caller-authored counts.
    It 'UnitT49_rejects_unbound_or_fabricated_supplemental_test_evidence' {
        foreach ($drift in @('missing-events', 'candidate', 'command', 'inventory', 'cleanup', 'raw-result', 'raw-count-string', 'aggregate-count-string')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive "test-process-$drift")
            $record = $fixture.RepositoryTests.events[0]
            switch ($drift) {
                'missing-events' { $fixture.RepositoryTests.events = @() }
                'candidate' { $record.candidateId = ('f' * 64) }
                'command' { $record.command = 'pwsh' }
                'inventory' { $record.testInventory = @('invented:test') }
                'cleanup' { $record.event.cleanedUp = $false }
                { $_ -in @('raw-result', 'raw-count-string') } {
                    $raw = Get-Content -Raw -LiteralPath $record.event.outputPath | ConvertFrom-Json
                    $envelope = [string]$raw.process.stdout | ConvertFrom-Json
                    if ($drift -ceq 'raw-result') { $envelope.testResult.passed = 0 }
                    else { $envelope.testResult.passed = [string]$envelope.testResult.passed }
                    $changedStdout = $envelope | ConvertTo-Json -Depth 10 -Compress
                    $raw.process.stdout = $changedStdout
                    $raw.stdout = $changedStdout
                    Write-ContinuationJson $record.event.outputPath $raw
                    $changedOutputSha256 = Get-StandardValidationOutputHash -Stdout $changedStdout -Stderr ''
                    $record.event.outputSha256 = $changedOutputSha256
                    $record.outputSha256 = $changedOutputSha256
                }
                'aggregate-count-string' { $fixture.RepositoryTests.testResult.passed = '55' }
            }
            Write-ContinuationJson $fixture.RepositoryTestEvidencePath $fixture.RepositoryTests
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Supplemental test process drift '$drift' was accepted."
            Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-repository-test-process-evidence-invalid') "Supplemental test process drift '$drift' did not report invalid process evidence."
        }
    }

    # Scenario: candidate bytes, revision, canonical state, typed exit code, or typed release prohibition changes after evidence was produced.
    # Purpose: reject stale or coerced canonical evidence while preserving schema-valid structured rejection output.
    It 'UnitT50_rejects_candidate_revision_and_canonical_state_drift' {
        foreach ($drift in @(
                'bytes', 'revision', 'canonical', 'exit-missing', 'exit-null', 'exit-string', 'exit-decimal',
                'report-release-missing', 'report-release-null', 'report-release-numeric',
                'source-release-missing', 'source-release-null', 'source-release-numeric')) {
            $fixture = New-ContinuationFixture -Root (Join-Path $TestDrive $drift)
            switch ($drift) {
                bytes { [IO.File]::AppendAllText((Join-Path $fixture.CandidateRoot 'skills/manage-confluence-docs-as-code/SKILL.md'), 'changed') }
                revision { $fixture.Report.candidate.sourceRevision = 'c' * 40 }
                canonical { $fixture.Report.state = 'PASS'; $fixture.Report.exitCode = 0 }
                'exit-missing' { [void]$fixture.Report.Remove('exitCode') }
                'exit-null' { $fixture.Report.exitCode = $null }
                'exit-string' { $fixture.Report.exitCode = '20' }
                'exit-decimal' { $fixture.Report.exitCode = [double]20 }
                'report-release-missing' { [void]$fixture.Report.Remove('releaseEligible') }
                'report-release-null' { $fixture.Report.releaseEligible = $null }
                'report-release-numeric' { $fixture.Report.releaseEligible = 0 }
                'source-release-missing' { [void]$fixture.Report.sourceConformance.Remove('releaseEligible') }
                'source-release-null' { $fixture.Report.sourceConformance.releaseEligible = $null }
                'source-release-numeric' { $fixture.Report.sourceConformance.releaseEligible = 0 }
            }
            $decision = Invoke-ContinuationFixture -Fixture $fixture
            Assert-Continuation ($decision.status -ceq 'inconsistent') "Candidate drift '$drift' was accepted."
            if ($drift -like '*-release-*') {
                Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-canonical-state-invalid') "Canonical release drift '$drift' did not report invalid canonical state."
            }
            if ($drift -like 'exit-*') {
                Assert-Continuation (@($decision.failureReasons) -contains 'internal-continuation-canonical-state-invalid') "Canonical exit drift '$drift' did not report invalid canonical state."
            }
            $decisionSchema = Join-Path $repositoryRoot 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'
            Assert-Continuation (($decision | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $decisionSchema) "Candidate drift '$drift' did not produce schema-valid rejection evidence."
        }
    }
}
