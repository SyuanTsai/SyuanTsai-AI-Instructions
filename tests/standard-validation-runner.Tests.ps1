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
                [ValidateSet('pass', 'static-fail', 'static-partial', 'package-fail', 'wrong-candidate', 'missing-output', 'timeout', 'snapshot-mutate', 'environment-leak', 'semantic-required', 'output-tamper', 'output-flood', 'output-near-quota', 'repository-missing-evidence', 'repository-zero-tests', 'repository-artifact-tamper')]
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
$fixtureBehavior = '__FIXTURE_BEHAVIOR__'
$logPath = '__FIXTURE_LOG_PATH__'
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
if ($fixtureBehavior -eq 'package-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'environment-leak' -and (
    -not [string]::IsNullOrWhiteSpace($env:SYP154_INHERITED_SECRET) -or
    -not [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_INHERITED_SECRET)
)) {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'output-tamper' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    try {
        [IO.File]::WriteAllText($env:STANDARD_VALIDATION_OUTPUT_PATH, '{"attacker":true}', (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        $result.status = 'failed'
        $result.decision = 'BLOCK'
    }
}
if ($fixtureBehavior -eq 'wrong-candidate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.candidateIdentity = ('0' * 64)
}
if ($fixtureBehavior -eq 'missing-output' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    exit 0
}
if ($fixtureBehavior -eq 'timeout' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    Start-Sleep -Seconds 10
}
if ($fixtureBehavior -eq 'output-flood' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    [Console]::Out.Write(('o' * 1100000))
    [Console]::Error.Write(('e' * 1100000))
}
if ($fixtureBehavior -eq 'output-near-quota' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.output = 'v' * 1045000
}
if ($fixtureBehavior -eq 'static-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'static-partial' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'partial'
    $result.decision = 'BLOCK'
    $result.analyzerCompleteness = 'partial'
    $result.activeSkills = @($skills | Select-Object -First 1)
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.scannerIdentity = 'development-fixture-static-analyzer'
    if ($fixtureBehavior -eq 'semantic-required') {
        $result.semanticRequired = $true
    }
    if ($fixtureBehavior -ne 'static-partial') {
        $result.analyzerCompleteness = 'complete'
    }
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'repository-tests') {
    [IO.File]::WriteAllText('__FIXTURE_SENTINEL_PATH__', 'repository-test-ran', (New-Object Text.UTF8Encoding($false)))
    $result.testInventory = @('fixture-repository-test')
    $result.testResult = [ordered]@{ status = 'passed'; decision = 'PASS' }
    $result.domainAdapterResult = [ordered]@{ status = 'passed'; decision = 'PASS' }
    if ($fixtureBehavior -eq 'repository-artifact-tamper') {
        $artifactRoot = Split-Path -Parent $env:STANDARD_VALIDATION_OUTPUT_PATH
        $receipt = @(Get-ChildItem -LiteralPath (Join-Path $artifactRoot 'runs') -Filter 'receipt.json' -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.FullName -match '[\\/]+controlled-acquisition[\\/]receipt\.json$' } |
                Select-Object -First 1)[0]
        if ($null -ne $receipt) { [IO.File]::Delete($receipt.FullName) }
    }
    if ($fixtureBehavior -eq 'repository-missing-evidence') {
        $result.Remove('testInventory')
    }
    if ($fixtureBehavior -eq 'repository-zero-tests') {
        $result.testInventory = @()
    }
}
if ($fixtureBehavior -eq 'snapshot-mutate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $targetSkill = @($skills | Select-Object -First 1)[0]
    Add-Content -LiteralPath (Join-Path $env:STANDARD_VALIDATION_CANDIDATE_ROOT ("skills/$targetSkill/SKILL.md")) -Value 'mutated-by-package-fixture' -Encoding UTF8
}
$result | ConvertTo-Json -Depth 10 -Compress
'@
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_BEHAVIOR__', $Behavior.Replace("'", "''"))
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_LOG_PATH__', $log.Replace("'", "''"))
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_SENTINEL_PATH__', $sentinel.Replace("'", "''"))
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
                [string] $SemanticProvider,
                [string] $SemanticPurpose,
                [string] $SemanticScope,
                [string] $SemanticEvidencePath,
                [switch] $CompleteLifecycle,
                [bool] $DevelopmentHarness = $true,
                [string] $AiReviewEvidencePath,
                [string] $HumanApprovalEvidencePath,
                [string] $PublishInstallEvidencePath,
                [string] $PostInstallEvidencePath,
                [string] $CancellationPath,
                [string] $ValidationRunId,
                [string] $SourceRepository = 'https://example.com/example/skills.git',
                # Hosted Windows PowerShell 5.1 can spend more than twenty
                # seconds creating the centrally owned child-process boundary;
                # keep the fixture default aligned with the production ceiling,
                # while timeout-specific scenarios pass an explicit one-second limit.
                [int] $TimeoutSeconds = 300
            )

            $arguments = @(
                '-NoProfile', '-File', $script:RunnerPath,
                '-CandidateRoot', $Fixture.Candidate,
                '-AdapterPath', $Fixture.Adapter,
                '-ArtifactsRoot', $Fixture.Artifacts,
                '-OutputPath', $Fixture.Output,
                '-SourceRepository', $SourceRepository,
                '-SourceRevision', ('a' * 40),
                '-BaseRevision', ('b' * 40),
                '-EventName', 'local',
                '-TimeoutSeconds', [string]$TimeoutSeconds,
                '-TrustedToolRoot', $Fixture.TrustedTools
            )
            if ($DevelopmentHarness) { $arguments += '-DevelopmentHarness' }
            if ($SemanticTriggered) { $arguments += '-SemanticTriggered' }
            if ($SemanticConsent) { $arguments += '-SemanticConsent' }
            if (-not [string]::IsNullOrWhiteSpace($SemanticProvider)) { $arguments += @('-SemanticProvider', $SemanticProvider) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticPurpose)) { $arguments += @('-SemanticPurpose', $SemanticPurpose) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticScope)) { $arguments += @('-SemanticScope', $SemanticScope) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticEvidencePath)) { $arguments += @('-SemanticEvidencePath', $SemanticEvidencePath) }
            if ($CompleteLifecycle) { $arguments += '-CompleteLifecycle' }
            if (-not [string]::IsNullOrWhiteSpace($AiReviewEvidencePath)) { $arguments += @('-AiReviewEvidencePath', $AiReviewEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($HumanApprovalEvidencePath)) { $arguments += @('-HumanApprovalEvidencePath', $HumanApprovalEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PublishInstallEvidencePath)) { $arguments += @('-PublishInstallEvidencePath', $PublishInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PostInstallEvidencePath)) { $arguments += @('-PostInstallEvidencePath', $PostInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
                $arguments += @('-CancellationPath', $CancellationPath)
            }
            if (-not [string]::IsNullOrWhiteSpace($ValidationRunId)) {
                $arguments += @('-RunId', $ValidationRunId)
            }

            $fixtureEnvironment = [ordered]@{
                STANDARD_VALIDATION_INHERITED_SECRET = 'fixture-reserved-prefix-secret-must-not-cross-the-child-boundary'
                SYP154_INHERITED_SECRET = 'fixture-secret-must-not-cross-the-child-boundary'
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

        function Get-TestTextSha256 {
            param([Parameter(Mandatory = $true)][string] $Value)

            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                return ([System.BitConverter]::ToString(
                    $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Value))
                ) -replace '-', '').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
        }

        function Write-TestAiReviewEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [object[]] $ReviewFindings = @(),
                [object[]] $FindingDisposition = @(),
                [System.Security.Cryptography.RSACryptoServiceProvider] $Rsa
            )
            $ownsRsa = $null -eq $Rsa
            $signingRsa = if ($ownsRsa) { New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048) } else { $Rsa }
            try {
                Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $signingRsa.ToXmlString($false)
                $findings = @($ReviewFindings)
                $dispositions = @($FindingDisposition)
                $findingsJson = if ($findings.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([object[]]$findings) -Compress -Depth 50 }
                $dispositionsJson = if ($dispositions.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([object[]]$dispositions) -Compress -Depth 50 }
                $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
                $fields = @{
                    candidateId = $CandidateId
                    decision = 'PASS'
                    evidenceType = 'ai-review'
                    findingDispositionSha256 = Get-TestTextSha256 -Value $dispositionsJson
                    issuedAt = $issuedAt
                    reviewedCandidate = $CandidateId
                    reviewFindingsSha256 = Get-TestTextSha256 -Value $findingsJson
                    status = 'passed'
                }
                $attestation = [pscustomobject][ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-ai-review-v1'
                    candidateId = $CandidateId
                    evidenceType = 'ai-review'
                    status = 'passed'
                    decision = 'PASS'
                    reviewedCandidate = $CandidateId
                    reviewFindingsSha256 = $fields.reviewFindingsSha256
                    findingDispositionSha256 = $fields.findingDispositionSha256
                    issuedAt = $issuedAt
                    signature = $null
                }
                $payload = Get-TestLifecycleAttestationPayload -ReceiptType 'ai-review-v1' -Fields $fields
                $attestation.signature = [Convert]::ToBase64String($signingRsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = 'ai-review'
                    candidateId = $CandidateId
                    status = 'passed'
                    decision = 'PASS'
                    reviewedCandidate = $CandidateId
                    reviewFindings = $findings
                    findingDisposition = $dispositions
                    reviewFindingsSha256 = $fields.reviewFindingsSha256
                    findingDispositionSha256 = $fields.findingDispositionSha256
                    attestation = $attestation
                }
                Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 50)
            }
            finally {
                if ($ownsRsa) { $signingRsa.Dispose() }
            }
        }

        function Write-TestSemanticEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][System.Security.Cryptography.RSACryptoServiceProvider] $Rsa
            )

            Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $Rsa.ToXmlString($false)
            $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            $provider = 'fixture-semantic-provider'
            $purpose = 'fixture semantic regression'
            $scope = 'candidate'
            $findingsSha256 = Get-TestTextSha256 -Value '[]'
            $fields = @{
                analyzerCompleteness = 'complete'
                analyzerIdentity = 'fixture-semantic-analyzer'
                candidateId = $CandidateId
                consentGranted = 'True'
                decision = 'PASS'
                evidenceType = 'semantic'
                findingsSha256 = $findingsSha256
                issuedAt = $issuedAt
                provider = $provider
                purpose = $purpose
                scope = $scope
                status = 'passed'
            }
            $attestation = [ordered]@{
                schemaVersion = 1
                attestationType = 'trusted-supervisor-semantic-v1'
                candidateId = $CandidateId
                evidenceType = 'semantic'
                status = 'passed'
                decision = 'PASS'
                provider = $provider
                purpose = $purpose
                scope = $scope
                consentGranted = $true
                analyzerIdentity = 'fixture-semantic-analyzer'
                analyzerCompleteness = 'complete'
                findingsSha256 = $findingsSha256
                issuedAt = $issuedAt
                signature = $null
            }
            $payload = Get-TestLifecycleAttestationPayload -ReceiptType 'semantic-v1' -Fields $fields
            $attestation.signature = [Convert]::ToBase64String($Rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            $evidence = [ordered]@{
                schemaVersion = 1
                evidenceType = 'semantic'
                candidateId = $CandidateId
                status = 'passed'
                decision = 'PASS'
                provider = $provider
                purpose = $purpose
                scope = $scope
                consentGranted = $true
                analyzerIdentity = 'fixture-semantic-analyzer'
                analyzerCompleteness = 'complete'
                findings = @()
                findingsSha256 = $findingsSha256
                attestation = $attestation
            }
            Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 50)
        }

        function Write-TestLifecycleEvidence {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][ValidateSet('publish-install', 'post-install')][string] $EvidenceType,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][System.Security.Cryptography.RSACryptoServiceProvider] $Rsa,
                [string[]] $InstalledInventory = @('skill-alpha', 'skill-beta')
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
                $inventory = @($InstalledInventory)
                $inventoryText = ConvertTo-Json -InputObject ([array]$inventory) -Compress
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
        Assert-Match ([string]$contract.execution.productionCommandPolicy) 'signed-resolver-receipt' 'Production commands must carry a trusted signed resolver receipt.'
        Assert-Match ([string]$contract.cli.launchBinding) 'SupervisorLaunchBindingPath' 'Production CLI must expose the trusted supervisor launch binding input.'
        Assert-True ([bool]$contract.execution.productionLaunchBinding.required) 'Production validation must require an authenticated launch binding.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.attestation) 'trusted-supervisor-validation-launch-v1' 'Launch binding attestation identity must be canonical.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.handoffRunIdFormat) 'lowercase-32-character-hexadecimal-N' 'The launch-binding handoff run-ID format must remain canonical.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.evidenceRunIdFormat) 'canonical-hyphenated-UUID-D' 'Evidence must declare the schema-compatible run-ID serialization.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.bindingSnapshot) 'reads.*hashes.*parses.*launch-binding.*snapshot.*evidence registration' 'The production launch-binding contract must retain the authenticated binding snapshot hash.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.adapterSnapshot) 'reads adapter bytes once.*parses those same bytes.*fails closed' 'The production launch-binding contract must bind authentication to one parsed adapter-byte snapshot.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.receiptSnapshot) 'reads.*hashes.*parses.*resolver receipt.*snapshot' 'The production launch-binding contract must bind resolver receipt fields and provenance to one parsed receipt snapshot.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.oneTimeConsumption) 'consumptionPath.*outside.*roots.*atomically.*marker.*existing marker.*replay' 'The production launch-binding contract must require authenticated one-time consumption outside caller-controlled roots.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'launchBinding.status=verified') 'Evidence required bindings must include verified launch-binding status.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'launchBinding.verified=true') 'Evidence required bindings must include the verified launch-binding boolean.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.packageAdapter) 'package-adapter' 'The package adapter slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.skillValidator) 'skill-validator' 'The skill-validator slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.skillTools) 'skill-tools' 'The skill-tools slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.staticAnalyzer) 'skillspector' 'The static analyzer slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.repositoryTests) 'pester' 'The repository-test slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.inventoryEncoding.line) '<path>\t<raw-file-sha256>\n' 'Canonical inventory hashing must exclude file length and use raw-file hashes.'
        Assert-Match ([string]$contract.execution.installedClosure) 'in-root-unix-symlink-target-identities' 'Installed tool closure must bind approved in-root Unix symlink targets.'
        Assert-Match (($contract.evidence.semanticEvidence.required -join ';') ) 'findingsSha256' 'Semantic evidence must include a complete findings digest.'
        $releaseConditions = ($contract.evidence.releaseEligibility.trueOnlyWhen -join ';')
        Assert-Match $releaseConditions 'stages\[1\.\.5\]\.status=passed' 'Release eligibility must bind the first five canonical stages.'
        Assert-Match $releaseConditions 'launchBinding\.status=verified' 'Release eligibility must bind verified launch-binding status.'
        Assert-Match $releaseConditions 'launchBinding\.verified=true' 'Release eligibility must bind the verified launch-binding boolean.'
        foreach ($stageId in @('conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Match $releaseConditions ("stages\[[0-9]+\]\.id=$stageId-and-status=") "Release eligibility must bind the '$stageId' canonical stage."
        }
        Assert-Equal $contract.consent.publishInstall 'candidate-bound-trusted-supervisor-signed-lifecycle-attestation' 'Publish/install lifecycle evidence must require a trusted attestation.'
        Assert-Match ([string]$contract.stages[8].barrier) 'trusted-supervisor-signed' 'Publish/install stage must require trusted signed evidence.'
        Assert-Match ([string]$contract.stages[9].barrier) 'trusted-supervisor-signed' 'Post-install stage must require trusted signed evidence.'
        Assert-Equal ([int]$contract.execution.childOutputCapture.perStreamCharacterQuota) 1048576 'Child output capture must expose a fixed per-stream character quota.'
        Assert-Match ([string]$contract.execution.childOutputCapture.onExceeded) 'terminate.*fail' 'Child output quota overflow must terminate the owned process and fail closed.'
        Assert-Match ([string]$contract.execution.childOutputCapture.diagnostic) 'separately' 'Child output quota diagnostics must be recorded separately from bounded stream prefixes.'
        $adapterSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-adapter-v1.schema.json') | ConvertFrom-Json
        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') | ConvertFrom-Json
        Assert-True (@($adapterSchema.required) -contains 'canonicalValidatorPath') 'The adapter schema must require the canonical validator path.'
        Assert-True (@($evidenceSchema.'$defs'.adapter.required) -contains 'canonicalValidatorPath') 'The evidence schema must require the canonical validator path in adapter evidence.'
        Assert-True (@($evidenceSchema.'$defs'.launchBinding.properties.status.enum) -contains 'unverified-production') 'The evidence schema must distinguish rejected production launch bindings from development harness runs.'
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
        Assert-Match $runnerSource 'Assert-StandardValidationCandidateAcquisitionArtifactsUnchanged' 'Every child invocation must revalidate the acquired candidate archive and receipt hashes.'
        Assert-Match $runnerSource 'Get-StandardValidationDescendantProcessIds|Kill\(\$true\)' 'Child cleanup must account for the complete owned process tree.'
        Assert-Match $runnerSource 'unshare|--pid|--fork|--kill-child' 'Unix child execution must use a kernel-enforced PID namespace boundary.'
        Assert-Match $runnerSource 'Get-StandardValidationUnixPidNamespaceProcessIds|PidNamespaceRequired' 'Unix cleanup must verify the owned PID namespace is empty before passing an event.'
        Assert-Match $runnerSource 'PR_SET_CHILD_SUBREAPER|SetChildSubreaper|SubreaperRequired' 'Restricted Unix hosts must use a kernel-enforced subreaper boundary and verify its descendants.'
        Assert-Match $runnerSource 'EnvironmentVariables\.Clear\(\)' 'Child processes must not inherit the supervisor environment wholesale.'
        Assert-Match $runnerSource 'New-StandardValidationOutputReservation' 'The runner must reserve the final evidence path.'
        Assert-Match $runnerSource 'Consume-StandardValidationSupervisorLaunchBinding' 'The runner must consume each authenticated launch binding once before production work.'
        Assert-Match $runnerSource 'Get-StandardValidationSemanticRequirement' 'Semantic trigger decisions must include typed analyzer requirements.'
        Assert-Match $runnerSource 'Assert-StandardValidationAiReviewEvidence' 'AI review evidence must use the central typed review policy.'
        Assert-Match $runnerSource 'Assert-StandardValidationToolReceipt' 'Production command provenance must use a signed resolver receipt.'
        Assert-Match $runnerSource 'ExpectedToolName' 'Production command provenance must bind to the expected adapter-slot tool role.'
        Assert-Match $runnerSource 'Get-StandardValidationExpectedToolName' 'Every adapter slot must resolve through the central canonical tool-role map.'
        Assert-Match $runnerSource 'Assert-StandardValidationCanonicalRootPath' 'Root containment checks must use canonical existing filesystem components.'
        Assert-Match $runnerSource 'Get-StandardValidationPathCaseBehavior|Get-StandardValidationPathComparison' 'Path containment checks must detect filesystem case behavior rather than infer it from the operating-system enum.'
        Assert-Match $runnerSource 'ChildWorkingRoot|childWorkingDirectory' 'Candidate-controlled children must run outside the supervisor evidence directory.'
        Assert-Match $runnerSource 'Assert-StandardValidationEvidenceArtifacts' 'Previously written evidence artifacts must be revalidated before finalization.'
        Assert-Match $runnerSource 'symlinked or reparse-point ancestor' 'Symlinked root ancestors must fail closed before artifact creation.'
        Assert-Match $runnerSource 'Assert-StandardValidationLauncherFileIdentity' 'Production package launchers must revalidate safe Unix launcher symlinks through the central helper.'
        Assert-Match $runnerSource 'Get-StandardValidationSafeUnixSymlinkEntry' 'Production installed closures must validate Unix symlink targets centrally.'
        Assert-Match $runnerSource 'Assert-StandardValidationRepositoryTestEnvelope|typed, non-empty testInventory' 'Repository Tests must require typed, non-empty coverage evidence before passing.'
        Assert-Match $runnerSource 'Assert-StandardValidationSemanticEvidence' 'Semantic evidence must be authenticated and complete.'
        Assert-Match $runnerSource 'semanticEvidence = \$null' 'Every stage must expose a writable semantic evidence slot.'
        Assert-False ($runnerSource -match 'return\s+,\$(?:Evidence|evidence)') 'Imported evidence helpers must return objects rather than unary-comma arrays.'
        Assert-Match $runnerSource 'Assert-StandardValidationFreshTimestamp' 'Resolver receipts and trusted review attestations must be fresh for the current run.'
        Assert-Match $runnerSource 'installedClosureSha256' 'Production tool execution must bind the complete installed dependency closure.'
        Assert-Match $runnerSource 'launcherDigestSha256' 'Production tool execution must bind the resolver launcher identity.'
        Assert-Match $runnerSource 'Production validation run IDs are generated by the trusted supervisor' 'Production validation must not accept a caller-selected run ID for receipt replay.'
        Assert-Match $runnerSource 'Assert-StandardValidationSupervisorLaunchBinding' 'Production validation must authenticate a supervisor launch binding before resolver receipt validation.'
        Assert-Match $runnerSource 'Get-StandardValidationJsonSnapshot|adapterSnapshotSha256' 'Production validation must parse the adapter from a retained byte snapshot.'
        Assert-Match $runnerSource 'bindingSnapshot|ExpectedSha256' 'Production validation must retain and register the authenticated launch-binding snapshot hash.'
        Assert-Match $runnerSource 'receiptSnapshot|actualReceiptSha256' 'Production validation must authenticate resolver receipt provenance and fields from one byte snapshot.'
        Assert-Match $runnerSource 'Adapter changed during the trusted supervisor launch handoff' 'Production validation must fail closed on adapter substitution during launch handoff.'
        Assert-Match $runnerSource 'SupervisorLaunchBindingPath' 'Production validation must receive the signed supervisor launch binding path.'
        Assert-Match $runnerSource 'ExpectedRunId' 'Production resolver receipt validation must use the current supervisor launch binding.'
        Assert-Match $runnerSource '-RunId \$ExpectedRunId' 'Production package-adapter receipt validation must reject a receipt from another run.'
        Assert-Match $runnerSource 'outputQuotaDiagnostic' 'Output quota diagnostics must be retained outside bounded stream content.'
        Assert-False ($runnerSource -match '\$stderr\s*=\s*"\$stderr`n\$quotaMessage"') 'Output quota diagnostics must not be appended beyond the stderr quota.'
        Assert-Match $runnerSource 'StandardValidationBoundedCapture' 'Child output capture must use the bounded supervisor-owned reader.'
        Assert-False ($runnerSource -match 'ReadToEndAsync') 'The runner must not retain unbounded child stdout/stderr with ReadToEndAsync.'
        $productionRunIdIndex = $runnerSource.IndexOf('$runId = Get-StandardValidationProductionRunId', [StringComparison]::Ordinal)
        $adapterValidationIndex = $runnerSource.IndexOf('$adapterResult = Assert-StandardValidationAdapter', [StringComparison]::Ordinal)
        Assert-True ($productionRunIdIndex -ge 0 -and $adapterValidationIndex -ge 0 -and $productionRunIdIndex -lt $adapterValidationIndex) 'Production run ID derivation must precede full adapter validation.'
        Assert-False ($runnerSource -match 'LD_LIBRARY_PATH') 'Dynamic loader overrides must not be inherited by child processes.'
        $reservationIndex = $runnerSource.IndexOf('$outputReservation = New-StandardValidationOutputReservation', [StringComparison]::Ordinal)
        $contractResolverIndex = $runnerSource.IndexOf('$contractResult = Assert-StandardValidationContractFiles', [StringComparison]::Ordinal)
        Assert-True ($reservationIndex -ge 0 -and $contractResolverIndex -ge 0 -and $reservationIndex -lt $contractResolverIndex) 'Final output reservation must precede authority contract resolver child processes.'
        $launchBindingIndex = $runnerSource.IndexOf('$launchBinding = Assert-StandardValidationSupervisorLaunchBinding', [StringComparison]::Ordinal)
        $productionReceiptIndex = $runnerSource.IndexOf('$runId = Get-StandardValidationProductionRunId', [StringComparison]::Ordinal)
        Assert-True ($launchBindingIndex -ge 0 -and $productionReceiptIndex -ge 0 -and $launchBindingIndex -lt $productionReceiptIndex) 'The authenticated launch binding must precede package-adapter receipt validation.'
    }

    # Scenario: Supervisor setup, Process.Start, or cleanup fails before or after child output capture begins.
    # Purpose: Preserve the original failure and close supervisor-owned resources without trusting an unstarted process object.
    It 'UnitT04_preserves_supervisor_diagnostics_and_prestart_cleanup' {
        . $script:RunnerPath `
            -CandidateRoot (Join-Path $TestDrive 'stderr-preservation-candidate') `
            -AdapterPath (Join-Path $TestDrive 'stderr-preservation-adapter.json') `
            -ArtifactsRoot (Join-Path $TestDrive 'stderr-preservation-artifacts') `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $firstError = 'Could not assign the validator to the owned Windows job object: AssignProcessToJobObject returned false.'
        Assert-Equal (Merge-StandardValidationProcessStderr -Existing $firstError -Captured '' -Quota 200) $firstError 'An empty child stderr stream must not erase the first supervisor diagnostic.'
        $merged = Merge-StandardValidationProcessStderr -Existing $firstError -Captured 'child stderr detail' -Quota 200
        Assert-Match $merged '(?s)Could not assign the validator.*child stderr detail' 'A non-empty child stderr stream must be appended after the first supervisor diagnostic.'
        Assert-True ($merged.Length -le 200) 'Merged supervisor and child stderr must remain within the process evidence quota.'
        Assert-Equal (Merge-StandardValidationProcessStderr -Existing '' -Captured 'child-only stderr' -Quota 200) 'child-only stderr' 'A child stderr stream must remain available when no supervisor diagnostic exists.'
        $nearQuota = Merge-StandardValidationProcessStderr -Existing 'first supervisor error' -Captured ('x' * 400) -Quota 64
        Assert-True ($nearQuota.StartsWith('first supervisor error')) 'Quota trimming must preserve the first supervisor diagnostic prefix.'
        Assert-True ($nearQuota.Length -le 64) 'Quota trimming must never exceed the process evidence quota.'
        $cleanupError = 'The owned Windows job object could not be closed safely (handle=42).'
        $cleanupFirst = Merge-StandardValidationProcessStderr -Existing $cleanupError -Captured ('child stderr detail ' * 40) -Quota 64
        Assert-True ($cleanupFirst.StartsWith('The owned Windows job object could not be closed safely')) 'Cleanup failure diagnostics must take precedence over child stderr.'
        Assert-True ($cleanupFirst.Length -le 64) 'Cleanup-priority stderr must remain within the process evidence quota.'
        $runnerSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RunnerPath
        Assert-Match $runnerSource 'Merge-StandardValidationProcessStderr[\s\S]*-Existing "The owned Windows job object could not be closed safely \(handle=' 'Job-object close failure must be passed as the first diagnostic before child stderr.'
        $shardExecutorSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1')
        Assert-True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardDescendantProcessIds -RootProcessId')).Count -ge 2) 'The shard executor must retain descendant identities while the child is alive.'
        Assert-Match $shardExecutorSource '\$paths\s*=\s*ConvertFrom-Json\s+-InputObject' 'The shard executor must preserve a multi-file shard path array on Windows PowerShell.'
        Assert-True ($shardExecutorSource -match '\$ownsCancellationPath\s+-and[\s\S]{0,240}Remove-Item\s+-LiteralPath \$CancellationPath') 'The shard executor may delete only a runner-owned cancellation marker.'
        Assert-False ($shardExecutorSource -match '&\s+taskkill\.exe') 'The shard executor must not depend on taskkill for owned-process cleanup.'
        Assert-Match $shardExecutorSource 'System\.Diagnostics\.Process\.Kill|Stop-Process' 'The shard executor must use a direct process termination API.'
        Assert-Match $shardExecutorSource 'Get-PesterShardFailureSummary|failureSummary' 'A failed shard must retain a sanitized first-failure summary.'
        Assert-Match $shardExecutorSource 'Read-PesterShardOutputTail' 'A result-less shard must preserve bounded tail diagnostics instead of retaining only the beginning of each stream.'
        Assert-Match $shardExecutorSource '(?s)Get-PesterShardFailureSummary.*?Read-PesterShardOutputTail' 'Failure summarization must inspect the bounded stream tail where terminal errors are written.'
        Assert-Match $shardExecutorSource 'allowlistedFallback' 'A result-less shard without a recognized Pester failure marker may expose only allowlisted bounded terminal context.'
        Assert-Match $shardExecutorSource "Show = ''All''" 'Pester shards must emit bounded per-test progress so an abrupt hosted exit identifies the last completed test.'
        Assert-Match $shardExecutorSource 'CreateKillOnCloseJob|AssignProcessToJobObject' 'The shard executor must establish a kernel-owned Job Object before bootstrap release.'
        Assert-Match $shardExecutorSource 'Assert-PesterShardPathAncestorsNoReparse' 'The shard preflight must reject reparse-point ancestors before creating shard artifacts.'
        Assert-Match $shardExecutorSource 'symlinked or reparse-point ancestor' 'The shard preflight must preserve a precise ancestor trust diagnostic.'
        Assert-Match $shardExecutorSource '\$isHardLink' 'The shard preflight must not mistake a legitimate hardlink executable for symlink traversal.'
        Assert-Match $shardExecutorSource 'Terminate the Job Object before draining inherited output pipes' 'Owned Job Object termination must precede inherited pipe draining.'
        Assert-Match $shardExecutorSource 'Cancellation marker observed before bootstrap release' 'Cancellation must be rechecked after ownership assignment and before bootstrap release.'
        Assert-Match $shardExecutorSource 'Pester shard process status is not completed or output quota was exceeded' 'The aggregate must fail closed on non-completed shard evidence or output-quota overflow.'
        Assert-Match $shardExecutorSource 'PesterShardBoundedCapture|outputQuotaCharacters' 'The shard executor must bound redirected child output.'
        Assert-Match $shardExecutorSource 'failureKind[\s=]+.*early-child-failure' 'A child initialization or Invoke-Pester exception must be represented as an explicit failed result contract.'
        Assert-Match $shardExecutorSource 'failurePhase\s*=\s*\$childFailurePhase' 'Early child evidence must identify the failing initialization or Invoke-Pester phase.'
        Assert-Match $shardExecutorSource 'FailedCount\s*=\s*1' 'Early child failure evidence must contain a nonzero failed count.'
        Assert-Match $shardExecutorSource 'childExitCode\s*-ne\s*0' 'An early child failure must retain a nonzero child exit code after writing evidence.'
        Assert-Match $shardExecutorSource 'ConvertTo-PesterShardEarlyFailureDiagnostic' 'Early child diagnostics must be bounded and sanitized before result/evidence emission.'
        Assert-Match $shardExecutorSource "invoke\.Parameters\.ContainsKey\(''Show''\)" 'The shard executor must gate the optional Show parameter for Pester versions that do not expose it.'
        Assert-True ($shardExecutorSource.Contains("`$ErrorActionPreference = ''Continue''")) 'The shard executor must preserve the original non-terminating-warning behavior while Pester fixtures execute.'
        Assert-True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardProcessIdentity')).Count -ge 2) 'Retained shard PIDs must be bound to immutable process identities.'
        $moduleAncestorValidation = $shardExecutorSource.IndexOf('Assert-PesterShardPathAncestorsNoReparse -Path $PesterModulePath', [StringComparison]::Ordinal)
        $moduleImport = $shardExecutorSource.IndexOf('Import-Module $PesterModulePath', [StringComparison]::Ordinal)
        Assert-True ($moduleAncestorValidation -ge 0 -and $moduleImport -ge 0 -and $moduleAncestorValidation -lt $moduleImport) 'The Pester module path and all existing ancestors must be validated before module initialization can execute.'

        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before process-start cleanup testing.'
        foreach ($functionName in @('New-PesterShardNotStartedCleanup', 'Get-PesterShardCleanupTarget', 'Resolve-PesterShardOutputFailure')) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true)
            Assert-True ($null -ne $definition) "The shard executor must define $functionName."
            Invoke-Expression $definition.Extent.Text
        }

        $unstartedProcess = New-Object Diagnostics.Process
        try {
            $notStarted = Get-PesterShardCleanupTarget `
                -Process $unstartedProcess `
                -ProcessStarted $false `
                -RootProcessId $null
            Assert-True ($null -eq $notStarted) 'An unstarted process must not enter process-tree cleanup or require its Id.'

            $throwingIdProcess = New-Object psobject
            $throwingIdProcess | Add-Member -MemberType ScriptProperty -Name Id -Value { throw 'The process Id getter must not be used.' }
            $started = Get-PesterShardCleanupTarget `
                -Process $throwingIdProcess `
                -ProcessStarted $true `
                -RootProcessId 4242
            Assert-Equal $started.rootProcessId 4242 'A started process cleanup target must use the stored authenticated root process ID.'
            Assert-True ([object]::ReferenceEquals($started.process, $throwingIdProcess)) 'The cleanup target must retain the original process object without reading its Id.'
        }
        finally { $unstartedProcess.Dispose() }

        Assert-Match $shardExecutorSource 'if \(-not \$processStarted\)[\s\S]{0,180}\$status = ''startup-failed''' 'A Process.Start failure must retain the explicit startup-failed status.'
        Assert-Match $shardExecutorSource '\$cleanupTarget\s*=\s*Get-PesterShardCleanupTarget[\s\S]{0,220}if \(\$null -ne \$cleanupTarget\)' 'Process-tree cleanup must be gated by the start-aware target.'
        Assert-False ($shardExecutorSource -match '-RootProcessId\s+\(\[int\]\$process\.Id\)') 'Cleanup must not reacquire the root ID from a process object.'
        $cleanupTargetIndex = $shardExecutorSource.IndexOf('$cleanupTarget = Get-PesterShardCleanupTarget', [StringComparison]::Ordinal)
        $jobHandleCloseIndex = $shardExecutorSource.LastIndexOf('if ($jobHandle -ne [IntPtr]::Zero)', [StringComparison]::Ordinal)
        $processEvidenceIndex = $shardExecutorSource.IndexOf('$diagnostic = [ordered]@{', [StringComparison]::Ordinal)
        Assert-True ($cleanupTargetIndex -ge 0 -and $jobHandleCloseIndex -gt $cleanupTargetIndex -and $processEvidenceIndex -gt $jobHandleCloseIndex) 'Job Object closure must remain independent of process-tree cleanup and precede process evidence finalization.'

        $preStartCleanup = New-PesterShardNotStartedCleanup
        $strictShape = & {
            Set-StrictMode -Version Latest
            $shape = New-PesterShardNotStartedCleanup
            [pscustomobject][ordered]@{
                cleanedUp = [bool]$shape.cleanedUp
                remainingCount = @($shape.remainingProcessIds).Count
                errorCount = @($shape.errors).Count
                warningCount = @($shape.warnings).Count
                authoritative = [bool]$shape.jobObject.authoritative
            }
        }
        Assert-True $strictShape.cleanedUp 'A process-not-started cleanup contract must begin clean.'
        Assert-Equal $strictShape.remainingCount 0 'A process-not-started cleanup contract must expose an empty remaining-process collection.'
        Assert-Equal $strictShape.errorCount 0 'A process-not-started cleanup contract must expose an empty error collection.'
        Assert-Equal $strictShape.warningCount 0 'A process-not-started cleanup contract must expose an empty warning collection.'
        Assert-False $strictShape.authoritative 'A Job Object that contains no started process must not be reported as authoritative containment.'
        $closeFailure = Resolve-PesterShardOutputFailure `
            -Cleanup $preStartCleanup `
            -Errors @('The owned Windows Job Object handle could not be closed safely.') `
            -Status 'startup-failed' `
            -ExceptionText 'Process.Start returned false.'
        Assert-Equal $closeFailure.status 'cleanup-failed' 'A pre-start Job Object close failure must become a cleanup failure.'
        Assert-Match ($closeFailure.cleanup.errors -join ' | ') 'Job Object handle could not be closed safely' 'A pre-start cleanup shape must gain close-failure evidence without throwing.'
        Assert-Match $closeFailure.exceptionText 'Process\.Start returned false.*Job Object handle could not be closed safely' 'The original startup failure and the cleanup failure must both remain available.'

        $postCaptureCleanup = $shardExecutorSource.Substring($shardExecutorSource.IndexOf('$outputWriteFailure = Resolve-PesterShardOutputFailure', [StringComparison]::Ordinal))
        Assert-False ($postCaptureCleanup -match '\$cleanup\.errors\s*=') 'Post-capture Job Object and bootstrap cleanup failures must not assign a missing cleanup.errors property directly.'
        Assert-True (([regex]::Matches($postCaptureCleanup, 'Resolve-PesterShardOutputFailure')).Count -ge 4) 'Output, Job Object, and bootstrap cleanup failures must share the property-safe fail-closed transition.'
    }

    # Scenario: A caller supplies a visible cancellation marker to the shard wrapper.
    # Purpose: Reject the unsupported channel in its own discoverable behavior test before any child or shard artifact can be created.
    It 'UnitT05_rejects_a_caller_visible_cancellation_channel_before_child_execution' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $shardExecutorSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        Assert-Match $shardExecutorSource 'does not accept a caller-visible CancellationPath' 'The shard executor must reject a caller-visible cancellation path before child execution.'
        $rejectionProbe = @"
