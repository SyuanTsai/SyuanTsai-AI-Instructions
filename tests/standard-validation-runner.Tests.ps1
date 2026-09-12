Describe 'Standard validation runner contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $script:PowerShellPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Join-Path $PSHOME 'powershell.exe'
        }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Join-Path $PSHOME 'pwsh.exe'
        }
        else {
            Join-Path $PSHOME 'pwsh'
        }

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

        function Write-TestUtf8File {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $Text
            )

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-RunnerFixture {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [string[]] $SkillIds = @('alpha', 'beta'),
                [ValidateSet('pass', 'static-fail', 'static-partial', 'package-fail', 'wrong-candidate', 'missing-output', 'timeout')]
                [string] $Behavior = 'pass'
            )

            $candidate = Join-Path $Root 'candidate'
            $tools = Join-Path $Root 'trusted-tools'
            $artifacts = Join-Path $Root 'artifacts'
            $output = Join-Path $artifacts 'evidence.json'
            $log = Join-Path $Root 'tool-events.log'
            $sentinel = Join-Path $Root 'repository-test-ran.txt'
            [void](New-Item -ItemType Directory -Path $candidate -Force)
            [void](New-Item -ItemType Directory -Path $tools -Force)
            [void](New-Item -ItemType Directory -Path $artifacts -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'skills') -Force)
            foreach ($skillId in $SkillIds) {
                $skillRoot = Join-Path $candidate ("skills/$skillId")
                [void](New-Item -ItemType Directory -Path $skillRoot -Force)
                Write-TestUtf8File -Path (Join-Path $skillRoot 'SKILL.md') -Text "---`nname: $skillId`ndescription: A harmless test Skill.`n---`n`n# $skillId`n"
            }

            $toolScript = Join-Path $tools 'fixture-tool.ps1'
            $toolScriptText = @'
