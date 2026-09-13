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
                [ValidateSet('pass', 'static-fail', 'static-partial', 'package-fail', 'wrong-candidate', 'missing-output', 'timeout', 'snapshot-mutate', 'environment-leak', 'semantic-required', 'output-tamper', 'repository-missing-evidence', 'repository-zero-tests', 'repository-artifact-tamper')]
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
        foreach ($stageId in @('conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Match $releaseConditions ("stages\[[0-9]+\]\.id=$stageId-and-status=") "Release eligibility must bind the '$stageId' canonical stage."
        }
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
        Assert-Match $runnerSource 'unshare|--pid|--fork|--kill-child' 'Unix child execution must use a kernel-enforced PID namespace boundary.'
        Assert-Match $runnerSource 'Get-StandardValidationUnixPidNamespaceProcessIds|PidNamespaceRequired' 'Unix cleanup must verify the owned PID namespace is empty before passing an event.'
        Assert-Match $runnerSource 'EnvironmentVariables\.Clear\(\)' 'Child processes must not inherit the supervisor environment wholesale.'
        Assert-Match $runnerSource 'New-StandardValidationOutputReservation' 'The runner must reserve the final evidence path.'
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
        Assert-False ($runnerSource -match 'LD_LIBRARY_PATH') 'Dynamic loader overrides must not be inherited by child processes.'
        $reservationIndex = $runnerSource.IndexOf('$outputReservation = New-StandardValidationOutputReservation', [StringComparison]::Ordinal)
        $contractResolverIndex = $runnerSource.IndexOf('$contractResult = Assert-StandardValidationContractFiles', [StringComparison]::Ordinal)
        Assert-True ($reservationIndex -ge 0 -and $contractResolverIndex -ge 0 -and $reservationIndex -lt $contractResolverIndex) 'Final output reservation must precede authority contract resolver child processes.'
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

        $credentialFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'credentialed-source-repository')
        $credentialResult = Invoke-RunnerFixture `
            -Fixture $credentialFixture `
            -SourceRepository 'https://token@github.com/org/repo.git'
        Assert-Match $credentialResult.Output '"state"\s*:\s*"INVALID"' 'Source repositories with embedded credentials must be rejected before evidence construction.'
        $credentialEvidenceText = if ($null -eq $credentialResult.Evidence) { '' } else { $credentialResult.Evidence | ConvertTo-Json -Depth 20 -Compress }
        Assert-False (($credentialResult.Output + $credentialEvidenceText) -match 'token') 'Rejected source-repository credentials must never appear in output or evidence.'
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
