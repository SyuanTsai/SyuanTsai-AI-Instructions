Describe 'Standard semantic bridge core' {
    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:BridgeModulePath = Join-Path $script:RepositoryRoot 'scripts\StandardSemanticBridge.psm1'
        Import-Module $script:BridgeModulePath -Force

function Assert-TestCondition {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestErrorMessage {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action | Out-Null; return $null }
    catch { return [string]$_.Exception.Message }
}

function New-TestSemanticFixture {
    param([int] $ItemCount = 1)

    $now = [DateTime]::UtcNow.AddMinutes(-5)
    $items = New-Object System.Collections.Generic.List[object]
    [void]$items.Add([pscustomobject][ordered]@{ path = 'skills/example/SKILL.md'; contentKind = 'skill-instructions'; text = 'synthetic semantic bridge text' })
    if ($ItemCount -gt 1) {
        [void]$items.Add([pscustomobject][ordered]@{ path = 'skills/example/README.md'; contentKind = 'skill-instructions'; text = 'second synthetic semantic bridge text' })
    }
    $itemArray = @($items.ToArray())
    $scopePaths = @($itemArray | ForEach-Object { [string]$_.path })
    $bindings = [pscustomobject][ordered]@{
        candidate = [pscustomobject][ordered]@{
            candidateId = ('a' * 64)
            sourceRepository = 'https://example.test/source.git'
            sourceRevision = ('b' * 40)
            baseRevision = ('c' * 40)
            sourceTree = ('d' * 40)
            inputInventorySha256 = ('e' * 64)
        }
        authority = [pscustomobject][ordered]@{
            repository = 'https://example.test/authority.git'
            revision = ('f' * 40)
            tree = ('1' * 40)
            snapshotInventorySha256 = ('2' * 64)
        }
        tool = [pscustomobject][ordered]@{
            toolId = 'fixture-tool'
            version = '1.0.0'
            packageSha256 = ('3' * 64)
            resolverReceiptSha256 = ('4' * 64)
        }
        launch = [pscustomobject][ordered]@{
            resolutionRunId = '11111111-1111-4111-8111-111111111111'
            launchReceiptSha256 = ('5' * 64)
            consumptionSha256 = ('6' * 64)
        }
    }
    $route = [pscustomobject][ordered]@{
        provider = 'fixture-provider'
        adapter = 'fixture-adapter'
        accountOrTenant = 'fixture-account'
        model = 'fixture-model'
        endpoint = 'https://example.test/v1'
        dataRegion = 'fixture-region'
        retentionPolicy = 'fixture-no-retention'
        trainingPolicy = 'fixture-no-training'
    }
    $scope = [pscustomobject][ordered]@{
        description = 'Synthetic test-only semantic scope.'
        paths = $scopePaths
        contentKinds = @('skill-instructions')
    }
    $analyzers = @(
        [pscustomobject][ordered]@{ id = 'semantic_developer_intent'; version = '1.0.0'; sourceSha256 = ('7' * 64) }
        [pscustomobject][ordered]@{ id = 'semantic_security_discovery'; version = '1.0.0'; sourceSha256 = ('8' * 64) }
    )
    $inventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $itemArray
    $analyzerSet = New-StandardSemanticBridgeAnalyzerSet -Analyzers $analyzers
    $request = New-StandardSemanticBridgeConsentRequest `
        -Bindings $bindings `
        -ProviderRoute $route `
        -Purpose 'Synthetic test-only semantic review.' `
        -Scope $scope `
        -ProviderTextInventory $inventory `
        -AnalyzerSet $analyzerSet `
        -RequestId '11111111-1111-4111-8111-111111111112' `
        -RequestedAt $now `
        -ExpiresAt $now.AddHours(1)
    $authorizer = [pscustomobject][ordered]@{
        subject = 'fixture-authorizer'
        authorityScope = 'fixture-semantic-egress'
        authenticationContext = 'fixture-strong-authentication'
    }
    $decision = New-StandardSemanticBridgeConsentDecision `
        -Request $request `
        -Authorizer $authorizer `
        -DecisionId '11111111-1111-4111-8111-111111111113' `
        -AuthorizedAt $now.AddMinutes(1)

    # The RSA key lives only in this test process.  No private key is written to
    # a fixture, module, schema, or evidence artifact.
    # RSACryptoServiceProvider accepts the key size on Windows PowerShell 5,
    # where RSA.Create() exposes KeySize as read-only.
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $publicRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $publicRsa.ImportParameters($rsa.ExportParameters($false))
    $provider = {
        param($providerRequest, $callbackContext)
        $path = [string]$providerRequest.path
        if ($null -ne $callbackContext -and [string]$callbackContext.timeoutPath -ceq $path) {
            [Threading.Thread]::Sleep(3000)
        }
        $findings = @(
            [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
            [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
        )
        return [pscustomobject][ordered]@{ findings = $findings; analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery') }
    }
    $signer = {
        param($signerRequest, $callbackContext)
        $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
            $signature = $signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            return [pscustomobject][ordered]@{ keyId = 'fixture-key'; algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'; signature = [Convert]::ToBase64String($signature) }
        }
        finally { $signingKey.Dispose() }
    }

    return [pscustomobject][ordered]@{
        Now = $now
        Bindings = $bindings
        Route = $route
        Scope = $scope
        Items = $itemArray
        Analyzers = $analyzers
        Inventory = $inventory
        AnalyzerSet = $analyzerSet
        Request = $request
        Decision = $decision
        Authorizer = $authorizer
        Provider = $provider
        Signer = $signer
        ProviderContext = [pscustomobject][ordered]@{ timeoutPath = $null }
        SignerContext = [pscustomobject][ordered]@{ privateKeyXml = $rsa.ToXmlString($true) }
        Rsa = $rsa
        PublicRsa = $publicRsa
    }
}

function Invoke-TestSemanticBridge {
    param(
        [Parameter(Mandatory = $true)] $Fixture,
        $Bindings = $null,
        $ProviderRoute = $null,
        $Purpose = $null,
        $Scope = $null,
        $Items = $null,
        $Request = $null,
        $Decision = $null,
        $Ledger = $null,
        [DateTime] $Now = [DateTime]::MinValue,
        [scriptblock] $Provider = $null,
        [scriptblock] $Signer = $null,
        $ProviderContext = $null,
        $SignerContext = $null,
        [int] $TimeoutSeconds = 30
    )
    if ($null -eq $Bindings) { $Bindings = $Fixture.Bindings }
    if ($null -eq $ProviderRoute) { $ProviderRoute = $Fixture.Route }
    if ($null -eq $Purpose) { $Purpose = 'Synthetic test-only semantic review.' }
    if ($null -eq $Scope) { $Scope = $Fixture.Scope }
    if ($null -eq $Items) { $Items = $Fixture.Items }
    if ($null -eq $Request) { $Request = $Fixture.Request }
    if ($null -eq $Decision) { $Decision = $Fixture.Decision }
    if ($null -eq $Ledger) { $Ledger = @{} }
        if ($Now -eq [DateTime]::MinValue) { $Now = [DateTime]::UtcNow }
        if ($null -eq $Provider) { $Provider = $Fixture.Provider }
        if ($null -eq $Signer) { $Signer = $Fixture.Signer }
        if ($null -eq $ProviderContext) { $ProviderContext = $Fixture.ProviderContext }
        if ($null -eq $SignerContext) { $SignerContext = $Fixture.SignerContext }
    return Invoke-StandardSemanticBridge `
        -ConsentRequest $Request `
        -ConsentDecision $Decision `
        -Bindings $Bindings `
        -ProviderRoute $ProviderRoute `
        -Purpose $Purpose `
        -Scope $Scope `
        -TextItems @($Items) `
        -Analyzers $Fixture.Analyzers `
        -ProviderCallback $Provider `
        -SignerCallback $Signer `
        -ExpectedSignerPublicKey $Fixture.PublicRsa `
        -ExpectedSignerKeyId 'fixture-key' `
        -ProviderCallbackContext $ProviderContext `
        -SignerCallbackContext $SignerContext `
        -IdempotencyLedger $Ledger `
        -TimeoutSeconds $TimeoutSeconds `
        -Now $Now
}

function Get-TestEvidenceBytesWithSignatureMutation {
    param([Parameter(Mandatory = $true)] $EvidenceBytes)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $evidence = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$EvidenceBytes)
    $signature = [string]$evidence.attestation.signature
    $replacement = if ($signature[0] -eq 'A') { 'B' } else { 'A' }
    $evidence.attestation.signature = $replacement + $signature.Substring(1)
    return $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
}

function Get-TestOrdinallySortedSemanticFindings {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()] $Findings)

    $sorted = New-Object System.Collections.Generic.List[object]
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($finding in @($Findings)) {
        $key = [string]$finding.analyzerId + [char]0 + [string]$finding.ruleId + [char]0 + [string]$finding.fingerprint + [char]0 + [string]$finding.path + [char]0 + [string]$finding.severity + [char]0 + [string]$finding.message
        $index = 0
        while ($index -lt $keys.Count -and [string]::CompareOrdinal($keys[$index], $key) -le 0) { $index++ }
        $keys.Insert($index, $key)
        $sorted.Insert($index, $finding)
    }
    return @($sorted.ToArray())
}

function Get-TestOrdinallySortedSemanticLedgerEntries {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()] $Entries)

    $sorted = New-Object System.Collections.Generic.List[object]
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries)) {
        $key = [string]$entry.idempotencyKey
        $index = 0
        while ($index -lt $keys.Count -and [string]::CompareOrdinal($keys[$index], $key) -le 0) { $index++ }
        $keys.Insert($index, $key)
        $sorted.Insert($index, $entry)
    }
    return @($sorted.ToArray())
}

function Update-TestEvidenceExecutionDigests {
    param([Parameter(Mandatory = $true)] $Evidence)

    $execution = $Evidence.execution
    $Evidence.findings = @(Get-TestOrdinallySortedSemanticFindings -Findings @($Evidence.findings))
    $execution.findingsSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact @($Evidence.findings)
    foreach ($record in @($execution.providerCalls)) {
        $findingsForPath = @(Get-TestOrdinallySortedSemanticFindings -Findings @($Evidence.findings | Where-Object { [string]$_.path -ceq [string]$record.path }))
        $record.findingsSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $findingsForPath
        $response = [pscustomobject][ordered]@{
            findings = $findingsForPath
            analyzerCoverage = @(Get-TestOrdinallySortedSemanticAnalyzerIds -Values @($record.analyzerCoverage))
        }
        $record.responseSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $response
    }
    $normalizedRecords = @(
        foreach ($record in @($execution.providerCalls)) {
            [pscustomobject][ordered]@{
                workItemId = [string]$record.workItemId
                index = [int]$record.index
                idempotencyKey = [string]$record.idempotencyKey
                path = [string]$record.path
                contentKind = [string]$record.contentKind
                textSha256 = [string]$record.textSha256
                byteCount = [int64]$record.byteCount
                analyzerSetIdentity = [string]$record.analyzerSetIdentity
                plannedAnalyzerIds = @($record.plannedAnalyzerIds)
                analyzerCoverage = @($record.analyzerCoverage)
                requestSha256 = [string]$record.requestSha256
                responseSha256 = [string]$record.responseSha256
                findingsSha256 = [string]$record.findingsSha256
                status = [string]$record.status
            }
        }
    )
    $rawGraphRecords = @(
        foreach ($record in @($execution.providerCalls)) {
            [pscustomobject][ordered]@{ idempotencyKey = [string]$record.idempotencyKey; graphSha256 = [string]$record.responseSha256 }
        }
    )
    $rawFindingRecords = @(
        foreach ($record in @($execution.providerCalls)) {
            [pscustomobject][ordered]@{ idempotencyKey = [string]$record.idempotencyKey; findingsSha256 = [string]$record.findingsSha256 }
        }
    )
    $sortedNormalizedRecords = @(Get-TestOrdinallySortedSemanticLedgerEntries -Entries $normalizedRecords)
    $sortedRawGraphRecords = @(Get-TestOrdinallySortedSemanticLedgerEntries -Entries $rawGraphRecords)
    $sortedRawFindingRecords = @(Get-TestOrdinallySortedSemanticLedgerEntries -Entries $rawFindingRecords)
    $execution.providerCallLedgerSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $sortedNormalizedRecords
    $execution.rawGraphLedgerSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $sortedRawGraphRecords
    $execution.rawFindingsLedgerSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $sortedRawFindingRecords
}

function Get-TestOrdinallySortedSemanticAnalyzerIds {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Values)

    $sorted = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $index = 0
        while ($index -lt $sorted.Count -and [string]::CompareOrdinal($sorted[$index], [string]$value) -le 0) { $index++ }
        $sorted.Insert($index, [string]$value)
    }
    return @($sorted.ToArray())
}

function Get-TestResignedEvidenceBytes {
    param(
        [Parameter(Mandatory = $true)] $EvidenceBytes,
        [Parameter(Mandatory = $true)] $Fixture,
        [Parameter(Mandatory = $true)][scriptblock] $Mutation
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $evidence = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$EvidenceBytes)
    $null = & $Mutation $evidence
    $unsigned = [ordered]@{}
    foreach ($property in @($evidence.PSObject.Properties | Where-Object { $_.Name -ne 'attestation' })) { $unsigned[$property.Name] = $property.Value }
    $unsignedBytes = $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value ([pscustomobject]$unsigned)))
    $evidence.attestation.signedPayloadSha256 = Get-TestSha256Bytes -Bytes $unsignedBytes
    $evidence.attestation.signature = [Convert]::ToBase64String($Fixture.Rsa.SignData($unsignedBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    return $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
}

function Get-TestSha256Bytes {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TestEvidenceBytesWithSignatureWhitespace {
    param([Parameter(Mandatory = $true)] $EvidenceBytes)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $evidence = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$EvidenceBytes)
    $signature = [string]$evidence.attestation.signature
    $evidence.attestation.signature = $signature.Substring(0, 1) + ' ' + $signature.Substring(1)
    return $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
}

function Get-TestNonCanonicalBase64PadBits {
    param([Parameter(Mandatory = $true)][string] $Text)
    if (-not $Text.EndsWith('==', [StringComparison]::Ordinal)) { throw 'The test signature did not use == padding.' }
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $chars = $Text.ToCharArray()
    $lastDataSextet = $alphabet.IndexOf($chars[$chars.Length - 3])
    if ($lastDataSextet -lt 0 -or ($lastDataSextet % 16) -ne 0 -or $lastDataSextet -ge 64) {
        throw "The test signature did not have canonical pad bits: $lastDataSextet"
    }
    $chars[$chars.Length - 3] = $alphabet[$lastDataSextet + 1]
    $mutated = -join $chars
    $decoded = [Convert]::FromBase64String($mutated)
    if ([Convert]::ToBase64String($decoded) -cne $Text -or [Convert]::ToBase64String($decoded) -ceq $mutated) {
        throw 'The test signature pad-bit mutation did not preserve decoded bytes while changing canonical encoding.'
    }
    return $mutated
}

function Get-TestEvidenceBytesWithSignatureNonCanonicalPadBits {
    param([Parameter(Mandatory = $true)] $EvidenceBytes)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $evidence = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$EvidenceBytes)
    $evidence.attestation.signature = Get-TestNonCanonicalBase64PadBits -Text ([string]$evidence.attestation.signature)
    return $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
}