try {
    & '$($shardPath.Replace("'", "''"))' ``
        -PesterModulePath '$((Join-Path $TestDrive 'missing-pester.psd1').Replace("'", "''"))' ``
        -PesterVersion '4.10.1' ``
        -ExpectedTotalCount 1 ``
        -ExpectedSkippedCount 0 ``
        -CancellationPath '$((Join-Path $TestDrive 'caller-visible.cancel').Replace("'", "''"))'
}
catch {
    [Console]::Error.WriteLine([string]`$_.Exception.Message)
    exit 1
}
"@
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rejectionProbe))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:PowerShellPath
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedProbe"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $probeProcess = New-Object Diagnostics.Process
        $probeProcess.StartInfo = $startInfo
        try {
            Assert-True $probeProcess.Start() 'The caller-visible cancellation rejection probe must start.'
            $probeStdout = $probeProcess.StandardOutput.ReadToEnd()
            $probeStderr = $probeProcess.StandardError.ReadToEnd()
            $probeProcess.WaitForExit()
            $probeExitCode = $probeProcess.ExitCode
        }
        finally { $probeProcess.Dispose() }
        $rejectedOutput = "$probeStdout`n$probeStderr"
        Assert-True ($probeExitCode -ne 0) 'A caller-visible cancellation path must cause a nonzero child exit.'
        Assert-Match $rejectedOutput 'does not accept a caller-visible CancellationPath' 'A caller-visible shard cancellation path must be rejected before any child process or shard artifact is created.'
    }

    # Scenario: Windows PowerShell writes only module-initialization progress CLIXML to stderr while the useful terminal context is on stdout.
    # Purpose: Keep progress serialization from masking the first actionable result-less shard diagnostic.
    It 'UnitT06_skips_progress_only_clixml_before_fallback_diagnostics' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before diagnostic helper testing.'
        foreach ($functionName in @(
            'Read-PesterShardOutputPrefix',
            'Read-PesterShardOutputTail',
            'ConvertFrom-PesterShardCliXmlDiagnostic',
            'Remove-PesterShardTerminalControlSequences',
            'ConvertTo-PesterShardSanitizedDiagnosticText',
            'Get-PesterShardFailureSummary'
        )) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true)
            Assert-True ($null -ne $definition) "The shard executor is missing $functionName."
            Invoke-Expression $definition.Extent.Text
        }
        $script:PesterShardChildOutputQuotaCharacters = 1048576
        $cliXmlDecoderSource = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertFrom-PesterShardCliXmlDiagnostic'
        }, $true).Extent.Text
        Assert-Match $cliXmlDecoderSource 'HashSet\[string\]' 'CLIXML diagnostic deduplication must use a set instead of repeatedly scanning the ordered list.'
        Assert-Match $cliXmlDecoderSource 'StringComparer\]::Ordinal' 'CLIXML diagnostic deduplication must preserve exact ordinal identity.'
        Assert-False ($cliXmlDecoderSource -match '\$diagnosticLines\.Contains\(') 'CLIXML diagnostic deduplication must not perform a linear list scan for every decoded line.'

        $manyRecordBuilder = New-Object Text.StringBuilder
        [void]$manyRecordBuilder.Append('#< CLIXML')
        [void]$manyRecordBuilder.Append([Environment]::NewLine)
        [void]$manyRecordBuilder.Append('<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">')
        for ($recordIndex = 0; $recordIndex -lt 12000; $recordIndex++) {
            [void]$manyRecordBuilder.Append(('<S S="information">unique-diagnostic-{0:D5}</S>' -f $recordIndex))
        }
        [void]$manyRecordBuilder.Append('<S S="information">unique-diagnostic-00000</S>')
        [void]$manyRecordBuilder.Append('</Objs>')
        $manyRecordCliXml = $manyRecordBuilder.ToString()
        Assert-True ($manyRecordCliXml.Length -lt $script:PesterShardChildOutputQuotaCharacters) 'The adversarial CLIXML fixture must remain inside the accepted child-output quota.'
        $manyRecordStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $manyRecordDiagnostic = ConvertFrom-PesterShardCliXmlDiagnostic -Text $manyRecordCliXml
        $manyRecordStopwatch.Stop()
        $manyRecordLines = @($manyRecordDiagnostic -split "`r?`n")
        Assert-Equal $manyRecordLines.Count 12000 'Quota-bounded CLIXML must preserve ordered unique diagnostics while removing duplicates.'
        Assert-Equal $manyRecordLines[0] 'unique-diagnostic-00000' 'CLIXML deduplication must preserve first-seen ordering.'
        Assert-Equal $manyRecordLines[-1] 'unique-diagnostic-11999' 'CLIXML deduplication must retain the final unique record.'
        Assert-True ($manyRecordStopwatch.Elapsed.TotalSeconds -lt 10) 'Quota-bounded CLIXML diagnostic decoding must finish within the absolute safety bound.'

        $stderrPath = Join-Path $TestDrive 'progress-only-stderr.txt'
        $stdoutPath = Join-Path $TestDrive 'terminal-stdout.txt'
        Write-TestUtf8File -Path $stderrPath -Text @'
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.ProgressRecord</T></TN><Props><S N="Activity">Preparing modules for first use.</S><S N="StatusDescription">Preparing modules for first use.</S></Props></Obj></Objs>
'@
        Write-TestUtf8File -Path $stdoutPath -Text 'PowerShell 5.1 shard exited before writing its result file.'

        $summary = Get-PesterShardFailureSummary -Paths @($stderrPath, $stdoutPath)
        Assert-Match $summary 'PowerShell 5\.1 shard exited before writing its result file\.' 'A progress-only stderr stream must not mask useful stdout fallback context.'
        Assert-False ($summary -match '(?i)#< CLIXML|Preparing modules for first use') 'Progress-only CLIXML must not become the first-failure summary.'

        $fallbackTerminalPath = Join-Path $TestDrive 'terminal-control-fallback.txt'
        $escape = [string][char]27
        $bell = [string][char]7
        Write-TestUtf8File -Path $fallbackTerminalPath -Text ($escape + ']0;untrusted terminal title' + $bell + 'PowerShell 5.1 shard exited before writing its result file.')
        $fallbackTerminalSummary = Get-PesterShardFailureSummary -Paths @($fallbackTerminalPath)
        Assert-Equal $fallbackTerminalSummary 'PowerShell 5.1 shard exited before writing its result file.' 'Fallback diagnostics must normalize terminal-control strings before applying the fixed allowlist.'
        Assert-False ($fallbackTerminalSummary -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]|untrusted terminal title') 'Fallback diagnostics must not retain terminal controls or their payload.'

        $credentialPath = Join-Path $TestDrive 'credential-continuation.txt'
        Write-TestUtf8File -Path $credentialPath -Text "Authorization:`ncredential-value-that-must-not-be-logged"
        $credentialSummary = Get-PesterShardFailureSummary -Paths @($credentialPath)
        Assert-False ($credentialSummary -match 'credential-value-that-must-not-be-logged') 'An unlabeled value after a sensitive header must never enter the workflow-visible fallback diagnostic.'
        Assert-Match $credentialSummary 'No allowlisted Pester diagnostic' 'Unrecognized arbitrary child output must be replaced by a fixed safe diagnostic.'

        $recognizedCredentialPath = Join-Path $TestDrive 'recognized-credential-continuation.txt'
        Write-TestUtf8File -Path $recognizedCredentialPath -Text "[-] fixture failure`nAuthorization:`nrecognized-credential-value-that-must-not-be-logged`n`nExpected: safe diagnostic context"
        $recognizedCredentialSummary = Get-PesterShardFailureSummary -Paths @($recognizedCredentialPath)
        Assert-False ($recognizedCredentialSummary -match 'recognized-credential-value-that-must-not-be-logged') 'A recognized failure block must not retain an unlabeled value after a sensitive header.'
        Assert-Match $recognizedCredentialSummary '\[-\] fixture failure' 'Sanitizing a sensitive continuation must preserve the recognized failure marker.'
        Assert-False ($recognizedCredentialSummary -match 'Expected: safe diagnostic context') 'A blank line must not restore raw output after a sensitive header.'
        Assert-Match $recognizedCredentialSummary 'redacted sensitive diagnostic continuation' 'The sensitive block must be represented only by a fixed safe continuation marker.'

        $wrappedCredentialPath = Join-Path $TestDrive 'wrapped-credential-before-marker.txt'
        Write-TestUtf8File -Path $wrappedCredentialPath -Text "Authorization:`nwrapped-credential-fragment-one`nwrapped-credential-fragment-two`n`n[-] fixture failure`nExpected: safe diagnostic context"
        $wrappedCredentialSummary = Get-PesterShardFailureSummary -Paths @($wrappedCredentialPath)
        Assert-False ($wrappedCredentialSummary -match 'wrapped-credential-fragment-(?:one|two)') 'Every wrapped credential continuation before a recognized failure marker must be redacted.'
        Assert-False ($wrappedCredentialSummary -match '\[-\] fixture failure|Expected: safe diagnostic context') 'No raw line after a sensitive header may be trusted as a boundary.'
        Assert-Match $wrappedCredentialSummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'A boundary-looking continuation must be represented by a fixed safe marker.'

        $windowBoundaryCredentialPath = Join-Path $TestDrive 'credential-crossing-tail-window.txt'
        $windowSuffix = "Authorization:`nwindow-boundary-credential`n`n[-] fixture failure`nExpected: safe diagnostic context`n"
        $windowFillerLength = (65536 + 5) - [Text.Encoding]::UTF8.GetByteCount($windowSuffix)
        Assert-True ($windowFillerLength -gt 0) 'The tail-window fixture must place the read offset inside the sensitive header.'
        Write-TestUtf8File -Path $windowBoundaryCredentialPath -Text ("safe prefix`n" + $windowSuffix + ('z' * $windowFillerLength))
        $windowBoundarySummary = Get-PesterShardFailureSummary -Paths @($windowBoundaryCredentialPath)
        Assert-False ($windowBoundarySummary -match 'window-boundary-credential') 'Sanitization must retain sensitive continuation state across a tail-window read boundary.'
        Assert-False ($windowBoundarySummary -match '\[-\] fixture failure|Expected: safe diagnostic context') 'Window-boundary sanitization must not restore raw output after a blank line.'
        Assert-Match $windowBoundarySummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'Window-boundary sanitization must retain only a fixed safe boundary marker.'

        $boundaryLookingCredentialPath = Join-Path $TestDrive 'boundary-looking-credential.txt'
        Write-TestUtf8File -Path $boundaryLookingCredentialPath -Text "[-] fixture failure`nAuthorization:`n[-]window-boundary-credential`nExpected: expected-boundary-credential"
        $boundaryLookingCredentialSummary = Get-PesterShardFailureSummary -Paths @($boundaryLookingCredentialPath)
        Assert-False ($boundaryLookingCredentialSummary -match '(?:window|expected)-boundary-credential') 'Boundary-looking credential continuations must never be trusted as raw diagnostic structure.'
        Assert-Match $boundaryLookingCredentialSummary '\[-\] fixture failure' 'A failure marker before a sensitive continuation must remain available.'

        $quotedKeyCredentialPath = Join-Path $TestDrive 'quoted-key-credential.txt'
        Write-TestUtf8File -Path $quotedKeyCredentialPath -Text "[-] fixture failure`n`"token`":`nquoted-key-credential-that-must-not-be-logged`nExpected: quoted-key-credential-context"
        $quotedKeyCredentialSummary = Get-PesterShardFailureSummary -Paths @($quotedKeyCredentialPath)
        Assert-False ($quotedKeyCredentialSummary -match 'quoted-key-credential-(?:that-must-not-be-logged|context)') 'A quoted sensitive key ending in a separator must enable continuation redaction.'
        Assert-Match $quotedKeyCredentialSummary '\[-\] fixture failure' 'Quoted-key redaction must retain safe context that precedes the sensitive block.'

        $oversizedCliXmlPath = Join-Path $TestDrive 'oversized-valid-clixml-stderr.txt'
        $oversizedCliXmlPadding = 'p' * 140000
        Write-TestUtf8File -Path $oversizedCliXmlPath -Text @"
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><Props><S N="Activity">$oversizedCliXmlPadding</S></Props></Obj><Obj S="information" RefId="1"><ToString>[-] oversized CLIXML fixture failure</ToString></Obj><Obj S="information" RefId="2"><ToString>Expected: safe oversized diagnostic context</ToString></Obj></Objs>
"@
        $oversizedCliXmlSummary = Get-PesterShardFailureSummary -Paths @($oversizedCliXmlPath)
        Assert-Match $oversizedCliXmlSummary '\[-\] oversized CLIXML fixture failure' 'Valid CLIXML within the child-output quota must decode even when it exceeds the former parser limit.'
        Assert-Match $oversizedCliXmlSummary 'Expected: safe oversized diagnostic context' 'Oversized valid CLIXML must preserve adjacent safe diagnostic context.'
        Assert-False ($oversizedCliXmlSummary -match '(?i)#< CLIXML|PowerShell CLIXML diagnostic could not be safely decoded') 'Valid quota-bounded CLIXML must not fall back to an undecodable-stream diagnostic.'

        $mixedStderrPath = Join-Path $TestDrive 'mixed-clixml-stderr.txt'
        Write-TestUtf8File -Path $mixedStderrPath -Text @'
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.ProgressRecord</T></TN><Props><S N="Activity">Preparing modules for first use.</S></Props></Obj><Obj S="information" RefId="1"><ToString> [-] Error occurred in test script 'tests\fixture.Tests.ps1'</ToString></Obj><Obj S="information" RefId="2"><ToString>   PSSecurityException: fixture execution policy failure</ToString></Obj></Objs>
'@
        $mixedSummary = Get-PesterShardFailureSummary -Paths @($mixedStderrPath, $stdoutPath)
        Assert-Match $mixedSummary 'PSSecurityException: fixture execution policy failure' 'Mixed CLIXML must decode the useful non-progress record instead of returning raw XML.'
        Assert-False ($mixedSummary -match '(?i)#< CLIXML|S="progress"') 'Decoded mixed CLIXML must omit serialization markup and progress records.'

        $truncatedStderrPath = Join-Path $TestDrive 'truncated-progress-clixml-stderr.txt'
        Write-TestUtf8File -Path $truncatedStderrPath -Text @'
#< CLIXML
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><MS><PR N="Record"><AV>Preparing modules for first use.</AV><AI>0<
'@
        $actionableStdoutPath = Join-Path $TestDrive 'actionable-stdout.txt'
        Write-TestUtf8File -Path $actionableStdoutPath -Text @'
[-] Error occurred in test script 'tests\fixture.Tests.ps1'
PSSecurityException: fixture execution policy failure
'@
        $truncatedSummary = Get-PesterShardFailureSummary -Paths @($truncatedStderrPath, $actionableStdoutPath)
        Assert-Match $truncatedSummary 'PSSecurityException: fixture execution policy failure' 'Truncated progress CLIXML must be deferred behind actionable stdout.'
        Assert-False ($truncatedSummary -match '(?i)#< CLIXML|Preparing modules for first use') 'Deferred truncated progress CLIXML must not mask actionable stdout.'

        $preservedRawSummary = Get-PesterShardFailureSummary -Paths @($truncatedStderrPath)
        Assert-Equal $preservedRawSummary 'PowerShell CLIXML diagnostic could not be safely decoded.' 'Unparseable CLIXML must retain a fixed diagnostic without exposing raw serialized values.'
        Assert-False ($preservedRawSummary -match '(?i)#< CLIXML|Preparing modules for first use') 'Unparseable CLIXML must never be copied into workflow-visible diagnostics.'
    }

    # Scenario: Parent and generated-child diagnostics contain sensitive continuations split by complete, unterminated, or adversarial terminal controls.
    # Purpose: Normalize terminal controls in one bounded pass before classifying sensitive boundaries and keep continuation values out of every workflow-visible diagnostic.
    It 'UnitT07_normalizes_terminal_controls_before_redacting_parent_and_child_diagnostics_in_bounded_time' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before generated child diagnostic testing.'
        $terminalControlFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Remove-PesterShardTerminalControlSequences'
        }, $true)
        Assert-True ($null -ne $terminalControlFunction) 'The shard executor must define its terminal-control normalizer.'
        Assert-False ($terminalControlFunction.Extent.Text -match '\[regex\]::Replace') 'Terminal-control normalization must not use a backtracking regex over quota-sized child output.'
        Assert-Match $terminalControlFunction.Extent.Text 'while\s*\(' 'Terminal-control normalization must scan its bounded input directly.'
        Invoke-Expression $terminalControlFunction.Extent.Text
        $parentDiagnosticFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertTo-PesterShardSanitizedDiagnosticText'
        }, $true)
        Assert-True ($null -ne $parentDiagnosticFunction) 'The shard executor must define its parent diagnostic sanitizer.'
        Invoke-Expression $parentDiagnosticFunction.Extent.Text
        $ansiReset = ([string][char]27) + '[0m'
        $parentDiagnostic = ConvertTo-PesterShardSanitizedDiagnosticText -Text "[-] fixture failure`n`"token`":$ansiReset`nparent-ansi-key-credential`nExpected: parent-ansi-key-context"
        Assert-False ($parentDiagnostic -match 'parent-ansi-key-(?:credential|context)') 'The parent sanitizer must strip terminal formatting before classifying a sensitive continuation delimiter.'
        Assert-Match $parentDiagnostic '\[-\] fixture failure' 'Parent ANSI normalization must retain safe context that precedes the sensitive block.'

        $escape = [string][char]27
        $indexedColor = $escape + '[38;5;8m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${indexedColor}context${ansiReset}") 'safe context' 'A color index numerically equal to the concealment opcode must remain ordinary readable SGR formatting.'
        $colonColor = $escape + '[38:2::255:0:0m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${colonColor}context${ansiReset}") 'safe context' 'A valid colon-form RGB SGR sequence must remain ordinary readable formatting.'
        $differentColors = $escape + '[38:2::255:0:0;48:2::0:0:255m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${differentColors}context${ansiReset}") 'safe context' 'Different valid foreground and background colors must remain readable formatting.'
        $bell = [string][char]7
        $backspace = [string][char]8
        $osc = $escape + ']0;fixture' + $bell
        $dcs = $escape + 'P1;2|fixture' + $escape + '\'
        $c1Csi = ([string][char]0x9B) + '0m'
        $c1Index = [string][char]0x84
        $cursorLeft = $escape + '[1D'
        $parentCases = @(
            [pscustomobject]@{ Name = 'blank'; Text = "[-] fixture failure`nAuthorization:`n`nparent-blank-credential`nExpected: parent-blank-context" },
            [pscustomobject]@{ Name = 'osc'; Text = "[-] fixture failure`n`"token`":$osc`nparent-osc-credential`nExpected: parent-osc-context" },
            [pscustomobject]@{ Name = 'dcs'; Text = "[-] fixture failure`n`"token`":$dcs`nparent-dcs-credential`nExpected: parent-dcs-context" },
            [pscustomobject]@{ Name = 'c1'; Text = "[-] fixture failure`n`"token`":$c1Csi`nparent-c1-credential`nExpected: parent-c1-context" },
            [pscustomobject]@{ Name = 'esc-csi-incomplete'; Text = "[-] fixture failure`nto${escape}[31`nken:`nparent-esc-csi-incomplete-credential`nExpected: parent-esc-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'c1-csi-incomplete'; Text = "[-] fixture failure`nto$([char]0x9B)31`nken:`nparent-c1-csi-incomplete-credential`nExpected: parent-c1-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-intermediate-incomplete'; Text = "[-] fixture failure`nto${escape}(`nken:`nparent-esc-intermediate-incomplete-credential`nExpected: parent-esc-intermediate-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-low-final'; Text = "[-] fixture failure`nto${escape}#8ken:`nparent-esc-low-final-credential`nExpected: parent-esc-low-final-context" },
            [pscustomobject]@{ Name = 'cursor-bs'; Text = "[-] fixture failure`ntox${backspace}ken:`nparent-cursor-bs-credential`nExpected: parent-cursor-bs-context" },
            [pscustomobject]@{ Name = 'cursor-csi'; Text = "[-] fixture failure`ntox${cursorLeft}ken:`nparent-cursor-csi-credential`nExpected: parent-cursor-csi-context" },
            [pscustomobject]@{ Name = 'cursor-cr'; Text = "[-] fixture failure`ntox`rken:`nparent-cursor-cr-credential`nExpected: parent-cursor-cr-context" },
            [pscustomobject]@{ Name = 'cursor-c1'; Text = "[-] fixture failure`ntox${c1Index}ken:`nparent-cursor-c1-credential`nExpected: parent-cursor-c1-context" },
            [pscustomobject]@{ Name = 'sgr-conceal'; Text = "[-] fixture failure`nto${escape}[8mx${ansiReset}ken:`nparent-sgr-conceal-credential`nExpected: parent-sgr-conceal-context" },
            [pscustomobject]@{ Name = 'sgr-equal-colon'; Text = "[-] fixture failure`nto${escape}[38:2::255:0:0;48:2::255:0:0mx${ansiReset}ken:`nparent-sgr-equal-colon-credential`nExpected: parent-sgr-equal-colon-context" },
            [pscustomobject]@{ Name = 'sgr-equal-indexed'; Text = "[-] fixture failure`nto${escape}[38;5;8m${escape}[48;5;8mx${ansiReset}ken:`nparent-sgr-equal-indexed-credential`nExpected: parent-sgr-equal-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic'; Text = "[-] fixture failure`nto${escape}[31;41mx${ansiReset}ken:`nparent-sgr-equal-basic-credential`nExpected: parent-sgr-equal-basic-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic-indexed'; Text = "[-] fixture failure`nto${escape}[31;48;5;1mx${ansiReset}ken:`nparent-sgr-equal-basic-indexed-credential`nExpected: parent-sgr-equal-basic-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-malformed-color'; Text = "[-] fixture failure`nto${escape}[38;5;999mx${ansiReset}ken:`nparent-sgr-malformed-color-credential`nExpected: parent-sgr-malformed-color-context" },
            [pscustomobject]@{ Name = 'block'; Text = "[-] fixture failure`ntoken: |-`nparent-block-credential`nExpected: parent-block-context" }
        )
        $parentLeaks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($case in $parentCases) {
            $caseDiagnostic = ConvertTo-PesterShardSanitizedDiagnosticText -Text $case.Text
            if ($caseDiagnostic -match "parent-$($case.Name)-(?:credential|context)") { [void]$parentLeaks.Add($case.Name) }
        }

        $childScriptAssignment = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$childScript'
        }, $true)
        Assert-True ($null -ne $childScriptAssignment) 'The shard executor must define its generated child script.'
        $PesterVersion = '4.10.1'
        $childScriptText = Invoke-Expression $childScriptAssignment.Right.Extent.Text
        $encodedChildScriptText = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScriptText))
        $childCommandLineLength = ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChildScriptText).Length
        Assert-True ($childCommandLineLength -le 32000) "The generated child command line must retain safety headroom below the Windows 32,767-character limit. Actual=$childCommandLineLength."
        $childTokens = $null
        $childErrors = $null
        $childAst = [Management.Automation.Language.Parser]::ParseInput($childScriptText, [ref]$childTokens, [ref]$childErrors)
        Assert-Equal @($childErrors).Count 0 'The generated child script must parse before early-failure diagnostic testing.'
        $childTerminalControlFunction = $childAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Remove-PesterShardTerminalControlSequences'
        }, $true)
        Assert-True ($null -ne $childTerminalControlFunction) 'The generated child must embed the same bounded terminal-control scanner.'
        Invoke-Expression $childTerminalControlFunction.Extent.Text
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${colonColor}context${ansiReset}") 'safe context' 'The generated child must preserve valid colon-form RGB SGR formatting.'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${differentColors}context${ansiReset}") 'safe context' 'The generated child must preserve different foreground and background colors.'
        $childDiagnosticFunction = $childAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertTo-PesterShardEarlyFailureDiagnostic'
        }, $true)
        Assert-True ($null -ne $childDiagnosticFunction) 'The generated child script must define its early-failure diagnostic sanitizer.'
        Invoke-Expression $childDiagnosticFunction.Extent.Text
        $childCases = @(
            [pscustomobject]@{ Name = 'blank'; Text = "fixture failure`nAuthorization:`n`nearly-child-blank-credential`nExpected: early-child-blank-context" },
            [pscustomobject]@{ Name = 'osc'; Text = "fixture failure`n`"token`":$osc`nearly-child-osc-credential`nExpected: early-child-osc-context" },
            [pscustomobject]@{ Name = 'dcs'; Text = "fixture failure`n`"token`":$dcs`nearly-child-dcs-credential`nExpected: early-child-dcs-context" },
            [pscustomobject]@{ Name = 'c1'; Text = "fixture failure`n`"token`":$c1Csi`nearly-child-c1-credential`nExpected: early-child-c1-context" },
            [pscustomobject]@{ Name = 'esc-csi-incomplete'; Text = "fixture failure`nto${escape}[31`nken:`nearly-child-esc-csi-incomplete-credential`nExpected: early-child-esc-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'c1-csi-incomplete'; Text = "fixture failure`nto$([char]0x9B)31`nken:`nearly-child-c1-csi-incomplete-credential`nExpected: early-child-c1-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-intermediate-incomplete'; Text = "fixture failure`nto${escape}(`nken:`nearly-child-esc-intermediate-incomplete-credential`nExpected: early-child-esc-intermediate-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-low-final'; Text = "fixture failure`nto${escape}#8ken:`nearly-child-esc-low-final-credential`nExpected: early-child-esc-low-final-context" },
            [pscustomobject]@{ Name = 'cursor-bs'; Text = "fixture failure`ntox${backspace}ken:`nearly-child-cursor-bs-credential`nExpected: early-child-cursor-bs-context" },
            [pscustomobject]@{ Name = 'cursor-csi'; Text = "fixture failure`ntox${cursorLeft}ken:`nearly-child-cursor-csi-credential`nExpected: early-child-cursor-csi-context" },
            [pscustomobject]@{ Name = 'cursor-cr'; Text = "fixture failure`ntox`rken:`nearly-child-cursor-cr-credential`nExpected: early-child-cursor-cr-context" },
            [pscustomobject]@{ Name = 'cursor-c1'; Text = "fixture failure`ntox${c1Index}ken:`nearly-child-cursor-c1-credential`nExpected: early-child-cursor-c1-context" },
            [pscustomobject]@{ Name = 'sgr-conceal'; Text = "fixture failure`nto${escape}[8mx${ansiReset}ken:`nearly-child-sgr-conceal-credential`nExpected: early-child-sgr-conceal-context" },
            [pscustomobject]@{ Name = 'sgr-equal-colon'; Text = "fixture failure`nto${escape}[38:2::255:0:0;48:2::255:0:0mx${ansiReset}ken:`nearly-child-sgr-equal-colon-credential`nExpected: early-child-sgr-equal-colon-context" },
            [pscustomobject]@{ Name = 'sgr-equal-indexed'; Text = "fixture failure`nto${escape}[38;5;8m${escape}[48;5;8mx${ansiReset}ken:`nearly-child-sgr-equal-indexed-credential`nExpected: early-child-sgr-equal-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic'; Text = "fixture failure`nto${escape}[31;41mx${ansiReset}ken:`nearly-child-sgr-equal-basic-credential`nExpected: early-child-sgr-equal-basic-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic-indexed'; Text = "fixture failure`nto${escape}[31;48;5;1mx${ansiReset}ken:`nearly-child-sgr-equal-basic-indexed-credential`nExpected: early-child-sgr-equal-basic-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-malformed-color'; Text = "fixture failure`nto${escape}[38;5;999mx${ansiReset}ken:`nearly-child-sgr-malformed-color-credential`nExpected: early-child-sgr-malformed-color-context" },
            [pscustomobject]@{ Name = 'block'; Text = "fixture failure`ntoken: >-`nearly-child-block-credential`nExpected: early-child-block-context" }
        )
        $childLeaks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($case in $childCases) {
            try { throw [InvalidOperationException]::new($case.Text) }
            catch { $caseDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_ }
            if ($caseDiagnostic -match "early-child-$($case.Name)-(?:credential|context)") { [void]$childLeaks.Add($case.Name) }
        }
        Assert-Equal ($parentLeaks.Count + $childLeaks.Count) 0 "Fail-closed continuation leaks: parent=[$($parentLeaks -join ', ')]; child=[$($childLeaks -join ', ')]."

        try {
            throw [InvalidOperationException]::new("fixture failure`nAuthorization:`nearly-child-credential-fragment-one`nearly-child-credential-fragment-two`n`nExpected: safe child context")
        }
        catch {
            $childFailureDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($childFailureDiagnostic -match 'early-child-credential-fragment-(?:one|two)') 'Early child result and stderr diagnostics must not retain any wrapped value after a sensitive header.'
        Assert-Match $childFailureDiagnostic 'fixture failure' 'Early child sanitization must preserve the exception summary.'
        Assert-False ($childFailureDiagnostic -match 'Expected: safe child context') 'Early child sanitization must remain fail closed across blank lines.'
        Assert-Match $childFailureDiagnostic 'redacted sensitive diagnostic continuation' 'Early child sanitization must emit only fixed markers after a sensitive header.'

        try {
            throw [InvalidOperationException]::new("fixture failure`nAuthorization:`n[-]early-child-boundary-credential`nExpected: early-child-expected-credential")
        }
        catch {
            $boundaryLookingChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($boundaryLookingChildDiagnostic -match 'early-child-(?:boundary|expected)-credential') 'The generated child sanitizer must not trust boundary-looking text while a sensitive continuation is active.'
        Assert-Match $boundaryLookingChildDiagnostic 'fixture failure' 'The generated child sanitizer must retain safe context that precedes the sensitive continuation.'

        try {
            throw [InvalidOperationException]::new("fixture failure`n`"token`":`nearly-child-quoted-key-credential`nExpected: early-child-quoted-key-context")
        }
        catch {
            $quotedKeyChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($quotedKeyChildDiagnostic -match 'early-child-quoted-key-(?:credential|context)') 'The generated child sanitizer must enable continuation redaction for quoted sensitive keys.'
        Assert-Match $quotedKeyChildDiagnostic 'fixture failure' 'The generated child sanitizer must retain safe context that precedes a quoted sensitive key.'

        try {
            throw [InvalidOperationException]::new("fixture failure`n`"token`":$ansiReset`nearly-child-ansi-key-credential`nExpected: early-child-ansi-key-context")
        }
        catch {
            $ansiKeyChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($ansiKeyChildDiagnostic -match 'early-child-ansi-key-(?:credential|context)') 'The generated child sanitizer must strip terminal formatting before classifying a sensitive continuation delimiter.'
        Assert-Match $ansiKeyChildDiagnostic 'fixture failure' 'ANSI normalization must retain safe context that precedes the sensitive block.'
    }

    # Scenario: The configured evidence directory is missing beneath a junction or symbolic-link ancestor.
    # Purpose: Reject the ancestor before New-Item can create any directory in the external target.
    It 'UnitT08_rejects_a_reparse_ancestor_before_creating_the_evidence_root' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $fixtureRoot = Join-Path $TestDrive 'precreate-evidence-root'
        $targetRoot = Join-Path $fixtureRoot 'target'
        $aliasRoot = Join-Path $fixtureRoot 'alias'
        $testRoot = Join-Path $fixtureRoot 'tests'
        $moduleRoot = Join-Path $fixtureRoot 'module'
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)
        [void](New-Item -ItemType Directory -Path $testRoot -Force)
        [void](New-Item -ItemType Directory -Path $moduleRoot -Force)
        $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $linkType -Path $aliasRoot -Target $targetRoot)
        Write-TestUtf8File -Path (Join-Path $testRoot 'fixture.Tests.ps1') -Text "Describe 'fixture' { It 'passes' { } }"
        Write-TestUtf8File -Path (Join-Path $moduleRoot 'Pester.psm1') -Text "function Invoke-Pester { }`nExport-ModuleMember -Function Invoke-Pester"
        Write-TestUtf8File -Path (Join-Path $moduleRoot 'Pester.psd1') -Text @'
@{
    RootModule = 'Pester.psm1'
    ModuleVersion = '4.10.1'
    GUID = 'a5e46c75-f24e-4c3f-baa2-57e93b50e620'
    FunctionsToExport = @('Invoke-Pester')
}
'@
        $evidenceRoot = Join-Path $aliasRoot 'must-not-be-created'
        $probeScript = @"
try {
    & '$($shardPath.Replace("'", "''"))' ``
        -PesterModulePath '$((Join-Path $moduleRoot 'Pester.psd1').Replace("'", "''"))' ``
        -PesterVersion '4.10.1' ``
        -ExpectedTotalCount 1 ``
        -ExpectedSkippedCount 0 ``
        -TestRoot '$($testRoot.Replace("'", "''"))' ``
        -EvidenceRoot '$($evidenceRoot.Replace("'", "''"))' ``
        -OuterTimeoutSeconds 5
}
catch {
    [Console]::Error.WriteLine([string]`$_.Exception.Message)
    exit 1
}
"@
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:PowerShellPath
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedProbe"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $probeProcess = New-Object Diagnostics.Process
        $probeProcess.StartInfo = $startInfo
        try {
            Assert-True $probeProcess.Start() 'The evidence-root pre-creation probe must start.'
            $probeStdout = $probeProcess.StandardOutput.ReadToEnd()
            $probeStderr = $probeProcess.StandardError.ReadToEnd()
            $probeProcess.WaitForExit()
            $probeExitCode = $probeProcess.ExitCode
        }
        finally { $probeProcess.Dispose() }
        $probeOutput = "$probeStdout`n$probeStderr"
        Assert-True ($probeExitCode -ne 0) 'A reparse-point evidence ancestor must be rejected.'
        Assert-Match $probeOutput 'Preflight evidence root contains a symlinked or reparse-point ancestor' 'The rejection must identify the evidence-root trust boundary.'
        Assert-False (Test-Path -LiteralPath (Join-Path $targetRoot 'must-not-be-created')) 'Evidence-root rejection must happen before the external target is mutated.'
    }

    # Scenario: A bounded stdout or stderr capture task faults after the child wrote otherwise successful result evidence.
    # Purpose: Make missing stream evidence a cleanup failure instead of accepting a completed shard.
    It 'UnitT09_fails_closed_when_bounded_output_capture_faults' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before capture-failure state testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-PesterShardOutputFailure'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must define its bounded-capture failure transition.'
        Invoke-Expression $definition.Extent.Text

        $cleanup = [pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }
        $faulted = Resolve-PesterShardOutputFailure `
            -Cleanup $cleanup `
            -Errors @('stderr bounded output capture failed: injected I/O fault') `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $faulted.status 'cleanup-failed' 'A capture task fault must override an otherwise completed shard.'
        Assert-False ([bool]$faulted.cleanup.cleanedUp) 'A capture task fault must invalidate cleanup evidence.'
        Assert-Match ($faulted.cleanup.errors -join ' | ') 'injected I/O fault' 'The capture fault must remain available in process evidence.'
        Assert-Match $faulted.exceptionText 'injected I/O fault' 'The capture fault must remain available to the caller.'

        $clean = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }) `
            -Errors @() `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $clean.status 'completed' 'The normal completed path must remain unchanged when capture has no errors.'
        Assert-True ([bool]$clean.cleanup.cleanedUp) 'The normal completed path must preserve cleanup success.'
    }

    # Scenario: A bounded capture task faults while its child process is still running.
    # Purpose: Surface the fault immediately so the supervisor can break the live wait and start Job Object cleanup.
    It 'UnitT10_terminates_the_live_wait_when_bounded_capture_faults' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before live capture-fault testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-PesterShardLiveCaptureState'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must expose a testable live capture-state transition.'
        Invoke-Expression $definition.Extent.Text

        $faultSource = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
        $faultSource.SetException((New-Object IO.IOException('injected live pipe fault')))
        $faulted = Get-PesterShardLiveCaptureState -Name 'stderr' -Task $faultSource.Task
        Assert-True ([bool]$faulted.isCompleted) 'A faulted live capture task must be recognized as completed.'
        Assert-True ([bool]$faulted.faulted) 'A faulted live capture task must be classified as a fault.'
        Assert-Match $faulted.error 'stderr bounded output capture failed:.*injected live pipe fault' 'The live fault must retain its stream and cause.'

        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        Assert-Match $source '\$captureFaultDetected\s*=\s*\$true' 'The live loop must record a detected capture fault.'
        Assert-Match $source 'if \(\$captureFaultDetected\) \{ break \}' 'The live loop must break immediately after a capture fault.'
    }

    # Scenario: Persisting bounded stdout or stderr evidence fails after capture and child completion.
    # Purpose: Prevent a successful shard result from being accepted without its bounded stream evidence.
    It 'UnitT11_fails_closed_when_bounded_output_evidence_cannot_be_persisted' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before output-persistence failure testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-PesterShardOutputFailure'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must define its output-failure transition.'
        Invoke-Expression $definition.Extent.Text

        $faulted = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }) `
            -Errors @('stdout evidence write failed: injected disk fault') `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $faulted.status 'cleanup-failed' 'An output evidence write fault must override an otherwise completed shard.'
        Assert-False ([bool]$faulted.cleanup.cleanedUp) 'An output evidence write fault must invalidate cleanup evidence.'
        Assert-Match ($faulted.cleanup.errors -join ' | ') 'injected disk fault' 'The output evidence write fault must remain in process evidence.'

        $startupFault = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ cleanedUp = $true; reason = 'process-not-started' }) `
            -Errors @('stderr evidence write failed: injected startup disk fault') `
            -Status 'startup-failed' `
            -ExceptionText $null
        Assert-Equal $startupFault.status 'cleanup-failed' 'An output write fault before process start must still fail closed.'
        Assert-Match ($startupFault.cleanup.errors -join ' | ') 'injected startup disk fault' 'A pre-start cleanup shape must gain output-write error evidence safely.'

        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        $writeFailureIndex = $source.IndexOf('$outputWriteError = "stdout evidence write failed:', [StringComparison]::Ordinal)
        $failClosedIndex = $source.IndexOf('-Errors @($outputWriteError)', [StringComparison]::Ordinal)
        Assert-True ($writeFailureIndex -ge 0 -and $failClosedIndex -gt $writeFailureIndex) 'Output write failures must enter the fail-closed transition before process evidence is finalized.'
    }

    # Scenario: A production adapter tries to bind a resolver receipt from a different slot,
    # or reaches the artifact root through a symlinked ancestor.
    # Purpose: Keep tool-role provenance and checkout-external artifact boundaries authoritative.
    It 'InterT07_rejects_cross_slot_receipts_and_symlinked_root_ancestors' {
        $functionRoot = Join-Path $TestDrive 'central-boundary-functions'
        [void](New-Item -ItemType Directory -Path $functionRoot -Force)
        . $script:RunnerPath `
            -CandidateRoot (Join-Path $functionRoot 'candidate') `
            -AdapterPath (Join-Path $functionRoot 'adapter.json') `
            -ArtifactsRoot (Join-Path $functionRoot 'artifacts') `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $functionRoot `
            -DefineFunctionsOnly

        $wrongRoleRejected = $false
        try {
            Assert-StandardValidationToolReceipt `
                -Provenance ([pscustomobject][ordered]@{
                    toolName = 'skill-validator'
                    receiptPath = [IO.Path]::GetFullPath((Join-Path $functionRoot 'missing-receipt.json'))
                    receiptSha256 = ('0' * 64)
                }) `
                -CommandPath (Join-Path $functionRoot 'missing-command') `
                -CandidateRoot (Join-Path $functionRoot 'candidate') `
                -ArtifactsRoot (Join-Path $functionRoot 'artifacts') `
                -TrustAnchorRoot $functionRoot `
                -RunId ([guid]::NewGuid()) `
                -ExpectedToolName 'skill-tools' `
                -Context 'cross-slot receipt' | Out-Null
        }
        catch {
            $wrongRoleRejected = $true
            Assert-Match $_.Exception.Message 'expected canonical tool role' 'A receipt from another adapter slot must be rejected before receipt I/O.'
        }
        Assert-True $wrongRoleRejected 'A cross-slot resolver receipt must never be accepted.'

        Assert-StandardValidationImmutableArchiveUrl `
            -SourceRepository 'https://github.com/org/repo.git' `
            -SourceRevision ('a' * 40) `
            -ArchiveUrl ('https://github.com/org/repo/archive/' + ('a' * 40) + '.zip') `
            -Context 'valid archive URL'
        $wrongRepositoryRejected = $false
        try {
            Assert-StandardValidationImmutableArchiveUrl `
                -SourceRepository 'https://github.com/org/repo.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveUrl ('https://github.com/org/repository/archive/' + ('a' * 40) + '.zip') `
                -Context 'wrong repository archive URL'
        }
        catch {
            $wrongRepositoryRejected = $true
            Assert-Match $_.Exception.Message 'not bound to the source repository' 'A repository-name prefix collision in an archive URL must be rejected.'
        }
        Assert-True $wrongRepositoryRejected 'An archive URL for a repository sharing the source-name prefix must fail closed.'

        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) { return }
        $symlinkRoot = Join-Path $TestDrive 'symlinked-artifact-ancestor'
        $targetRoot = Join-Path $symlinkRoot 'target'
        $aliasRoot = Join-Path $symlinkRoot 'alias'
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)
        [void](New-Item -ItemType SymbolicLink -Path $aliasRoot -Target $targetRoot)
        $symlinkRejected = $false
        try {
            Assert-StandardValidationCanonicalRootPath `
                -Path (Join-Path $aliasRoot 'output') `
                -Context 'symlinked artifact root' | Out-Null
        }
        catch {
            $symlinkRejected = $true
            Assert-Match $_.Exception.Message 'symlinked or reparse-point ancestor' 'A symlinked artifact-root ancestor must be rejected.'
        }
        Assert-True $symlinkRejected 'An artifact root reached through a symlinked ancestor must fail closed.'
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

        $runIdFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'caller-run-id')
        $runIdResult = Invoke-RunnerFixture -Fixture $runIdFixture -DevelopmentHarness:$false -ValidationRunId ('a' * 32)
        Assert-Equal $runIdResult.Evidence.state 'INVALID' 'Production validation must reject a caller-selected run ID.'
        Assert-Match $runIdResult.Output 'generated by the trusted supervisor|caller' 'Run-ID replay rejection must identify the trusted supervisor boundary.'

        $missingBindingFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'missing-launch-binding')
        $missingBindingResult = Invoke-RunnerFixture -Fixture $missingBindingFixture -DevelopmentHarness:$false
        Assert-Equal $missingBindingResult.Evidence.state 'INVALID' 'Production validation must reject a missing supervisor launch binding.'
        Assert-Equal $missingBindingResult.Evidence.launchBinding.status 'unverified-production' 'A rejected production launch binding must not be labeled as a development harness.'
        Assert-Match $missingBindingResult.Output 'SupervisorLaunchBindingPath|launch binding' 'The missing launch binding must identify the trusted supervisor boundary.'

        $credentialFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'credentialed-source-repository')
        $credentialResult = Invoke-RunnerFixture `
            -Fixture $credentialFixture `
            -SourceRepository 'https://token@github.com/org/repo.git'
        Assert-Match $credentialResult.Output '"state"\s*:\s*"INVALID"' 'Source repositories with embedded credentials must be rejected before evidence construction.'
        $credentialEvidenceText = if ($null -eq $credentialResult.Evidence) { '' } else { $credentialResult.Evidence | ConvertTo-Json -Depth 20 -Compress }
        Assert-False (($credentialResult.Output + $credentialEvidenceText) -match 'token') 'Rejected source-repository credentials must never appear in output or evidence.'
    }

    # Scenario: A production adapter carries a freshly signed resolver receipt and a trusted supervisor launch binding.
    # Purpose: Authenticate the supervisor-to-resolver handoff before receipt validation, then bind every slot to the same run.
    It 'UnitT01_authenticates_supervisor_launch_binding_before_signed_resolver_receipt' {
        $root = Join-Path $TestDrive 'production-run-id-derivation'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }

        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath (Join-Path $root 'adapter.json') `
            -ArtifactsRoot $artifactsRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly

        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            Write-TestUtf8File -Path (Join-Path $trustedRoot 'trusted-supervisor-public-key.xml') -Text $rsa.ToXmlString($false)
            $installRoot = Join-Path $trustedRoot 'fixture-tool'
            [void](New-Item -ItemType Directory -Path $installRoot -Force)
            $commandPath = Join-Path $installRoot 'fixture-tool.bin'
            Write-TestUtf8File -Path $commandPath -Text 'trusted fixture executable bytes'
            $executableSha256 = Get-StandardValidationFileSha256 -Path $commandPath -Context 'test resolver executable'
            $installedInventory = Get-StandardValidationInventory -Root $installRoot -Context 'test resolver closure'
            $installedClosureSha256 = Get-StandardValidationInventorySha256 -Inventory $installedInventory
            $launcher = [ordered]@{
                kind = 'direct-executable'
                shimPath = $null
                shimSha256 = $null
                payloadPath = $null
                payloadSha256 = $null
                runtimePath = $null
                runtimeSha256 = $null
            }
            $launcherDigestSha256 = Get-StandardValidationLauncherDigest -Launcher $launcher -Context 'test resolver launcher'
            $productionGuid = [guid]::NewGuid()
            $runIdText = $productionGuid.ToString('N')
            $resolvedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            $fields = @{
                channel = 'latest-stable'
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                installRoot = [IO.Path]::GetFullPath($installRoot)
                launcherDigestSha256 = $launcherDigestSha256
                issuedAt = $resolvedAtUtc
                resolvedIdentity = 'fixture-tool@1.0.0'
                resolvedVersion = '1.0.0'
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                source = 'https://example.com/fixture-tool'
                status = 'verified'
                toolName = 'package-adapter'
            }
            $attestation = [ordered]@{
                schemaVersion = 1
                attestationType = 'trusted-supervisor-validation-tool-v1'
                toolName = 'package-adapter'
                source = 'https://example.com/fixture-tool'
                channel = 'latest-stable'
                status = 'verified'
                resolvedVersion = '1.0.0'
                resolvedIdentity = 'fixture-tool@1.0.0'
                installRoot = [IO.Path]::GetFullPath($installRoot)
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                launcherDigestSha256 = $launcherDigestSha256
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                issuedAt = $resolvedAtUtc
                signature = $null
            }
            $payload = Get-StandardValidationSignedReceiptPayload -ReceiptType 'validation-tool-v1' -Fields $fields
            $attestation.signature = [Convert]::ToBase64String($rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            $receipt = [ordered]@{
                schemaVersion = 1
                evidenceType = 'validation-tool-resolution'
                status = 'verified'
                toolName = 'package-adapter'
                source = 'https://example.com/fixture-tool'
                channel = 'latest-stable'
                resolvedVersion = '1.0.0'
                resolvedIdentity = 'fixture-tool@1.0.0'
                installRoot = [IO.Path]::GetFullPath($installRoot)
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                launcher = $launcher
                launcherDigestSha256 = $launcherDigestSha256
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                attestation = $attestation
            }
            $receiptPath = Join-Path $trustedRoot 'fixture-tool-receipt.json'
            Write-TestUtf8File -Path $receiptPath -Text ($receipt | ConvertTo-Json -Depth 20)
            $receiptSha256 = Get-StandardValidationFileSha256 -Path $receiptPath -Context 'test resolver receipt'
            $adapterPath = Join-Path $root 'adapter.json'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
            $adapterSha256 = Get-StandardValidationFileSha256 -Path $adapterPath -Context 'test adapter'
            $outputPath = Join-Path $artifactsRoot 'evidence.json'
            $authorityRevision = 'c' * 40
            $candidateArchiveSha256 = 'd' * 64
            $bindingIssuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            $bindingExpiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
            $consumptionPath = Join-Path $root 'launch-consumption.json'
            $bindingFields = @{
                adapterPath = [IO.Path]::GetFullPath($adapterPath)
                adapterSha256 = $adapterSha256
                artifactsRoot = [IO.Path]::GetFullPath($artifactsRoot)
                authorityRevision = $authorityRevision
                baseRevision = 'b' * 40
                candidateArchiveSha256 = $candidateArchiveSha256
                candidateRoot = [IO.Path]::GetFullPath($candidateRoot)
                consumptionPath = [IO.Path]::GetFullPath($consumptionPath)
                eventName = 'local'
                expiresAt = $bindingExpiresAt
                issuedAt = $bindingIssuedAt
                outputPath = [IO.Path]::GetFullPath($outputPath)
                resolutionRunId = $runIdText
                sourceRepository = 'https://example.com/example/skills.git'
                sourceRevision = 'a' * 40
                trustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
            }
            $launchBinding = [ordered]@{
                schemaVersion = 1
                evidenceType = 'validation-launch-binding'
                status = 'issued'
                candidateRoot = [IO.Path]::GetFullPath($candidateRoot)
                adapterPath = [IO.Path]::GetFullPath($adapterPath)
                artifactsRoot = [IO.Path]::GetFullPath($artifactsRoot)
                outputPath = [IO.Path]::GetFullPath($outputPath)
                trustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
                sourceRepository = 'https://example.com/example/skills.git'
                sourceRevision = 'a' * 40
                baseRevision = 'b' * 40
                eventName = 'local'
                candidateArchiveSha256 = $candidateArchiveSha256
                adapterSha256 = $adapterSha256
                authorityRevision = $authorityRevision
                resolutionRunId = $runIdText
                issuedAt = $bindingIssuedAt
                expiresAt = $bindingExpiresAt
                consumptionPath = [IO.Path]::GetFullPath($consumptionPath)
                signature = $null
            }
            $bindingPayload = Get-StandardValidationSignedReceiptPayload -ReceiptType 'validation-launch-v1' -Fields $bindingFields
            $launchBinding.signature = [Convert]::ToBase64String($rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($bindingPayload), 'SHA256'))
            $bindingPath = Join-Path $root 'launch-binding.json'
            Write-TestUtf8File -Path $bindingPath -Text ($launchBinding | ConvertTo-Json -Depth 20)
            $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'test launch binding'
            $adapterSnapshot = Get-StandardValidationJsonSnapshot -Path $adapterPath -Context 'adapter substitution snapshot'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":2}'
            Assert-Equal $adapterSnapshot.value.schemaVersion 1 'The adapter snapshot must retain the bytes parsed before a path substitution.'
            $substitutionBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSnapshot.sha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'adapter substitution snapshot'
            Assert-Equal $substitutionBinding.resolutionRunId $runIdText 'The launch binding must authenticate the immutable adapter snapshot rather than rereading a substituted path.'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
            $validatedBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'test supervisor launch binding'
            Assert-Equal $validatedBinding.resolutionRunId $runIdText 'The trusted launch binding must carry the supervisor-generated N-format run ID.'
            Assert-StandardValidationLaunchBindingUnchanged -Binding $validatedBinding

            $spec = [pscustomobject][ordered]@{
                command = [IO.Path]::GetFullPath($commandPath)
                arguments = [object[]]@()
                provenance = [pscustomobject][ordered]@{
                    toolName = 'package-adapter'
                    receiptPath = [IO.Path]::GetFullPath($receiptPath)
                    receiptSha256 = $receiptSha256
                }
            }
            $adapter = [pscustomobject][ordered]@{ packageAdapter = $spec }
            $derivedRunId = Get-StandardValidationProductionRunId `
                -Adapter $adapter `
                -CandidateRoot $candidateRoot `
                -ArtifactsRoot $artifactsRoot `
                -TrustedToolRoot $trustedRoot `
                -TrustAnchorRoot $trustedRoot `
                -ExpectedRunId $productionGuid `
                -ExpectedLaunchIssuedAt $validatedBinding.issuedAt
            Assert-Equal $derivedRunId.ToString('N') $runIdText 'Production run ID must come from the authenticated supervisor launch binding and signed resolver receipt.'

            $bindingReplayRejected = $false
            try {
                Assert-StandardValidationSupervisorLaunchBinding `
                    -Path $bindingPath `
                    -CandidateRoot $candidateRoot `
                    -AdapterPath $adapterPath `
                    -AdapterSha256 $adapterSha256 `
                    -ArtifactsRoot (Join-Path $root 'replayed-artifacts') `
                    -OutputPath (Join-Path $root 'replayed-artifacts/evidence.json') `
                    -TrustedToolRoot $trustedRoot `
                    -SourceRepository 'https://example.com/example/skills.git' `
                    -SourceRevision ('a' * 40) `
                    -BaseRevision ('b' * 40) `
                    -EventName 'local' `
                    -CandidateArchiveSha256 $candidateArchiveSha256 `
                    -AuthorityRevision $authorityRevision `
                    -TrustAnchorRoot $trustedRoot `
                    -Context 'replayed launch binding' | Out-Null
            }
            catch {
                $bindingReplayRejected = $true
                Assert-Match $_.Exception.Message 'different artifactsRoot' 'A signed launch binding must not be replayable into a different artifact root.'
            }
            Assert-True $bindingReplayRejected 'A signed launch binding must bind the artifact root used by the current invocation.'

            $replayRejected = $false
            try {
                Get-StandardValidationProductionRunId `
                    -Adapter $adapter `
                    -CandidateRoot $candidateRoot `
                    -ArtifactsRoot $artifactsRoot `
                    -TrustedToolRoot $trustedRoot `
                    -TrustAnchorRoot $trustedRoot `
                    -ExpectedRunId ([guid]::NewGuid()) | Out-Null
            }
            catch {
                $replayRejected = $true
                Assert-Match $_.Exception.Message 'different validation run|current trusted-supervisor validation run' 'A signed receipt from an earlier run must be rejected for a new supervisor run.'
            }
            Assert-True $replayRejected 'A still-fresh signed resolver receipt must not be replayable into a new validation run.'

            $validated = Assert-StandardValidationCommandSpec `
                -Spec $spec `
                -Context 'production run-id binding' `
                -CandidateRoot $candidateRoot `
                -ArtifactsRoot $artifactsRoot `
                -TrustedToolRoot $trustedRoot `
                -TrustAnchorRoot $trustedRoot `
                -RunId $derivedRunId `
                -ExpectedToolName 'package-adapter' `
                -DevelopmentHarness:$false
            Assert-Equal $validated.toolReceipt.runId.ToString('N') $runIdText 'The full production command validation must preserve the derived run ID.'

            $script:OriginalLaunchBindingSnapshot = (Get-Command Get-StandardValidationJsonSnapshot -CommandType Function).ScriptBlock
            $script:OriginalLaunchBindingJson = (Get-Command Get-StandardValidationJson -CommandType Function).ScriptBlock
            $script:BindingSubstitutionPath = [IO.Path]::GetFullPath($bindingPath)
            function Get-StandardValidationJsonSnapshot {
                param([string] $Path, [string] $Context)
                $snapshot = & $script:OriginalLaunchBindingSnapshot -Path $Path -Context $Context
                if ([IO.Path]::GetFullPath($Path) -ceq $script:BindingSubstitutionPath) {
                    Write-TestUtf8File -Path $Path -Text '{"replacement":true}'
                }
                return $snapshot
            }
            function Get-StandardValidationJson {
                param([string] $Path, [string] $Context)
                $value = & $script:OriginalLaunchBindingJson -Path $Path -Context $Context
                if ([IO.Path]::GetFullPath($Path) -ceq $script:BindingSubstitutionPath) {
                    Write-TestUtf8File -Path $Path -Text '{"replacement":true}'
                }
                return $value
            }
            $snapshotBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'launch binding substitution snapshot'
            Assert-Equal $snapshotBinding.sha256 $bindingSha256 'The launch-binding evidence hash must come from the authenticated byte snapshot.'
            Assert-False ((Get-StandardValidationFileSha256 -Path $bindingPath -Context 'substituted launch binding') -ceq $bindingSha256) 'The binding substitution regression must replace the live path after snapshot capture.'
            Write-TestUtf8File -Path $bindingPath -Text ($launchBinding | ConvertTo-Json -Depth 20)
        }
        finally { $rsa.Dispose() }
    }

    # Scenario: The public production runner must consume the exact run-ID format emitted by the authenticated launch-binding helper.
    # Purpose: Exercise Invoke-StandardValidationRun through the launch-binding handoff before the authority gate, so a format mismatch cannot hide behind helper-only coverage.
    It 'UnitT02_public_production_path_preserves_authenticated_launch_run_id_format' {
        $root = Join-Path $TestDrive 'public-production-launch-binding'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        $adapterPath = Join-Path $root 'adapter.json'
        $bindingPath = Join-Path $root 'launch-binding.json'
        $consumptionPath = Join-Path $root 'launch-consumption.json'
        $outputPath = Join-Path $artifactsRoot 'evidence.json'
        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly
        Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
        Write-TestUtf8File -Path $bindingPath -Text '{"fixture":true}'
        $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'public launch binding fixture'
        $publicRunGuid = [guid]::NewGuid()
        $publicRunIdText = $publicRunGuid.ToString('N')
        $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')

        $script:PublicLaunchBindingPath = $bindingPath
        $script:PublicLaunchBindingSha256 = $bindingSha256
        $script:PublicLaunchBindingRunIdText = $publicRunIdText
        $script:PublicLaunchBindingIssuedAt = $issuedAt
        $script:PublicLaunchBindingExpiresAt = $expiresAt
        $script:PublicLaunchBindingConsumptionPath = $consumptionPath
        $script:PublicLaunchBindingAdapterSha256 = $null
        function Assert-StandardValidationSupervisorLaunchBinding {
            param([string] $AdapterSha256)
            $script:PublicLaunchBindingAdapterSha256 = $AdapterSha256
            return [pscustomobject][ordered]@{
                status = 'verified'
                verified = $true
                path = $script:PublicLaunchBindingPath
                sha256 = $script:PublicLaunchBindingSha256
                resolutionRunId = $script:PublicLaunchBindingRunIdText
                issuedAt = $script:PublicLaunchBindingIssuedAt
                expiresAt = $script:PublicLaunchBindingExpiresAt
                consumptionPath = $script:PublicLaunchBindingConsumptionPath
                consumptionSha256 = ('0' * 64)
            }
        }
        function Assert-StandardValidationAuthoritySnapshot {
            throw 'BLOCKED|public launch-binding handoff reached the authority gate.'
        }

        $result = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false

        Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'The public production path must write terminal evidence after the test authority boundary.'
        $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $outputPath | ConvertFrom-Json
        Assert-Equal $script:PublicLaunchBindingAdapterSha256 (Get-StandardValidationFileSha256 -Path $adapterPath -Context 'public adapter snapshot') 'The public production path must hand the authenticated binding the hash of the parsed adapter snapshot.'
        Assert-Equal $evidence.state 'BLOCKED' 'The public production path must reach the authority boundary after launch binding authentication.'
        Assert-Match ([string]$evidence.failure.message) 'public launch-binding handoff reached the authority gate' 'The public production path must not fail on an N-format launch run ID before the authority boundary.'
        Assert-True (Test-Path -LiteralPath $consumptionPath -PathType Leaf) 'The public production path must consume the signed launch binding before the authority boundary.'

        Remove-Item -LiteralPath $artifactsRoot -Recurse -Force
        [void](New-Item -ItemType Directory -Path $artifactsRoot -Force)
        $replayResult = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false
        Assert-Equal $replayResult.state 'BLOCKED' 'A deleted and recreated artifact root must not permit launch-binding replay.'
        Assert-Match ([string]$replayResult.failure.message) 'already been consumed|replay' 'Launch-binding replay must be rejected by the external consumption marker.'
    }

    # Scenario: The adapter is replaced after the immutable bytes have been snapshotted but before launch handoff returns.
    # Purpose: Fail closed before any adapter-derived command can execute when the path no longer matches the authenticated snapshot.
    It 'UnitT03_rejects_adapter_substitution_during_launch_handoff' {
        $root = Join-Path $TestDrive 'adapter-substitution-during-launch'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        $adapterPath = Join-Path $root 'adapter.json'
        $bindingPath = Join-Path $root 'launch-binding.json'
        $consumptionPath = Join-Path $root 'launch-consumption.json'
        $outputPath = Join-Path $artifactsRoot 'evidence.json'
        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly
        Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
        Write-TestUtf8File -Path $bindingPath -Text '{"fixture":true}'
        $adapterSha256 = Get-StandardValidationFileSha256 -Path $adapterPath -Context 'adapter substitution fixture'
        $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'adapter substitution binding fixture'
        $runIdText = ([guid]::NewGuid()).ToString('N')
        $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
        $script:SubstitutionAdapterPath = $adapterPath
        $script:SubstitutionAdapterSha256 = $null
        $script:SubstitutionBindingPath = $bindingPath
        $script:SubstitutionBindingSha256 = $bindingSha256
        $script:SubstitutionRunIdText = $runIdText
        $script:SubstitutionIssuedAt = $issuedAt
        $script:SubstitutionExpiresAt = $expiresAt
        $script:SubstitutionConsumptionPath = $consumptionPath
        function Assert-StandardValidationSupervisorLaunchBinding {
            param([string] $AdapterSha256)
            $script:SubstitutionAdapterSha256 = $AdapterSha256
            Write-TestUtf8File -Path $script:SubstitutionAdapterPath -Text '{"schemaVersion":2}'
            return [pscustomobject][ordered]@{
                status = 'verified'
                verified = $true
                path = $script:SubstitutionBindingPath
                sha256 = $script:SubstitutionBindingSha256
                resolutionRunId = $script:SubstitutionRunIdText
                issuedAt = $script:SubstitutionIssuedAt
                expiresAt = $script:SubstitutionExpiresAt
                consumptionPath = $script:SubstitutionConsumptionPath
                consumptionSha256 = ('0' * 64)
            }
        }
        function Assert-StandardValidationAuthoritySnapshot {
            throw 'BLOCKED|authority gate must not be reached after adapter substitution.'
        }

        $result = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false

        Assert-Equal $script:SubstitutionAdapterSha256 $adapterSha256 'The launch handoff must authenticate the hash of the immutable adapter snapshot.'
        Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Adapter substitution must produce terminal evidence.'
        $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $outputPath | ConvertFrom-Json
        Assert-Equal $evidence.state 'BLOCKED' 'Adapter substitution during launch handoff must fail closed.'
        Assert-Equal $evidence.launchBinding.resolutionRunId ([guid]::ParseExact($runIdText, 'N').ToString()) 'Substitution failure evidence must retain the authenticated launch-binding run ID.'
        Assert-Match ([string]$evidence.failure.message) 'Adapter changed during the trusted supervisor launch handoff' 'The failure must identify the adapter substitution boundary.'
    }

    # Scenario: A child emits more data than the supervisor can safely retain on either redirected stream.
    # Purpose: Bound stdout/stderr memory, terminate the owned process tree, and report a failed validation rather than buffering unbounded output.
    It 'InterT11_terminates_child_when_output_capture_exceeds_quota' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-flood') -Behavior 'output-flood'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($result.ExitCode -ne 0) 'An output-flood child must not return a pass exit code.'
        Assert-Equal $result.Evidence.state 'FAILED' 'An output-flood child must fail the validation run.'
        Assert-Match $result.Output 'output.*quota|quota.*output' 'The failure must identify bounded output capture as the cause.'
        $quotaEvent = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Artifacts 'runs') -Filter 'event-*.json' -Recurse -File |
                ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } |
                Where-Object { $_.process.outputQuotaExceeded -eq $true } | Select-Object -First 1)[0]
        Assert-True ($null -ne $quotaEvent) 'The output-flood event must retain raw bounded-capture evidence.'
        Assert-True (([string]$quotaEvent.process.stdout).Length -le 1048576) 'The stdout prefix must remain within its quota on overflow.'
        Assert-True (([string]$quotaEvent.process.stderr).Length -le 1048576) 'The stderr prefix must remain within its quota on overflow.'
        Assert-Match ([string]$quotaEvent.process.outputQuotaDiagnostic) 'quota exceeded' 'The overflow diagnostic must be recorded outside the bounded stderr prefix.'
    }

    # Scenario: A child emits a valid JSON envelope whose stdout is near, but below, the capture quota.
    # Purpose: Preserve the complete in-quota stream rather than applying an undocumented serialization margin.
    It 'InterT12_preserves_valid_output_below_capture_quota' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-near-quota') -Behavior 'output-near-quota'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'PASS' 'A valid near-quota output envelope must remain a passing validation.'
        $nearQuotaEvent = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Artifacts 'runs') -Filter 'event-*.json' -Recurse -File |
                ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } |
                Where-Object { $_.process.outputQuotaExceeded -eq $false -and ([string]$_.process.stdout).Length -gt (1048576 - 4096) } |
                Select-Object -First 1)[0]
        Assert-True ($null -ne $nearQuotaEvent) 'The valid near-quota event must retain the full stream above the former safety-margin threshold.'
        Assert-True (([string]$nearQuotaEvent.process.stdout).Length -le 1048576) 'The valid near-quota stdout must remain within the capture quota.'
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
        foreach ($behavior in @('repository-missing-evidence', 'repository-zero-tests')) {
            $invalidFixture = New-RunnerFixture -Root (Join-Path $TestDrive $behavior) -Behavior $behavior
            $invalidResult = Invoke-RunnerFixture -Fixture $invalidFixture
            Assert-True ($invalidResult.ExitCode -ne 0) "Repository test evidence '$behavior' must not return a pass exit code."
            Assert-Equal $invalidResult.Evidence.state 'FAILED' "Repository test evidence '$behavior' must fail the run."
            Assert-Match $invalidResult.Output 'testInventory|typed.*coverage|Repository Tests' "Repository test evidence '$behavior' must identify the missing or empty coverage."
        }
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

        $analyzerTriggerFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-required') -Behavior 'semantic-required'
        $analyzerTriggerResult = Invoke-RunnerFixture -Fixture $analyzerTriggerFixture
        Assert-Equal $analyzerTriggerResult.Evidence.state 'BLOCKED' 'A typed analyzer semantic trigger must not be suppressible by omitting the caller switch.'
        $analyzerTriggerStage = @($analyzerTriggerResult.Evidence.stages | Where-Object id -eq 'conditional-semantic-scan')[0]
        Assert-True ([bool]$analyzerTriggerStage.triggerDecision.analyzerRequired) 'The semantic stage must record the analyzer-required trigger.'
        Assert-True ([bool]$analyzerTriggerStage.triggerDecision.effectiveTriggered) 'The effective semantic trigger must include the analyzer requirement.'

        $semanticEvidenceFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-evidence')
        . $script:RunnerPath `
            -CandidateRoot $semanticEvidenceFixture.Candidate `
            -AdapterPath $semanticEvidenceFixture.Adapter `
            -ArtifactsRoot $semanticEvidenceFixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $semanticAdapterSha = Get-StandardValidationFileSha256 -Path $semanticEvidenceFixture.Adapter -Context 'test adapter'
        $semanticInventory = Get-StandardValidationInventory -Root $semanticEvidenceFixture.Candidate -Context 'test candidate'
        $semanticContentSha = Get-StandardValidationInventorySha256 -Inventory $semanticInventory
        $semanticCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$semanticContentSha`n$semanticAdapterSha`n")
        $semanticEvidencePath = Join-Path $semanticEvidenceFixture.Root 'semantic.json'
        $semanticRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            Write-TestSemanticEvidence -Fixture $semanticEvidenceFixture -Path $semanticEvidencePath -CandidateId $semanticCandidateId -Rsa $semanticRsa
        }
        finally { $semanticRsa.Dispose() }
        $semanticResult = Invoke-RunnerFixture `
            -Fixture $semanticEvidenceFixture `
            -SemanticTriggered `
            -SemanticConsent `
            -SemanticProvider 'fixture-semantic-provider' `
            -SemanticPurpose 'fixture semantic regression' `
            -SemanticScope 'candidate' `
            -SemanticEvidencePath $semanticEvidencePath
        Assert-Equal $semanticResult.Evidence.state 'PASS' 'A valid authenticated semantic result must pass the semantic barrier.'
        $semanticStage = @($semanticResult.Evidence.stages | Where-Object id -eq 'conditional-semantic-scan')[0]
        Assert-Equal $semanticStage.status 'passed' 'A valid semantic result must complete the semantic stage.'
        Assert-Equal ([string]$semanticStage.semanticEvidence.evidenceType) 'semantic' 'The semantic evidence must be retained on its stage object.'
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

        $environmentFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'environment-leak') -Behavior 'environment-leak'
        $environmentResult = Invoke-RunnerFixture -Fixture $environmentFixture
        Assert-Equal $environmentResult.Evidence.state 'PASS' 'A secret inherited by the supervisor must not be visible to a validation child.'

        $artifactTamperFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'repository-artifact-tamper') -Behavior 'repository-artifact-tamper'
        $artifactTamperResult = Invoke-RunnerFixture -Fixture $artifactTamperFixture
        Assert-Equal $artifactTamperResult.Evidence.state 'FAILED' 'A repository test that removes a prior evidence artifact must fail validation.'
        Assert-Match $artifactTamperResult.Output 'Previously written validation evidence artifact' 'Prior evidence artifact tampering must be reported as a validation failure.'

        $outputTamperFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-tamper') -Behavior 'output-tamper'
        $outputTamperResult = Invoke-RunnerFixture -Fixture $outputTamperFixture
        Assert-True ($outputTamperResult.Evidence.state -ne 'PASS') 'A child process that substitutes the reserved final output must never produce PASS.'
        $attackerProperty = if ($null -eq $outputTamperResult.Evidence) { $null } else { $outputTamperResult.Evidence.PSObject.Properties['attacker'] }
        Assert-True ($null -eq $attackerProperty) 'Final evidence must not be replaced by attacker-controlled output.'
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
        Write-TestAiReviewEvidence -Fixture $aiOnlyFixture -Path $aiEvidence -CandidateId $aiOnlyCandidateId
        $aiOnlyResult = Invoke-RunnerFixture -Fixture $aiOnlyFixture -CompleteLifecycle -AiReviewEvidencePath $aiEvidence
        Assert-Equal $aiOnlyResult.Evidence.state 'BLOCKED' 'AI review evidence alone must not satisfy human approval.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'ai-review')[0].status) 'passed' 'AI review evidence should be recorded independently before the block.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'Missing human approval must block the lifecycle.'

        $unsignedAiFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'unsigned-ai-review')
        $unsignedAiAdapterSha = Get-StandardValidationFileSha256 -Path $unsignedAiFixture.Adapter -Context 'test adapter'
        $unsignedAiInventory = Get-StandardValidationInventory -Root $unsignedAiFixture.Candidate -Context 'test candidate'
        $unsignedAiContentSha = Get-StandardValidationInventorySha256 -Inventory $unsignedAiInventory
        $unsignedAiCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$unsignedAiContentSha`n$unsignedAiAdapterSha`n")
        $unsignedAiEvidence = Join-Path $unsignedAiFixture.Root 'ai-review.json'
        Write-TestAiReviewEvidence -Fixture $unsignedAiFixture -Path $unsignedAiEvidence -CandidateId $unsignedAiCandidateId
        $unsignedAiObject = Get-Content -Raw -Encoding UTF8 -LiteralPath $unsignedAiEvidence | ConvertFrom-Json
        $unsignedAiObject.PSObject.Properties.Remove('attestation')
        Write-TestUtf8File -Path $unsignedAiEvidence -Text ($unsignedAiObject | ConvertTo-Json -Depth 50)
        $unsignedAiResult = Invoke-RunnerFixture -Fixture $unsignedAiFixture -CompleteLifecycle -AiReviewEvidencePath $unsignedAiEvidence
        Assert-Equal $unsignedAiResult.Evidence.state 'BLOCKED' 'A candidate-bound PASS without a trusted AI attestation must not pass.'
        Assert-Match $unsignedAiResult.Output 'attestation|signature' 'Unsigned AI review evidence must fail at the attestation barrier.'

        $blockedAiFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'blocked-ai-review')
        $blockedAiAdapterSha = Get-StandardValidationFileSha256 -Path $blockedAiFixture.Adapter -Context 'test adapter'
        $blockedAiInventory = Get-StandardValidationInventory -Root $blockedAiFixture.Candidate -Context 'test candidate'
        $blockedAiContentSha = Get-StandardValidationInventorySha256 -Inventory $blockedAiInventory
        $blockedAiCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$blockedAiContentSha`n$blockedAiAdapterSha`n")
        $blockedAiEvidence = Join-Path $blockedAiFixture.Root 'ai-review.json'
        Write-TestUtf8File -Path $blockedAiEvidence -Text ([ordered]@{
                schemaVersion = 1
                evidenceType = 'ai-review'
                candidateId = $blockedAiCandidateId
                status = 'passed'
                decision = 'BLOCK'
                reviewedCandidate = $blockedAiCandidateId
                reviewFindings = @([ordered]@{ severity = 'high' })
                findingDisposition = @([ordered]@{ findingId = 'finding-1'; disposition = 'accepted' })
            } | ConvertTo-Json -Depth 10)
        $blockedAiResult = Invoke-RunnerFixture -Fixture $blockedAiFixture -CompleteLifecycle -AiReviewEvidencePath $blockedAiEvidence
        Assert-True ($blockedAiResult.Evidence.state -ne 'PASS') 'AI evidence with a BLOCK decision must not pass as lifecycle evidence.'

        $ambiguousInventoryFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'ambiguous-inventory')
        $ambiguousInventoryAdapterSha = Get-StandardValidationFileSha256 -Path $ambiguousInventoryFixture.Adapter -Context 'test adapter'
        $ambiguousInventory = Get-StandardValidationInventory -Root $ambiguousInventoryFixture.Candidate -Context 'test candidate'
        $ambiguousContentSha = Get-StandardValidationInventorySha256 -Inventory $ambiguousInventory
        $ambiguousCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$ambiguousContentSha`n$ambiguousInventoryAdapterSha`n")
        $ambiguousAiEvidence = Join-Path $ambiguousInventoryFixture.Root 'ai-review.json'
        $ambiguousHumanEvidence = Join-Path $ambiguousInventoryFixture.Root 'human-approval.json'
        $ambiguousPublishEvidence = Join-Path $ambiguousInventoryFixture.Root 'publish-install.json'
        $ambiguousPostEvidence = Join-Path $ambiguousInventoryFixture.Root 'post-install.json'
        $ambiguousRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        Write-TestAiReviewEvidence -Fixture $ambiguousInventoryFixture -Path $ambiguousAiEvidence -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa
        Write-TestHumanApprovalEvidence -Fixture $ambiguousInventoryFixture -Path $ambiguousHumanEvidence -CandidateId $ambiguousCandidateId
        try {
            Write-TestUtf8File -Path (Join-Path $ambiguousInventoryFixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $ambiguousRsa.ToXmlString($false)
            Write-TestLifecycleEvidence -Path $ambiguousPublishEvidence -EvidenceType 'publish-install' -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa
            Write-TestLifecycleEvidence -Path $ambiguousPostEvidence -EvidenceType 'post-install' -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa -InstalledInventory @('skill;alpha', 'skill', 'beta')
        }
        finally { $ambiguousRsa.Dispose() }
        $ambiguousResult = Invoke-RunnerFixture -Fixture $ambiguousInventoryFixture -CompleteLifecycle -AiReviewEvidencePath $ambiguousAiEvidence -HumanApprovalEvidencePath $ambiguousHumanEvidence -PublishInstallEvidencePath $ambiguousPublishEvidence -PostInstallEvidencePath $ambiguousPostEvidence
        Assert-Equal $ambiguousResult.Evidence.state 'PASS' 'Signed post-install inventory entries containing delimiters must remain unambiguous and verifiable.'

        $forgedFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'forged-human-approval')
        $forgedAdapterSha = Get-StandardValidationFileSha256 -Path $forgedFixture.Adapter -Context 'test adapter'
        $forgedInventory = Get-StandardValidationInventory -Root $forgedFixture.Candidate -Context 'test candidate'
        $forgedContentSha = Get-StandardValidationInventorySha256 -Inventory $forgedInventory
        $forgedCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$forgedContentSha`n$forgedAdapterSha`n")
        $forgedAiEvidence = Join-Path $forgedFixture.Root 'ai-review.json'
        $forgedHumanEvidence = Join-Path $forgedFixture.Root 'human-approval.json'
        Write-TestAiReviewEvidence -Fixture $forgedFixture -Path $forgedAiEvidence -CandidateId $forgedCandidateId
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
        Write-TestAiReviewEvidence -Fixture $tamperedFixture -Path $tamperedAiEvidence -CandidateId $tamperedCandidateId
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
        Write-TestAiReviewEvidence -Fixture $forgedLifecycleFixture -Path $forgedLifecycleAiEvidence -CandidateId $forgedLifecycleCandidateId
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
        $lifecycleRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        Write-TestAiReviewEvidence -Fixture $fullFixture -Path $fullAiEvidence -CandidateId $fullCandidateId -Rsa $lifecycleRsa
        Write-TestHumanApprovalEvidence -Fixture $fullFixture -Path $fullHumanEvidence -CandidateId $fullCandidateId
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
