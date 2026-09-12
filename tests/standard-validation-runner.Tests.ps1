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
                [ValidateSet('pass', 'static-fail', 'static-partial', 'package-fail', 'wrong-candidate', 'missing-output', 'timeout', 'snapshot-mutate')]
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
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'scripts') -Force)
            Write-TestUtf8File -Path (Join-Path $candidate 'scripts/Invoke-StandardValidation.ps1') -Text '# canonical validation entry point fixture`n'
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
if ($env:STANDARD_VALIDATION_FIXTURE_BEHAVIOR -eq 'snapshot-mutate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $targetSkill = @($skills | Select-Object -First 1)[0]
    Add-Content -LiteralPath (Join-Path $env:STANDARD_VALIDATION_CANDIDATE_ROOT ("skills/$targetSkill/SKILL.md")) -Value 'mutated-by-package-fixture' -Encoding UTF8
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
                canonicalValidatorPath = 'scripts/Invoke-StandardValidation.ps1'
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
                TrustedTools = $tools
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
                [bool] $DevelopmentHarness = $true,
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
                '-TrustedToolRoot', $Fixture.TrustedTools
            )
            if ($DevelopmentHarness) { $arguments += '-DevelopmentHarness' }
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

        function Get-TestHumanApprovalPayload {
            param(
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][string] $ApprovalId,
                [Parameter(Mandatory = $true)][string] $Approver,
                [Parameter(Mandatory = $true)][string] $ApprovalTimestamp,
                [Parameter(Mandatory = $true)][string] $ReviewDisposition,
                [Parameter(Mandatory = $true)][string] $HostId,
                [Parameter(Mandatory = $true)][string] $ActorId
            )
            return "candidateId=$CandidateId`napprovalId=$ApprovalId`napprover=$Approver`napprovalTimestamp=$ApprovalTimestamp`nreviewDisposition=$ReviewDisposition`nhostId=$HostId`nactorId=$ActorId"
        }

        function Write-TestHumanApprovalEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId
            )
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'human-approval-public-key.xml') -Text $rsa.ToXmlString($false)
                $approvalId = 'approval-001'
                $approver = 'human@example.test'
                $approvalTimestamp = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
                $reviewDisposition = 'approved'
                $hostId = 'test-host'
                $actorId = 'test-actor'
                $payload = Get-TestHumanApprovalPayload -CandidateId $CandidateId -ApprovalId $approvalId -Approver $approver -ApprovalTimestamp $approvalTimestamp -ReviewDisposition $reviewDisposition -HostId $hostId -ActorId $actorId
                $signature = [Convert]::ToBase64String($rsa.SignData([Text.Encoding]::UTF8.GetBytes($payload), 'SHA256'))
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = 'human-approval'
                    candidateId = $CandidateId
                    status = 'approved'
                    approvalId = $approvalId
                    approver = $approver
                    approvalTimestamp = $approvalTimestamp
                    reviewDisposition = $reviewDisposition
                    attestation = [ordered]@{
                        schemaVersion = 1
                        attestationType = 'trusted-supervisor-human-approval-v1'
                        candidateId = $CandidateId
                        approvalId = $approvalId
                        hostId = $hostId
                        actorId = $actorId
                        issuedAt = $approvalTimestamp
                        reviewDisposition = $reviewDisposition
                        signature = $signature
                    }
                }
                Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 20)
            }
            finally { $rsa.Dispose() }
        }

        function Get-TestLifecycleAttestationPayload {
            param(
                [Parameter(Mandatory = $true)][string] $ReceiptType,
                [Parameter(Mandatory = $true)][hashtable] $Fields
            )
            $orderedNames = @($Fields.Keys | Sort-Object)
            return (@("receiptType=$ReceiptType" + ($orderedNames | ForEach-Object { "$_=$([string]$Fields[$_])" })) -join "`n")
        }

        function Write-TestLifecycleEvidence {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][ValidateSet('publish-install', 'post-install')][string] $EvidenceType,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][System.Security.Cryptography.RSACryptoServiceProvider] $Rsa
            )

            $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            if ($EvidenceType -ceq 'publish-install') {
                $releaseIdentity = 'release-example'
                $fields = @{
                    authorization = 'True'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    issuedAt = $issuedAt
                    releaseIdentity = $releaseIdentity
                    status = 'authorized'
                }
                $attestation = [ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-publish-install-v1'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    status = 'authorized'
                    authorization = $true
                    releaseIdentity = $releaseIdentity
                    issuedAt = $issuedAt
                    signature = $null
                }
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = $EvidenceType
                    candidateId = $CandidateId
                    status = 'authorized'
                    authorization = $true
                    releaseIdentity = $releaseIdentity
                    attestation = $attestation
                }
            }
            else {
                $inventory = @('skill-alpha', 'skill-beta')
                $inventoryText = [string]::Join(';', $inventory)
                $fields = @{
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    installedInventory = $inventoryText
                    issuedAt = $issuedAt
                    postInstallIntegrity = 'True'
                    status = 'passed'
                }
                $attestation = [ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-post-install-v1'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    status = 'passed'
                    installedInventory = $inventory
                    postInstallIntegrity = $true
                    issuedAt = $issuedAt
                    signature = $null
                }
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = $EvidenceType
                    candidateId = $CandidateId
                    status = 'passed'
                    installedInventory = $inventory
                    postInstallIntegrity = $true
                    attestation = $attestation
                }
            }
            $receiptType = "$EvidenceType-v1"
            $payload = Get-TestLifecycleAttestationPayload -ReceiptType $receiptType -Fields $fields
            $evidence.attestation.signature = [Convert]::ToBase64String($Rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 20)
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
        Assert-Equal $contract.consent.publishInstall 'candidate-bound-trusted-supervisor-signed-lifecycle-attestation' 'Publish/install lifecycle evidence must require a trusted attestation.'
        Assert-Match ([string]$contract.stages[8].barrier) 'trusted-supervisor-signed' 'Publish/install stage must require trusted signed evidence.'
        Assert-Match ([string]$contract.stages[9].barrier) 'trusted-supervisor-signed' 'Post-install stage must require trusted signed evidence.'
        $adapterSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-adapter-v1.schema.json') | ConvertFrom-Json
        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') | ConvertFrom-Json
        Assert-True (@($adapterSchema.required) -contains 'canonicalValidatorPath') 'The adapter schema must require the canonical validator path.'
        Assert-True (@($evidenceSchema.'$defs'.adapter.required) -contains 'canonicalValidatorPath') 'The evidence schema must require the canonical validator path in adapter evidence.'
        Assert-True (@($evidenceSchema.allOf).Count -ge 6) 'The evidence schema must bind every terminal state to its exit code and release eligibility.'
        $evidenceSchemaText = $evidenceSchema | ConvertTo-Json -Depth 20 -Compress
        Assert-Match $evidenceSchemaText '"if".*"state".*"then".*"exitCode"' 'The evidence schema must express conditional terminal state/exit-code relationships.'
        Assert-Match $evidenceSchemaText '"releaseEligible".*"const":false|"releaseEligible".*"const":true' 'The evidence schema must express release eligibility constraints.'
        $runnerSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RunnerPath
        Assert-False ($runnerSource -match '\[string\]\s+\$TrustedToolRoot\s*=\s*\(Split-Path\s+-Parent\s+\$PSScriptRoot\)') 'The runner must not evaluate PSScriptRoot in a parameter default before script initialization.'
        Assert-Match $runnerSource 'if\s*\(\[string\]::IsNullOrWhiteSpace\(\$TrustedToolRoot\)\)' 'The runner must derive its default trusted tool root after parameter binding.'
        Assert-Match $runnerSource 'Assert-AuthorityConsumerEntryPointContract' 'The runner must enforce the central consumer entry-point contract.'
        Assert-Match $runnerSource 'Assert-StandardValidationSnapshotUnchanged' 'The runner must revalidate the candidate snapshot around child execution.'
        Assert-Match $runnerSource 'Assert-StandardValidationHumanApprovalEvidence' 'Human approval must be authenticated by the runner.'
        Assert-Match $runnerSource 'Assert-StandardValidationLifecycleEvidence' 'Publish/install and post-install evidence must be authenticated by the runner.'
        Assert-Match $runnerSource 'CandidateArchivePath|CandidateAcquisitionEvidencePath' 'Production acquisition must bind the candidate to an acquired immutable archive.'
        Assert-Match $runnerSource 'AuthorityRevision|AuthorityArchivePath|AuthoritySnapshotEvidencePath' 'Authority evidence must bind to an immutable authority snapshot.'
        Assert-Match $runnerSource 'Assert-StandardValidationCandidateAcquisition|Assert-StandardValidationAuthoritySnapshot' 'The runner must verify source and authority acquisition bindings before validation.'
        Assert-Match $runnerSource 'Get-StandardValidationDescendantProcessIds|Kill\(\$true\)' 'Child cleanup must account for the complete owned process tree.'
    }

    # Scenario: A production adapter attempts to execute a payload through a generic interpreter.
    # Purpose: Prevent an untrusted -File/-c payload from becoming a pre-Static trusted command.
    It 'InterT05_rejects_generic_interpreter_payloads_in_production_adapters' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'production-interpreter')
        $adapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.Adapter | ConvertFrom-Json
        $adapter.mode = 'production'
        Write-TestUtf8File -Path $fixture.Adapter -Text ($adapter | ConvertTo-Json -Depth 20)
        $result = Invoke-RunnerFixture -Fixture $fixture -DevelopmentHarness:$false
        Assert-Equal $result.Evidence.state 'INVALID' 'Production adapters must reject incomplete or unsafe acquisition before execution.'
        Assert-Match $result.Output 'generic interpreter|direct executable|Production validation requires' 'The invalid result must explain the production boundary.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'A rejected interpreter payload must not execute package validation.'
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

    # Scenario: A package validator writes into the candidate snapshot exposed to child processes.
    # Purpose: Detect snapshot drift after every child and fail before the next barrier can consume it.
    It 'InterT25_fails_closed_when_a_child_mutates_the_candidate_snapshot' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'snapshot-mutate') -Behavior 'snapshot-mutate'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'FAILED' 'A child-mutated candidate snapshot must fail validation.'
        Assert-Match $result.Output 'snapshot.*changed|snapshot.*drift' 'The failure must identify candidate snapshot drift.'
        Assert-False (@($result.Evidence.stages | Where-Object id -eq 'skillspector-static' | Select-Object -ExpandProperty status) -contains 'passed') 'Snapshot drift must not reach Static.'
        Assert-False (Test-Path -LiteralPath $fixture.Sentinel -PathType Leaf) 'Snapshot drift must not dispatch repository tests.'
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

    # Scenario: A candidate adds a workflow that invokes an alternate validation script.
    # Purpose: Ensure the runner applies the central consumer entry-point inventory before package validation.
    It 'InterT75_blocks_alternate_consumer_entry_points_before_package_validation' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'alternate-entry-point')
        Write-TestUtf8File -Path (Join-Path $fixture.Candidate '.github/workflows/alternate-validation.yml') -Text @'