function Update-TestConsentDigests {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] $Decision
    )

    $requestPayload = [ordered]@{}
    foreach ($property in @($Request.PSObject.Properties | Where-Object { $_.Name -ne 'consentPayloadSha256' })) { $requestPayload[$property.Name] = $property.Value }
    $Request.consentPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$requestPayload)
    $Decision.consentRequestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $Request
    $decisionPayload = [ordered]@{}
    foreach ($property in @($Decision.PSObject.Properties | Where-Object { $_.Name -ne 'consentDecisionPayloadSha256' })) { $decisionPayload[$property.Name] = $property.Value }
    $Decision.consentDecisionPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$decisionPayload)
}

    }

    # Scenario: Analyzer entries arrive in a different order and include an exact duplicate ID.
    # Purpose: The bridge must expose one deterministic analyzer-set identity and reject ambiguous IDs.
    It 'UnitT10_canonicalizes_analyzer_set_identity_and_rejects_duplicate_ids' {
        $analyzers = @(
            [pscustomobject][ordered]@{ id = 'zeta'; version = '1.0'; sourceSha256 = ('b' * 64) }
            [pscustomobject][ordered]@{ id = 'alpha'; version = '1.0'; sourceSha256 = ('a' * 64) }
        )
        $identity = Get-StandardSemanticAnalyzerSetIdentity -Analyzers $analyzers
        Assert-TestCondition ($identity -match '^semantic-analyzer-set-v1:[0-9a-f]{64}$') 'Analyzer-set identity format is invalid.'
        Assert-TestCondition ($identity -ceq ('semantic-analyzer-set-v1:' + (Get-StandardSemanticBridgeArtifactSha256 -Artifact @('alpha@1.0', 'zeta@1.0')))) 'Analyzer-set identity is not deterministic.'
        $errorMessage = Get-TestErrorMessage {
            Get-StandardSemanticAnalyzerSetIdentity -Analyzers @($analyzers + @([pscustomobject][ordered]@{ id = 'alpha'; version = '2.0'; sourceSha256 = ('c' * 64) }))
        }
        Assert-TestCondition ($errorMessage -match 'duplicate analyzer ID') 'Duplicate analyzer IDs were not rejected.'
        Assert-TestCondition ((Get-StandardSemanticBridgeCanonicalJson -Value @('alpha@1.0', 'zeta@1.0')) -ceq '["alpha@1.0","zeta@1.0"]') 'Analyzer identity JSON is not canonical.'
    }

    # Scenario: A valid inventory, typed consent, mock provider, and ephemeral RSA signer complete one run.
    # Purpose: The local bridge must execute inventory -> consent verification -> provider -> signed evidence.
    It 'InterT20_happy_path_returns_evidence_bytes_verified_by_explicit_public_key' {
        $fixture = New-TestSemanticFixture
        $invocationStartedAt = [DateTime]::UtcNow
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Now $fixture.Now.AddMinutes(2)
        $invocationCompletedAt = [DateTime]::UtcNow
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "The happy-path bridge run did not pass: $($run.reason)"
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The happy-path provider call count changed.'
        Assert-TestCondition ([int]$run.successfulProviderCallCount -eq 1) 'The happy-path successful call count changed.'
        Assert-TestCondition (@($run.evidenceBytes).Count -gt 0) 'The happy-path bridge emitted no evidence bytes.'
        Assert-TestCondition ([int]$run.evidence.execution.plannedWorkItemCount -eq [int]$fixture.Inventory.fileCount) 'The evidence execution count is not inventory-bound.'
        $generatedAt = [DateTime]::Parse([string]$run.evidence.generatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Assert-TestCondition ($generatedAt -ge $invocationStartedAt.AddSeconds(-1) -and $generatedAt -le $invocationCompletedAt.AddSeconds(1)) 'The evidence generatedAt timestamp did not reflect the actual bridge invocation.'
        Assert-TestCondition ([string]$run.evidence.attestation.issuedAt -ceq [string]$run.evidence.generatedAt) 'The signer attestation issuedAt timestamp diverged from generatedAt.'
        Assert-TestCondition (@($run.evidence.execution.providerCalls).Count -eq 1) 'The evidence omitted the concrete provider-call ledger row.'
        Assert-TestCondition ([string]$run.evidence.execution.providerCalls[0].path -ceq 'skills/example/SKILL.md') 'The concrete provider-call ledger row lost its inventory path.'
        Assert-TestCondition (@($run.evidence.execution.providerCalls[0].plannedAnalyzerIds).Count -eq 2 -and @($run.evidence.execution.providerCalls[0].analyzerCoverage).Count -eq 2) 'The concrete provider-call ledger row lost per-work-item analyzer coverage.'
        $replay = @{}
        $verification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes `
            -ConsentRequest $fixture.Request `
            -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa `
            -ExpectedKeyId 'fixture-key' `
            -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route `
            -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope `
            -ExpectedProviderTextInventory $fixture.Inventory `
            -Now ([DateTime]::UtcNow) `
            -ReplayLedger $replay
        Assert-TestCondition ([bool]$verification.valid) 'The explicit public key did not verify the happy-path evidence.'
        Assert-TestCondition ([string]$verification.evidenceSha256 -ceq [string]$run.evidenceSha256) 'The verified evidence digest changed.'
        Assert-TestCondition ($replay.Count -eq 1) 'The verifier did not record the consumed evidence ID.'
    }

    # Scenario: The parent process contains an unrelated secret while both isolated callback paths execute.
    # Purpose: Provider and signer callbacks must start with only the minimal PowerShell OS/runtime environment.
    It 'InterT25_provider_and_signer_callbacks_do_not_inherit_parent_secrets' {
        $fixture = New-TestSemanticFixture
        $secretName = 'SYP154_CALLBACK_INHERITED_SECRET'
        $previousSecret = [Environment]::GetEnvironmentVariable($secretName, [EnvironmentVariableTarget]::Process)
        $provider = {
            param($providerRequest, $callbackContext)
            $inherited = [Environment]::GetEnvironmentVariable(
                [string]$callbackContext.secretName,
                [EnvironmentVariableTarget]::Process
            )
            if (-not [string]::IsNullOrWhiteSpace($inherited)) {
                throw 'provider callback inherited a parent secret.'
            }
            $path = [string]$providerRequest.path
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $signer = {
            param($signerRequest, $callbackContext)
            $inherited = [Environment]::GetEnvironmentVariable(
                [string]$callbackContext.secretName,
                [EnvironmentVariableTarget]::Process
            )
            if (-not [string]::IsNullOrWhiteSpace($inherited)) {
                throw 'signer callback inherited a parent secret.'
            }
            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                $signature = $signingKey.SignData(
                    [byte[]]$signerRequest.payloadBytes,
                    [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1
                )
                return [pscustomobject][ordered]@{
                    keyId = 'fixture-key'
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = [Convert]::ToBase64String($signature)
                }
            }
            finally { $signingKey.Dispose() }
        }
        [Environment]::SetEnvironmentVariable($secretName, 'parent-secret-must-not-cross-callback-boundary', [EnvironmentVariableTarget]::Process)
        try {
            $run = Invoke-TestSemanticBridge `
                -Fixture $fixture `
                -Provider $provider `
                -Signer $signer `
                -ProviderContext ([pscustomobject][ordered]@{ secretName = $secretName }) `
                -SignerContext ([pscustomobject][ordered]@{ secretName = $secretName; privateKeyXml = $fixture.Rsa.ToXmlString($true) })
        }
        finally {
            [Environment]::SetEnvironmentVariable($secretName, $previousSecret, [EnvironmentVariableTarget]::Process)
        }
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "Callbacks inherited parent environment or otherwise failed: $($run.reason)"
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The provider callback regression did not execute exactly once.'
        Assert-TestCondition ($null -ne $run.evidenceBytes) 'The signer callback regression emitted no evidence.'
    }

    # Scenario: Consent is absent in substance, expired, or the current route is no longer consent-bound.
    # Purpose: No provider callback may occur before every consent condition passes.
    Context 'UnitT30 consent expiry behavior' {
    It 'UnitT30_missing_expired_or_mismatched_consent_has_zero_provider_calls' {
        $fixture = New-TestSemanticFixture
        $fixture.Decision.consentGranted = $false
        $missing = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$missing.status -ceq 'BLOCKED') 'Missing consent did not block the bridge.'
        Assert-TestCondition ([int]$missing.providerCallCount -eq 0) 'Missing consent reached the provider.'

        $fixture = New-TestSemanticFixture
        $expired = Invoke-TestSemanticBridge -Fixture $fixture -Now $fixture.Now.AddHours(2)
        Assert-TestCondition ([string]$expired.status -ceq 'BLOCKED') 'Expired consent did not block the bridge.'
        Assert-TestCondition ([int]$expired.providerCallCount -eq 0) 'Expired consent reached the provider.'

        $fixture = New-TestSemanticFixture
        $actualUtcNow = [DateTime]::UtcNow
        $backdatedRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111124' `
            -RequestedAt $actualUtcNow.AddMinutes(-5) -ExpiresAt $actualUtcNow.AddMinutes(-2)
        $backdatedDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $backdatedRequest -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111125' -AuthorizedAt $actualUtcNow.AddMinutes(-4)
        $backdatedNow = $actualUtcNow.AddMinutes(-3)
        $backdatedExpiredRun = Invoke-TestSemanticBridge -Fixture $fixture -Request $backdatedRequest -Decision $backdatedDecision -Now $backdatedNow
        Assert-TestCondition ([string]$backdatedExpiredRun.status -ceq 'BLOCKED') 'A backdated Now value reopened consent already expired by wall-clock UTC.'
        Assert-TestCondition ([int]$backdatedExpiredRun.providerCallCount -eq 0) 'Backdated Now released provider egress for expired consent.'
        Assert-TestCondition ($null -eq $backdatedExpiredRun.evidenceBytes) 'Backdated Now caused expired consent to emit evidence.'

        $fixture = New-TestSemanticFixture -ItemCount 2
        $consentStartedAt = [DateTime]::UtcNow
        $shortRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111120' `
            -RequestedAt $consentStartedAt.AddSeconds(-1) -ExpiresAt $consentStartedAt.AddSeconds(4)
        $shortDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $shortRequest -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111121' -AuthorizedAt $consentStartedAt
        $providerLog = Join-Path $TestDrive 'expired-provider-call-log.txt'
        $slowFirstProvider = {
            param($providerRequest, $callbackContext)
            $priorCalls = if ([IO.File]::Exists([string]$callbackContext.callLogPath)) { [IO.File]::ReadAllLines([string]$callbackContext.callLogPath).Length } else { 0 }
            [IO.File]::AppendAllText([string]$callbackContext.callLogPath, [string]$providerRequest.path + [Environment]::NewLine)
            if ($priorCalls -eq 0) { [Threading.Thread]::Sleep([int]$callbackContext.firstCallDelayMilliseconds) }
            $path = [string]$providerRequest.path
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "expiry-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "expiry-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $expiredDuringInventory = Invoke-TestSemanticBridge `
            -Fixture $fixture -Request $shortRequest -Decision $shortDecision `
            -Provider $slowFirstProvider `
            -ProviderContext ([pscustomobject][ordered]@{ callLogPath = $providerLog; firstCallDelayMilliseconds = 6000 }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        Assert-TestCondition ([string]$expiredDuringInventory.status -ceq 'BLOCKED') 'Consent that expired during the first provider callback did not block the remaining inventory.'
        Assert-TestCondition ([int]$expiredDuringInventory.providerCallCount -eq 1) 'A second provider callback was released after consent expired.'
        Assert-TestCondition (@(Get-Content -LiteralPath $providerLog).Count -eq 1) 'The provider call log showed egress for more than the first item after expiry.'
        Assert-TestCondition ($null -eq $expiredDuringInventory.evidenceBytes) 'Expired inventory consent emitted signed evidence.'

        $fixture = New-TestSemanticFixture
        $consentStartedAt = [DateTime]::UtcNow
        $shortRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111122' `
            -RequestedAt $consentStartedAt.AddSeconds(-1) -ExpiresAt $consentStartedAt.AddSeconds(4)
        $shortDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $shortRequest -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111123' -AuthorizedAt $consentStartedAt
        $signerMarker = Join-Path $TestDrive 'expired-signer-was-called.txt'
        $slowProviderLog = Join-Path $TestDrive 'expired-before-signer-provider-log.txt'
        $expiredBeforeSignerSigner = {
            param($signerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, 'invoked')
            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                return [pscustomobject][ordered]@{
                    keyId = 'fixture-key'
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = [Convert]::ToBase64String($signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
                }
            }
            finally { $signingKey.Dispose() }
        }
        $expiredBeforeSigner = Invoke-TestSemanticBridge `
            -Fixture $fixture -Request $shortRequest -Decision $shortDecision `
            -Provider $slowFirstProvider `
            -ProviderContext ([pscustomobject][ordered]@{ callLogPath = $slowProviderLog; firstCallDelayMilliseconds = 6000 }) `
            -Signer $expiredBeforeSignerSigner `
            -SignerContext ([pscustomobject][ordered]@{ markerPath = $signerMarker; privateKeyXml = $fixture.Rsa.ToXmlString($true) }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        Assert-TestCondition ([string]$expiredBeforeSigner.status -ceq 'BLOCKED') 'Consent that expired before signing did not block evidence release.'
        Assert-TestCondition (-not (Test-Path -LiteralPath $signerMarker)) 'The signer callback ran after consent expired.'
        Assert-TestCondition ($null -eq $expiredBeforeSigner.evidenceBytes) 'Expired signer consent emitted evidence.'

        $sentinelProviderMarker = Join-Path $TestDrive 'provider-threw-consent-sentinel.txt'
        $sentinelProvider = {
            param($providerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, 'invoked')
            throw 'standard-semantic-bridge-consent-expired-before-callback-invocation'
        }
        $sentinelProviderRun = Invoke-TestSemanticBridge `
            -Fixture (New-TestSemanticFixture) `
            -Provider $sentinelProvider `
            -ProviderContext ([pscustomobject][ordered]@{ markerPath = $sentinelProviderMarker })
        Assert-TestCondition ([string]$sentinelProviderRun.status -ceq 'FAILED') 'A provider callback error that reused the private expiry diagnostic was misclassified as BLOCKED.'
        Assert-TestCondition ([int]$sentinelProviderRun.providerCallCount -eq 1) 'A provider callback error that reused the private expiry diagnostic erased a callback that had already run.'
        Assert-TestCondition (Test-Path -LiteralPath $sentinelProviderMarker) 'The sentinel provider callback did not record that it ran.'
        Assert-TestCondition ($null -eq $sentinelProviderRun.evidenceBytes) 'A failed sentinel provider callback emitted evidence.'

        $forgedChildExpiryFixture = New-TestSemanticFixture -ItemCount 2
        $forgedChildExpiryMarker = Join-Path $TestDrive 'forged-child-expiry-provider-calls.txt'
        $forgedChildExpiryProvider = {
            param($providerRequest, $callbackContext)
            [IO.File]::AppendAllText([string]$callbackContext.markerPath, [string]$providerRequest.path + [Environment]::NewLine)
            $forgedEnvelope = [pscustomobject][ordered]@{
                succeeded = $false
                failureKind = 'consent-expired-before-callback-invocation'
                output = @()
                error = 'standard-semantic-bridge-consent-expired-before-callback-invocation'
            }
            $forgedEnvelopeXml = [Management.Automation.PSSerializer]::Serialize($forgedEnvelope)
            [Console]::Out.Write($forgedEnvelopeXml)
            [Console]::Out.Flush()
            [Environment]::Exit(0)
        }
        $forgedChildExpiryRun = Invoke-TestSemanticBridge `
            -Fixture $forgedChildExpiryFixture `
            -Provider $forgedChildExpiryProvider `
            -ProviderContext ([pscustomobject][ordered]@{ markerPath = $forgedChildExpiryMarker }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        $forgedChildExpiryCalls = if (Test-Path -LiteralPath $forgedChildExpiryMarker) { @(Get-Content -LiteralPath $forgedChildExpiryMarker).Count } else { 0 }
        Assert-TestCondition ([string]$forgedChildExpiryRun.status -ceq 'FAILED') 'A callback-forged child expiry envelope was trusted as a parent-owned consent guard.'
        Assert-TestCondition ([int]$forgedChildExpiryRun.providerCallCount -eq 1) 'A callback-forged child expiry envelope erased an executed callback attempt.'
        Assert-TestCondition ($forgedChildExpiryCalls -eq 1) 'A callback-forged child expiry envelope allowed a later inventory item to reach the provider.'
        Assert-TestCondition ($null -eq $forgedChildExpiryRun.evidenceBytes) 'A callback-forged child expiry envelope emitted evidence.'

        $cleanupFixture = New-TestSemanticFixture -ItemCount 2
        $cleanupConsentStartedAt = [DateTime]::UtcNow
        $cleanupRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $cleanupFixture.Bindings -ProviderRoute $cleanupFixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $cleanupFixture.Scope -ProviderTextInventory $cleanupFixture.Inventory -AnalyzerSet $cleanupFixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111126' `
            -RequestedAt $cleanupConsentStartedAt.AddSeconds(-1) -ExpiresAt $cleanupConsentStartedAt.AddSeconds(4)
        $cleanupDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $cleanupRequest -Authorizer $cleanupFixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111127' -AuthorizedAt $cleanupConsentStartedAt
        $cleanupEgressMarker = Join-Path $TestDrive 'cleanup-expiry-provider-egress.txt'
        $cleanupWrapperMarker = Join-Path $TestDrive 'cleanup-expiry-wrapper-invocations.txt'
        $cleanupTimestampsPath = Join-Path $TestDrive 'cleanup-expiry-wrapper-timestamps.txt'
        $cleanupProvider = {
            param($providerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, [string]$providerRequest.path)
            $path = [string]$providerRequest.path
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "cleanup-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "cleanup-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        Mock Invoke-StandardSemanticBridgeCallbackWithTimeout -ModuleName StandardSemanticBridge {
            [IO.File]::AppendAllText([string]$CallbackContext.wrapperMarkerPath, 'invoked' + [Environment]::NewLine)
            $enteredUtc = [DateTime]::UtcNow
            $testExpiryUtc = [DateTime]::Parse(
                [string]$ConsentExpiresAt,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            [IO.File]::WriteAllText([string]$CallbackContext.timestampPath, $enteredUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) + [Environment]::NewLine + $testExpiryUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) + [Environment]::NewLine)
            while ([DateTime]::UtcNow -lt $testExpiryUtc) { Start-Sleep -Milliseconds 25 }
            $expiredUtc = [DateTime]::UtcNow
            [IO.File]::AppendAllText([string]$CallbackContext.timestampPath, $expiredUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture))
            $exception = [InvalidOperationException]::new('standard-semantic-bridge-consent-expired-before-callback-invocation')
            $exception.Data['CallbackCleanupError'] = 'test-injected callback cleanup failure'
            if ([bool]$CallbackContext.attachExpiryGuardMarker) {
                $exception.Data['StandardSemanticBridge.InternalFailureKind'] = 'ConsentExpiredBeforeCallbackInvocation'
            }
            throw $exception
        }
        $cleanupFailureRun = Invoke-TestSemanticBridge `
            -Fixture $cleanupFixture -Request $cleanupRequest -Decision $cleanupDecision `
            -Provider $cleanupProvider `
            -ProviderContext ([pscustomobject][ordered]@{ markerPath = $cleanupEgressMarker; wrapperMarkerPath = $cleanupWrapperMarker; timestampPath = $cleanupTimestampsPath; attachExpiryGuardMarker = $false }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        $cleanupWrapperInvocations = if (Test-Path -LiteralPath $cleanupWrapperMarker) { @(Get-Content -LiteralPath $cleanupWrapperMarker).Count } else { 0 }
        $cleanupTimestamps = @(Get-Content -LiteralPath $cleanupTimestampsPath)
        $cleanupEnteredUtc = [DateTime]::Parse([string]$cleanupTimestamps[0], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $cleanupExpiresUtc = [DateTime]::Parse([string]$cleanupTimestamps[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $cleanupObservedExpiredUtc = [DateTime]::Parse([string]$cleanupTimestamps[2], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        Assert-TestCondition ($cleanupWrapperInvocations -eq 1) 'Cleanup regression did not intercept exactly the first callback wrapper invocation.'
        Assert-TestCondition ($cleanupEnteredUtc -lt $cleanupExpiresUtc -and $cleanupExpiresUtc -le $cleanupObservedExpiredUtc) 'The cleanup-only callback mock did not enter before consent expiry and complete after expiry.'
        Assert-TestCondition ([string]$cleanupFailureRun.status -ceq 'FAILED') 'Provider cleanup failure accompanying expired consent was hidden by a later clean BLOCKED result.'
        Assert-TestCondition ([string]$cleanupFailureRun.reason -match 'test-injected callback cleanup failure') 'Terminal provider cleanup failure omitted its diagnostic.'
        Assert-TestCondition ([int]$cleanupFailureRun.providerCallCount -eq 1) 'Cleanup-only failure changed the attempted provider-call count.'
        Assert-TestCondition ([int]$cleanupFailureRun.successfulProviderCallCount -eq 0) 'Provider cleanup failure recorded a successful callback.'
        Assert-TestCondition (-not (Test-Path -LiteralPath $cleanupEgressMarker)) 'The provider callback received text after the test expiry guard.'
        Assert-TestCondition ($null -eq $cleanupFailureRun.evidenceBytes) 'Provider cleanup failure emitted evidence.'

        $guardCleanupFixture = New-TestSemanticFixture -ItemCount 2
        $guardCleanupStartedAt = [DateTime]::UtcNow
        $guardCleanupRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $guardCleanupFixture.Bindings -ProviderRoute $guardCleanupFixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $guardCleanupFixture.Scope -ProviderTextInventory $guardCleanupFixture.Inventory -AnalyzerSet $guardCleanupFixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111128' `
            -RequestedAt $guardCleanupStartedAt.AddSeconds(-1) -ExpiresAt $guardCleanupStartedAt.AddSeconds(4)
        $guardCleanupDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $guardCleanupRequest -Authorizer $guardCleanupFixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111129' -AuthorizedAt $guardCleanupStartedAt
        $guardCleanupEgressMarker = Join-Path $TestDrive 'guard-cleanup-expiry-provider-egress.txt'
        $guardCleanupWrapperMarker = Join-Path $TestDrive 'guard-cleanup-expiry-wrapper-invocations.txt'
        $guardCleanupTimestampsPath = Join-Path $TestDrive 'guard-cleanup-expiry-wrapper-timestamps.txt'
        $guardAndCleanupFailureRun = Invoke-TestSemanticBridge `
            -Fixture $guardCleanupFixture -Request $guardCleanupRequest -Decision $guardCleanupDecision `
            -Provider $cleanupProvider `
            -ProviderContext ([pscustomobject][ordered]@{ markerPath = $guardCleanupEgressMarker; wrapperMarkerPath = $guardCleanupWrapperMarker; timestampPath = $guardCleanupTimestampsPath; attachExpiryGuardMarker = $true }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        $guardCleanupWrapperInvocations = if (Test-Path -LiteralPath $guardCleanupWrapperMarker) { @(Get-Content -LiteralPath $guardCleanupWrapperMarker).Count } else { 0 }
        $guardCleanupTimestamps = @(Get-Content -LiteralPath $guardCleanupTimestampsPath)
        $guardCleanupEnteredUtc = [DateTime]::Parse([string]$guardCleanupTimestamps[0], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $guardCleanupExpiresUtc = [DateTime]::Parse([string]$guardCleanupTimestamps[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $guardCleanupObservedExpiredUtc = [DateTime]::Parse([string]$guardCleanupTimestamps[2], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        Assert-TestCondition ($guardCleanupWrapperInvocations -eq 1) 'Guard-plus-cleanup regression did not intercept exactly the first callback wrapper invocation.'
        Assert-TestCondition ($guardCleanupEnteredUtc -lt $guardCleanupExpiresUtc -and $guardCleanupExpiresUtc -le $guardCleanupObservedExpiredUtc) 'The guard-plus-cleanup callback mock did not enter before consent expiry and complete after expiry.'
        Assert-TestCondition ([string]$guardAndCleanupFailureRun.status -ceq 'FAILED') 'Cleanup did not take precedence over a simultaneous parent expiry marker.'
        Assert-TestCondition ([string]$guardAndCleanupFailureRun.reason -match 'test-injected callback cleanup failure') 'Guard-plus-cleanup failure omitted its cleanup diagnostic.'
        Assert-TestCondition ([int]$guardAndCleanupFailureRun.providerCallCount -eq 0) 'Guard-plus-cleanup failure counted a callback that did not receive text.'
        Assert-TestCondition ([int]$guardAndCleanupFailureRun.successfulProviderCallCount -eq 0) 'Guard-plus-cleanup failure recorded a successful callback.'
        Assert-TestCondition (-not (Test-Path -LiteralPath $guardCleanupEgressMarker)) 'The provider callback received text after parent expiry.'
        Assert-TestCondition ($null -eq $guardAndCleanupFailureRun.evidenceBytes) 'Guard-plus-cleanup failure emitted evidence.'

        $fixture = New-TestSemanticFixture
        $routeDrift = ConvertFrom-Json -InputObject ($fixture.Route | ConvertTo-Json -Depth 20)
        $routeDrift.model = 'different-fixture-model'
        $mismatched = Invoke-TestSemanticBridge -Fixture $fixture -ProviderRoute $routeDrift
        Assert-TestCondition ([string]$mismatched.status -ceq 'BLOCKED') 'Mismatched consent did not block the bridge.'
        Assert-TestCondition ([int]$mismatched.providerCallCount -eq 0) 'Mismatched consent reached the provider.'
    }

    }

    Context 'UnitT31 signer consent expiry behavior' {
    It 'UnitT31_consent_expiry_during_signer_blocks_signed_output' {
        $fixture = New-TestSemanticFixture
        $slowSignerMarker = Join-Path $TestDrive 'consent-expired-during-signer.txt'
        $slowSignerTimestampsPath = Join-Path $TestDrive 'consent-expired-during-signer-timestamps.txt'
        $slowSignerCompletedMarker = Join-Path $TestDrive 'consent-expired-during-signer-signature-completed.txt'
        $clockObservationsPath = Join-Path $TestDrive 'consent-expired-during-signer-clock-observations.txt'
        $slowSigner = {
            param($signerRequest, $callbackContext)
            $expiresAtUtc = [DateTime]::Parse(
                [string]$callbackContext.expiresAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            $enteredAtUtc = [DateTime]::UtcNow
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, $enteredAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture))
            if ($enteredAtUtc -ge $expiresAtUtc) { throw 'test signer callback entered after consent expiry.' }

            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                $signature = [Convert]::ToBase64String($signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
                $signedAtUtc = [DateTime]::UtcNow
                $signatureBytes = [Convert]::FromBase64String($signature)
                if (-not $signingKey.VerifyData([byte[]]$signerRequest.payloadBytes, $signatureBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
                    throw 'test signer callback did not produce a verifiable signature.'
                }
                [IO.File]::WriteAllText(
                    [string]$callbackContext.timestampsPath,
                    @(
                        $enteredAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                        $expiresAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                        $signedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    ) -join [Environment]::NewLine
                )
                [IO.File]::WriteAllText([string]$callbackContext.signatureCompletedMarkerPath, 'signature-verified')
                return [pscustomobject][ordered]@{
                    keyId = 'fixture-key'
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = $signature
                }
            }
            finally { $signingKey.Dispose() }
        }

        # Test the parent consent state machine with a module-private clock
        # override. Consent remains an hour ahead of real time, so the actual
        # signer child process enforces its real-clock expiry guard and completes
        # before the final parent clock sample simulates consent expiry.
        $consentStartedAt = [DateTime]::UtcNow
        $consentExpiresAt = $consentStartedAt.AddHours(1)
        $clockState = [pscustomobject][ordered]@{
            activeUtc = $consentStartedAt
            expiredUtc = $consentExpiresAt.AddTicks(1)
            signatureCompletedMarkerPath = $slowSignerCompletedMarker
            observationsPath = $clockObservationsPath
        }
        $bridgeModule = Get-Module StandardSemanticBridge
        $originalClockProvider = & $bridgeModule {
            (Get-Item -Path Function:\Get-StandardSemanticBridgeUtcNow).ScriptBlock
        }

        try {
            & $bridgeModule {
                param($State)
                $script:StandardSemanticBridgeTestClockState = $State
                Set-Item -Path Function:\Get-StandardSemanticBridgeUtcNow -Value {
                    $state = $script:StandardSemanticBridgeTestClockState
                    if ($null -eq $state) { throw 'test clock override state is not configured.' }
                    $signatureCompleted = [IO.File]::Exists([string]$state.signatureCompletedMarkerPath)
                    $phase = if ($signatureCompleted) { 'expired' } else { 'active' }
                    $observation = '{0}|signatureCompleted={1}' -f $phase, $signatureCompleted.ToString().ToLowerInvariant()
                    [IO.File]::AppendAllText([string]$state.observationsPath, $observation + [Environment]::NewLine)
                    if ($signatureCompleted) { return [DateTime]$state.expiredUtc }
                    return [DateTime]$state.activeUtc
                }
            } $clockState

            $shortRequest = New-StandardSemanticBridgeConsentRequest `
                -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
                -Scope $fixture.Scope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
                -RequestId '11111111-1111-4111-8111-111111111124' `
                -RequestedAt $consentStartedAt.AddSeconds(-1) -ExpiresAt $consentExpiresAt
            $shortDecision = New-StandardSemanticBridgeConsentDecision `
                -Request $shortRequest -Authorizer $fixture.Authorizer `
                -DecisionId '11111111-1111-4111-8111-111111111125' -AuthorizedAt $consentStartedAt
            $expiredDuringSigner = Invoke-TestSemanticBridge `
                -Fixture $fixture -Request $shortRequest -Decision $shortDecision `
                -Signer $slowSigner `
                -SignerContext ([pscustomobject][ordered]@{
                    markerPath = $slowSignerMarker
                    timestampsPath = $slowSignerTimestampsPath
                    signatureCompletedMarkerPath = $slowSignerCompletedMarker
                    expiresAtUtc = $shortRequest.expiresAt
                    privateKeyXml = $fixture.Rsa.ToXmlString($true)
                }) `
                -Now $consentStartedAt -TimeoutSeconds 20
        }
        finally {
            & $bridgeModule {
                param($OriginalClockProvider)
                Set-Item -Path Function:\Get-StandardSemanticBridgeUtcNow -Value $OriginalClockProvider
                Remove-Variable -Name StandardSemanticBridgeTestClockState -Scope Script -ErrorAction SilentlyContinue
            } $originalClockProvider
        }

        $clockObservationSummary = if (Test-Path -LiteralPath $clockObservationsPath -PathType Leaf) {
            (@(Get-Content -LiteralPath $clockObservationsPath) -join ';')
        }
        else { '<missing>' }
        $signerEntryDiagnostic = "state=$($expiredDuringSigner.status); reason=$($expiredDuringSigner.reason); clockObservations=$clockObservationSummary"
        Assert-TestCondition (Test-Path -LiteralPath $slowSignerMarker -PathType Leaf) "The signer callback did not write its entry marker. $signerEntryDiagnostic"
        Assert-TestCondition (Test-Path -LiteralPath $slowSignerCompletedMarker -PathType Leaf) 'The signer callback did not complete and verify its signature.'
        Assert-TestCondition ([IO.File]::ReadAllText($slowSignerCompletedMarker) -ceq 'signature-verified') 'The signer completion marker does not confirm signature verification.'
        Assert-TestCondition (Test-Path -LiteralPath $slowSignerTimestampsPath -PathType Leaf) 'The signer callback did not write its timestamps.'
        Assert-TestCondition (Test-Path -LiteralPath $clockObservationsPath -PathType Leaf) 'The test clock did not record consent-gate observations.'
        $signerTimestamps = @(Get-Content -LiteralPath $slowSignerTimestampsPath)
        Assert-TestCondition ($signerTimestamps.Count -eq 3) "Signer timestamp file must contain exactly 3 lines; found $($signerTimestamps.Count)."
        $parsedTimestamps = New-Object 'System.Collections.Generic.List[DateTime]'
        foreach ($timestampText in $signerTimestamps) {
            $parsedTimestamp = [DateTime]::MinValue
            $parsed = [DateTime]::TryParseExact(
                [string]$timestampText,
                'o',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsedTimestamp
            )
            Assert-TestCondition ([bool]$parsed) "Signer timestamp has an invalid round-trip format: '$timestampText'."
            [void]$parsedTimestamps.Add($parsedTimestamp.ToUniversalTime())
        }
        $signerEnteredAtUtc = $parsedTimestamps[0]
        $signerExpiresAtUtc = $parsedTimestamps[1]
        $signatureProducedAtUtc = $parsedTimestamps[2]
        $clockObservations = @(Get-Content -LiteralPath $clockObservationsPath)
        Assert-TestCondition ($clockObservations.Count -ge 4) "Expected at least four parent consent clock samples; found $($clockObservations.Count)."
        $preExpiryClockObservations = New-Object 'System.Collections.Generic.List[string]'
        for ($clockIndex = 0; $clockIndex -lt ($clockObservations.Count - 1); $clockIndex++) {
            [void]$preExpiryClockObservations.Add([string]$clockObservations[$clockIndex])
        }
        Assert-TestCondition (@($preExpiryClockObservations | Where-Object { $_ -cne 'active|signatureCompleted=false' }).Count -eq 0) 'The clock was not active for every parent consent check before the signer completed.'
        Assert-TestCondition ([string]$clockObservations[$clockObservations.Count - 1] -ceq 'expired|signatureCompleted=true') 'The clock did not switch to expired after the signer completed.'
        Assert-TestCondition ($signerEnteredAtUtc -lt $signerExpiresAtUtc -and $signerEnteredAtUtc -lt $signatureProducedAtUtc) 'The signer did not enter before consent expiry and finish after entry.'
        Assert-TestCondition ([string]$expiredDuringSigner.status -ceq 'BLOCKED') 'Consent that expired while the signer callback ran did not block the final result.'
        Assert-TestCondition ($null -eq $expiredDuringSigner.evidenceBytes) 'Consent expiry during signing released evidence bytes.'
    }
    }

    # Scenario: Candidate identity, source revision, outbound inventory, and provider route each drift independently.
    # Purpose: Every material input must invalidate the old decision before egress.
    It 'UnitT40_candidate_source_inventory_and_route_drift_invalidate_consent' {
        $evidenceFixture = New-TestSemanticFixture
        $goodEvidence = Invoke-TestSemanticBridge -Fixture $evidenceFixture
        Assert-TestCondition ([string]$goodEvidence.status -ceq 'PASS') "The baseline evidence fixture did not pass: $($goodEvidence.reason)"
        foreach ($case in @('candidate', 'source', 'inventory', 'route')) {
            $fixture = New-TestSemanticFixture
            $bindings = $fixture.Bindings
            $route = $fixture.Route
            $items = $fixture.Items
            $expectedInventory = $evidenceFixture.Inventory
            $expectedBindings = $evidenceFixture.Bindings
            $expectedRoute = $evidenceFixture.Route
            if ($case -eq 'candidate') {
                $bindings = ConvertFrom-Json -InputObject ($fixture.Bindings | ConvertTo-Json -Depth 20)
                $bindings.candidate.candidateId = ('9' * 64)
                $expectedBindings = $bindings
            }
            elseif ($case -eq 'source') {
                $bindings = ConvertFrom-Json -InputObject ($fixture.Bindings | ConvertTo-Json -Depth 20)
                $bindings.candidate.sourceRevision = ('9' * 40)
                $expectedBindings = $bindings
            }
            elseif ($case -eq 'inventory') {
                $items = @([pscustomobject][ordered]@{ path = 'skills/example/SKILL.md'; contentKind = 'skill-instructions'; text = 'changed after consent' })
                $expectedInventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $items
            }
            else {
                $route = ConvertFrom-Json -InputObject ($fixture.Route | ConvertTo-Json -Depth 20)
                $route.model = 'another-model'
                $expectedRoute = $route
            }
            $run = Invoke-TestSemanticBridge -Fixture $fixture -Bindings $bindings -ProviderRoute $route -Items $items
            Assert-TestCondition ([string]$run.status -ceq 'BLOCKED') "$case drift did not block the bridge."
            Assert-TestCondition ([int]$run.providerCallCount -eq 0) "$case drift reached the provider."
            $evidenceCheck = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $goodEvidence.evidenceBytes `
                -ConsentRequest $evidenceFixture.Request `
                -ConsentDecision $evidenceFixture.Decision `
                -PublicKey $evidenceFixture.PublicRsa `
                -ExpectedKeyId 'fixture-key' `
                -ExpectedBindings $expectedBindings `
                -ExpectedProviderRoute $expectedRoute `
                -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $evidenceFixture.Scope `
                -ExpectedProviderTextInventory $expectedInventory `
                -Now ([DateTime]::UtcNow)
            Assert-TestCondition (-not [bool]$evidenceCheck.valid) "$case drift did not invalidate old evidence."
        }
    }

    # Scenario: The signer emits a valid artifact, then the signature syntax, bytes, or expected key identity is substituted.
    # Purpose: Authority-style signing and verification must enforce schema-valid base64 and authenticate bytes and key identity.
    It 'UnitT50_wrong_signature_and_key_identity_are_rejected' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        $whitespaceSigner = {
            param($signerRequest, $callbackContext)
            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                $signatureBytes = $signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $signatureText = [Convert]::ToBase64String($signatureBytes)
                return [pscustomobject][ordered]@{
                    keyId = 'fixture-key'
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = $signatureText.Substring(0, 1) + ' ' + $signatureText.Substring(1)
                }
            }
            finally { $signingKey.Dispose() }
        }
        $badSigner = Invoke-TestSemanticBridge -Fixture $fixture -Signer $whitespaceSigner
        Assert-TestCondition ([string]$badSigner.status -ceq 'FAILED') 'A signer response with whitespace in base64 was accepted.'
        Assert-TestCondition ($null -eq $badSigner.evidenceBytes) 'A signer response with whitespace emitted evidence.'

        $shortSignatureSigner = {
            param($signerRequest, $callbackContext)
            return [pscustomobject][ordered]@{
                keyId = 'fixture-key'
                algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                signature = 'AA=='
            }
        }
        $shortSignatureRun = Invoke-TestSemanticBridge -Fixture $fixture -Signer $shortSignatureSigner
        Assert-TestCondition ([string]$shortSignatureRun.status -ceq 'FAILED') 'A canonical Base64 value that is not a valid RSA signature was accepted by the bridge.'
        Assert-TestCondition ($null -eq $shortSignatureRun.evidenceBytes) 'An invalid RSA signature emitted evidence.'

        $rsaSigner = {
            param($signerRequest, $callbackContext)
            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                return [pscustomobject][ordered]@{
                    keyId = [string]$callbackContext.keyId
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = [Convert]::ToBase64String($signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
                }
            }
            finally { $signingKey.Dispose() }
        }
        $rogueRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            $sameIdWrongKey = Invoke-TestSemanticBridge `
                -Fixture $fixture -Signer $rsaSigner `
                -SignerContext ([pscustomobject][ordered]@{ privateKeyXml = $rogueRsa.ToXmlString($true); keyId = 'fixture-key' })
            Assert-TestCondition ([string]$sameIdWrongKey.status -ceq 'FAILED') 'A signature from an untrusted RSA key with the expected keyId was accepted.'
            Assert-TestCondition ($null -eq $sameIdWrongKey.evidenceBytes) 'An untrusted RSA key emitted evidence.'
        }
        finally { $rogueRsa.Dispose() }

        $wrongKeyIdRun = Invoke-TestSemanticBridge `
            -Fixture $fixture -Signer $rsaSigner `
            -SignerContext ([pscustomobject][ordered]@{ privateKeyXml = $fixture.Rsa.ToXmlString($true); keyId = 'substituted-key-id' })
        Assert-TestCondition ([string]$wrongKeyIdRun.status -ceq 'FAILED') 'A valid signature that claimed an untrusted keyId was accepted by the bridge.'
        Assert-TestCondition ($null -eq $wrongKeyIdRun.evidenceBytes) 'A signer with an untrusted keyId emitted evidence.'

        $sentinelSignerMarker = Join-Path $TestDrive 'signer-threw-consent-sentinel.txt'
        $sentinelSigner = {
            param($signerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, 'invoked')
            throw 'standard-semantic-bridge-consent-expired-before-callback-invocation'
        }
        $sentinelSignerRun = Invoke-TestSemanticBridge `
            -Fixture $fixture `
            -Signer $sentinelSigner `
            -SignerContext ([pscustomobject][ordered]@{ markerPath = $sentinelSignerMarker })
        Assert-TestCondition ([string]$sentinelSignerRun.status -ceq 'FAILED') 'A signer callback error that reused the private expiry diagnostic was misclassified as BLOCKED.'
        Assert-TestCondition ([int]$sentinelSignerRun.providerCallCount -eq 1) 'A signer callback error that reused the private expiry diagnostic lost the completed provider call.'
        Assert-TestCondition (Test-Path -LiteralPath $sentinelSignerMarker) 'The sentinel signer callback did not record that it ran.'
        Assert-TestCondition ($null -eq $sentinelSignerRun.evidenceBytes) 'A failed sentinel signer callback emitted evidence.'

        $whitespaceBytes = Get-TestEvidenceBytesWithSignatureWhitespace -EvidenceBytes $run.evidenceBytes
        $badWhitespace = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $whitespaceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$badWhitespace.valid) 'Evidence with whitespace in signature base64 was accepted.'

        $nonCanonicalSigner = {
            param($signerRequest, $callbackContext)
            $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                $signatureBytes = $signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $signatureText = [Convert]::ToBase64String($signatureBytes)
                if (-not $signatureText.EndsWith('==', [StringComparison]::Ordinal)) { throw 'The test signer did not produce == padding.' }
                $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
                $chars = $signatureText.ToCharArray()
                $lastDataSextet = $alphabet.IndexOf($chars[$chars.Length - 3])
                if ($lastDataSextet -lt 0 -or ($lastDataSextet % 16) -ne 0 -or $lastDataSextet -ge 64) {
                    throw "The test signer did not have canonical pad bits: $lastDataSextet"
                }
                $chars[$chars.Length - 3] = $alphabet[$lastDataSextet + 1]
                $signatureText = -join $chars
                if ([Convert]::ToBase64String([Convert]::FromBase64String($signatureText)) -ceq $signatureText) {
                    throw 'The test signer pad-bit mutation remained canonical.'
                }
                return [pscustomobject][ordered]@{
                    keyId = 'fixture-key'
                    algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                    signature = $signatureText
                }
            }
            finally { $signingKey.Dispose() }
        }
        $badPadBitsSigner = Invoke-TestSemanticBridge -Fixture $fixture -Signer $nonCanonicalSigner
        Assert-TestCondition ([string]$badPadBitsSigner.status -ceq 'FAILED') 'A signer response with non-canonical base64 pad bits was accepted.'
        Assert-TestCondition ($null -eq $badPadBitsSigner.evidenceBytes) 'A signer response with non-canonical base64 pad bits emitted evidence.'

        $nonCanonicalPadBitsBytes = Get-TestEvidenceBytesWithSignatureNonCanonicalPadBits -EvidenceBytes $run.evidenceBytes
        $badNonCanonicalPadBits = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $nonCanonicalPadBitsBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$badNonCanonicalPadBits.valid) 'Evidence with non-canonical base64 pad bits was accepted.'

        $mutatedBytes = Get-TestEvidenceBytesWithSignatureMutation -EvidenceBytes $run.evidenceBytes
        $badSignature = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $mutatedBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$badSignature.valid) 'A changed signature was accepted.'
        $wrongKey = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'substituted-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$wrongKey.valid) 'A substituted signer identity was accepted.'

        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $issuedAtMutation = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$run.evidenceBytes)
        $generatedAt = [DateTime]::Parse([string]$issuedAtMutation.generatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $issuedAtMutation.attestation.issuedAt = $generatedAt.AddMilliseconds(1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $issuedAtBytes = $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $issuedAtMutation))
        $mismatchedIssuedAt = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $issuedAtBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$mismatchedIssuedAt.valid) 'Evidence with an attestation issuedAt different from generatedAt was accepted.'
    }

    # Scenario: A provider omits one analyzer's finding/coverage, and a signed artifact is then replayed.
    # Purpose: Incomplete findings cannot become PASS and a consumer ledger accepts one evidence ID only once.
    It 'InterT60_incomplete_findings_and_evidence_replay_fail_closed' {
        $fixture = New-TestSemanticFixture
        $incompleteProvider = {
            param($providerRequest)
            return [pscustomobject][ordered]@{
                findings = @([pscustomobject][ordered]@{ severity = 'informational'; fingerprint = 'only-one'; ruleId = 'fixture.one'; message = 'incomplete'; path = [string]$providerRequest.path; analyzerId = 'semantic_developer_intent' })
                analyzerCoverage = @('semantic_developer_intent')
            }
        }
        $incomplete = Invoke-TestSemanticBridge -Fixture $fixture -Provider $incompleteProvider
        Assert-TestCondition ([string]$incomplete.status -ceq 'FAILED') 'Incomplete analyzer findings did not fail.'
        Assert-TestCondition ($null -eq $incomplete.evidenceBytes) 'Incomplete analyzer findings emitted evidence.'

        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        $replay = @{}
        $first = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow) -ReplayLedger $replay
        $second = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow) -ReplayLedger $replay
        Assert-TestCondition ([bool]$first.valid) 'The first evidence consumption did not pass.'
        Assert-TestCondition (-not [bool]$second.valid) 'Replayed evidence was accepted.'
        Assert-TestCondition ([string]$second.reason -match 'replay') 'Replay rejection did not identify replay.'
    }

    # Scenario: Provider output uses a case variant of a declared analyzer ID.
    # Purpose: Analyzer identity membership is ordinal and must not inherit PowerShell's case-insensitive comparison defaults.
    It 'InterT175_provider_finding_analyzer_identity_is_ordinal' {
        $fixture = New-TestSemanticFixture
        $caseVariantProvider = {
            param($providerRequest)
            $path = [string]$providerRequest.path
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent-case"; ruleId = 'fixture.intent'; message = 'case variant analyzer'; path = $path; analyzerId = 'SEMANTIC_DEVELOPER_INTENT' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security-case"; ruleId = 'fixture.security'; message = 'declared analyzer'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $caseVariantProvider
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'Provider output with a case-variant analyzer identity was accepted.'
        Assert-TestCondition ([int]$run.successfulProviderCallCount -eq 0) 'Case-variant analyzer output was recorded as a successful provider call.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'Case-variant analyzer output emitted evidence.'
    }

    # Scenario: A valid signed artifact changes one finding to an undeclared analyzer and recomputes all dependent evidence digests.
    # Purpose: Imported findings must be checked against the declared analyzer set even when the signer signs a self-consistent artifact.
    It 'InterT176_imported_signed_finding_analyzer_must_be_declared' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "The baseline evidence fixture did not pass: $($run.reason)"
        $tamperedBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation {
            param($evidence)
            $evidence.findings[1].analyzerId = 'semantic_undeclared_source'
            Update-TestEvidenceExecutionDigests -Evidence $evidence
        }
        $verification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $tamperedBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$verification.valid) 'A re-signed finding with an undeclared analyzer identity was accepted.'
        Assert-TestCondition ([string]$verification.reason -match 'analyzer') 'Undeclared imported analyzer rejection did not identify the analyzer failure.'
    }

    # Scenario: A provider emits an enum spelling that differs only by case from the canonical severity.
    # Purpose: Severity membership is ordinal so a signed uppercase medium cannot bypass the human-review policy.
    It 'InterT180_provider_finding_severity_membership_is_ordinal' {
        foreach ($severityVariant in @('MEDIUM', 'Medium')) {
            $fixture = New-TestSemanticFixture
            $caseVariantProvider = {
                param($providerRequest, $callbackContext)
                $path = [string]$providerRequest.path
                return [pscustomobject][ordered]@{
                    findings = @(
                        [pscustomobject][ordered]@{ severity = [string]$callbackContext.severity; fingerprint = "fp-$path-medium"; ruleId = 'fixture.medium'; message = 'case-variant medium finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                        [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-info"; ruleId = 'fixture.info'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                    )
                    analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
                }
            }
            $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $caseVariantProvider -ProviderContext ([pscustomobject]@{ severity = $severityVariant })
            Assert-TestCondition ([string]$run.status -ceq 'FAILED') "Provider severity '$severityVariant' was accepted."
            Assert-TestCondition ([int]$run.successfulProviderCallCount -eq 0) "Provider severity '$severityVariant' was recorded as successful."
            Assert-TestCondition ($null -eq $run.evidenceBytes) "Provider severity '$severityVariant' emitted signed evidence."
        }
    }

    # Scenario: A fully re-signed imported artifact changes a canonical medium severity to a case variant and recomputes every dependent digest.
    # Purpose: Imported evidence must enforce the same ordinal severity contract as live provider output.
    It 'InterT181_imported_resigned_finding_severity_membership_is_ordinal' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "The baseline evidence fixture did not pass: $($run.reason)"
        $tamperedBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation {
            param($evidence)
            $evidence.findings[0].severity = 'MEDIUM'
            Update-TestEvidenceExecutionDigests -Evidence $evidence
        }
        $verification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $tamperedBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$verification.valid) 'Re-signed imported severity MEDIUM was accepted.'
        Assert-TestCondition ([string]$verification.reason -match 'severity') 'Imported severity MEDIUM rejection did not identify the severity failure.'
    }

    # Scenario: Two signed provider-call records swap their work indexes and IDs while recomputing request, ledger, evidence, and signature digests.
    # Purpose: Each ledger index must bind to the inventory item at that exact normalized index, not merely to any path in the inventory.
    It 'InterT177_imported_provider_call_index_must_bind_to_indexed_inventory_item' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "The baseline two-item evidence fixture did not pass: $($run.reason)"
        $tamperedBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation {
            param($evidence)
            $records = @($evidence.execution.providerCalls)
            $records[0].index = 1
            $records[0].workItemId = 'semantic-work-item-0001'
            $records[1].index = 0
            $records[1].workItemId = 'semantic-work-item-0000'
            foreach ($record in $records) {
                $requestShape = [pscustomobject][ordered]@{
                    workItemId = [string]$record.workItemId
                    idempotencyKey = [string]$record.idempotencyKey
                    providerRoute = $evidence.providerRoute
                    path = [string]$record.path
                    contentKind = [string]$record.contentKind
                    textSha256 = [string]$record.textSha256
                    byteCount = [int64]$record.byteCount
                }
                $record.requestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $requestShape
            }
            Update-TestEvidenceExecutionDigests -Evidence $evidence
        }
        $verification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $tamperedBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$verification.valid) 'Provider-call indexes swapped across inventory paths were accepted after every evidence digest was recomputed.'
        Assert-TestCondition ([string]$verification.reason -match 'inventory item|index') 'Index-to-inventory rejection did not identify the mismatched binding.'
    }

    # Scenario: One work item succeeds, the next times out, and the retry reuses the idempotency ledger.
    # Purpose: Successful outbound work is never sent twice; partial/timeout runs never report PASS, and route drift needs fresh consent.
    It 'InterT70_timeout_partial_retry_has_no_duplicate_success_and_requires_fresh_consent' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $ledger = @{}
        $timeoutContext = [pscustomobject][ordered]@{ timeoutPath = 'skills/example/README.md' }
        $first = Invoke-TestSemanticBridge -Fixture $fixture -Ledger $ledger -ProviderContext $timeoutContext -TimeoutSeconds 1
        Assert-TestCondition ([string]$first.status -ceq 'FAILED') 'The partial timeout run did not fail.'
        Assert-TestCondition ($null -eq $first.evidenceBytes) 'The partial timeout run emitted evidence.'
        Assert-TestCondition ([int]$first.providerCallCount -eq 2) 'The first partial run did not call both work items once.'

        $second = Invoke-TestSemanticBridge -Fixture $fixture -Ledger $ledger
        Assert-TestCondition ([string]$second.status -ceq 'FAILED') 'The retry with unavailable prior response bytes did not fail closed.'
        Assert-TestCondition ($null -eq $second.evidenceBytes) 'The partial retry emitted evidence.'
        Assert-TestCondition ([int]$second.providerCallCount -eq 1) 'The retry resent an already successful work item.'
        foreach ($entry in @($ledger.Values)) {
            Assert-TestCondition (@($entry.PSObject.Properties.Name) -notcontains 'text') 'The idempotency ledger retained provider text.'
            Assert-TestCondition (@($entry.PSObject.Properties.Name) -notcontains 'bytes') 'The idempotency ledger retained provider bytes.'
        }

        $driftedRoute = ConvertFrom-Json -InputObject ($fixture.Route | ConvertTo-Json -Depth 20)
        $driftedRoute.model = 'fresh-consent-model'
        $blocked = Invoke-TestSemanticBridge -Fixture $fixture -ProviderRoute $driftedRoute -Ledger $ledger
        Assert-TestCondition ([string]$blocked.status -ceq 'BLOCKED') 'Provider route drift reused stale consent.'
        Assert-TestCondition ([int]$blocked.providerCallCount -eq 0) 'Provider route drift reached the provider.'

        $freshInventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $fixture.Items
        $freshAnalyzerSet = New-StandardSemanticBridgeAnalyzerSet -Analyzers $fixture.Analyzers
        $freshRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $driftedRoute -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $freshInventory -AnalyzerSet $freshAnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111114' -RequestedAt $fixture.Now.AddMinutes(3) -ExpiresAt $fixture.Now.AddHours(2)
        $freshDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $freshRequest -Authorizer $fixture.Authorizer -DecisionId '11111111-1111-4111-8111-111111111115' -AuthorizedAt $fixture.Now.AddMinutes(4)
        $fresh = Invoke-TestSemanticBridge -Fixture $fixture -ProviderRoute $driftedRoute -Request $freshRequest -Decision $freshDecision -Ledger $ledger -Now $fixture.Now.AddMinutes(5)
        Assert-TestCondition ([string]$fresh.status -ceq 'PASS') 'Fresh route-bound consent did not permit the retry.'
        Assert-TestCondition ([int]$fresh.providerCallCount -eq 2) 'Fresh route-bound consent did not execute both work items.'
    }

    # Scenario: A schema-v1 semantic artifact is supplied to the v2 verifier.
    # Purpose: The new bridge must not reinterpret or silently accept the existing v1 contract.
    It 'UnitT80_v1_shaped_artifact_fails_closed_in_v2_verifier' {
        $fixture = New-TestSemanticFixture
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $v1Bytes = $utf8.GetBytes('{"schemaVersion":1,"evidenceType":"semantic","status":"passed","decision":"PASS"}')
        $result = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $v1Bytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition (-not [bool]$result.valid) 'A v1-shaped artifact was accepted as v2 evidence.'
    }

    # Scenario: Signed evidence bytes contain a duplicate JSON property before deserialization.
    # Purpose: Canonical byte verification must reject parser-colliding input instead of normalizing it.
    It 'UnitT90_duplicate_json_property_fails_closed_before_authority_acceptance' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $json = $utf8.GetString($run.evidenceBytes)
        $duplicateBytes = $utf8.GetBytes($json.Insert(1, '"schemaVersion":2,'))

        $result = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $duplicateBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)

        Assert-TestCondition (-not [bool]$result.valid) 'Duplicate JSON properties were accepted.'
        Assert-TestCondition ([string]$result.reason -match 'canonical UTF-8 JSON') 'Duplicate JSON rejection did not identify canonical byte failure.'
    }

    # Scenario: Signed artifacts replace numeric schemaVersion 2 with a string or boolean while every dependent digest and signature is recomputed.
    # Purpose: Consent and evidence schema versions must have the JSON numeric type required by the published schema.
    It 'UnitT91_schema_version_requires_native_numeric_two' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "The baseline schema-version evidence fixture did not pass: $($run.reason)"

        $baselineVerification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition ([bool]$baselineVerification.valid) 'Native numeric schemaVersion 2 was rejected.'

        foreach ($invalidSchemaVersion in @('2', $true)) {
            $schemaVersionForMutation = $invalidSchemaVersion
            $mutation = {
                param($evidence)
                $evidence.schemaVersion = $schemaVersionForMutation
            }.GetNewClosure()
            $invalidEvidenceBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation $mutation
            $invalidVerification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $invalidEvidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
                -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
                -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
            Assert-TestCondition (-not [bool]$invalidVerification.valid) "Re-signed evidence with schemaVersion '$invalidSchemaVersion' was accepted."
        }
        foreach ($invalidSurface in @('request-string', 'request-boolean', 'decision-string', 'decision-boolean')) {
            $request = ConvertFrom-Json -InputObject (Get-StandardSemanticBridgeCanonicalJson -Value $fixture.Request)
            $decision = ConvertFrom-Json -InputObject (Get-StandardSemanticBridgeCanonicalJson -Value $fixture.Decision)
            $invalidSchemaVersion = if ($invalidSurface.EndsWith('string', [StringComparison]::Ordinal)) { '2' } else { $true }
            if ($invalidSurface.StartsWith('request-', [StringComparison]::Ordinal)) { $request.schemaVersion = $invalidSchemaVersion }
            else { $decision.schemaVersion = $invalidSchemaVersion }
            Update-TestConsentDigests -Request $request -Decision $decision

            $invalidConsentRun = Invoke-TestSemanticBridge -Fixture $fixture -Request $request -Decision $decision
            Assert-TestCondition ([string]$invalidConsentRun.status -ceq 'BLOCKED') "$invalidSurface schemaVersion did not block consent."
            Assert-TestCondition ([int]$invalidConsentRun.providerCallCount -eq 0) "$invalidSurface schemaVersion reached the provider."
        }

        $numericEquivalentBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation {
            param($evidence)
            $evidence.schemaVersion = [double]2.0
        }
        $numericEquivalentVerification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $numericEquivalentBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition ([bool]$numericEquivalentVerification.valid) 'Numeric schemaVersion 2.0 was rejected although it is schema-equivalent to integer 2.'
    }

    # Scenario: A validly re-signed evidence artifact uses locale-formatted timestamp strings instead of RFC 3339 date-time values.
    # Purpose: Every signed evidence timestamp must meet the schema lexical contract before parsed-instant comparisons, while offsets remain valid.
    It 'UnitT95_rejects_non_rfc3339_resigned_evidence_timestamps_but_accepts_offsets' {
        $fixture = New-TestSemanticFixture
        try {
            $run = Invoke-TestSemanticBridge -Fixture $fixture
            Assert-TestCondition ([string]$run.status -ceq 'PASS') "The baseline timestamp fixture did not pass: $($run.reason)"

            foreach ($field in @('generatedAt', 'attestation.issuedAt', 'consent.authorizedAt', 'consent.expiresAt')) {
                $mutation = {
                    param($evidence)
                    $parts = $field -split '\.'
                    $owner = $evidence
                    for ($index = 0; $index -lt ($parts.Count - 1); $index++) { $owner = $owner.($parts[$index]) }
                    $leaf = $parts[$parts.Count - 1]
                    $raw = $owner.($leaf)
                    if ($raw -is [DateTime]) { $timestamp = [DateTimeOffset]::new(([DateTime]$raw).ToUniversalTime()) }
                    elseif ($raw -is [DateTimeOffset]) { $timestamp = ([DateTimeOffset]$raw).ToUniversalTime() }
                    else { $timestamp = [DateTimeOffset]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).ToUniversalTime() }
                    $owner.($leaf) = $timestamp.ToString('MM/dd/yyyy HH:mm:ss.fff zzz', [Globalization.CultureInfo]::InvariantCulture)
                }.GetNewClosure()
                $invalidBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation $mutation
                $invalid = Test-StandardSemanticBridgeEvidence `
                    -EvidenceBytes $invalidBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
                    -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
                    -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
                    -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
                Assert-TestCondition (-not [bool]$invalid.valid) "A re-signed locale-formatted $field timestamp was accepted."
                Assert-TestCondition ([string]$invalid.reason -match 'RFC 3339') "The $field rejection did not identify its RFC 3339 type/format failure: $($invalid.reason)"
            }

            $offsetMutation = {
                param($evidence)
                foreach ($field in @('generatedAt', 'attestation.issuedAt', 'consent.authorizedAt', 'consent.expiresAt')) {
                    $parts = $field -split '\.'
                    $owner = $evidence
                    for ($index = 0; $index -lt ($parts.Count - 1); $index++) { $owner = $owner.($parts[$index]) }
                    $leaf = $parts[$parts.Count - 1]
                    $raw = $owner.($leaf)
                    if ($raw -is [DateTime]) { $timestamp = [DateTimeOffset]::new(([DateTime]$raw).ToUniversalTime()) }
                    elseif ($raw -is [DateTimeOffset]) { $timestamp = ([DateTimeOffset]$raw).ToUniversalTime() }
                    else { $timestamp = [DateTimeOffset]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).ToUniversalTime() }
                    $owner.($leaf) = $timestamp.ToOffset([TimeSpan]::FromHours(5.5)).ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", [Globalization.CultureInfo]::InvariantCulture)
                }
            }
            $offsetBytes = Get-TestResignedEvidenceBytes -EvidenceBytes $run.evidenceBytes -Fixture $fixture -Mutation $offsetMutation
            $offsetVerification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $offsetBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
                -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
                -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
            Assert-TestCondition ([bool]$offsetVerification.valid) "Equivalent RFC 3339 timestamps with +05:30 offsets were rejected: $($offsetVerification.reason)"
        }
        finally {
            $fixture.Rsa.Dispose()
            $fixture.PublicRsa.Dispose()
        }
    }

    # Scenario: A multi-item execution validates consent once, then uses its detached expiry gate.
    # Purpose: Full request/decision/schema validation must not repeat at each provider boundary.
    It 'InterT184_full_consent_validation_runs_once_for_multi_item_execution' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $module = Get-Module -Name StandardSemanticBridge | Select-Object -First 1
        $originalValidator = & $module {
            (Get-Item -Path Function:\Test-StandardSemanticBridgeConsent).ScriptBlock
        }
        & $module {
            param($validator)
            $script:StandardSemanticBridgeConsentPerfTestCount = 0
            $script:StandardSemanticBridgeConsentPerfTestOriginal = $validator
            Set-Item -Path Function:\Test-StandardSemanticBridgeConsent -Value {
                [CmdletBinding()]
                param(
                    [Parameter(Mandatory = $true)] $ConsentRequest,
                    [Parameter(Mandatory = $true)] $ConsentDecision,
                    [Parameter(Mandatory = $true)] $CurrentBindings,
                    [Parameter(Mandatory = $true)] $CurrentProviderRoute,
                    [Parameter(Mandatory = $true)][string] $CurrentPurpose,
                    [Parameter(Mandatory = $true)] $CurrentScope,
                    [Parameter(Mandatory = $true)] $CurrentProviderTextInventory,
                    [Parameter(Mandatory = $true)] $CurrentAnalyzerSet,
                    [DateTime] $Now = [DateTime]::UtcNow
                )
                $script:StandardSemanticBridgeConsentPerfTestCount++
                & $script:StandardSemanticBridgeConsentPerfTestOriginal @PSBoundParameters
            }
        } $originalValidator

        try {
            $run = Invoke-TestSemanticBridge -Fixture $fixture
            $validationCount = & $module { $script:StandardSemanticBridgeConsentPerfTestCount }
        }
        finally {
            & $module {
                param($validator)
                Set-Item -Path Function:\Test-StandardSemanticBridgeConsent -Value $validator
                Remove-Variable -Name StandardSemanticBridgeConsentPerfTestCount, StandardSemanticBridgeConsentPerfTestOriginal -Scope Script -ErrorAction SilentlyContinue
            } $originalValidator
            $fixture.Rsa.Dispose()
            $fixture.PublicRsa.Dispose()
        }

        Assert-TestCondition ([string]$run.status -ceq 'PASS') 'The multi-item consent count fixture did not complete successfully.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 2) "The fixture did not reach all provider items: status=$($run.status), calls=$($run.providerCallCount), reason=$($run.reason)"
        Assert-TestCondition ([int]$validationCount -eq 1) "Full consent/schema validation ran $validationCount times; it must run once per execution."
    }

    # Scenario: Another runspace mutates caller-owned inputs after the first provider starts.
    # Purpose: Egress, evidence metadata, and later callback contexts must use the start-of-call snapshot.
    It 'InterT185_execution_snapshot_is_detached_from_external_mutation' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $firstPath = [string]$fixture.Inventory.items[0].path
        $secondPath = [string]$fixture.Inventory.items[1].path
        $secondSourceItem = @($fixture.Items | Where-Object { [string]$_.path -ceq $secondPath })[0]
        $originalSecondText = [string]$secondSourceItem.text
        $originalAuthorizer = [string]$fixture.Decision.authorizer.subject
        $providerStartedMarker = Join-Path $TestDrive 'snapshot-provider-started.txt'
        $mutationCompletedMarker = Join-Path $TestDrive 'snapshot-mutation-completed.txt'
        $providerContext = [pscustomobject][ordered]@{
            marker = $providerStartedMarker
            mutationCompletedMarker = $mutationCompletedMarker
            firstPath = $firstPath
            secondPath = $secondPath
            expectedSecondText = $originalSecondText
            emptyArray = @()
            singletonArray = @('context-only')
            manyArray = @('context-first', 'context-second', 'context-third')
            nested = [pscustomobject][ordered]@{ singletonArray = @('nested-only') }
        }
        $provider = {
            param($providerRequest, $callbackContext)
            $path = [string]$providerRequest.path
            if ($path -ceq [string]$callbackContext.firstPath) {
                [IO.File]::WriteAllText([string]$callbackContext.marker, 'first-provider-started')
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while (-not (Test-Path -LiteralPath ([string]$callbackContext.mutationCompletedMarker) -PathType Leaf)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'timed out waiting for the external mutation completion marker.' }
                    [Threading.Thread]::Sleep(25)
                }
            }
            if ($path -ceq [string]$callbackContext.secondPath -and
                ([string]$providerRequest.text -cne [string]$callbackContext.expectedSecondText)) {
                throw 'provider input or callback context changed after the execution snapshot.'
            }
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "snapshot-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "snapshot-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $mutationRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $mutationRunspace.Open()
        $mutationPowerShell = [System.Management.Automation.PowerShell]::Create()
        $mutationPowerShell.Runspace = $mutationRunspace
        [void]$mutationPowerShell.AddScript({
            param($request, $decision, $bindings, $route, $scope, $secondItem, $analyzers, $providerContext, $signerContext, $marker, $completedMarker)
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
                if ([DateTime]::UtcNow -ge $deadline) { throw 'timed out waiting for the first provider marker.' }
                [Threading.Thread]::Sleep(25)
            }
            $request.scope.description = 'externally mutated consent request.'
            $decision.authorizer.subject = 'externally mutated authorizer.'
            $bindings.tool.toolId = 'externally-mutated-tool'
            $route.model = 'externally-mutated-model'
            $scope.description = 'externally mutated current scope.'
            $secondItem.text = 'externally mutated source text.'
            $analyzers[0].version = '9.9.9'
            $providerContext.expectedSecondText = 'externally mutated callback context.'
            $signerContext.privateKeyXml = '<invalid external signer mutation />'
            [IO.File]::WriteAllText($completedMarker, 'mutation-complete')
            return 'mutation-applied'
        }).AddArgument($fixture.Request).AddArgument($fixture.Decision).AddArgument($fixture.Bindings).AddArgument($fixture.Route).AddArgument($fixture.Scope).AddArgument($secondSourceItem).AddArgument($fixture.Analyzers).AddArgument($providerContext).AddArgument($fixture.SignerContext).AddArgument($providerStartedMarker).AddArgument($mutationCompletedMarker)
        $mutationAsync = $mutationPowerShell.BeginInvoke()

        try {
            $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $provider -ProviderContext $providerContext -SignerContext $fixture.SignerContext -TimeoutSeconds 45
            $mutationOutput = @($mutationPowerShell.EndInvoke($mutationAsync))
            $mutationErrors = @($mutationPowerShell.Streams.Error)
        }
        finally {
            $mutationPowerShell.Dispose()
            $mutationRunspace.Dispose()
            $fixture.Rsa.Dispose()
            $fixture.PublicRsa.Dispose()
        }

        Assert-TestCondition ($mutationOutput -contains 'mutation-applied') 'The external mutation fixture did not modify caller-owned inputs.'
        Assert-TestCondition (Test-Path -LiteralPath $providerStartedMarker -PathType Leaf) "The provider callback did not enter before the mutation fixture ran: status=$($run.status), calls=$($run.providerCallCount), reason=$($run.reason)"
        Assert-TestCondition (Test-Path -LiteralPath $mutationCompletedMarker -PathType Leaf) 'The external mutation runspace did not complete all writes before provider response.'
        Assert-TestCondition ($mutationErrors.Count -eq 0) "The external mutation runspace reported errors: $($mutationErrors -join '; ')"
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "External input mutation changed execution status: $($run.reason)"
        Assert-TestCondition ([int]$run.providerCallCount -eq 2) 'External mutation changed the captured work-item count.'
        Assert-TestCondition ([string]$run.evidence.consent.authorizer.subject -ceq $originalAuthorizer) 'Evidence metadata did not use the captured decision.'
    }

    # Scenario: CLIXML-detached values retain array shape and binary content.
    # Purpose: Snapshot normalization must preserve 0/1/N arrays and byte[] values on Windows PowerShell and PowerShell 7.
    It 'UnitT186_detached_snapshot_preserves_array_shape_and_binary_bytes' {
        $module = Get-Module -Name StandardSemanticBridge | Select-Object -First 1
        $sourceBytes = [byte[]](1, 2, 3, 4)
        $nestedBytes = [byte[]](9, 8, 7)
        $source = [pscustomobject][ordered]@{
            zero = @()
            one = @('only')
            many = @('first', 'second', 'third')
            bytes = $sourceBytes
            nested = [pscustomobject][ordered]@{ values = @('nested-only'); bytes = $nestedBytes }
        }
        $snapshot = & $module {
            param($value)
            Copy-StandardSemanticBridgeExecutionSnapshotValue -Value $value
        } $source

        Assert-TestCondition ($snapshot.zero -is [array] -and $snapshot.zero.Count -eq 0) 'An empty array did not retain array shape.'
        Assert-TestCondition ($snapshot.one -is [array] -and $snapshot.one.Count -eq 1 -and [string]$snapshot.one[0] -ceq 'only') 'A singleton array did not retain array shape.'
        Assert-TestCondition ($snapshot.many -is [array] -and $snapshot.many.Count -eq 3 -and (@($snapshot.many) -join ',') -ceq 'first,second,third') 'A multi-item array did not retain array shape and values.'
        Assert-TestCondition ($snapshot.bytes -is [byte[]] -and (@($snapshot.bytes) -join ',') -ceq '1,2,3,4') 'A root byte array did not retain its type and content.'
        Assert-TestCondition (-not [object]::ReferenceEquals($sourceBytes, $snapshot.bytes)) 'The root byte-array snapshot aliases caller-owned bytes.'
        Assert-TestCondition ($snapshot.nested.values -is [array] -and $snapshot.nested.values.Count -eq 1) 'A nested singleton array did not retain array shape.'
        Assert-TestCondition ($snapshot.nested.bytes -is [byte[]] -and (@($snapshot.nested.bytes) -join ',') -ceq '9,8,7') 'A nested byte array did not retain its type and content.'
        Assert-TestCondition (-not [object]::ReferenceEquals($nestedBytes, $snapshot.nested.bytes)) 'The nested byte-array snapshot aliases caller-owned bytes.'
    }

    # Scenario: A direct callback helper round-trips array and binary arguments through its child process.
    # Purpose: Child bootstrap normalization must restore the exact schema payload shapes.
    It 'UnitT187_callback_child_preserves_payload_array_and_binary_shapes' {
        $argument = [pscustomobject][ordered]@{
            emptyArray = @()
            singletonArray = @('argument-only')
            manyArray = @('argument-first', 'argument-second', 'argument-third')
            nested = [pscustomobject][ordered]@{ singletonArray = @('argument-nested') }
            bytes = [byte[]](0x11, 0x22, 0x33)
        }
        $callbackContext = [pscustomobject][ordered]@{
            emptyArray = @()
            singletonArray = @('context-only')
            manyArray = @('context-first', 'context-second', 'context-third')
            nested = [pscustomobject][ordered]@{ singletonArray = @('context-nested') }
            bytes = [byte[]](0x44, 0x55, 0x66, 0x77)
        }
        $callback = {
            param($callbackArgument, $context)
            [pscustomobject][ordered]@{
                callbackEntered = $true
                argumentArraysPreserved = [bool]($callbackArgument.emptyArray -is [array] -and $callbackArgument.emptyArray.Count -eq 0 -and $callbackArgument.singletonArray -is [array] -and $callbackArgument.singletonArray.Count -eq 1 -and $callbackArgument.manyArray -is [array] -and $callbackArgument.manyArray.Count -eq 3 -and $callbackArgument.nested.singletonArray -is [array] -and $callbackArgument.nested.singletonArray.Count -eq 1)
                contextArraysPreserved = [bool]($context.emptyArray -is [array] -and $context.emptyArray.Count -eq 0 -and $context.singletonArray -is [array] -and $context.singletonArray.Count -eq 1 -and $context.manyArray -is [array] -and $context.manyArray.Count -eq 3 -and $context.nested.singletonArray -is [array] -and $context.nested.singletonArray.Count -eq 1)
                argumentByteArrayPreserved = [bool]($callbackArgument.bytes -is [byte[]] -and $callbackArgument.bytes.Count -eq 3 -and [int]$callbackArgument.bytes[0] -eq 0x11 -and [int]$callbackArgument.bytes[2] -eq 0x33)
                contextByteArrayPreserved = [bool]($context.bytes -is [byte[]] -and $context.bytes.Count -eq 4 -and [int]$context.bytes[0] -eq 0x44 -and [int]$context.bytes[3] -eq 0x77)
            }
        }
        $module = Get-Module -Name StandardSemanticBridge | Select-Object -First 1
        $resultItems = @(& $module {
            param($callback, $argument, $context)
            Invoke-StandardSemanticBridgeCallbackWithTimeout -Callback $callback -Argument $argument -CallbackContext $context -TimeoutMilliseconds 10000 -Context 'payload shape test'
        } $callback $argument $callbackContext)

        Assert-TestCondition ($resultItems.Count -eq 1) 'The child callback did not return exactly one result.'
        $shapeResult = $resultItems[0]
        Assert-TestCondition ([bool]$shapeResult.callbackEntered) 'The child callback did not enter.'
        Assert-TestCondition ([bool]$shapeResult.argumentArraysPreserved) 'The child callback argument lost a 0/1/N array shape.'
        Assert-TestCondition ([bool]$shapeResult.contextArraysPreserved) 'The child callback context lost a 0/1/N array shape.'
        Assert-TestCondition ([bool]$shapeResult.argumentByteArrayPreserved) 'The child callback argument lost its byte[] type or content.'
        Assert-TestCondition ([bool]$shapeResult.contextByteArrayPreserved) 'The child callback context lost its byte[] type or content.'
    }

    # Scenario: Public execution receives scalar values at parameters whose contract requires arrays.
    # Purpose: Snapshot normalization must not silently wrap invalid caller shapes into valid arrays.
    It 'UnitT188_scalar_public_inputs_fail_closed_without_provider_egress' {
        foreach ($invalidParameter in @('TextItems', 'Analyzers')) {
            $fixture = New-TestSemanticFixture
            $textItems = $fixture.Items
            $analyzers = $fixture.Analyzers
            if ($invalidParameter -ceq 'TextItems') { $textItems = $fixture.Items[0] }
            else { $analyzers = $fixture.Analyzers[0] }

            try {
                $run = Invoke-StandardSemanticBridge `
                    -ConsentRequest $fixture.Request `
                    -ConsentDecision $fixture.Decision `
                    -Bindings $fixture.Bindings `
                    -ProviderRoute $fixture.Route `
                    -Purpose 'Synthetic test-only semantic review.' `
                    -Scope $fixture.Scope `
                    -TextItems $textItems `
                    -Analyzers $analyzers `
                    -ProviderCallback $fixture.Provider `
                    -SignerCallback $fixture.Signer `
                    -ExpectedSignerPublicKey $fixture.PublicRsa `
                    -ExpectedSignerKeyId 'fixture-key' `
                    -ProviderCallbackContext $fixture.ProviderContext `
                    -SignerCallbackContext $fixture.SignerContext `
                    -TimeoutSeconds 30 `
                    -Now ([DateTime]::UtcNow)

                Assert-TestCondition ([string]$run.status -ceq 'FAILED') "Scalar $invalidParameter input did not fail closed."
                Assert-TestCondition ([int]$run.providerCallCount -eq 0) "Scalar $invalidParameter input reached the provider."
                Assert-TestCondition ($null -eq $run.evidenceBytes) "Scalar $invalidParameter input emitted evidence."
            }
            finally {
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }

    # Scenario: The caller supplies a safe Windows-style path that inventory construction canonicalizes to forward slashes.
    # Purpose: Execution must recover the exact source item by its canonical inventory path, while rejecting normalized aliases.
    It 'InterT178_windows_style_source_path_resolves_by_canonical_inventory_path' {
        $fixture = New-TestSemanticFixture
        $items = @([pscustomobject][ordered]@{
            path = 'skills\example\SKILL.md'
            contentKind = 'skill-instructions'
            text = 'synthetic semantic bridge text from a Windows-style source path'
        })
        $inventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $items
        $scope = [pscustomobject][ordered]@{
            description = 'Synthetic test-only semantic scope.'
            paths = @('skills/example/SKILL.md')
            contentKinds = @('skill-instructions')
        }
        $request = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $scope -ProviderTextInventory $inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111118' -RequestedAt $fixture.Now -ExpiresAt $fixture.Now.AddHours(1)
        $decision = New-StandardSemanticBridgeConsentDecision `
            -Request $request -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111119' -AuthorizedAt $fixture.Now.AddMinutes(1)

        $run = Invoke-TestSemanticBridge -Fixture $fixture -Items $items -Request $request -Decision $decision -Scope $scope
        Assert-TestCondition ([string]$run.status -ceq 'PASS') "A consented Windows-style source path failed before evidence generation: $($run.reason)"
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The Windows-style source item was not sent to the provider exactly once.'
        Assert-TestCondition (@($run.providerCalls).Count -eq 1) 'Successful evidence does not contain exactly one provider call.'
        Assert-TestCondition ([string]$run.providerCalls[0].path -ceq 'skills/example/SKILL.md') 'The provider call did not use the canonical inventory path.'

        $verification = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $request -ConsentDecision $decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $scope -ExpectedProviderTextInventory $inventory -Now ([DateTime]::UtcNow)
        Assert-TestCondition ([bool]$verification.valid) "The canonical-path provider evidence did not verify: $($verification.reason)"

        $duplicateAliases = @(
            [pscustomobject][ordered]@{ path = 'skills\example\SKILL.md'; contentKind = 'skill-instructions'; text = 'first' }
            [pscustomobject][ordered]@{ path = 'skills/example/SKILL.md'; contentKind = 'skill-instructions'; text = 'second' }
        )
        $duplicateError = Get-TestErrorMessage { New-StandardSemanticBridgeProviderTextInventory -TextItems $duplicateAliases }
        Assert-TestCondition ($duplicateError -match 'duplicate path') 'Distinct raw path aliases that normalize to one inventory path were accepted.'
    }

    # Scenario: Two planned work items return a global union while one item omits an analyzer.
    # Purpose: Coverage must be checked against each work item, and a finding from another path must not be attributed to the current item.
    It 'InterT100_each_work_item_requires_complete_analyzer_coverage_and_bound_finding_path' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $provider = {
            param($providerRequest)
            $path = [string]$providerRequest.path
            $coverage = if ($path -ceq 'skills/example/README.md') { @('semantic_developer_intent') } else { @('semantic_developer_intent', 'semantic_security_discovery') }
            $findingPath = if ($path -ceq 'skills/example/README.md') { 'skills/example/SKILL.md' } else { $path }
            return [pscustomobject][ordered]@{
                findings = @([pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path"; ruleId = 'fixture.item'; message = 'synthetic finding'; path = $findingPath; analyzerId = 'semantic_developer_intent' })
                analyzerCoverage = $coverage
            }
        }
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $provider
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'A partial per-work-item analyzer response unexpectedly passed.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 2) 'The negative per-work-item provider was not actually called for both items.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'An invalid per-work-item response emitted evidence.'
    }

    # Scenario: Consent is imported with a scope that omits one provider inventory path.
    # Purpose: Scope coverage is a pre-egress condition; no provider callback may run for an uncovered inventory.
    It 'UnitT110_incomplete_consent_scope_blocks_before_provider_call' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $incompleteScope = [pscustomobject][ordered]@{
            description = 'Synthetic incomplete semantic scope.'
            paths = @('skills/example/SKILL.md')
            contentKinds = @('skill-instructions')
        }
        $request = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $incompleteScope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111116' -RequestedAt $fixture.Now -ExpiresAt $fixture.Now.AddHours(1)
        $decision = New-StandardSemanticBridgeConsentDecision `
            -Request $request -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111117' -AuthorizedAt $fixture.Now.AddMinutes(1)
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Scope $incompleteScope -Request $request -Decision $decision
        Assert-TestCondition ([string]$run.status -ceq 'BLOCKED') 'Consent with incomplete inventory scope was not blocked.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 0) 'Incomplete consent scope reached the provider.'
    }

    # Scenario: Imported request/decision objects contain malformed UUIDs, extra authorizer properties, or invalid time ordering.
    # Purpose: Imported consent must be typed and self-consistent before any outbound call is permitted.
    It 'UnitT120_imported_consent_typed_invariants_fail_closed' {
        foreach ($case in @('uuid', 'authorizer', 'requested-order', 'authorized-order')) {
            $fixture = New-TestSemanticFixture
            $request = ConvertFrom-Json -InputObject ($fixture.Request | ConvertTo-Json -Depth 50)
            $decision = ConvertFrom-Json -InputObject ($fixture.Decision | ConvertTo-Json -Depth 50)
            if ($case -ceq 'uuid') {
                $request.requestId = 'not-a-uuid'
                $decision.requestId = 'not-a-uuid'
            }
            elseif ($case -ceq 'authorizer') {
                $decision.authorizer | Add-Member -MemberType NoteProperty -Name unexpected -Value 'must-fail'
            }
            elseif ($case -ceq 'requested-order') {
                $request.expiresAt = $request.requestedAt
                $decision.expiresAt = $request.expiresAt
            }
            else {
                $decision.authorizedAt = $request.expiresAt
            }
            Update-TestConsentDigests -Request $request -Decision $decision
            $run = Invoke-TestSemanticBridge -Fixture $fixture -Request $request -Decision $decision
            Assert-TestCondition ([string]$run.status -ceq 'BLOCKED') "$case imported consent was not blocked."
            Assert-TestCondition ([int]$run.providerCallCount -eq 0) "$case imported consent reached the provider."
        }
    }

    # Scenario: Provider input is supplied as malformed bytes, then as valid strict-UTF8 bytes.
    # Purpose: Binary data must stop before egress, while valid bytes may cross only as decoded text.
    It 'UnitT125_rejects_binary_bytes_before_provider_egress_and_decodes_strict_UTF8_text' {
        $fixture = New-TestSemanticFixture
        $invalidItems = @([pscustomobject][ordered]@{
                path = 'skills/example/SKILL.md'
                contentKind = 'skill-instructions'
                bytes = [byte[]]@(0xc3, 0x28)
            })
        $invalidInventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $invalidItems
        $invalidRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $invalidInventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111116' -RequestedAt $fixture.Now -ExpiresAt $fixture.Now.AddHours(1)
        $invalidDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $invalidRequest -Authorizer $fixture.Authorizer -DecisionId '11111111-1111-4111-8111-111111111117' -AuthorizedAt $fixture.Now.AddMinutes(1)
        $invalidRun = Invoke-TestSemanticBridge -Fixture $fixture -Items $invalidItems -Request $invalidRequest -Decision $invalidDecision
        Assert-TestCondition ([string]$invalidRun.status -ceq 'FAILED') 'Malformed UTF-8 bytes did not fail closed.'
        Assert-TestCondition ([int]$invalidRun.providerCallCount -eq 0) 'Malformed UTF-8 bytes reached the provider.'

        $validText = 'strict UTF-8 text'
        $validItems = @([pscustomobject][ordered]@{
                path = 'skills/example/SKILL.md'
                contentKind = 'skill-instructions'
                bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($validText)
            })
        $validInventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $validItems
        $validRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $validInventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111118' -RequestedAt $fixture.Now -ExpiresAt $fixture.Now.AddHours(1)
        $validDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $validRequest -Authorizer $fixture.Authorizer -DecisionId '11111111-1111-4111-8111-111111111119' -AuthorizedAt $fixture.Now.AddMinutes(1)
        $validProvider = {
            param($providerRequest, $callbackContext)
            if ([string]$providerRequest.text -cne [string]$callbackContext.expectedText -or $null -ne $providerRequest.bytes) {
                throw 'provider request did not contain only the strict-UTF8 decoded text.'
            }
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = 'valid-bytes-intent'; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = [string]$providerRequest.path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = 'valid-bytes-security'; ruleId = 'fixture.security'; message = 'synthetic finding'; path = [string]$providerRequest.path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $validRun = Invoke-TestSemanticBridge -Fixture $fixture -Items $validItems -Request $validRequest -Decision $validDecision `
            -Provider $validProvider -ProviderContext ([pscustomobject]@{ expectedText = $validText })
        Assert-TestCondition ([string]$validRun.status -ceq 'PASS') "Valid strict-UTF8 bytes did not pass as text: $($validRun.reason)"
        Assert-TestCondition ([int]$validRun.providerCallCount -eq 1) 'Valid strict-UTF8 text did not reach the provider exactly once.'
    }

    # Scenario: A provider callback spawns a blocking descendant and later a separate callback floods stderr before blocking.
    # Purpose: The isolated boundary must kill the complete owned tree on PS5.1 and enforce stream quotas while reading, not after buffering.
    It 'InterT130_provider_callback_boundary_kills_descendants_and_enforces_output_quotas' {
        $fixture = New-TestSemanticFixture
        $startedMarker = Join-Path $TestDrive 'provider-started.txt'
        $lateMarker = Join-Path $TestDrive 'provider-late-output.txt'
        $childStartedMarker = Join-Path $TestDrive 'provider-child-started.txt'
        $childLateMarker = Join-Path $TestDrive 'provider-child-late-output.txt'
        $childPidMarker = Join-Path $TestDrive 'provider-child-pid.txt'
        $slowProvider = {
            param($providerRequest, $callbackContext)
            $childStartedPath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$callbackContext.childStartedMarker))
            $childLatePath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$callbackContext.childLateMarker))
            $childScript = @"
`$startedPath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$childStartedPath'))
`$latePath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$childLatePath'))
[IO.File]::WriteAllText(`$startedPath, 'started')
[Threading.Thread]::Sleep(3000)
[IO.File]::WriteAllText(`$latePath, 'late descendant output')
"@
            $childInfo = New-Object Diagnostics.ProcessStartInfo
            $childInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $childInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $childInfo.UseShellExecute = $false
            $childInfo.CreateNoWindow = $true
            $child = New-Object Diagnostics.Process
            $child.StartInfo = $childInfo
            if (-not $child.Start()) { throw 'provider descendant did not start.' }
            [IO.File]::WriteAllText([string]$callbackContext.childPidMarker, [string]$child.Id)
            $child.Dispose()
            $childStartDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath ([string]$callbackContext.childStartedMarker) -PathType Leaf) -and [DateTime]::UtcNow -lt $childStartDeadline) {
                [Threading.Thread]::Sleep(25)
            }
            if (-not (Test-Path -LiteralPath ([string]$callbackContext.childStartedMarker) -PathType Leaf)) { throw 'provider descendant did not record startup.' }
            [IO.File]::WriteAllText(
                [string]$callbackContext.startedMarker,
                [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
            )
            [Threading.Thread]::Sleep(3000)
            [IO.File]::WriteAllText([string]$callbackContext.lateMarker, 'late provider output')
            return [pscustomobject][ordered]@{ findings = @(); analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery') }
        }
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $slowProvider -ProviderContext ([pscustomobject]@{
                startedMarker = $startedMarker
                lateMarker = $lateMarker
                childStartedMarker = $childStartedMarker
                childLateMarker = $childLateMarker
                childPidMarker = $childPidMarker
            }) -TimeoutSeconds 2
        $returnedTick = [Diagnostics.Stopwatch]::GetTimestamp()
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'A provider callback beyond its deadline unexpectedly passed.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The timed provider callback was not actually invoked.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'A timed provider callback emitted evidence.'
        Assert-TestCondition (Test-Path -LiteralPath $startedMarker -PathType Leaf) 'The provider callback did not record its actual invocation.'
        Assert-TestCondition (Test-Path -LiteralPath $childStartedMarker -PathType Leaf) 'The provider descendant did not record its actual invocation.'
        Assert-TestCondition (Test-Path -LiteralPath $childPidMarker -PathType Leaf) 'The provider descendant PID was not captured.'
        $callbackStartedTick = [long]([IO.File]::ReadAllText($startedMarker))
        $elapsedFromCallbackStartSeconds = ([double]($returnedTick - $callbackStartedTick)) / [double][Diagnostics.Stopwatch]::Frequency
        Assert-TestCondition ($elapsedFromCallbackStartSeconds -lt 2.5) 'The bridge waited for the provider callback after its invocation deadline.'
        Start-Sleep -Milliseconds 250
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) {
            # Windows reports the callback child in the host PID namespace.  On
            # Linux this marker contains a namespace-local PID, so Get-Process
            # could inspect an unrelated host process instead of the callback child.
            $childProcess = Get-Process -Id ([int]([IO.File]::ReadAllText($childPidMarker))) -ErrorAction SilentlyContinue
            Assert-TestCondition ($null -eq $childProcess) 'A timed-out provider callback descendant remained alive after boundary cleanup.'
        }
        Start-Sleep -Milliseconds 2500
        Assert-TestCondition (-not (Test-Path -LiteralPath $lateMarker)) 'A timed-out provider callback continued and produced late output.'
        Assert-TestCondition (-not (Test-Path -LiteralPath $childLateMarker)) 'A timed-out provider callback descendant continued and produced late output.'

        $quotaStartedMarker = Join-Path $TestDrive 'provider-quota-started.txt'
        $quotaLateMarker = Join-Path $TestDrive 'provider-quota-late-output.txt'
        $noisyProvider = {
            param($providerRequest, $callbackContext)
            [IO.File]::WriteAllText(
                [string]$callbackContext.startedMarker,
                [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
            )
            [Console]::Error.Write(('e' * 20000))
            [Threading.Thread]::Sleep(3000)
            [IO.File]::WriteAllText([string]$callbackContext.lateMarker, 'late quota output')
            return [pscustomobject][ordered]@{ findings = @(); analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery') }
        }
        $quotaRun = Invoke-TestSemanticBridge -Fixture $fixture -Provider $noisyProvider -ProviderContext ([pscustomobject]@{
                startedMarker = $quotaStartedMarker
                lateMarker = $quotaLateMarker
            }) -TimeoutSeconds 5
        $quotaReturnedTick = [Diagnostics.Stopwatch]::GetTimestamp()
        Assert-TestCondition ([string]$quotaRun.status -ceq 'FAILED') 'A provider callback exceeding stderr quota unexpectedly passed.'
        Assert-TestCondition (Test-Path -LiteralPath $quotaStartedMarker -PathType Leaf) 'The quota callback did not record its invocation.'
        $quotaStartedTick = [long]([IO.File]::ReadAllText($quotaStartedMarker))
        $quotaElapsedSeconds = ([double]($quotaReturnedTick - $quotaStartedTick)) / [double][Diagnostics.Stopwatch]::Frequency
        Assert-TestCondition ($quotaElapsedSeconds -lt 2.5) 'The bridge buffered callback stderr until the callback deadline instead of enforcing the live quota.'
        Start-Sleep -Milliseconds 2500
        Assert-TestCondition (-not (Test-Path -LiteralPath $quotaLateMarker)) 'A quota-terminated provider callback continued and produced late output.'
    }

    # Scenario: Provider work completes, but the signer records its actual invocation and enters a non-cooperative .NET blocking call.
    # Purpose: The signer deadline is measured from invocation; its terminable boundary cannot emit an unsigned or late PASS artifact.
    It 'InterT140_signer_callback_deadline_fails_closed' {
        $fixture = New-TestSemanticFixture
        $startedMarker = Join-Path $TestDrive 'signer-started.txt'
        $lateMarker = Join-Path $TestDrive 'signer-late-output.txt'
        $slowSigner = {
            param($signerRequest, $callbackContext)
            [IO.File]::WriteAllText(
                [string]$callbackContext.startedMarker,
                [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
            )
            [Threading.Thread]::Sleep(3000)
            [IO.File]::WriteAllText([string]$callbackContext.lateMarker, 'late signer output')
            return [pscustomobject][ordered]@{ keyId = 'fixture-key'; algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'; signature = 'AA==' }
        }
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Signer $slowSigner -SignerContext ([pscustomobject]@{
                startedMarker = $startedMarker
                lateMarker = $lateMarker
            }) -TimeoutSeconds 1
        $returnedTick = [Diagnostics.Stopwatch]::GetTimestamp()
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'A signer callback beyond its deadline unexpectedly passed.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The signer timeout did not preserve the completed provider-call count.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'A timed signer callback emitted evidence.'
        Assert-TestCondition (Test-Path -LiteralPath $startedMarker -PathType Leaf) 'The signer callback did not record its actual invocation.'
        $callbackStartedTick = [long]([IO.File]::ReadAllText($startedMarker))
        $elapsedFromCallbackStartSeconds = ([double]($returnedTick - $callbackStartedTick)) / [double][Diagnostics.Stopwatch]::Frequency
        Assert-TestCondition ($elapsedFromCallbackStartSeconds -lt 2.5) 'The bridge waited for the signer callback after its invocation deadline.'
        Start-Sleep -Milliseconds 2500
        Assert-TestCondition (-not (Test-Path -LiteralPath $lateMarker)) 'A timed-out signer callback continued and produced late output.'

        $expiredGuardMarker = Join-Path $TestDrive 'expired-wrapper-guard-callback-ran.txt'
        $module = Get-Module StandardSemanticBridge | Select-Object -First 1
        $expiredGuardError = Get-TestErrorMessage {
            & $module {
                param($markerPath)
                $callback = {
                    param($argument, $callbackContext)
                    [IO.File]::WriteAllText([string]$callbackContext.markerPath, 'invoked')
                    return 'callback-ran'
                }
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext ([pscustomobject]@{ markerPath = $markerPath }) `
                    -TimeoutMilliseconds 5000 `
                    -ConsentExpiresAt ([DateTime]::UtcNow.AddSeconds(-1)) `
                    -Context 'guarded direct callback'
            } $expiredGuardMarker
        }
        Assert-TestCondition ([string]$expiredGuardError -match 'consent-expired-before-callback-invocation') 'The isolated callback wrapper did not report an expired consent guard.'
        Assert-TestCondition (-not (Test-Path -LiteralPath $expiredGuardMarker)) 'The isolated callback ran after the wrapper received an expired consent guard.'
    }

    # Scenario: Canonical hashing receives floating-point and non-finite numeric values.
    # Purpose: Numeric digests must use invariant round-trip formatting and reject JSON-invalid NaN/Infinity values.
    It 'UnitT150_numeric_canonicalization_is_invariant_and_fails_closed_for_nonfinite_values' {
        Assert-TestCondition ((Get-StandardSemanticBridgeCanonicalJson -Value ([double]1.5)) -ceq '1.5') 'Floating-point canonical JSON was not invariant.'
        Assert-TestCondition ((Get-StandardSemanticBridgeCanonicalJson -Value ([decimal]1.50)) -ceq '1.5') 'Decimal canonical JSON was not normalized.'
        $errorMessage = Get-TestErrorMessage { Get-StandardSemanticBridgeCanonicalJson -Value ([double]::NaN) }
        Assert-TestCondition ($errorMessage -match 'NaN|Infinity') 'Non-finite numeric canonicalization did not fail closed.'
    }

    Context 'SYP154 replay ledger concurrency' {
        # Scenario: Two verifier runspaces consume the same signed evidence through one caller-owned ledger.
        # Purpose: The check-and-consume operation must be atomic, so at most one verifier can accept the evidence.
        It 'InterT191_shared_replay_ledger_allows_only_one_concurrent_evidence_consumer' {
            if (-not ('Syp154Replay.BarrierHashtable' -as [type])) {
                $barrierSource = @"
using System;
using System.Collections;
using System.Threading;

namespace Syp154Replay {
    public sealed class BarrierHashtable : Hashtable {
        private readonly Barrier readers = new Barrier(2);
        private readonly object writeLock = new object();

        public override bool ContainsKey(object key) {
            bool exists = base.ContainsKey(key);
            if (!String.Equals(key as string, "SyncRoot", StringComparison.Ordinal) && !exists && !readers.SignalAndWait(TimeSpan.FromSeconds(8))) {
                throw new TimeoutException("both verifier calls did not reach the replay check");
            }
            return exists;
        }

        public override object this[object key] {
            get { return base[key]; }
            set { lock (writeLock) { base[key] = value; } }
        }
    }
}
"@
                Add-Type -TypeDefinition $barrierSource
            }

            $fixture = New-TestSemanticFixture
            $publicKeyOne = $null
            $publicKeyTwo = $null
            $powerShellOne = $null
            $powerShellTwo = $null
            try {
                $run = Invoke-TestSemanticBridge -Fixture $fixture
                Assert-TestCondition ([string]$run.status -ceq 'PASS') 'The signed fixture evidence must pass before testing concurrent replay consumption.'

                $publicKeyOne = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
                $publicKeyTwo = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
                $publicParameters = $fixture.PublicRsa.ExportParameters($false)
                $publicKeyOne.ImportParameters($publicParameters)
                $publicKeyTwo.ImportParameters($publicParameters)
                $replayLedger = [Syp154Replay.BarrierHashtable]::new()
                $sharedParameters = @{
                    EvidenceBytes = [byte[]]$run.evidenceBytes
                    ConsentRequest = $fixture.Request
                    ConsentDecision = $fixture.Decision
                    ExpectedKeyId = 'fixture-key'
                    ExpectedBindings = $fixture.Bindings
                    ExpectedProviderRoute = $fixture.Route
                    ExpectedPurpose = 'Synthetic test-only semantic review.'
                    ExpectedScope = $fixture.Scope
                    ExpectedProviderTextInventory = $fixture.Inventory
                    Now = [DateTime]::UtcNow
                    ReplayLedger = $replayLedger
                }
                $parametersOne = [hashtable]$sharedParameters.Clone()
                $parametersOne.PublicKey = $publicKeyOne
                $parametersTwo = [hashtable]$sharedParameters.Clone()
                $parametersTwo.PublicKey = $publicKeyTwo
                $modulePath = Join-Path $script:RepositoryRoot 'scripts\StandardSemanticBridge.psm1'
                $verifyScript = 'param($modulePath, $parameters); Import-Module -Name $modulePath -Force; Test-StandardSemanticBridgeEvidence @parameters'
                $powerShellOne = [powershell]::Create()
                $powerShellTwo = [powershell]::Create()
                [void]$powerShellOne.AddScript($verifyScript).AddArgument($modulePath).AddArgument($parametersOne)
                [void]$powerShellTwo.AddScript($verifyScript).AddArgument($modulePath).AddArgument($parametersTwo)
                $asyncOne = $powerShellOne.BeginInvoke()
                $asyncTwo = $powerShellTwo.BeginInvoke()
                $resultOne = @($powerShellOne.EndInvoke($asyncOne))[0]
                $resultTwo = @($powerShellTwo.EndInvoke($asyncTwo))[0]
                $results = @($resultOne, $resultTwo)
                $validResults = @($results | Where-Object { $null -ne $_ -and [bool]$_.valid })
                $rejectedResults = @($results | Where-Object { $null -ne $_ -and -not [bool]$_.valid })
                Assert-TestCondition ($validResults.Count -eq 1) "Concurrent duplicate evidence verification should have one winner; observed $($validResults.Count) valid results."
                Assert-TestCondition ($rejectedResults.Count -eq 1 -and [string]$rejectedResults[0].reason -match 'replay') 'The losing verifier call must report a replay rejection.'
                Assert-TestCondition (@($replayLedger.Keys).Count -eq 1) 'The shared replay ledger must contain exactly one consumed evidence ID.'

                $shadowRun = Invoke-TestSemanticBridge -Fixture $fixture
                Assert-TestCondition ([string]$shadowRun.status -ceq 'PASS') 'Fresh signed evidence must pass before testing the SyncRoot-key collision.'
                $shadowLedger = @{}
                $shadowLedger['SyncRoot'] = $null
                $shadowParameters = [hashtable]$sharedParameters.Clone()
                $shadowParameters.EvidenceBytes = [byte[]]$shadowRun.evidenceBytes
                $shadowParameters.PublicKey = $publicKeyOne
                $shadowParameters.Now = [DateTime]::UtcNow
                $shadowParameters.ReplayLedger = $shadowLedger
                $shadowResult = Test-StandardSemanticBridgeEvidence @shadowParameters
                Assert-TestCondition ([bool]$shadowResult.valid) "A caller ledger with a null SyncRoot key must still verify fresh evidence; reason: $($shadowResult.reason)."
                $shadowEvidenceId = [string]$shadowResult.evidence.evidenceId
                Assert-TestCondition ($shadowLedger.ContainsKey($shadowEvidenceId)) 'The verifier did not consume evidence when the caller ledger contains a SyncRoot key.'
                $shadowEntry = $shadowLedger[$shadowEvidenceId]
                Assert-TestCondition ([string]$shadowEntry.status -ceq 'consumed' -and [string]$shadowEntry.evidenceSha256 -ceq [string]$shadowResult.evidenceSha256) 'The SyncRoot-key collision ledger entry does not match the verified evidence.'
                Assert-TestCondition ($shadowLedger.ContainsKey('SyncRoot') -and $null -eq $shadowLedger['SyncRoot']) 'The verifier overwrote the caller-owned SyncRoot entry.'
            }
            finally {
                if ($null -ne $powerShellOne) { $powerShellOne.Dispose() }
                if ($null -ne $powerShellTwo) { $powerShellTwo.Dispose() }
                if ($null -ne $publicKeyOne) { $publicKeyOne.Dispose() }
                if ($null -ne $publicKeyTwo) { $publicKeyTwo.Dispose() }
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }
}

Describe 'SYP-212 caller RSA snapshot coverage' -Tag 'SYP212RSA' {
    BeforeAll {
        $script:RsaSnapshotBridgePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'scripts\StandardSemanticBridge.psm1'
        Import-Module $script:RsaSnapshotBridgePath -Force

        function Assert-RsaSnapshotTestCondition {
            param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function New-RsaSnapshotFixture {
            $now = [DateTime]::UtcNow.AddMinutes(-5)
            $items = @([pscustomobject][ordered]@{ path = 'skills/example/SKILL.md'; contentKind = 'skill-instructions'; text = 'synthetic semantic bridge text' })
            $bindings = [pscustomobject][ordered]@{
                candidate = [pscustomobject][ordered]@{ candidateId = ('a' * 64); sourceRepository = 'https://example.test/source.git'; sourceRevision = ('b' * 40); baseRevision = ('c' * 40); sourceTree = ('d' * 40); inputInventorySha256 = ('e' * 64) }
                authority = [pscustomobject][ordered]@{ repository = 'https://example.test/authority.git'; revision = ('f' * 40); tree = ('1' * 40); snapshotInventorySha256 = ('2' * 64) }
                tool = [pscustomobject][ordered]@{ toolId = 'fixture-tool'; version = '1.0.0'; packageSha256 = ('3' * 64); resolverReceiptSha256 = ('4' * 64) }
                launch = [pscustomobject][ordered]@{ resolutionRunId = '11111111-1111-4111-8111-111111111111'; launchReceiptSha256 = ('5' * 64); consumptionSha256 = ('6' * 64) }
            }
            $route = [pscustomobject][ordered]@{ provider = 'fixture-provider'; adapter = 'fixture-adapter'; accountOrTenant = 'fixture-account'; model = 'fixture-model'; endpoint = 'https://example.test/v1'; dataRegion = 'fixture-region'; retentionPolicy = 'fixture-no-retention'; trainingPolicy = 'fixture-no-training' }
            $scope = [pscustomobject][ordered]@{ description = 'Synthetic test-only semantic scope.'; paths = @('skills/example/SKILL.md'); contentKinds = @('skill-instructions') }
            $analyzers = @(
                [pscustomobject][ordered]@{ id = 'semantic_developer_intent'; version = '1.0.0'; sourceSha256 = ('7' * 64) }
                [pscustomobject][ordered]@{ id = 'semantic_security_discovery'; version = '1.0.0'; sourceSha256 = ('8' * 64) }
            )
            $inventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $items
            $analyzerSet = New-StandardSemanticBridgeAnalyzerSet -Analyzers $analyzers
            $request = New-StandardSemanticBridgeConsentRequest -Bindings $bindings -ProviderRoute $route -Purpose 'Synthetic test-only semantic review.' -Scope $scope -ProviderTextInventory $inventory -AnalyzerSet $analyzerSet -RequestId '11111111-1111-4111-8111-111111111112' -RequestedAt $now -ExpiresAt $now.AddHours(1)
            $authorizer = [pscustomobject][ordered]@{ subject = 'fixture-authorizer'; authorityScope = 'fixture-semantic-egress'; authenticationContext = 'fixture-strong-authentication' }
            $decision = New-StandardSemanticBridgeConsentDecision -Request $request -Authorizer $authorizer -DecisionId '11111111-1111-4111-8111-111111111113' -AuthorizedAt $now.AddMinutes(1)
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $publicRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $publicRsa.ImportParameters($rsa.ExportParameters($false))
            $provider = {
                param($providerRequest, $callbackContext)
                $path = [string]$providerRequest.path
                return [pscustomobject][ordered]@{
                    findings = @(
                        [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                        [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                    )
                    analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
                }
            }
            $signer = {
                param($signerRequest, $callbackContext)
                $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
                try {
                    $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                    $signature = $signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                    return [pscustomobject][ordered]@{ keyId = 'fixture-key'; algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'; signature = [Convert]::ToBase64String($signature) }
                }
                finally { $signingKey.Dispose() }
            }
            return [pscustomobject][ordered]@{
                Bindings = $bindings; Route = $route; Scope = $scope; Items = $items; Analyzers = $analyzers
                Inventory = $inventory; Request = $request; Decision = $decision; Provider = $provider; Signer = $signer
                SignerContext = [pscustomobject][ordered]@{ privateKeyXml = $rsa.ToXmlString($true) }; Rsa = $rsa; PublicRsa = $publicRsa
            }
        }

        function Invoke-RsaSnapshotFixture {
            param([Parameter(Mandatory = $true)] $Fixture, [scriptblock] $Provider = $null, $ProviderContext = $null, [scriptblock] $Signer = $null, $SignerContext = $null, $ExpectedPublicKey = $null)
            if ($null -eq $Provider) { $Provider = $Fixture.Provider }
            if ($null -eq $ProviderContext) { $ProviderContext = [pscustomobject]@{} }
            if ($null -eq $Signer) { $Signer = $Fixture.Signer }
            if ($null -eq $SignerContext) { $SignerContext = $Fixture.SignerContext }
            if ($null -eq $ExpectedPublicKey) { $ExpectedPublicKey = $Fixture.PublicRsa }
            return Invoke-StandardSemanticBridge `
                -ConsentRequest $Fixture.Request -ConsentDecision $Fixture.Decision -Bindings $Fixture.Bindings `
                -ProviderRoute $Fixture.Route -Purpose 'Synthetic test-only semantic review.' -Scope $Fixture.Scope `
                -TextItems @($Fixture.Items) -Analyzers $Fixture.Analyzers -ProviderCallback $Provider `
                -SignerCallback $Signer -ExpectedSignerPublicKey $ExpectedPublicKey -ExpectedSignerKeyId 'fixture-key' `
                -ProviderCallbackContext $ProviderContext -SignerCallbackContext $SignerContext -IdempotencyLedger @{} -TimeoutSeconds 30 -Now ([DateTime]::UtcNow)
        }
    }

    # Scenario: A separate runspace replaces the caller-owned verifier key after
    # provider execution starts, while the signer uses the replacement key.
    # Purpose: The bridge must verify against its entry-time public-key snapshot.
    It 'InterT182_caller_public_key_mutation_during_provider_callback_fails_closed' {
        $fixture = $null
        $rogueRsa = $null
        $mutator = $null
        $mutatorAsync = $null
        $providerStartedMarker = Join-Path $TestDrive 'rsa-provider-started.txt'
        $keyMutationMarker = Join-Path $TestDrive 'rsa-key-mutated.txt'
        $provider = {
            param($providerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.providerStartedMarker, 'started')
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath ([string]$callbackContext.keyMutationMarker) -PathType Leaf)) {
                if ([DateTime]::UtcNow -ge $deadline) { throw 'timed out waiting for the caller RSA mutation.' }
                [Threading.Thread]::Sleep(20)
            }
            $path = [string]$providerRequest.path
            return [pscustomobject][ordered]@{
                findings = @(
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
                    [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
                )
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        try {
            $fixture = New-RsaSnapshotFixture
            $rogueRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $mutator = [System.Management.Automation.PowerShell]::Create()
            [void]$mutator.AddScript({
                param($callerRsa, $roguePublicXml, $providerStartedPath, $mutationDonePath)
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while (-not (Test-Path -LiteralPath $providerStartedPath -PathType Leaf)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'timed out waiting for provider-start marker.' }
                    [Threading.Thread]::Sleep(20)
                }
                $callerRsa.FromXmlString([string]$roguePublicXml)
                [IO.File]::WriteAllText([string]$mutationDonePath, 'mutated')
            }.ToString()).AddArgument($fixture.PublicRsa).AddArgument($rogueRsa.ToXmlString($false)).AddArgument($providerStartedMarker).AddArgument($keyMutationMarker)
            $mutatorAsync = $mutator.BeginInvoke()
            $rogueSignerContext = [pscustomobject][ordered]@{ privateKeyXml = $rogueRsa.ToXmlString($true) }
            $run = Invoke-RsaSnapshotFixture `
                -Fixture $fixture `
                -Provider $provider `
                -ProviderContext ([pscustomobject][ordered]@{ providerStartedMarker = $providerStartedMarker; keyMutationMarker = $keyMutationMarker }) `
                -SignerContext $rogueSignerContext
            [void]$mutator.EndInvoke($mutatorAsync)
            Assert-RsaSnapshotTestCondition (-not $mutator.HadErrors -and $mutator.Streams.Error.Count -eq 0) 'The external runspace failed while replacing the caller RSA key.'
            Assert-RsaSnapshotTestCondition (Test-Path -LiteralPath $providerStartedMarker -PathType Leaf) 'Provider callback did not start the coordinated key mutation.'
            Assert-RsaSnapshotTestCondition (Test-Path -LiteralPath $keyMutationMarker -PathType Leaf) 'The external runspace did not complete the caller RSA mutation.'
            Assert-RsaSnapshotTestCondition ([string]$run.status -ceq 'FAILED') "A signer using a key installed during provider execution returned $($run.status)."
            Assert-RsaSnapshotTestCondition ([int]$run.providerCallCount -eq 1 -and [int]$run.successfulProviderCallCount -eq 1) 'The bridge did not complete exactly one provider call before rejecting the signature.'
            Assert-RsaSnapshotTestCondition ([string]$run.reason -ceq 'signer signature verification failed.') 'The bridge failure was not caused by rejecting the signer signature against the entry-time key.'
            Assert-RsaSnapshotTestCondition ($null -eq $run.evidenceBytes) 'Caller RSA mutation during provider execution emitted evidence bytes.'
            $callerPublicParameters = $fixture.PublicRsa.ExportParameters($false)
            Assert-RsaSnapshotTestCondition ($null -ne $callerPublicParameters.Modulus -and $callerPublicParameters.Modulus.Length -gt 0) 'The bridge disposed or otherwise broke the caller-owned RSA instance.'
        }
        finally {
            if ($null -ne $mutator) {
                if ($null -ne $mutatorAsync -and -not $mutatorAsync.IsCompleted) { $mutator.Stop() }
                $mutator.Dispose()
            }
            if ($null -ne $rogueRsa) { $rogueRsa.Dispose() }
            if ($null -ne $fixture) {
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }

    # Scenario: Evidence verification overlaps an external mutation at the
    # export/verify boundary of a caller-owned RSA implementation.
    # Purpose: Verification must use captured public parameters and leave caller
    # ownership intact even when the supplied RSA changes during validation.
    It 'InterT183_evidence_verifier_uses_entry_snapshot_during_caller_key_mutation' {
        if (-not ('Syp212.CoordinatedPublicRsa' -as [type])) {
            $coordinatedRsaSource = @'
using System;
using System.Security.Cryptography;
using System.Threading;

namespace Syp212 {
    public sealed class CoordinatedPublicRsa : RSA {
        private readonly RSA inner;
        private readonly RSAParameters replacement;
        private readonly bool failPublicExport;
        private readonly ManualResetEvent mutationRequested = new ManualResetEvent(false);
        private readonly ManualResetEvent mutationCompleted = new ManualResetEvent(false);
        private volatile bool privateExportRequested;

        public CoordinatedPublicRsa(RSA innerKey, RSAParameters replacementParameters) {
            inner = innerKey;
            replacement = replacementParameters;
        }

        public CoordinatedPublicRsa(RSA innerKey, RSAParameters replacementParameters, bool shouldFailPublicExport) {
            inner = innerKey;
            replacement = replacementParameters;
            failPublicExport = shouldFailPublicExport;
        }

        public RSA Inner { get { return inner; } }
        public WaitHandle MutationRequested { get { return mutationRequested; } }
        public bool PrivateExportRequested { get { return privateExportRequested; } }

        public void MutateCallerKey() {
            inner.ImportParameters(replacement);
            mutationCompleted.Set();
        }

        private void WaitForMutation() {
            mutationRequested.Set();
            if (!mutationCompleted.WaitOne(15000)) {
                throw new CryptographicException("timed out waiting for external caller-key mutation.");
            }
        }

        public override RSAParameters ExportParameters(bool includePrivateParameters) {
            if (includePrivateParameters) {
                privateExportRequested = true;
                throw new CryptographicException("private RSA export is forbidden in this test.");
            }
            if (failPublicExport) {
                throw new CryptographicException("test public RSA export failure.");
            }
            RSAParameters captured = inner.ExportParameters(false);
            WaitForMutation();
            return captured;
        }

        public override void ImportParameters(RSAParameters parameters) {
            inner.ImportParameters(parameters);
        }

        public override bool VerifyHash(byte[] hash, byte[] signature, HashAlgorithmName hashAlgorithm, RSASignaturePadding padding) {
            WaitForMutation();
            return inner.VerifyHash(hash, signature, hashAlgorithm, padding);
        }

        public override bool VerifyData(byte[] data, int offset, int count, byte[] signature, HashAlgorithmName hashAlgorithm, RSASignaturePadding padding) {
            WaitForMutation();
            return inner.VerifyData(data, offset, count, signature, hashAlgorithm, padding);
        }

        protected override void Dispose(bool disposing) {
            if (disposing) {
                inner.Dispose();
                mutationRequested.Dispose();
                mutationCompleted.Dispose();
            }
            base.Dispose(disposing);
        }
    }

}
'@
            Add-Type -TypeDefinition $coordinatedRsaSource -ErrorAction Stop
        }

        $fixture = $null
        $rogueRsa = $null
        $innerPublicRsa = $null
        $coordinatedRsa = $null
        $mutator = $null
        $mutatorAsync = $null
        $failedExportInnerRsa = $null
        $failedExportRsa = $null
        try {
            $fixture = New-RsaSnapshotFixture
            $honestRun = Invoke-RsaSnapshotFixture -Fixture $fixture
            Assert-RsaSnapshotTestCondition ([string]$honestRun.status -ceq 'PASS') 'The honest fixture signature did not pass before verifier-race coverage.'
            $rogueRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $innerPublicRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $innerPublicRsa.ImportParameters($fixture.PublicRsa.ExportParameters($false))
            $replacementParameters = $rogueRsa.ExportParameters($false)
            $coordinatedRsa = [Syp212.CoordinatedPublicRsa]::new($innerPublicRsa, $replacementParameters)
            $mutator = [System.Management.Automation.PowerShell]::Create()
            [void]$mutator.AddScript({
                param($coordinatedKey)
                if (-not $coordinatedKey.MutationRequested.WaitOne(20000)) { throw 'timed out waiting for evidence verifier synchronization.' }
                $coordinatedKey.MutateCallerKey()
            }.ToString()).AddArgument($coordinatedRsa)
            $mutatorAsync = $mutator.BeginInvoke()
            $verification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $honestRun.evidenceBytes `
                -ConsentRequest $fixture.Request `
                -ConsentDecision $fixture.Decision `
                -PublicKey $coordinatedRsa `
                -ExpectedKeyId 'fixture-key' `
                -ExpectedBindings $fixture.Bindings `
                -ExpectedProviderRoute $fixture.Route `
                -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $fixture.Scope `
                -ExpectedProviderTextInventory $fixture.Inventory `
                -Now ([DateTime]::UtcNow)
            [void]$mutator.EndInvoke($mutatorAsync)
            Assert-RsaSnapshotTestCondition (-not $mutator.HadErrors -and $mutator.Streams.Error.Count -eq 0) 'The verifier-race external runspace failed to mutate the caller key.'
            Assert-RsaSnapshotTestCondition ([bool]$verification.valid) "The evidence verifier did not use its entry snapshot: $($verification.reason)"
            Assert-RsaSnapshotTestCondition (-not $coordinatedRsa.PrivateExportRequested) 'The verifier requested private RSA parameters.'
            $stillUsable = $coordinatedRsa.Inner.ExportParameters($false)
            Assert-RsaSnapshotTestCondition ($null -ne $stillUsable.Modulus -and $stillUsable.Modulus.Length -gt 0) 'The verifier disposed or otherwise broke the caller-owned RSA instance.'

            $failedExportInnerRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $failedExportInnerRsa.ImportParameters($fixture.PublicRsa.ExportParameters($false))
            $failedExportRsa = [Syp212.CoordinatedPublicRsa]::new($failedExportInnerRsa, $replacementParameters, $true)
            $failedExportVerification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $honestRun.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
                -PublicKey $failedExportRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
                -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
            Assert-RsaSnapshotTestCondition (-not [bool]$failedExportVerification.valid -and [string]$failedExportVerification.reason -match 'test public RSA export failure') 'The evidence verifier did not fail closed when public-parameter export failed.'
            $failedExportBridgeRun = Invoke-RsaSnapshotFixture -Fixture $fixture -ExpectedPublicKey $failedExportRsa
            Assert-RsaSnapshotTestCondition ([string]$failedExportBridgeRun.status -ceq 'FAILED' -and $null -eq $failedExportBridgeRun.evidenceBytes) 'The bridge emitted evidence after public-parameter export failed.'
            Assert-RsaSnapshotTestCondition (-not $failedExportRsa.PrivateExportRequested) 'The bridge requested private RSA parameters while failing closed.'
            $callerAfterExportFailure = $failedExportRsa.Inner.ExportParameters($false)
            Assert-RsaSnapshotTestCondition ($null -ne $callerAfterExportFailure.Modulus -and $callerAfterExportFailure.Modulus.Length -gt 0) 'The bridge disposed the caller-owned RSA after export failure.'
        }
        finally {
            if ($null -ne $mutator) {
                if ($null -ne $mutatorAsync -and -not $mutatorAsync.IsCompleted) { $mutator.Stop() }
                $mutator.Dispose()
            }
            if ($null -ne $failedExportRsa) { $failedExportRsa.Dispose() }
            elseif ($null -ne $failedExportInnerRsa) { $failedExportInnerRsa.Dispose() }
            if ($null -ne $coordinatedRsa) { $coordinatedRsa.Dispose() }
            elseif ($null -ne $innerPublicRsa) { $innerPublicRsa.Dispose() }
            if ($null -ne $rogueRsa) { $rogueRsa.Dispose() }
            if ($null -ne $fixture) {
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }

    It 'InterT189_replay_ledger_mutation_cannot_change_verified_evidence_bytes_or_digest' {
        if (-not ('Syp212.ByteMutationReplayLedger' -as [type])) {
            $byteMutationLedgerSource = @'
using System.Collections;

namespace Syp212 {
    public sealed class ByteMutationReplayLedger : Hashtable {
        private readonly byte[] input;
        public bool MutationApplied { get; private set; }

        public ByteMutationReplayLedger(byte[] evidenceBytes) {
            input = evidenceBytes;
        }

        public override bool ContainsKey(object key) {
            input[0] = 0x5b;
            MutationApplied = true;
            return base.ContainsKey(key);
        }
    }


}
'@
            Add-Type -TypeDefinition $byteMutationLedgerSource -ErrorAction Stop
        }

        $fixture = $null
        try {
            $fixture = New-RsaSnapshotFixture
            $honestRun = Invoke-RsaSnapshotFixture -Fixture $fixture
            Assert-RsaSnapshotTestCondition ([string]$honestRun.status -ceq 'PASS') 'The honest fixture signature did not pass before evidence-byte mutation coverage.'
            $expectedEvidenceSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact $honestRun.evidence
            $callerEvidenceBytes = [byte[]]$honestRun.evidenceBytes
            $replayLedger = [Syp212.ByteMutationReplayLedger]::new($callerEvidenceBytes)
            $verification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $callerEvidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
                -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
                -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
                -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory `
                -ReplayLedger $replayLedger -Now ([DateTime]::UtcNow)

            Assert-RsaSnapshotTestCondition ([bool]$replayLedger.MutationApplied -and $callerEvidenceBytes[0] -eq 0x5b) 'The replay-ledger race did not mutate the caller-owned evidence bytes.'
            Assert-RsaSnapshotTestCondition ([bool]$verification.valid) "The original signed evidence did not verify: $($verification.reason)"
            Assert-RsaSnapshotTestCondition ([string]$verification.evidenceSha256 -ceq [string]$expectedEvidenceSha) 'The verifier returned a digest for bytes different from the signed entry snapshot.'
            $replayEntry = $replayLedger[[string]$honestRun.evidence.evidenceId]
            Assert-RsaSnapshotTestCondition ([string]$replayEntry.evidenceSha256 -ceq [string]$expectedEvidenceSha) 'The replay ledger recorded a digest for bytes different from the signed entry snapshot.'
        }
        finally {
            if ($null -ne $fixture) {
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }

    It 'InterT190_evidence_verifier_keeps_authorization_inputs_bound_to_entry_snapshot' {
        $fixture = $null
        $module = $null
        $originalValidator = $null
        try {
            $fixture = New-RsaSnapshotFixture
            $run = Invoke-RsaSnapshotFixture -Fixture $fixture
            Assert-RsaSnapshotTestCondition ([string]$run.status -ceq 'PASS') 'The signed fixture did not pass before consent-input snapshot coverage.'

            $expectedScope = [pscustomobject][ordered]@{
                description = 'Different expected authorization scope'
                paths = @($fixture.Scope.paths)
                contentKinds = @($fixture.Scope.contentKinds)
            }
            $requestA = New-StandardSemanticBridgeConsentRequest `
                -Bindings $fixture.Bindings -ProviderRoute $fixture.Route `
                -Purpose 'Synthetic test-only semantic review.' -Scope $expectedScope `
                -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.Request.analyzerSet `
                -RequestId $fixture.Request.requestId -RequestedAt $fixture.Request.requestedAt `
                -ExpiresAt $fixture.Request.expiresAt
            $decisionA = New-StandardSemanticBridgeConsentDecision `
                -Request $requestA -Authorizer $fixture.Decision.authorizer `
                -DecisionId $fixture.Decision.decisionId -AuthorizedAt $fixture.Decision.authorizedAt

            $module = Get-Module StandardSemanticBridge | Select-Object -First 1
            $originalValidator = & $module { (Get-Item Function:\Test-StandardSemanticBridgeConsent).ScriptBlock }
            & $module {
                param($original, $requestAValue, $decisionAValue, $requestBValue, $decisionBValue)
                $script:Syp212ConsentAuditOriginalValidator = $original
                $script:Syp212ConsentAuditRequestA = $requestAValue
                $script:Syp212ConsentAuditDecisionA = $decisionAValue
                $script:Syp212ConsentAuditRequestB = $requestBValue
                $script:Syp212ConsentAuditDecisionB = $decisionBValue
                $script:Syp212ConsentAuditInitialValid = $false
                $script:Syp212ConsentAuditMutationApplied = $false
                Set-Item Function:\Test-StandardSemanticBridgeConsent -Value {
                    param($ConsentRequest, $ConsentDecision, $CurrentBindings, $CurrentProviderRoute, $CurrentPurpose, $CurrentScope, $CurrentProviderTextInventory, $CurrentAnalyzerSet, [DateTime] $Now)
                    $result = & $script:Syp212ConsentAuditOriginalValidator @PSBoundParameters
                    $script:Syp212ConsentAuditInitialValid = [bool]$result.valid
                    if ($result.valid) {
                        foreach ($property in $script:Syp212ConsentAuditRequestB.PSObject.Properties) {
                            $script:Syp212ConsentAuditRequestA.($property.Name) = $property.Value
                        }
                        foreach ($property in $script:Syp212ConsentAuditDecisionB.PSObject.Properties) {
                            $script:Syp212ConsentAuditDecisionA.($property.Name) = $property.Value
                        }
                        $script:Syp212ConsentAuditMutationApplied = $true
                    }
                    return $result
                }
            } $originalValidator $requestA $decisionA $fixture.Request $fixture.Decision

            $verification = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $run.evidenceBytes -ConsentRequest $requestA -ConsentDecision $decisionA `
                -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' `
                -ExpectedBindings $fixture.Bindings -ExpectedProviderRoute $fixture.Route `
                -ExpectedPurpose 'Synthetic test-only semantic review.' -ExpectedScope $expectedScope `
                -ExpectedProviderTextInventory $fixture.Inventory -Now ([DateTime]::UtcNow)
            $interleaving = & $module {
                [pscustomobject][ordered]@{
                    InitialConsentValid = $script:Syp212ConsentAuditInitialValid
                    CallerMutationApplied = $script:Syp212ConsentAuditMutationApplied
                }
            }

            Assert-RsaSnapshotTestCondition ([bool]$interleaving.InitialConsentValid) 'Consent A was not valid against the expected authorization scope before mutation.'
            Assert-RsaSnapshotTestCondition ([bool]$interleaving.CallerMutationApplied) 'The deterministic caller-owned consent graph mutation did not occur after initial validation.'
            Assert-RsaSnapshotTestCondition ((Get-StandardSemanticBridgeCanonicalJson $fixture.Scope) -ceq (Get-StandardSemanticBridgeCanonicalJson $requestA.scope)) 'The coordinated mutation did not replace the request scope with the signed evidence scope.'
            Assert-RsaSnapshotTestCondition (-not [bool]$verification.valid) 'The verifier accepted signed evidence from scope B after the caller replaced validated consent A with B.'
            Assert-RsaSnapshotTestCondition ([string]$verification.reason -ceq 'evidence scope is not consent-bound.') "The verifier rejected consent mutation for an unexpected reason: $($verification.reason)"
        }
        finally {
            if ($null -ne $module -and $null -ne $originalValidator) {
                & $module {
                    param($original)
                    Set-Item Function:\Test-StandardSemanticBridgeConsent -Value $original
                    Remove-Variable -Name Syp212ConsentAuditOriginalValidator, Syp212ConsentAuditRequestA, Syp212ConsentAuditDecisionA, Syp212ConsentAuditRequestB, Syp212ConsentAuditDecisionB, Syp212ConsentAuditInitialValid, Syp212ConsentAuditMutationApplied -Scope Script -ErrorAction SilentlyContinue
                } $originalValidator
            }
            if ($null -ne $fixture) {
                $fixture.Rsa.Dispose()
                $fixture.PublicRsa.Dispose()
            }
        }
    }
}

# Scenario: A successful callback host starts a real child process that holds
# redirected output handles, returns, and exits before the child writes a marker.
# Purpose: The owned process boundary must terminate the descendant immediately
# after host exit so capture cannot wait for a late side effect.
Describe 'Unix callback process group boundary' {
    It 'InterT135_successful_callback_host_exit_terminates_forked_descendant_before_late_side_effect' {
        Import-Module (Join-Path $PSScriptRoot '..\scripts\StandardSemanticBridge.psm1') -Force
        $childStartedMarker = Join-Path $TestDrive 'provider-success-child-started.txt'
        $childLateMarker = Join-Path $TestDrive 'provider-success-child-late-output.txt'
        $forkedProvider = {
            param($providerRequest, $callbackContext)
            $childStartedPath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$callbackContext.childStartedMarker))
            $childLatePath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$callbackContext.childLateMarker))
            $childScript = @"
`$startedPath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$childStartedPath'))
`$latePath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$childLatePath'))
[IO.File]::WriteAllText(`$startedPath, 'started')
[Threading.Thread]::Sleep(2000)
[IO.File]::WriteAllText(`$latePath, 'late descendant output')
"@
            $childInfo = New-Object Diagnostics.ProcessStartInfo
            $childInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $childInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $childInfo.UseShellExecute = $false
            $childInfo.CreateNoWindow = $true
            $childInfo.RedirectStandardOutput = $true
            $childInfo.RedirectStandardError = $true
            $child = New-Object Diagnostics.Process
            $child.StartInfo = $childInfo
            try {
                if (-not $child.Start()) { throw 'provider success descendant did not start.' }
            }
            finally { $child.Dispose() }
            $childStartDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath ([string]$callbackContext.childStartedMarker) -PathType Leaf) -and [DateTime]::UtcNow -lt $childStartDeadline) {
                [Threading.Thread]::Sleep(25)
            }
            if (-not (Test-Path -LiteralPath ([string]$callbackContext.childStartedMarker) -PathType Leaf)) {
                throw 'provider success descendant did not record startup.'
            }
            return [pscustomobject][ordered]@{
                findings = @()
                analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
            }
        }
        $module = Get-Module StandardSemanticBridge | Select-Object -First 1
        $run = & $module {
            param($callback, $callbackContext)
            Invoke-StandardSemanticBridgeCallbackWithTimeout `
                -Callback $callback `
                -Argument ([pscustomobject]@{}) `
                -CallbackContext $callbackContext `
                -TimeoutMilliseconds 10000 `
                -Context 'provider callback'
        } $forkedProvider ([pscustomobject]@{
                childStartedMarker = $childStartedMarker
                childLateMarker = $childLateMarker
            })
        if ($null -eq $run) { throw 'A successful provider callback returned no result.' }
        if (-not (Test-Path -LiteralPath $childStartedMarker -PathType Leaf)) {
            throw 'The successful callback descendant did not record startup.'
        }
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $childLateMarker) {
            throw 'A successful callback descendant produced a late side effect after host exit.'
        }
        Start-Sleep -Milliseconds 2250
        if (Test-Path -LiteralPath $childLateMarker) {
            throw 'A successful callback descendant survived cleanup and produced late output.'
        }
    }
}

$script:UnixContainmentIsLinuxAtDiscovery = ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix -and [IO.File]::Exists('/proc/self/ns/pid'))

Describe 'Unix callback containment boundary' -Tags LinuxContainment {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\scripts\StandardSemanticBridge.psm1') -Force
        $script:UnixContainmentModule = Get-Module StandardSemanticBridge | Select-Object -First 1
    }

    # Scenario: A callback returns normally without creating a descendant, or the host cannot prove Linux namespace capability.
    # Purpose: The namespace-only boundary must permit a clean callback and fail closed before callback execution when its capability is unavailable.
    It 'InterT160_normal_callback_exit_completes_inside_verified_boundary' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $unsharePath = @('/usr/bin/unshare', '/bin/unshare') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        $parentNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/pid' -ErrorAction Stop).Target
        if ([string]::IsNullOrWhiteSpace($parentNamespace)) { $parentNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/pid' -ErrorAction Stop).LinkTarget }
        $probeNamespace = $null
        $probeExit = 127
        if (-not [string]::IsNullOrWhiteSpace([string]$unsharePath)) {
            $probeOutput = @(& $unsharePath --user --map-root-user --pid --fork --kill-child=SIGKILL -- sh -c 'readlink /proc/self/ns/pid' 2>&1)
            $probeExit = $LASTEXITCODE
            if ($probeOutput.Count -gt 0) { $probeNamespace = [string]$probeOutput[-1] }
        }
        $namespaceCapabilityAvailable = ($probeExit -eq 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$probeNamespace) -and
            [string]$probeNamespace -cne $parentNamespace)
        $executionMarker = Join-Path $TestDrive 'unix-containment-normal-executed.txt'
        $callback = {
            param($argument, $context)
            [IO.File]::WriteAllText([string]$context.executionMarker, 'executed')
            return 'normal-complete'
        }
        $forcedMarker = Join-Path $TestDrive 'unix-containment-capability-forced-unavailable.txt'
        $forcedErrorMessage = $null
        & $script:UnixContainmentModule { $script:StandardSemanticBridgeTestForceLinuxNamespaceUnavailable = $true }
        try {
            try {
                & $script:UnixContainmentModule {
                    param($callback, $callbackContext)
                    Invoke-StandardSemanticBridgeCallbackWithTimeout `
                        -Callback $callback `
                        -Argument ([pscustomobject]@{}) `
                        -CallbackContext $callbackContext `
                        -TimeoutMilliseconds 5000 `
                        -Context 'forced unavailable Unix containment callback'
                } $callback ([pscustomobject]@{ executionMarker = $forcedMarker }) | Out-Null
            }
            catch { $forcedErrorMessage = [string]$_.Exception.Message }
        }
        finally { & $script:UnixContainmentModule { $script:StandardSemanticBridgeTestForceLinuxNamespaceUnavailable = $false } }
        if ([string]::IsNullOrWhiteSpace($forcedErrorMessage) -or $forcedErrorMessage -notmatch 'namespace|unshare|containment|boundary') {
            throw 'The forced unavailable capability path did not fail closed before callback execution.'
        }
        if (Test-Path -LiteralPath $forcedMarker -PathType Leaf) {
            throw 'The callback marker appeared during the forced unavailable capability path.'
        }
        $run = $null
        $errorMessage = $null
        try {
            $run = & $script:UnixContainmentModule {
                param($callback, $callbackContext)
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext $callbackContext `
                    -TimeoutMilliseconds 5000 `
                    -Context 'normal Unix containment callback'
            } $callback ([pscustomobject]@{ executionMarker = $executionMarker })
        }
        catch { $errorMessage = [string]$_.Exception.Message }
        if (-not $namespaceCapabilityAvailable) {
            if ([string]::IsNullOrWhiteSpace($errorMessage) -or $errorMessage -notmatch 'namespace|unshare|containment|boundary') {
                throw 'Unavailable Linux PID namespace capability must fail closed before callback execution.'
            }
            if (Test-Path -LiteralPath $executionMarker -PathType Leaf) {
                throw 'A callback marker appeared even though Linux PID namespace capability was unavailable.'
            }
            return
        }
        $tinyDeadlineMarker = Join-Path $TestDrive 'unix-containment-tiny-deadline-not-executed.txt'
        $tinyDeadlineException = $null
        try {
            & $script:UnixContainmentModule {
                param($callback, $callbackContext)
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext $callbackContext `
                    -TimeoutMilliseconds 1 `
                    -Context 'tiny-deadline Unix containment callback' | Out-Null
            } $callback ([pscustomobject]@{ executionMarker = $tinyDeadlineMarker })
        }
        catch { $tinyDeadlineException = $_.Exception }
        if ($tinyDeadlineException -isnot [TimeoutException] -or
            [string]$tinyDeadlineException.Message -notmatch '(?i)deadline was exceeded') {
            throw 'A Linux callback whose invocation deadline expired before READY did not report a deadline TimeoutException.'
        }
        $tinyDeadlineCleanupFailed = & $script:UnixContainmentModule {
            param($exception)
            Test-StandardSemanticBridgeCallbackCleanupFailureException -Exception $exception
        } $tinyDeadlineException
        if ([bool]$tinyDeadlineCleanupFailed) { throw 'The expired-before-READY callback did not verify its process-boundary cleanup.' }
        if (Test-Path -LiteralPath $tinyDeadlineMarker -PathType Leaf) {
            throw 'The callback payload was released after its invocation deadline expired before READY.'
        }
        if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
            throw "A callback failed despite a successful namespace capability probe: $errorMessage"
        }
        $runValues = @($run)
        if ($runValues.Count -eq 0 -or [string]$runValues[0] -cne 'normal-complete' -or -not (Test-Path -LiteralPath $executionMarker -PathType Leaf)) {
            throw 'A normal callback did not complete inside the verified Unix boundary.'
        }
    }

    # Scenario: A callback exceeds its invocation deadline while still running.
    # Purpose: Timeout cleanup must terminate the host and every descendant before the late marker is written.
    It 'InterT161_timeout_terminates_callback_and_descendants_before_late_side_effect' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $startedMarker = Join-Path $TestDrive 'unix-containment-timeout-started.txt'
        $childStartedMarker = Join-Path $TestDrive 'unix-containment-timeout-child-started.txt'
        $lateMarker = Join-Path $TestDrive 'unix-containment-timeout-late.txt'
        $callback = {
            param($argument, $context)
            [IO.File]::WriteAllText([string]$context.startedMarker, 'callback-started')
            $childScript = "[IO.File]::WriteAllText('$([string]$context.childStartedMarker)', 'child-started'); [Threading.Thread]::Sleep(10000); [IO.File]::WriteAllText('$([string]$context.lateMarker)', 'late timeout output')"
            $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $childInfo = New-Object Diagnostics.ProcessStartInfo
            $childInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $childInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChild
            $childInfo.UseShellExecute = $false
            $childInfo.CreateNoWindow = $true
            $childInfo.RedirectStandardOutput = $true
            $childInfo.RedirectStandardError = $true
            $child = New-Object Diagnostics.Process
            $child.StartInfo = $childInfo
            try { if (-not $child.Start()) { throw 'timeout child did not start.' } }
            finally { $child.Dispose() }
            [Threading.Thread]::Sleep(10000)
            [IO.File]::WriteAllText([string]$context.lateMarker, 'late timeout output')
        }
        $errorMessage = $null
        $timeoutException = $null
        try {
            & $script:UnixContainmentModule {
                param($callback, $callbackContext)
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext $callbackContext `
                    -TimeoutMilliseconds 8000 `
                    -Context 'timeout Unix containment callback'
            } $callback ([pscustomobject]@{ startedMarker = $startedMarker; childStartedMarker = $childStartedMarker; lateMarker = $lateMarker }) | Out-Null
        }
        catch {
            $timeoutException = $_.Exception
            $errorMessage = [string]$_.Exception.Message
        }
        if ($timeoutException -isnot [TimeoutException] -or
            [string]::IsNullOrWhiteSpace($errorMessage) -or
            $errorMessage -notmatch '(?i)deadline was exceeded' -or
            $errorMessage -match '(?i)(could not terminate|did not terminate|cleanup)') {
            throw 'The timeout callback did not fail with a deadline diagnostic.'
        }
        $timeoutCleanupFailed = & $script:UnixContainmentModule {
            param($exception)
            Test-StandardSemanticBridgeCallbackCleanupFailureException -Exception $exception
        } $timeoutException
        if ([bool]$timeoutCleanupFailed) { throw 'The timed-out callback did not verify its process-boundary cleanup.' }
        if (-not (Test-Path -LiteralPath $startedMarker -PathType Leaf) -or -not (Test-Path -LiteralPath $childStartedMarker -PathType Leaf)) {
            throw 'The timeout regression did not prove that the callback child started before cleanup.'
        }
        # The child and parent intentionally sleep 10000 ms before their late
        # writes.  Since the invocation budget is 8000 ms including up to 5000
        # ms of startup, this final wait extends beyond the latest possible
        # callback start plus its full sleep, even on a cold hosted runner.
        Start-Sleep -Milliseconds 11000
        if (Test-Path -LiteralPath $lateMarker) { throw 'A timed-out callback produced a late side effect.' }
    }

    # Scenario: A callback launches a real Linux setsid child that leaves the original process group.
    # Purpose: PID namespace cleanup must contain a reparented, escaped descendant.
    It 'InterT162_setsid_descendant_is_terminated_before_namespace_boundary_returns' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $setsidPath = @('/usr/bin/setsid', '/bin/setsid') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$setsidPath)) { throw 'Linux setsid executable is required for this regression.' }
        $startedMarker = Join-Path $TestDrive 'unix-containment-setsid-started.txt'
        $lateMarker = Join-Path $TestDrive 'unix-containment-setsid-late.txt'
        $callback = {
            param($argument, $context)
            $startedPath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$context.startedMarker))
            $latePath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$context.lateMarker))
            $childScript = "`$started = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$startedPath')); `$late = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$latePath')); [IO.File]::WriteAllText(`$started, 'started'); [Threading.Thread]::Sleep(2000); [IO.File]::WriteAllText(`$late, 'late setsid output')"
            $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $childInfo = New-Object Diagnostics.ProcessStartInfo
            $childInfo.FileName = [string]$context.setsidPath
            $childInfo.Arguments = '"' + $hostPath + '" -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChild
            $childInfo.UseShellExecute = $false
            $childInfo.CreateNoWindow = $true
            $childInfo.RedirectStandardOutput = $true
            $childInfo.RedirectStandardError = $true
            $child = New-Object Diagnostics.Process
            $child.StartInfo = $childInfo
            try { if (-not $child.Start()) { throw 'setsid child did not start.' } }
            finally { $child.Dispose() }
            $startDeadline = [DateTime]::UtcNow.AddMilliseconds(1000)
            while (-not (Test-Path -LiteralPath ([string]$context.startedMarker) -PathType Leaf) -and [DateTime]::UtcNow -lt $startDeadline) { Start-Sleep -Milliseconds 20 }
            if (-not (Test-Path -LiteralPath ([string]$context.startedMarker) -PathType Leaf)) { throw 'setsid child did not record startup.' }
            return 'setsid-started'
        }
        $run = & $script:UnixContainmentModule {
            param($callback, $callbackContext)
            Invoke-StandardSemanticBridgeCallbackWithTimeout `
                -Callback $callback `
                -Argument ([pscustomobject]@{}) `
                -CallbackContext $callbackContext `
                -TimeoutMilliseconds 5000 `
                -Context 'setsid Unix containment callback'
        } $callback ([pscustomobject]@{ setsidPath = $setsidPath; startedMarker = $startedMarker; lateMarker = $lateMarker })
        if ($null -eq $run) { throw 'The setsid callback returned no result.' }
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $lateMarker) { throw 'A setsid descendant produced a late side effect.' }
        Start-Sleep -Milliseconds 2200
        if (Test-Path -LiteralPath $lateMarker) { throw 'A reparented setsid descendant survived cleanup.' }
    }

    # Scenario: A callback exits successfully after starting a child that holds redirected output handles.
    # Purpose: Host exit must trigger cleanup before capture waits on a descendant's late output.
    It 'InterT163_successful_host_exit_closes_late_output_handles' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $startedMarker = Join-Path $TestDrive 'unix-containment-success-started.txt'
        $lateMarker = Join-Path $TestDrive 'unix-containment-success-late.txt'
        $callback = {
            param($argument, $context)
            $childScript = "[IO.File]::WriteAllText('$([string]$context.startedMarker)', 'started'); [Threading.Thread]::Sleep(2000); [IO.File]::WriteAllText('$([string]$context.lateMarker)', 'late output')"
            $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $childInfo = New-Object Diagnostics.ProcessStartInfo
            $childInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $childInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChild
            $childInfo.UseShellExecute = $false
            $childInfo.CreateNoWindow = $true
            $childInfo.RedirectStandardOutput = $true
            $childInfo.RedirectStandardError = $true
            $child = New-Object Diagnostics.Process
            $child.StartInfo = $childInfo
            try { if (-not $child.Start()) { throw 'late-output child did not start.' } }
            finally { $child.Dispose() }
            $startDeadline = [DateTime]::UtcNow.AddMilliseconds(1000)
            while (-not (Test-Path -LiteralPath ([string]$context.startedMarker) -PathType Leaf) -and [DateTime]::UtcNow -lt $startDeadline) { Start-Sleep -Milliseconds 20 }
            if (-not (Test-Path -LiteralPath ([string]$context.startedMarker) -PathType Leaf)) { throw 'late-output child did not record startup.' }
            return 'host-exited'
        }
        $run = & $script:UnixContainmentModule {
            param($callback, $callbackContext)
            Invoke-StandardSemanticBridgeCallbackWithTimeout `
                -Callback $callback `
                -Argument ([pscustomobject]@{}) `
                -CallbackContext $callbackContext `
                -TimeoutMilliseconds 5000 `
                -Context 'late-output Unix containment callback'
        } $callback ([pscustomobject]@{ startedMarker = $startedMarker; lateMarker = $lateMarker })
        if ($null -eq $run) { throw 'The late-output callback returned no result.' }
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $lateMarker) { throw 'A callback descendant produced late output after host exit.' }
        Start-Sleep -Milliseconds 2200
        if (Test-Path -LiteralPath $lateMarker) { throw 'A callback descendant survived output-handle cleanup.' }
    }

    # Scenario: The parent process carries a secret that is not part of the callback contract.
    # Purpose: Namespace launch must preserve the existing allowlisted child environment boundary.
    It 'InterT164_parent_secret_is_excluded_from_callback_environment' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $secretName = 'STANDARD_SEMANTIC_BRIDGE_TEST_SECRET_' + ([Guid]::NewGuid().ToString('N'))
        $secretValue = 'parent-secret-' + ([Guid]::NewGuid().ToString('N'))
        $executionMarker = Join-Path $TestDrive 'unix-containment-secret-executed.txt'
        [Environment]::SetEnvironmentVariable($secretName, $secretValue, [EnvironmentVariableTarget]::Process)
        try {
            $callback = {
                param($argument, $context)
                [IO.File]::WriteAllText([string]$context.executionMarker, 'executed')
                return [Environment]::GetEnvironmentVariable([string]$context.secretName, [EnvironmentVariableTarget]::Process)
            }
            $run = & $script:UnixContainmentModule {
                param($callback, $callbackContext)
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext $callbackContext `
                    -TimeoutMilliseconds 5000 `
                    -Context 'secret exclusion Unix containment callback'
            } $callback ([pscustomobject]@{ secretName = $secretName; executionMarker = $executionMarker })
            if (-not (Test-Path -LiteralPath $executionMarker -PathType Leaf)) {
                throw 'The secret exclusion callback did not execute.'
            }
            if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run[0])) {
                throw 'A callback observed a parent secret outside its explicit contract.'
            }
        }
        finally { [Environment]::SetEnvironmentVariable($secretName, $null, [EnvironmentVariableTarget]::Process) }
    }

    # Scenario: A controlled outer PowerShell host starts with a harmless secret in its initial environment.
    # Purpose: A PID namespace must use a private procfs view so a callback cannot inspect its host parent's /proc/<pid>/environ.
    It 'InterT165_callback_cannot_read_host_parent_procfs_or_initial_environment_secret' -Skip:($script:UnixContainmentIsLinuxAtDiscovery -eq $false) {
        $unsharePath = @('/usr/bin/unshare', '/bin/unshare') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        $umountPath = @('/usr/bin/umount', '/bin/umount') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        $pythonPath = @('/usr/bin/python3', '/bin/python3') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$unsharePath) -or [string]::IsNullOrWhiteSpace([string]$umountPath) -or
            [string]::IsNullOrWhiteSpace([string]$pythonPath)) {
            throw 'Linux unshare, umount, and /usr/bin/python3 executables are required for this regression.'
        }
        $parentNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/pid' -ErrorAction Stop).Target
        if ([string]::IsNullOrWhiteSpace($parentNamespace)) { $parentNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/pid' -ErrorAction Stop).LinkTarget }
        $probeNamespace = $null
        $probeExit = 127
        if (-not [string]::IsNullOrWhiteSpace([string]$unsharePath)) {
            $probeOutput = @(& $unsharePath --user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc -- sh -c 'readlink /proc/self/ns/pid' 2>&1)
            $probeExit = $LASTEXITCODE
            if ($probeOutput.Count -gt 0) { $probeNamespace = [string]$probeOutput[-1] }
        }
        $namespaceCapabilityAvailable = ($probeExit -eq 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$probeNamespace) -and
            [string]$probeNamespace -cne $parentNamespace)
        $secretName = 'STANDARD_SEMANTIC_BRIDGE_INITIAL_SECRET_' + ([Guid]::NewGuid().ToString('N'))
        $secretValue = 'harmless-initial-secret-' + ([Guid]::NewGuid().ToString('N'))
        $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\StandardSemanticBridge.psm1'))
        $markerPath = Join-Path $TestDrive 'unix-containment-parent-procfs-observation.json'
        $launcherResultPath = Join-Path $TestDrive 'unix-containment-parent-procfs-launcher-result.txt'
        $nestedUmountProbePath = Join-Path $TestDrive 'unix-containment-nested-umount-probe.py'
        $nestedNamespaceObservationPath = Join-Path $TestDrive 'unix-containment-nested-namespace.json'
        $nestedTmpfsMountPath = Join-Path $TestDrive 'unix-containment-nested-tmpfs-mount'
        [void][IO.Directory]::CreateDirectory($nestedTmpfsMountPath)
        $testDriveUnixMode = [IO.File]::GetUnixFileMode([string]$TestDrive)
        [IO.File]::SetUnixFileMode([string]$TestDrive, ($testDriveUnixMode -bor [IO.UnixFileMode]::OtherExecute))
        [IO.File]::SetUnixFileMode(
            [string]$nestedTmpfsMountPath,
            ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor
                [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherWrite -bor [IO.UnixFileMode]::OtherExecute)
        )
        $nestedUmountProbeScript = @'