$logPath = $env:STANDARD_VALIDATION_FIXTURE_LOG
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    Add-Content -LiteralPath $logPath -Value ("{0}|{1}|{2}" -f $env:STANDARD_VALIDATION_STAGE_ID, $env:STANDARD_VALIDATION_TOOL_ID, $env:STANDARD_VALIDATION_SKILL_ID) -Encoding UTF8
}
$skills = @()
if (-not [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_ACTIVE_SKILLS)) {
    $skills = @($env:STANDARD_VALIDATION_ACTIVE_SKILLS -split ';' | Where-Object { $_ })
}
$result = [ordered]@{
    schemaVersion = 1
    status = 'passed'
    decision = 'PASS'
    candidateIdentity = $env:STANDARD_VALIDATION_CANDIDATE_ID
    skillId = $env:STANDARD_VALIDATION_SKILL_ID
    activeSkills = $skills
    skillInventorySha256 = $env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256
    output = "fixture-$($env:STANDARD_VALIDATION_TOOL_ID)"
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'package-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'wrong-candidate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.candidateIdentity = ('0' * 64)
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'missing-output' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    exit 0
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'timeout' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    Start-Sleep -Seconds 10
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'static-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'static-partial' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'partial'
    $result.decision = 'BLOCK'
    $result.analyzerCompleteness = 'partial'
    $result.activeSkills = @($skills | Select-Object -First 1)
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.scannerIdentity = 'development-fixture-static-analyzer'
    if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -ne 'static-partial') {
        $result.analyzerCompleteness = 'complete'
    }
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'repository-tests') {
    [IO.File]::WriteAllText($env:STANDARD_VALIDATION_FIXTURE_SENTINEL, 'repository-test-ran', (New-Object Text.UTF8Encoding($false)))
}
$result | ConvertTo-Json -Depth 10 -Compress
'@
            Write-TestUtf8File -Path $toolScript -Text $toolScriptText

            $adapter = [ordered]@{
                schemaVersion = 1
                adapter = 'standard-validation-adapter-v1'
                mode = 'development-harness'
                skillsRoot = 'skills'
                activeSkills = @($SkillIds)
                packageAdapter = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                skillValidator = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                skillTools = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                staticAnalyzer = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                repositoryTests = @(
                    [ordered]@{
                        id = 'fixture-repository-test'
                        command = $script:PowerShellPath
                        arguments = @('-NoProfile', '-File', $toolScript)
                    }
                )
            }
            $adapterPath = Join-Path $Root 'adapter.json'
            Write-TestUtf8File -Path $adapterPath -Text ($adapter | ConvertTo-Json -Depth 20)

            return [pscustomobject][ordered]@{
                Root = $Root
                Candidate = $candidate
                Adapter = $adapterPath
                Artifacts = $artifacts
                Output = $output
                Log = $log
                Sentinel = $sentinel
                Behavior = $Behavior
                SkillIds = @($SkillIds)
            }
        }

        function Invoke-RunnerFixture {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [switch] $SemanticTriggered,
                [switch] $SemanticConsent,
                [switch] $CompleteLifecycle,
                [string] $AiReviewEvidencePath,
                [string] $HumanApprovalEvidencePath,
                [string] $PublishInstallEvidencePath,
                [string] $PostInstallEvidencePath,
                [string] $CancellationPath,
                [int] $TimeoutSeconds = 20
            )

            $arguments = @(
                '-NoProfile', '-File', $script:RunnerPath,
                '-CandidateRoot', $Fixture.Candidate,
                '-AdapterPath', $Fixture.Adapter,
                '-ArtifactsRoot', $Fixture.Artifacts,
                '-OutputPath', $Fixture.Output,
                '-SourceRepository', 'https://example.com/example/skills.git',
                '-SourceRevision', ('a' * 40),
                '-BaseRevision', ('b' * 40),
                '-EventName', 'local',
                '-TimeoutSeconds', [string]$TimeoutSeconds,
                '-DevelopmentHarness'
            )
            if ($SemanticTriggered) { $arguments += '-SemanticTriggered' }
            if ($SemanticConsent) { $arguments += '-SemanticConsent' }
            if ($CompleteLifecycle) { $arguments += '-CompleteLifecycle' }
            if (-not [string]::IsNullOrWhiteSpace($AiReviewEvidencePath)) { $arguments += @('-AiReviewEvidencePath', $AiReviewEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($HumanApprovalEvidencePath)) { $arguments += @('-HumanApprovalEvidencePath', $HumanApprovalEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PublishInstallEvidencePath)) { $arguments += @('-PublishInstallEvidencePath', $PublishInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PostInstallEvidencePath)) { $arguments += @('-PostInstallEvidencePath', $PostInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
                $arguments += @('-CancellationPath', $CancellationPath)
            }

            $fixtureEnvironment = [ordered]@{
                STANDARD_VALIDATION_FIXTURE_LOG = $Fixture.Log
                STANDARD_VALIDATION_FIXTURE_BEHAVIOR = $Fixture.Behavior
                STANDARD_VALIDATION_FIXTURE_SENTINEL = $Fixture.Sentinel
            }
            $previousEnvironment = @{}
            foreach ($entry in $fixtureEnvironment.GetEnumerator()) {
                $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, 'Process')
                [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
            }
            try {
                $captured = & $script:PowerShellPath @arguments 2>&1 | Out-String
                $exitCode = $LASTEXITCODE
            }
            finally {
                foreach ($entry in $fixtureEnvironment.GetEnumerator()) {
                    [Environment]::SetEnvironmentVariable([string]$entry.Key, $previousEnvironment[$entry.Key], 'Process')
                }
            }
            $evidence = $null
            if (Test-Path -LiteralPath $Fixture.Output -PathType Leaf) {
                try { $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $Fixture.Output | ConvertFrom-Json } catch { }
            }
            return [pscustomobject][ordered]@{
                Output = $captured
                ExitCode = $exitCode
                Evidence = $evidence
            }
        }
    }

    # Scenario: The public contract must be machine-readable before a consumer can adopt it.
    # Purpose: Keep the ten canonical stages and non-overlapping terminal outcomes explicit.
    It 'UnitT00_exposes_fixed_stage_order_and_distinct_terminal_states' {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/standard-validation-contract-v1.json') -PathType Leaf) 'The immutable validation contract is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-adapter-v1.schema.json') -PathType Leaf) 'The adapter schema is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') -PathType Leaf) 'The evidence schema is missing.'
        $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        Assert-Equal $contract.schemaVersion 1 'Validation contract schema version must be one.'
        $stages = @($contract.stages)
        Assert-Equal $stages.Count 10 'Validation contract must expose exactly ten stages.'
        Assert-Equal (($stages | ForEach-Object id) -join ',') 'controlled-acquisition,integrity-verification,package-validation,skillspector-static,repository-tests,conditional-semantic-scan,ai-review,human-approval,publish-or-install,post-install-verification' 'Stage order must be canonical.'
        Assert-Equal (($contract.terminalStates | ForEach-Object state) -join ',') 'PASS,BLOCKED,FAILED,INVALID,CANCELLED' 'Terminal states must remain distinct.'
    }

    # Scenario: A harmless development adapter exposes two active Skills to the central runner.
    # Purpose: Prove package adapter, skill-validator and skill-tools all emit real receipts before Static.
    It 'InterT10_runs_adapter_and_both_package_tools_for_every_active_skill_before_static' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'package-order')
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.ExitCode 0 'A complete development validation fixture must pass.'
        Assert-Equal $result.Evidence.state 'PASS' 'The evidence state must report a validation pass.'
        Assert-Equal @($result.Evidence.stages).Count 10 'The final evidence must retain the full stage contract.'
        $events = @(Get-Content -Encoding UTF8 -LiteralPath $fixture.Log)
        Assert-True ($events.Count -ge 6) 'The fixture must emit package and Static events.'
        $staticIndex = [Array]::IndexOf($events, ($events | Where-Object { $_ -like 'skillspector-static|staticAnalyzer|*' } | Select-Object -First 1))
        Assert-True ($staticIndex -gt 0) 'Static must execute after package events.'
        foreach ($skillId in $fixture.SkillIds) {
            Assert-True (@($events | Where-Object { $_ -like "package-validation|skill-validator|$skillId" }).Count -eq 1) "skill-validator must run for '$skillId'."
            Assert-True (@($events | Where-Object { $_ -like "package-validation|skill-tools|$skillId" }).Count -eq 1) "skill-tools must run for '$skillId'."
        }
        Assert-True ((@($events | Where-Object { $_ -like 'skillspector-static|staticAnalyzer|*' }).Count) -eq 1) 'Static must run once for the complete active Skill set.'
        $packageStage = @($result.Evidence.stages | Where-Object id -eq 'package-validation')[0]
        Assert-True (@($packageStage.events | Where-Object { $_.outputPath -and (Test-Path -LiteralPath $_.outputPath -PathType Leaf) }).Count -eq 5) 'Every package process must retain an actual output event artifact.'
    }

    # Scenario: Static reports a failure or incomplete analyzer coverage.
    # Purpose: Prevent candidate repository tests from running across the Static barrier.
    It 'InterT20_blocks_repository_test_dispatch_when_static_fails_or_is_partial' {
        foreach ($behavior in @('static-fail', 'static-partial')) {
            $fixture = New-RunnerFixture -Root (Join-Path $TestDrive $behavior) -Behavior $behavior
            $result = Invoke-RunnerFixture -Fixture $fixture
            Assert-True ($result.ExitCode -ne 0) "Static '$behavior' must not return a pass exit code."
            Assert-False (Test-Path -LiteralPath $fixture.Sentinel -PathType Leaf) "Repository tests must not run after Static '$behavior'."
            Assert-Equal @($result.Evidence.stages | Where-Object id -eq 'repository-tests' | Select-Object -ExpandProperty status) 'not-run' "Repository tests must be marked not-run after Static '$behavior'."
        }
    }

    # Scenario: A candidate adds a Skill after the adapter was authored.
    # Purpose: Ensure active Skill coverage is discovered and cannot be silently omitted.
    It 'InterT30_fails_closed_on_undeclared_new_skill_and_runs_it_when_declared' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'new-skill') -SkillIds @('alpha')
        $newSkillRoot = Join-Path $fixture.Candidate 'skills/new-skill'
        [void](New-Item -ItemType Directory -Path $newSkillRoot -Force)
        Write-TestUtf8File -Path (Join-Path $newSkillRoot 'SKILL.md') -Text "---`nname: new-skill`ndescription: Added after adapter creation.`n---`n"
        $blocked = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($blocked.ExitCode -ne 0) 'An undeclared active Skill must fail closed.'
        Assert-Equal $blocked.Evidence.state 'INVALID' 'A stale adapter must be an invalid candidate/configuration.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'No package tool may run before active Skill reconciliation.'

        $adapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.Adapter | ConvertFrom-Json
        $adapter.activeSkills = @('alpha', 'new-skill')
        Write-TestUtf8File -Path $fixture.Adapter -Text ($adapter | ConvertTo-Json -Depth 20)
        $fixture2 = New-RunnerFixture -Root (Join-Path $TestDrive 'new-skill-declared') -SkillIds @('alpha', 'new-skill')
        $result = Invoke-RunnerFixture -Fixture $fixture2
        Assert-Equal $result.ExitCode 0 'A declared new Skill must be included by the same runner.'
        Assert-True (@(Get-Content -Encoding UTF8 -LiteralPath $fixture2.Log | Where-Object { $_ -like 'package-validation|skill-validator|new-skill' }).Count -eq 1) 'The newly declared Skill must receive package validation.'
    }

    # Scenario: A report is replayed for a different candidate identity.
    # Purpose: Bind every package receipt to the candidate actually being validated.
    It 'InterT40_rejects_wrong_candidate_evidence_and_does_not_enter_static' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'wrong-candidate') -Behavior 'wrong-candidate'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($result.ExitCode -ne 0) 'Wrong-candidate evidence must not pass.'
        Assert-Equal $result.Evidence.state 'FAILED' 'A tool identity mismatch must be a failed validation.'
        Assert-False (@(Get-Content -Encoding UTF8 -LiteralPath $fixture.Log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'skillspector-static|*' }).Count -gt 0) 'Static must not run after wrong-candidate evidence.'
    }

    # Scenario: Semantic analysis is triggered without consent, and later lifecycle evidence is incomplete.
    # Purpose: Keep external semantic consent, AI review, human approval, and release evidence independent.
    It 'InterT50_blocks_triggered_semantic_without_consent_and_never_fakes_later_completion' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-consent')
        $result = Invoke-RunnerFixture -Fixture $fixture -SemanticTriggered
        Assert-True ($result.ExitCode -ne 0) 'Triggered semantic work without consent must be blocked.'
        Assert-Equal $result.Evidence.state 'BLOCKED' 'Missing semantic consent must produce BLOCKED.'
        foreach ($stageId in @('ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            $stage = @($result.Evidence.stages | Where-Object id -eq $stageId)[0]
            Assert-Equal $stage.status 'not-applicable' "Unperformed '$stageId' must not be reported as passed."
        }
    }

    # Scenario: The same event/candidate is invoked twice against one artifact root.
    # Purpose: Enforce one canonical execution and preserve the first evidence instead of overwriting it.
    It 'InterT60_rejects_duplicate_event_candidate_execution' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'duplicate')
        $first = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $first.ExitCode 0 'The first fixture execution must pass.'
        $firstEvidenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixture.Output).Hash
        $second = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($second.ExitCode -ne 0) 'A duplicate event/candidate execution must be rejected.'
        $secondEvidenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixture.Output).Hash
        Assert-Equal $secondEvidenceHash $firstEvidenceHash 'Duplicate execution must not overwrite the first evidence.'
    }

    # Scenario: A trusted child process is cancelled, times out, or emits no parseable result.
    # Purpose: Keep supervisor cleanup and output parsing fail-closed instead of converting process failure to PASS.
    It 'InterT70_never_passes_timeout_cancellation_or_missing_output' {
        $timeoutFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'timeout') -Behavior 'timeout'
        $timeoutResult = Invoke-RunnerFixture -Fixture $timeoutFixture -TimeoutSeconds 1
        Assert-Equal $timeoutResult.Evidence.state 'FAILED' 'A timed-out child process must fail validation.'
        Assert-True ($timeoutResult.ExitCode -ne 0) 'A timed-out child process must have a nonzero exit code.'

        $cancelFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'cancelled')
        $cancelPath = Join-Path $cancelFixture.Root 'cancel.requested'
        Write-TestUtf8File -Path $cancelPath -Text 'cancel'
        $cancelResult = Invoke-RunnerFixture -Fixture $cancelFixture -CancellationPath $cancelPath
        Assert-Equal $cancelResult.Evidence.state 'CANCELLED' 'A cancellation request must produce CANCELLED.'
        Assert-True ($cancelResult.ExitCode -ne 0) 'A cancellation request must never have a pass exit code.'

        $missingFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'missing-output') -Behavior 'missing-output'
        $missingResult = Invoke-RunnerFixture -Fixture $missingFixture
        Assert-Equal $missingResult.Evidence.state 'FAILED' 'Missing tool output must fail validation.'
        Assert-False (@($missingResult.Evidence.stages | Where-Object id -eq 'skillspector-static' | Select-Object -ExpandProperty status) -contains 'passed') 'Missing tool output must not reach Static.'
    }

    # Scenario: Adapter configuration is duplicated or requests a mode inconsistent with the trusted supervisor.
    # Purpose: Keep consumer configuration and execution mode as fail-closed inputs rather than policy overrides.
    It 'InterT80_rejects_duplicate_active_skills_and_mode_trust_mismatch' {
        $duplicateFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'duplicate-skills') -SkillIds @('alpha')
        $duplicateAdapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $duplicateFixture.Adapter | ConvertFrom-Json
        $duplicateAdapter.activeSkills = @('alpha', 'alpha')
        Write-TestUtf8File -Path $duplicateFixture.Adapter -Text ($duplicateAdapter | ConvertTo-Json -Depth 20)
        $duplicateResult = Invoke-RunnerFixture -Fixture $duplicateFixture
        Assert-Equal $duplicateResult.Evidence.state 'INVALID' 'Duplicate active Skill configuration must be invalid.'
        Assert-False (Test-Path -LiteralPath $duplicateFixture.Log -PathType Leaf) 'Duplicate active Skill configuration must not run a package tool.'

        $modeFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'mode-mismatch')
        $modeAdapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $modeFixture.Adapter | ConvertFrom-Json
        $modeAdapter.mode = 'production'
        Write-TestUtf8File -Path $modeFixture.Adapter -Text ($modeAdapter | ConvertTo-Json -Depth 20)
        $modeResult = Invoke-RunnerFixture -Fixture $modeFixture
        Assert-Equal $modeResult.Evidence.state 'INVALID' 'A development supervisor must reject a production adapter mode.'
        Assert-False (Test-Path -LiteralPath $modeFixture.Log -PathType Leaf) 'Mode mismatch must not run a package tool.'
    }

    # Scenario: Lifecycle evidence is supplied after validation, first without and then with independent human/release evidence.
    # Purpose: Prove that AI review cannot substitute for human approval and that a development harness is never release-eligible.
    It 'InterT90_keeps_ai_review_human_approval_and_release_evidence_independent' {
        $aiOnlyFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'ai-only')
        . $script:RunnerPath `
            -CandidateRoot $aiOnlyFixture.Candidate `
            -AdapterPath $aiOnlyFixture.Adapter `
            -ArtifactsRoot $aiOnlyFixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $aiOnlyAdapterSha = Get-StandardValidationFileSha256 -Path $aiOnlyFixture.Adapter -Context 'test adapter'
        $aiOnlyInventory = Get-StandardValidationInventory -Root $aiOnlyFixture.Candidate -Context 'test candidate'
        $aiOnlyContentSha = Get-StandardValidationInventorySha256 -Inventory $aiOnlyInventory
        $aiOnlyCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$aiOnlyContentSha`n$aiOnlyAdapterSha`n")
        $aiEvidence = Join-Path $aiOnlyFixture.Root 'ai-review.json'
        Write-TestUtf8File -Path $aiEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'ai-review'; candidateId = $aiOnlyCandidateId; status = 'passed'; decision = 'PASS'; reviewFindings = @(); findingDisposition = @() } | ConvertTo-Json -Depth 10)
        $aiOnlyResult = Invoke-RunnerFixture -Fixture $aiOnlyFixture -CompleteLifecycle -AiReviewEvidencePath $aiEvidence
        Assert-Equal $aiOnlyResult.Evidence.state 'BLOCKED' 'AI review evidence alone must not satisfy human approval.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'ai-review')[0].status) 'passed' 'AI review evidence should be recorded independently before the block.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'Missing human approval must block the lifecycle.'

        $fullFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'full-lifecycle')
        $fullAdapterSha = Get-StandardValidationFileSha256 -Path $fullFixture.Adapter -Context 'test adapter'
        $fullInventory = Get-StandardValidationInventory -Root $fullFixture.Candidate -Context 'test candidate'
        $fullContentSha = Get-StandardValidationInventorySha256 -Inventory $fullInventory
        $fullCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$fullContentSha`n$fullAdapterSha`n")
        $fullAiEvidence = Join-Path $fullFixture.Root 'ai-review.json'
        $fullHumanEvidence = Join-Path $fullFixture.Root 'human-approval.json'
        $fullPublishEvidence = Join-Path $fullFixture.Root 'publish-install.json'
        $fullPostEvidence = Join-Path $fullFixture.Root 'post-install.json'
        Write-TestUtf8File -Path $fullAiEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'ai-review'; candidateId = $fullCandidateId; status = 'passed'; decision = 'PASS'; reviewFindings = @(); findingDisposition = @() } | ConvertTo-Json -Depth 10)
        Write-TestUtf8File -Path $fullHumanEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'human-approval'; candidateId = $fullCandidateId; status = 'approved'; approver = 'human@example.test'; approvalTimestamp = '2026-09-11T00:00:00Z' } | ConvertTo-Json -Depth 10)
        Write-TestUtf8File -Path $fullPublishEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'publish-install'; candidateId = $fullCandidateId; status = 'authorized'; authorization = $true; releaseIdentity = 'release-example' } | ConvertTo-Json -Depth 10)
        Write-TestUtf8File -Path $fullPostEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'post-install'; candidateId = $fullCandidateId; status = 'passed'; installedInventory = @('skill-alpha', 'skill-beta'); postInstallIntegrity = $true } | ConvertTo-Json -Depth 10)
        $fullResult = Invoke-RunnerFixture -Fixture $fullFixture -CompleteLifecycle -AiReviewEvidencePath $fullAiEvidence -HumanApprovalEvidencePath $fullHumanEvidence -PublishInstallEvidencePath $fullPublishEvidence -PostInstallEvidencePath $fullPostEvidence
        Assert-Equal $fullResult.Evidence.state 'PASS' 'Complete lifecycle evidence should pass the development behavior fixture.'
        Assert-False ([bool]$fullResult.Evidence.releaseEligible) 'Development harness evidence must never be release-eligible.'
        foreach ($stageId in @('ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Equal (@($fullResult.Evidence.stages | Where-Object id -eq $stageId)[0].status) 'passed' "Lifecycle stage '$stageId' must be independently recorded."
        }
    }
}
