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

        $fixture = New-TestSemanticFixture
        $consentStartedAt = [DateTime]::UtcNow
        $shortRequest = New-StandardSemanticBridgeConsentRequest `
            -Bindings $fixture.Bindings -ProviderRoute $fixture.Route -Purpose 'Synthetic test-only semantic review.' `
            -Scope $fixture.Scope -ProviderTextInventory $fixture.Inventory -AnalyzerSet $fixture.AnalyzerSet `
            -RequestId '11111111-1111-4111-8111-111111111124' `
            -RequestedAt $consentStartedAt.AddSeconds(-1) -ExpiresAt $consentStartedAt.AddSeconds(4)
        $shortDecision = New-StandardSemanticBridgeConsentDecision `
            -Request $shortRequest -Authorizer $fixture.Authorizer `
            -DecisionId '11111111-1111-4111-8111-111111111125' -AuthorizedAt $consentStartedAt
        $slowSignerMarker = Join-Path $TestDrive 'consent-expired-during-signer.txt'
        $slowSigner = {
            param($signerRequest, $callbackContext)
            [IO.File]::WriteAllText([string]$callbackContext.markerPath, 'invoked')
            [Threading.Thread]::Sleep([int]$callbackContext.delayMilliseconds)
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
        $expiredDuringSigner = Invoke-TestSemanticBridge `
            -Fixture $fixture -Request $shortRequest -Decision $shortDecision `
            -Signer $slowSigner `
            -SignerContext ([pscustomobject][ordered]@{ markerPath = $slowSignerMarker; delayMilliseconds = 6000; privateKeyXml = $fixture.Rsa.ToXmlString($true) }) `
            -Now ([DateTime]::UtcNow) -TimeoutSeconds 20
        Assert-TestCondition ([string]$expiredDuringSigner.status -ceq 'BLOCKED') 'Consent that expired while the signer callback ran did not block the final result.'
        Assert-TestCondition ((Test-Path -LiteralPath $slowSignerMarker)) 'The signer callback did not start while consent was active.'
        Assert-TestCondition ($null -eq $expiredDuringSigner.evidenceBytes) 'Consent expiry during signing released evidence bytes.'

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
            $childStartDeadline = [DateTime]::UtcNow.AddMilliseconds(500)
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
            }) -TimeoutSeconds 1
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
            $childStartDeadline = [DateTime]::UtcNow.AddMilliseconds(500)
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
            $childScript = "[IO.File]::WriteAllText('$([string]$context.childStartedMarker)', 'child-started'); [Threading.Thread]::Sleep(3000); [IO.File]::WriteAllText('$([string]$context.lateMarker)', 'late timeout output')"
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
            [Threading.Thread]::Sleep(3000)
            [IO.File]::WriteAllText([string]$context.lateMarker, 'late timeout output')
        }
        $errorMessage = $null
        try {
            & $script:UnixContainmentModule {
                param($callback, $callbackContext)
                Invoke-StandardSemanticBridgeCallbackWithTimeout `
                    -Callback $callback `
                    -Argument ([pscustomobject]@{}) `
                    -CallbackContext $callbackContext `
                    -TimeoutMilliseconds 1500 `
                    -Context 'timeout Unix containment callback'
            } $callback ([pscustomobject]@{ startedMarker = $startedMarker; childStartedMarker = $childStartedMarker; lateMarker = $lateMarker }) | Out-Null
        }
        catch { $errorMessage = [string]$_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($errorMessage) -or
            $errorMessage -notmatch '(?i)deadline was exceeded\.$' -or
            $errorMessage -match '(?i)(could not terminate|did not terminate|cleanup)') {
            throw 'The timeout callback did not fail with a deadline diagnostic.'
        }
        if (-not (Test-Path -LiteralPath $startedMarker -PathType Leaf) -or -not (Test-Path -LiteralPath $childStartedMarker -PathType Leaf)) {
            throw 'The timeout regression did not prove that the callback child started before cleanup.'
        }
        # The child intentionally sleeps 3000 ms before its late write.  Wait
        # past that deadline so a surviving descendant cannot write after this
        # assertion has already passed.
        Start-Sleep -Milliseconds 2200
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
        $markerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$markerPath))
        $moduleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$modulePath))
        $secretNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$secretName))
        $launcherResultBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$launcherResultPath))
        $launcherScript = @"
`$ErrorActionPreference = 'Stop'
`$modulePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$moduleBase64'))
`$secretName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$secretNameBase64'))
`$markerPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$markerBase64'))
`$launcherResultPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$launcherResultBase64'))
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
    `$observation = [pscustomobject][ordered]@{
        parentHostProcPathVisible = [bool]`$parentProcVisible
        parentEnvironmentReadable = [bool]`$parentProcReadSucceeded
        parentInitialSecretVisible = [bool]`$parentSecretVisible
    }
    [IO.File]::WriteAllText([string]`$context.markerPath, (ConvertTo-Json -InputObject `$observation -Compress))
    return 'callback-complete'
}
try {
    & `$bridgeModule {
        param(`$callback, `$callbackContext)
        Invoke-StandardSemanticBridgeCallbackWithTimeout `
            -Callback `$callback `
            -Argument ([pscustomobject]@{}) `
            -CallbackContext `$callbackContext `
            -TimeoutMilliseconds 5000 `
            -Context 'host parent procfs isolation regression'
    } `$callback ([pscustomobject]@{ parentHostPid = `$parentHostPid; secretName = `$secretName; markerPath = `$markerPath }) | Out-Null
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
    }
}