import ctypes
import errno
import json
import os
import sys

result_fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
report = {}
libc = ctypes.CDLL(None, use_errno=True)
libc.unshare.argtypes = [ctypes.c_int]
libc.unshare.restype = ctypes.c_int
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
libc.mount.restype = ctypes.c_int
libc.umount2.argtypes = [ctypes.c_char_p, ctypes.c_int]
libc.umount2.restype = ctypes.c_int

def read_status():
    values = {}
    with open('/proc/self/status', 'r', encoding='ascii') as status_file:
        for line in status_file:
            key, separator, value = line.partition(':')
            if separator:
                values[key] = value.strip()
    return values

def errno_result(result):
    value = ctypes.get_errno() if result != 0 else 0
    return {'succeeded': result == 0, 'errno': value, 'errno_name': errno.errorcode.get(value), 'error': os.strerror(value) if value else None}

def main():
    report['parent_user_namespace'] = os.readlink('/proc/self/ns/user')
    report['parent_mount_namespace'] = os.readlink('/proc/self/ns/mnt')
    report['thread_count_before_unshare'] = len(os.listdir('/proc/self/task'))
    if report['thread_count_before_unshare'] != 1:
        report['setup_error'] = 'Python helper is not single-threaded; unshare(CLONE_NEWUSER) is unsafe here.'
        return

    # Keep all observations in this process: exec after unshare would recalculate
    # capabilities and, with CapBnd=0, discard the privilege needed to probe the
    # locked inherited mount. No uid_map is written, so no CAP_SETFCAP mapping is
    # needed. The already-open result descriptor survives the namespace change.
    flags = 0x10000000 | 0x00020000  # CLONE_NEWUSER | CLONE_NEWNS
    if libc.unshare(flags) != 0:
        error_number = ctypes.get_errno()
        report['unshare'] = {'succeeded': False, 'errno': error_number, 'error': os.strerror(error_number)}
        return

    report['unshare'] = {'succeeded': True, 'errno': 0, 'error': None}
    report['user_namespace'] = os.readlink('/proc/self/ns/user')
    report['mount_namespace'] = os.readlink('/proc/self/ns/mnt')
    status = read_status()
    report['cap_eff'] = status.get('CapEff')
    report['cap_prm'] = status.get('CapPrm')
    report['cap_bnd'] = status.get('CapBnd')
    try:
        report['cap_sys_admin'] = bool(int(status['CapEff'], 16) & (1 << 21))
    except (KeyError, ValueError):
        report['cap_sys_admin'] = False

    # Isolate mount propagation before using a dedicated empty directory under
    # TestDrive. The mount is private to this process's nested mount namespace.
    make_private_result = libc.mount(None, b'/', None, 0x00040000 | 0x00004000, None)  # MS_PRIVATE | MS_REC
    report['make_mounts_private'] = errno_result(make_private_result)
    mount_point = os.fsencode(sys.argv[2])
    report['tmpfs_mount_point'] = os.fsdecode(mount_point)
    if make_private_result == 0:
        mount_result = libc.mount(b'tmpfs', mount_point, b'tmpfs', 0, ctypes.c_void_p())
        report['tmpfs_mount'] = errno_result(mount_result)
        if mount_result == 0:
            unmount_tmpfs_result = libc.umount2(mount_point, 0)
            report['tmpfs_unmount'] = errno_result(unmount_tmpfs_result)
        else:
            report['tmpfs_unmount'] = {'succeeded': False, 'errno': 0, 'errno_name': None, 'error': 'tmpfs mount did not succeed'}
    else:
        report['tmpfs_mount'] = {'succeeded': False, 'errno': 0, 'errno_name': None, 'error': 'mount propagation could not be made private'}
        report['tmpfs_unmount'] = {'succeeded': False, 'errno': 0, 'errno_name': None, 'error': 'tmpfs mount was not attempted'}

    # Linux returns EINVAL when a less-privileged nested mount namespace tries
    # to separate an inherited mount from its parent mount tree.
    proc_unmount_result = libc.umount2(b'/proc', 0)
    report['proc_unmount'] = errno_result(proc_unmount_result)