name: Alternate validation
on:
  pull_request:
jobs:
  alternate:
    steps:
      - run: ./scripts/alternate-validation.ps1
'@
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'BLOCKED' 'An alternate consumer validation entry point must block the run.'
        Assert-Match $result.Output 'entry-point|canonical' 'The failure must identify the canonical entry-point contract.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'Entry-point contract failure must occur before package validation.'
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

        $forgedFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'forged-human-approval')
        $forgedAdapterSha = Get-StandardValidationFileSha256 -Path $forgedFixture.Adapter -Context 'test adapter'
        $forgedInventory = Get-StandardValidationInventory -Root $forgedFixture.Candidate -Context 'test candidate'
        $forgedContentSha = Get-StandardValidationInventorySha256 -Inventory $forgedInventory
        $forgedCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$forgedContentSha`n$forgedAdapterSha`n")
        $forgedAiEvidence = Join-Path $forgedFixture.Root 'ai-review.json'
        $forgedHumanEvidence = Join-Path $forgedFixture.Root 'human-approval.json'
        Write-TestUtf8File -Path $forgedAiEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'ai-review'; candidateId = $forgedCandidateId; status = 'passed'; decision = 'PASS'; reviewFindings = @(); findingDisposition = @() } | ConvertTo-Json -Depth 10)
        Write-TestUtf8File -Path $forgedHumanEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'human-approval'; candidateId = $forgedCandidateId; status = 'approved'; approver = 'human@example.test'; approvalTimestamp = '2026-09-11T00:00:00Z' } | ConvertTo-Json -Depth 10)
        $forgedResult = Invoke-RunnerFixture -Fixture $forgedFixture -CompleteLifecycle -AiReviewEvidencePath $forgedAiEvidence -HumanApprovalEvidencePath $forgedHumanEvidence
        Assert-Equal $forgedResult.Evidence.state 'BLOCKED' 'Self-asserted human approval fields must not satisfy the approval barrier.'
        Assert-Match $forgedResult.Output 'attestation|trusted|signature' 'The failure must identify the missing trusted approval attestation.'
        Assert-Equal (@($forgedResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'Unattested human approval must block the lifecycle.'

        $tamperedFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'tampered-human-approval')
        $tamperedAdapterSha = Get-StandardValidationFileSha256 -Path $tamperedFixture.Adapter -Context 'test adapter'
        $tamperedInventory = Get-StandardValidationInventory -Root $tamperedFixture.Candidate -Context 'test candidate'
        $tamperedContentSha = Get-StandardValidationInventorySha256 -Inventory $tamperedInventory
        $tamperedCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$tamperedContentSha`n$tamperedAdapterSha`n")
        $tamperedAiEvidence = Join-Path $tamperedFixture.Root 'ai-review.json'
        $tamperedHumanEvidence = Join-Path $tamperedFixture.Root 'human-approval.json'
        Write-TestUtf8File -Path $tamperedAiEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'ai-review'; candidateId = $tamperedCandidateId; status = 'passed'; decision = 'PASS'; reviewFindings = @(); findingDisposition = @() } | ConvertTo-Json -Depth 10)
        Write-TestHumanApprovalEvidence -Fixture $tamperedFixture -Path $tamperedHumanEvidence -CandidateId $tamperedCandidateId
        $tamperedText = Get-Content -Raw -Encoding UTF8 -LiteralPath $tamperedHumanEvidence
        $tamperedText = $tamperedText -replace '("signature"\s*:\s*")[^"]+("\s*})', '$1AAAA$2'
        Write-TestUtf8File -Path $tamperedHumanEvidence -Text $tamperedText
        $tamperedResult = Invoke-RunnerFixture -Fixture $tamperedFixture -CompleteLifecycle -AiReviewEvidencePath $tamperedAiEvidence -HumanApprovalEvidencePath $tamperedHumanEvidence
        Assert-Equal $tamperedResult.Evidence.state 'BLOCKED' 'A tampered human approval signature must not pass the approval barrier.'
        Assert-Match $tamperedResult.Output 'signature verification failed' 'The failure must identify signature verification failure.'
        Assert-Equal (@($tamperedResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'A tampered approval signature must block the lifecycle.'

        $forgedLifecycleFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'forged-lifecycle-evidence')
        $forgedLifecycleAdapterSha = Get-StandardValidationFileSha256 -Path $forgedLifecycleFixture.Adapter -Context 'test adapter'
        $forgedLifecycleInventory = Get-StandardValidationInventory -Root $forgedLifecycleFixture.Candidate -Context 'test candidate'
        $forgedLifecycleContentSha = Get-StandardValidationInventorySha256 -Inventory $forgedLifecycleInventory
        $forgedLifecycleCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$forgedLifecycleContentSha`n$forgedLifecycleAdapterSha`n")
        $forgedLifecycleAiEvidence = Join-Path $forgedLifecycleFixture.Root 'ai-review.json'
        $forgedLifecycleHumanEvidence = Join-Path $forgedLifecycleFixture.Root 'human-approval.json'
        $forgedLifecyclePublishEvidence = Join-Path $forgedLifecycleFixture.Root 'publish-install.json'
        Write-TestUtf8File -Path $forgedLifecycleAiEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'ai-review'; candidateId = $forgedLifecycleCandidateId; status = 'passed'; decision = 'PASS'; reviewFindings = @(); findingDisposition = @() } | ConvertTo-Json -Depth 10)
        Write-TestHumanApprovalEvidence -Fixture $forgedLifecycleFixture -Path $forgedLifecycleHumanEvidence -CandidateId $forgedLifecycleCandidateId
        Write-TestUtf8File -Path $forgedLifecyclePublishEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'publish-install'; candidateId = $forgedLifecycleCandidateId; status = 'authorized'; authorization = $true; releaseIdentity = 'release-example' } | ConvertTo-Json -Depth 10)
        $forgedLifecycleResult = Invoke-RunnerFixture -Fixture $forgedLifecycleFixture -CompleteLifecycle -AiReviewEvidencePath $forgedLifecycleAiEvidence -HumanApprovalEvidencePath $forgedLifecycleHumanEvidence -PublishInstallEvidencePath $forgedLifecyclePublishEvidence
        Assert-Equal $forgedLifecycleResult.Evidence.state 'BLOCKED' 'Self-asserted publish/install fields must not satisfy the lifecycle barrier.'
        Assert-Match $forgedLifecycleResult.Output 'attestation|trusted|signature' 'The failure must identify the missing trusted lifecycle attestation.'
        Assert-Equal (@($forgedLifecycleResult.Evidence.stages | Where-Object id -eq 'publish-or-install')[0].status) 'blocked' 'Unattested publish/install evidence must block the lifecycle.'

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
        Write-TestHumanApprovalEvidence -Fixture $fullFixture -Path $fullHumanEvidence -CandidateId $fullCandidateId
        $lifecycleRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            Write-TestUtf8File -Path (Join-Path $fullFixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $lifecycleRsa.ToXmlString($false)
            Write-TestLifecycleEvidence -Path $fullPublishEvidence -EvidenceType 'publish-install' -CandidateId $fullCandidateId -Rsa $lifecycleRsa
            Write-TestLifecycleEvidence -Path $fullPostEvidence -EvidenceType 'post-install' -CandidateId $fullCandidateId -Rsa $lifecycleRsa
        }
        finally { $lifecycleRsa.Dispose() }
        $fullResult = Invoke-RunnerFixture -Fixture $fullFixture -CompleteLifecycle -AiReviewEvidencePath $fullAiEvidence -HumanApprovalEvidencePath $fullHumanEvidence -PublishInstallEvidencePath $fullPublishEvidence -PostInstallEvidencePath $fullPostEvidence
        Assert-Equal $fullResult.Evidence.state 'PASS' 'Complete lifecycle evidence should pass the development behavior fixture.'
        Assert-False ([bool]$fullResult.Evidence.releaseEligible) 'Development harness evidence must never be release-eligible.'
        foreach ($stageId in @('ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Equal (@($fullResult.Evidence.stages | Where-Object id -eq $stageId)[0].status) 'passed' "Lifecycle stage '$stageId' must be independently recorded."
        }
    }
}