try:
    main()
except BaseException as error:
    report['helper_error'] = type(error).__name__ + ': ' + str(error)

encoded = (json.dumps(report, sort_keys=True) + '\n').encode('utf-8')
os.write(result_fd, encoded)
os.close(result_fd)
sys.stdout.write(encoded.decode('utf-8'))
'@
        [IO.File]::WriteAllText($nestedUmountProbePath, $nestedUmountProbeScript)
        $markerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$markerPath))
        $moduleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$modulePath))
        $secretNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$secretName))
        $launcherResultBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$launcherResultPath))
        $nestedUmountProbeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$nestedUmountProbePath))
        $nestedNamespaceObservationBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$nestedNamespaceObservationPath))
        $nestedTmpfsMountPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$nestedTmpfsMountPath))
        $pythonPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$pythonPath))
        $umountPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$umountPath))
        $launcherScript = @"
`$ErrorActionPreference = 'Stop'
`$modulePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$moduleBase64'))
`$secretName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$secretNameBase64'))
`$markerPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$markerBase64'))
`$launcherResultPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$launcherResultBase64'))
`$nestedUmountProbePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$nestedUmountProbeBase64'))
`$nestedNamespaceObservationPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$nestedNamespaceObservationBase64'))
`$nestedTmpfsMountPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$nestedTmpfsMountPathBase64'))
`$umountPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$umountPathBase64'))
`$pythonPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pythonPathBase64'))
`$initialSecret = [Environment]::GetEnvironmentVariable(`$secretName, [EnvironmentVariableTarget]::Process)
if ([string]::IsNullOrWhiteSpace(`$initialSecret)) { throw 'The controlled callback host did not receive its initial environment secret.' }
`$parentHostPid = [Diagnostics.Process]::GetCurrentProcess().Id
Import-Module -Name `$modulePath -Force -ErrorAction Stop
`$bridgeModule = Get-Module StandardSemanticBridge | Select-Object -First 1
`$callback = {
    param(`$argument, `$context)
    `$parentProcPath = '/proc/' + [string]`$context.parentHostPid + '/environ'
    `$parentProcVisible = Test-Path -LiteralPath `$parentProcPath -PathType Leaf
    `$parentSecretVisible = `$false
    `$parentProcReadSucceeded = `$false
    if (`$parentProcVisible) {
        try {
            `$parentEnvironment = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes(`$parentProcPath))
            `$parentProcReadSucceeded = `$true
            `$secretPrefix = [string]`$context.secretName + '='
            foreach (`$entry in `$parentEnvironment.Split([char]0)) {
                if (`$entry.StartsWith(`$secretPrefix, [StringComparison]::Ordinal) -and `$entry.Length -gt `$secretPrefix.Length) {
                    `$parentSecretVisible = `$true
                    break
                }
            }
        }
        catch { `$parentProcReadSucceeded = `$false }
    }
    `$statusValues = @{}
    foreach (`$line in [IO.File]::ReadAllLines('/proc/self/status')) {
        `$match = [regex]::Match([string]`$line, '^([^:]+):\s*(.*?)\s*`$')
        if (`$match.Success) { `$statusValues[`$match.Groups[1].Value] = `$match.Groups[2].Value }
    }
    `$capabilityZeros = @{}
    foreach (`$name in @('CapEff', 'CapPrm', 'CapBnd')) {
        `$capabilityZeros[`$name] = (`$statusValues.ContainsKey(`$name) -and [string]`$statusValues[`$name] -match '^0+`$')
    }
    `$noNewPrivilegesEnabled = (`$statusValues.ContainsKey('NoNewPrivs') -and [string]`$statusValues.NoNewPrivs -ceq '1')
    `$selfPidOne = (`$statusValues.ContainsKey('Pid') -and [string]`$statusValues.Pid -ceq '1' -and
        `$statusValues.ContainsKey('NSpid') -and @(([string]`$statusValues.NSpid -split '\s+') | Where-Object { `$_ -match '\S' }).Count -eq 1 -and
        [string](@(([string]`$statusValues.NSpid -split '\s+') | Where-Object { `$_ -match '\S' })[0]) -ceq '1')
    `$directUmountInfo = New-Object Diagnostics.ProcessStartInfo
    `$directUmountInfo.FileName = [string]`$context.umountPath
    `$directUmountInfo.UseShellExecute = `$false
    `$directUmountInfo.CreateNoWindow = `$true
    `$directUmountInfo.ArgumentList.Add('-n')
    `$directUmountInfo.ArgumentList.Add('/proc')
    `$directUmountProcess = [Diagnostics.Process]::Start(`$directUmountInfo)
    if (-not `$directUmountProcess.WaitForExit(3000)) {
        try { `$directUmountProcess.Kill() } catch { }
        throw 'Direct procfs unmount probe did not exit within its 3-second bound.'
    }
    `$directUmountExitCode = [int]`$directUmountProcess.ExitCode
    `$directUmountProcess.Dispose()
    `$nestedProbeInfo = New-Object Diagnostics.ProcessStartInfo
    `$nestedProbeInfo.FileName = [string]`$context.pythonPath
    `$nestedProbeInfo.UseShellExecute = `$false
    `$nestedProbeInfo.CreateNoWindow = `$true
    `$nestedProbeInfo.RedirectStandardOutput = `$true
    `$nestedProbeInfo.RedirectStandardError = `$true
    `$nestedProbeInfo.ArgumentList.Add([string]`$context.nestedUmountProbePath)
    `$nestedProbeInfo.ArgumentList.Add([string]`$context.nestedNamespaceObservationPath)
    `$nestedProbeInfo.ArgumentList.Add([string]`$context.nestedTmpfsMountPath)
    `$nestedProbeProcess = [Diagnostics.Process]::Start(`$nestedProbeInfo)
    `$nestedProbeStdoutTask = `$nestedProbeProcess.StandardOutput.ReadToEndAsync()
    `$nestedProbeStderrTask = `$nestedProbeProcess.StandardError.ReadToEndAsync()
    if (-not `$nestedProbeProcess.WaitForExit(5000)) {
        try { `$nestedProbeProcess.Kill() } catch { }
        [void]`$nestedProbeProcess.WaitForExit(1000)
        `$nestedProbeStdout = `$nestedProbeStdoutTask.GetAwaiter().GetResult()
        `$nestedProbeStderr = `$nestedProbeStderrTask.GetAwaiter().GetResult()
        `$nestedProbeExitCode = if (`$nestedProbeProcess.HasExited) { [int]`$nestedProbeProcess.ExitCode } else { -1 }
        `$nestedProbeProcess.Dispose()
        throw "Native nested namespace probe exceeded 5 seconds (exit=`$nestedProbeExitCode; stdout=`$nestedProbeStdout; stderr=`$nestedProbeStderr)."
    }
    `$nestedProbeExitCode = [int]`$nestedProbeProcess.ExitCode
    `$nestedProbeStdout = `$nestedProbeStdoutTask.GetAwaiter().GetResult()
    `$nestedProbeStderr = `$nestedProbeStderrTask.GetAwaiter().GetResult()
    `$nestedProbeProcess.Dispose()
    `$nestedProbeObservation = `$null
    if ([IO.File]::Exists([string]`$context.nestedNamespaceObservationPath)) {
        try { `$nestedProbeObservation = [IO.File]::ReadAllText([string]`$context.nestedNamespaceObservationPath) | ConvertFrom-Json -ErrorAction Stop }
        catch { `$nestedProbeStderr += (' Could not parse nested probe JSON: ' + [string]`$_.Exception.Message) }
    }
    `$parentUserNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/user' -ErrorAction Stop).Target
    `$parentMountNamespace = [string](Get-Item -LiteralPath '/proc/self/ns/mnt' -ErrorAction Stop).Target
    `$nestedNamespaceSetupSucceeded = (`$nestedProbeExitCode -eq 0 -and `$null -ne `$nestedProbeObservation -and
        [bool]`$nestedProbeObservation.unshare.succeeded -and
        -not [string]::IsNullOrWhiteSpace([string]`$nestedProbeObservation.user_namespace) -and
        -not [string]::IsNullOrWhiteSpace([string]`$nestedProbeObservation.mount_namespace) -and
        [string]`$nestedProbeObservation.user_namespace -cne `$parentUserNamespace -and
        [string]`$nestedProbeObservation.mount_namespace -cne `$parentMountNamespace)
    `$nestedCapSysAdmin = (`$null -ne `$nestedProbeObservation -and [bool]`$nestedProbeObservation.cap_sys_admin)
    `$nestedMountPrivate = (`$null -ne `$nestedProbeObservation -and [bool]`$nestedProbeObservation.make_mounts_private.succeeded)
    `$nestedTmpfsMountSucceeded = (`$null -ne `$nestedProbeObservation -and [bool]`$nestedProbeObservation.tmpfs_mount.succeeded)
    `$nestedTmpfsUnmountSucceeded = (`$null -ne `$nestedProbeObservation -and [bool]`$nestedProbeObservation.tmpfs_unmount.succeeded)
    `$nestedProcUnmountErrno = if (`$null -ne `$nestedProbeObservation -and `$null -ne `$nestedProbeObservation.proc_unmount) { [int]`$nestedProbeObservation.proc_unmount.errno } else { -1 }
    `$nestedProcUnmountLocked = (`$null -ne `$nestedProbeObservation -and
        [string]`$nestedProbeObservation.proc_unmount.errno_name -ceq 'EINVAL')
    `$observation = [pscustomobject][ordered]@{
        parentHostProcPathVisible = [bool]`$parentProcVisible
        parentEnvironmentReadable = [bool]`$parentProcReadSucceeded
        parentInitialSecretVisible = [bool]`$parentSecretVisible
        capEffZero = [bool]`$capabilityZeros.CapEff
        capPrmZero = [bool]`$capabilityZeros.CapPrm
        capBndZero = [bool]`$capabilityZeros.CapBnd
        noNewPrivilegesEnabled = [bool]`$noNewPrivilegesEnabled
        selfPidOne = [bool]`$selfPidOne
        directProcUmountDenied = (`$directUmountExitCode -ne 0)
        nestedUserMountNamespaceUmountDenied = [bool]`$nestedProcUnmountLocked
        nestedNamespaceSetupSucceeded = [bool]`$nestedNamespaceSetupSucceeded
        nestedCapSysAdmin = [bool]`$nestedCapSysAdmin
        nestedMountPrivate = [bool]`$nestedMountPrivate
        nestedTmpfsMountSucceeded = [bool]`$nestedTmpfsMountSucceeded
        nestedTmpfsUnmountSucceeded = [bool]`$nestedTmpfsUnmountSucceeded
        nestedUserMountNamespaceProbeExitCode = `$nestedProbeExitCode
        nestedUserMountNamespaceProbeStdout = [string]`$nestedProbeStdout
        nestedUserMountNamespaceProbeStderr = [string]`$nestedProbeStderr
        nestedUserMountNamespaceProbe = `$nestedProbeObservation
        nestedProcUmountErrno = `$nestedProcUnmountErrno
    }
    [IO.File]::WriteAllText([string]`$context.markerPath, (ConvertTo-Json -InputObject `$observation -Compress))
    return 'callback-complete'
}
try {
    & `$bridgeModule {
        param(`$callback, `$callbackContext)
        Invoke-StandardSemanticBridgeCallbackWithTimeout -Callback `$callback -Argument ([pscustomobject]@{}) -CallbackContext `$callbackContext -TimeoutMilliseconds 5000 -Context 'host parent procfs isolation regression'
        } `$callback ([pscustomobject]@{ parentHostPid = `$parentHostPid; secretName = `$secretName; markerPath = `$markerPath; umountPath = `$umountPath; pythonPath = `$pythonPath; nestedUmountProbePath = `$nestedUmountProbePath; nestedNamespaceObservationPath = `$nestedNamespaceObservationPath; nestedTmpfsMountPath = `$nestedTmpfsMountPath }) | Out-Null
    [IO.File]::WriteAllText(`$launcherResultPath, 'callback-completed')
}
catch {
    [IO.File]::WriteAllText(`$launcherResultPath, ('callback-failed: ' + [string]`$_.Exception.Message))
    exit 11
}
"@
        $encodedLauncher = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcherScript))
        $launcherInfo = New-Object Diagnostics.ProcessStartInfo
        $launcherInfo.FileName = [string]$hostPath
        $launcherInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedLauncher
        $launcherInfo.UseShellExecute = $false
        $launcherInfo.CreateNoWindow = $true
        $launcherInfo.RedirectStandardOutput = $true
        $launcherInfo.RedirectStandardError = $true
        $launcherInfo.Environment[$secretName] = $secretValue
        $launcher = New-Object Diagnostics.Process
        $launcher.StartInfo = $launcherInfo
        try {
            if (-not $launcher.Start()) { throw 'The controlled outer PowerShell host did not start.' }
            if (-not $launcher.WaitForExit(20000)) {
                try { $launcher.Kill() } catch { }
                throw 'The controlled outer PowerShell host did not exit within its 20-second test bound.'
            }
            $launcherExitCode = $launcher.ExitCode
            $launcherError = $launcher.StandardError.ReadToEnd()
        }
        finally { $launcher.Dispose() }
        if (-not $namespaceCapabilityAvailable) {
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                throw 'The callback ran even though Linux PID namespace capability was unavailable.'
            }
            $unavailableResult = if (Test-Path -LiteralPath $launcherResultPath -PathType Leaf) { [IO.File]::ReadAllText($launcherResultPath) } else { '' }
            if ($launcherExitCode -eq 0 -or [string]::IsNullOrWhiteSpace($unavailableResult) -or $unavailableResult -notmatch '(?i)namespace|unshare|containment|boundary') {
                throw "Unavailable Linux PID namespace capability did not make callback startup fail closed: $launcherError"
            }
            return
        }
        if ($launcherExitCode -ne 0 -or -not (Test-Path -LiteralPath $launcherResultPath -PathType Leaf)) {
            $failure = if (Test-Path -LiteralPath $launcherResultPath -PathType Leaf) { [IO.File]::ReadAllText($launcherResultPath) } else { $launcherError }
            throw "The controlled callback host failed despite available PID namespace capability: $failure"
        }
        if ([IO.File]::ReadAllText($launcherResultPath) -cne 'callback-completed' -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw 'The private callback did not complete and record its procfs observation.'
        }
        $observation = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
        if ([bool]$observation.parentHostProcPathVisible) {
            throw 'The callback could see the host parent PID in procfs; PID namespace launch did not mount a private procfs.'
        }
        if ([bool]$observation.parentInitialSecretVisible) {
            throw 'The callback read the host parent initial environment secret through procfs.'
        }
        foreach ($field in @('capEffZero', 'capPrmZero', 'capBndZero', 'noNewPrivilegesEnabled', 'selfPidOne', 'directProcUmountDenied', 'nestedNamespaceSetupSucceeded', 'nestedCapSysAdmin', 'nestedMountPrivate', 'nestedTmpfsMountSucceeded', 'nestedTmpfsUnmountSucceeded', 'nestedUserMountNamespaceUmountDenied')) {
            $property = $observation.PSObject.Properties[$field]
            if ($null -eq $property -or -not [bool]$property.Value) {
                $nestedDiagnostic = " nestedProbeExitCode=$($observation.nestedUserMountNamespaceProbeExitCode); nestedProcUmountErrno=$($observation.nestedProcUmountErrno); nestedProbe=$($observation.nestedUserMountNamespaceProbe | ConvertTo-Json -Compress -Depth 6); stdout=$($observation.nestedUserMountNamespaceProbeStdout); stderr=$($observation.nestedUserMountNamespaceProbeStderr)"
                throw "The callback security boundary assertion failed: $field.$nestedDiagnostic"
            }
        }

        # Establish an inherited procfs alias before starting a second controlled
        # host. The callback boundary must detect it in mountinfo and fail before
        # the callback payload is released.
        $aliasMarkerPath = Join-Path $TestDrive 'unix-containment-procfs-alias-callback.json'
        $aliasLauncherResultPath = Join-Path $TestDrive 'unix-containment-procfs-alias-launcher-result.txt'
        $aliasMountPath = Join-Path $TestDrive 'unix-containment-procfs-alias'
        $aliasReadyPath = Join-Path $TestDrive 'unix-containment-procfs-alias-ready.txt'
        $aliasMountInfoPath = Join-Path $TestDrive 'unix-containment-procfs-alias-mountinfo.txt'
        $aliasMarkerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$aliasMarkerPath))
        $aliasLauncherResultBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$aliasLauncherResultPath))
        $aliasLauncherScript = $launcherScript.Replace([string]$markerBase64, [string]$aliasMarkerBase64).Replace([string]$launcherResultBase64, [string]$aliasLauncherResultBase64)
        $encodedAliasLauncher = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($aliasLauncherScript))
        $aliasWrapperScriptPath = Join-Path $TestDrive 'unix-containment-procfs-alias-launcher.sh'
        $aliasWrapperScript = @'
set -eu
alias_path="$1"
ready_path="$2"
mountinfo_path="$3"
host_path="$4"
encoded_launcher="$5"
secret_name="$6"
python_path="$7"
mkdir -p "$alias_path"
mount --make-rprivate /
mount -t proc proc "$alias_path"
cat /proc/self/mountinfo > "$mountinfo_path"
if ! "$python_path" - "$alias_path/1/environ" "$secret_name" <<'PY'
import os
import sys

try:
    with open(sys.argv[1], 'rb') as source:
        parent_environment = source.read().split(b'\0')
    secret_name = sys.argv[2]
    secret_value = os.environ.get(secret_name)
    if secret_value is None:
        sys.exit(41)
    expected = os.fsencode(secret_name) + b'=' + os.fsencode(secret_value)
    if expected not in parent_environment:
        sys.exit(42)
except OSError:
    sys.exit(43)
PY
then
    echo 'The new outer procfs alias did not expose the harmless injected parent sentinel.' >&2
    exit 44
fi
printf ready > "$ready_path"
exec "$host_path" -NoLogo -NoProfile -NonInteractive -EncodedCommand "$encoded_launcher"
'@
        [IO.File]::WriteAllText($aliasWrapperScriptPath, $aliasWrapperScript)
        $aliasLauncherInfo = New-Object Diagnostics.ProcessStartInfo
        $aliasLauncherInfo.FileName = [string]$unsharePath
        $aliasLauncherInfo.UseShellExecute = $false
        $aliasLauncherInfo.CreateNoWindow = $true
        $aliasLauncherInfo.RedirectStandardOutput = $true
        $aliasLauncherInfo.RedirectStandardError = $true
        foreach ($item in @('--user', '--map-root-user', '--pid', '--fork', '--kill-child=SIGKILL', '--mount-proc', '--', '/bin/sh', $aliasWrapperScriptPath, $aliasMountPath, $aliasReadyPath, $aliasMountInfoPath, [string]$hostPath, $encodedAliasLauncher, [string]$secretName, [string]$pythonPath)) {
            $aliasLauncherInfo.ArgumentList.Add([string]$item)
        }
        $aliasLauncherInfo.Environment[$secretName] = $secretValue
        $aliasLauncher = New-Object Diagnostics.Process
        $aliasLauncher.StartInfo = $aliasLauncherInfo
        try {
            if (-not $aliasLauncher.Start()) { throw 'The controlled procfs-alias outer host did not start.' }
            if (-not $aliasLauncher.WaitForExit(20000)) {
                try { $aliasLauncher.Kill() } catch { }
                throw 'The controlled procfs-alias outer host did not exit within its 20-second test bound.'
            }
            $aliasLauncherExitCode = $aliasLauncher.ExitCode
            $aliasLauncherError = $aliasLauncher.StandardError.ReadToEnd()
        }
        finally { $aliasLauncher.Dispose() }
        if (-not (Test-Path -LiteralPath $aliasReadyPath -PathType Leaf) -or [IO.File]::ReadAllText($aliasReadyPath) -cne 'ready') {
            throw "The adversarial inherited procfs alias could not be established: $aliasLauncherError"
        }
        $aliasMountObserved = $false
        foreach ($mountInfoLine in [IO.File]::ReadAllLines($aliasMountInfoPath)) {
            $separatorIndex = $mountInfoLine.IndexOf(' - ', [StringComparison]::Ordinal)
            if ($separatorIndex -le 0) { continue }
            $leftFields = @($mountInfoLine.Substring(0, $separatorIndex).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            $rightFields = @($mountInfoLine.Substring($separatorIndex + 3).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            if ($leftFields.Count -ge 6 -and $rightFields.Count -ge 1 -and
                [string]$leftFields[4] -ceq [string]$aliasMountPath -and [string]$rightFields[0] -ceq 'proc') {
                $aliasMountObserved = $true
                break
            }
        }
        if (-not $aliasMountObserved) { throw 'The inherited procfs alias precondition was not visible in outer mountinfo.' }
        if (Test-Path -LiteralPath $aliasMarkerPath -PathType Leaf) {
            throw 'The callback executed despite an inherited procfs alias outside /proc.'
        }
        $aliasResult = if (Test-Path -LiteralPath $aliasLauncherResultPath -PathType Leaf) { [IO.File]::ReadAllText($aliasLauncherResultPath) } else { '' }
        if ($aliasLauncherExitCode -eq 0 -or $aliasResult -notmatch '^callback-failed:.*(namespace|procfs|containment|boundary)' ) {
            throw "An inherited procfs alias did not fail closed before callback execution: $aliasResult $aliasLauncherError"
        }
    }
}
