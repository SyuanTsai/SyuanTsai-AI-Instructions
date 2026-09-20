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

    $now = [DateTime]::Parse('2026-09-19T02:00:00.000Z').ToUniversalTime()
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
    $state = [hashtable]@{ providerCallCount = 0; callsByPath = @{}; timeoutPath = $null; timeoutRemaining = $false; rsa = $rsa }
    $provider = {
        param($providerRequest)
        $path = [string]$providerRequest.path
        $state.providerCallCount++
        if (-not $state.callsByPath.ContainsKey($path)) { $state.callsByPath[$path] = 0 }
        $state.callsByPath[$path]++
        if ($state.timeoutRemaining -and [string]$state.timeoutPath -ceq $path) {
            $state.timeoutRemaining = $false
            throw [TimeoutException]::new('fixture timeout')
        }
        $findings = @(
            [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-intent"; ruleId = 'fixture.intent'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_developer_intent' }
            [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = "fp-$path-security"; ruleId = 'fixture.security'; message = 'synthetic finding'; path = $path; analyzerId = 'semantic_security_discovery' }
        )
        return [pscustomobject][ordered]@{ findings = $findings; analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery') }
    }.GetNewClosure()
    $signer = {
        param($signerRequest)
        $signature = $state.rsa.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [pscustomobject][ordered]@{ keyId = 'fixture-key'; algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'; signature = [Convert]::ToBase64String($signature) }
    }.GetNewClosure()

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
        State = $state
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
        if ($Now -eq [DateTime]::MinValue) { $Now = $Fixture.Now.AddMinutes(2) }
        if ($null -eq $Provider) { $Provider = $Fixture.Provider }
        if ($null -eq $Signer) { $Signer = $Fixture.Signer }
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
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$run.status -ceq 'PASS') 'The happy-path bridge run did not pass.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The happy-path provider call count changed.'
        Assert-TestCondition ([int]$run.successfulProviderCallCount -eq 1) 'The happy-path successful call count changed.'
        Assert-TestCondition (@($run.evidenceBytes).Count -gt 0) 'The happy-path bridge emitted no evidence bytes.'
        Assert-TestCondition ([int]$run.evidence.execution.plannedWorkItemCount -eq [int]$fixture.Inventory.fileCount) 'The evidence execution count is not inventory-bound.'
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
            -Now $fixture.Now.AddMinutes(2) `
            -ReplayLedger $replay
        Assert-TestCondition ([bool]$verification.valid) 'The explicit public key did not verify the happy-path evidence.'
        Assert-TestCondition ([string]$verification.evidenceSha256 -ceq [string]$run.evidenceSha256) 'The verified evidence digest changed.'
        Assert-TestCondition ($replay.Count -eq 1) 'The verifier did not record the consumed evidence ID.'
    }

    # Scenario: Consent is absent in substance, expired, or the current route is no longer consent-bound.
    # Purpose: No provider callback may occur before every consent condition passes.
    It 'UnitT30_missing_expired_or_mismatched_consent_has_zero_provider_calls' {
        $fixture = New-TestSemanticFixture
        $fixture.Decision.consentGranted = $false
        $missing = Invoke-TestSemanticBridge -Fixture $fixture
        Assert-TestCondition ([string]$missing.status -ceq 'BLOCKED') 'Missing consent did not block the bridge.'
        Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 0) 'Missing consent reached the provider.'

        $fixture = New-TestSemanticFixture
        $expired = Invoke-TestSemanticBridge -Fixture $fixture -Now $fixture.Now.AddHours(2)
        Assert-TestCondition ([string]$expired.status -ceq 'BLOCKED') 'Expired consent did not block the bridge.'
        Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 0) 'Expired consent reached the provider.'

        $fixture = New-TestSemanticFixture
        $routeDrift = ConvertFrom-Json -InputObject ($fixture.Route | ConvertTo-Json -Depth 20)
        $routeDrift.model = 'different-fixture-model'
        $mismatched = Invoke-TestSemanticBridge -Fixture $fixture -ProviderRoute $routeDrift
        Assert-TestCondition ([string]$mismatched.status -ceq 'BLOCKED') 'Mismatched consent did not block the bridge.'
        Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 0) 'Mismatched consent reached the provider.'
    }

    # Scenario: Candidate identity, source revision, outbound inventory, and provider route each drift independently.
    # Purpose: Every material input must invalidate the old decision before egress.
    It 'UnitT40_candidate_source_inventory_and_route_drift_invalidate_consent' {
        $evidenceFixture = New-TestSemanticFixture
        $goodEvidence = Invoke-TestSemanticBridge -Fixture $evidenceFixture
        Assert-TestCondition ([string]$goodEvidence.status -ceq 'PASS') 'The baseline evidence fixture did not pass.'
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
            Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 0) "$case drift reached the provider."
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
                -Now $evidenceFixture.Now.AddMinutes(2)
            Assert-TestCondition (-not [bool]$evidenceCheck.valid) "$case drift did not invalidate old evidence."
        }
    }

    # Scenario: The signer emits a valid artifact, then the signature or expected key identity is substituted.
    # Purpose: Authority-style verification must authenticate both bytes and the caller-supplied key identity.
    It 'UnitT50_wrong_signature_and_key_identity_are_rejected' {
        $fixture = New-TestSemanticFixture
        $run = Invoke-TestSemanticBridge -Fixture $fixture
        $mutatedBytes = Get-TestEvidenceBytesWithSignatureMutation -EvidenceBytes $run.evidenceBytes
        $badSignature = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $mutatedBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2)
        Assert-TestCondition (-not [bool]$badSignature.valid) 'A changed signature was accepted.'
        $wrongKey = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'substituted-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2)
        Assert-TestCondition (-not [bool]$wrongKey.valid) 'A substituted signer identity was accepted.'
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
        }.GetNewClosure()
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
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2) -ReplayLedger $replay
        $second = Test-StandardSemanticBridgeEvidence `
            -EvidenceBytes $run.evidenceBytes -ConsentRequest $fixture.Request -ConsentDecision $fixture.Decision `
            -PublicKey $fixture.PublicRsa -ExpectedKeyId 'fixture-key' -ExpectedBindings $fixture.Bindings `
            -ExpectedProviderRoute $fixture.Route -ExpectedPurpose 'Synthetic test-only semantic review.' `
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2) -ReplayLedger $replay
        Assert-TestCondition ([bool]$first.valid) 'The first evidence consumption did not pass.'
        Assert-TestCondition (-not [bool]$second.valid) 'Replayed evidence was accepted.'
        Assert-TestCondition ([string]$second.reason -match 'replay') 'Replay rejection did not identify replay.'
    }

    # Scenario: One work item succeeds, the next times out, and the retry reuses the idempotency ledger.
    # Purpose: Successful outbound work is never sent twice; partial/timeout runs never report PASS, and route drift needs fresh consent.
    It 'InterT70_timeout_partial_retry_has_no_duplicate_success_and_requires_fresh_consent' {
        $fixture = New-TestSemanticFixture -ItemCount 2
        $fixture.State.timeoutPath = 'skills/example/README.md'
        $fixture.State.timeoutRemaining = $true
        $ledger = @{}
        $first = Invoke-TestSemanticBridge -Fixture $fixture -Ledger $ledger
        Assert-TestCondition ([string]$first.status -ceq 'FAILED') 'The partial timeout run did not fail.'
        Assert-TestCondition ($null -eq $first.evidenceBytes) 'The partial timeout run emitted evidence.'
        Assert-TestCondition ([int]$first.providerCallCount -eq 2) 'The first partial run did not call both work items once.'
        Assert-TestCondition ([int]$fixture.State.callsByPath['skills/example/SKILL.md'] -eq 1) 'The first work item call count changed.'
        Assert-TestCondition ([int]$fixture.State.callsByPath['skills/example/README.md'] -eq 1) 'The timed-out work item call count changed.'

        $second = Invoke-TestSemanticBridge -Fixture $fixture -Ledger $ledger
        Assert-TestCondition ([string]$second.status -ceq 'FAILED') 'The retry with unavailable prior response bytes did not fail closed.'
        Assert-TestCondition ($null -eq $second.evidenceBytes) 'The partial retry emitted evidence.'
        Assert-TestCondition ([int]$second.providerCallCount -eq 1) 'The retry resent an already successful work item.'
        Assert-TestCondition ([int]$fixture.State.callsByPath['skills/example/SKILL.md'] -eq 1) 'The successful work item was sent twice.'
        Assert-TestCondition ([int]$fixture.State.callsByPath['skills/example/README.md'] -eq 2) 'The failed work item was not retried exactly once.'
        foreach ($entry in @($ledger.Values)) {
            Assert-TestCondition (@($entry.PSObject.Properties.Name) -notcontains 'text') 'The idempotency ledger retained provider text.'
            Assert-TestCondition (@($entry.PSObject.Properties.Name) -notcontains 'bytes') 'The idempotency ledger retained provider bytes.'
        }

        $driftedRoute = ConvertFrom-Json -InputObject ($fixture.Route | ConvertTo-Json -Depth 20)
        $driftedRoute.model = 'fresh-consent-model'
        $blocked = Invoke-TestSemanticBridge -Fixture $fixture -ProviderRoute $driftedRoute -Ledger $ledger
        Assert-TestCondition ([string]$blocked.status -ceq 'BLOCKED') 'Provider route drift reused stale consent.'
        Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 3) 'Provider route drift reached the provider.'

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
        Assert-TestCondition ([int]$fixture.State.providerCallCount -eq 5) 'Fresh route-bound consent did not execute both work items.'
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
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2)
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
            -ExpectedScope $fixture.Scope -ExpectedProviderTextInventory $fixture.Inventory -Now $fixture.Now.AddMinutes(2)

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
        }.GetNewClosure()
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

    # Scenario: A provider callback blocks longer than the configured deadline and never returns a response.
    # Purpose: Timeout must stop the actual callback pipeline, fail closed, and avoid accepting late callback output.
    It 'InterT130_provider_callback_deadline_stops_actual_callback' {
        $fixture = New-TestSemanticFixture
        $state = [hashtable]@{ completed = $false; startedAt = [long]0 }
        $slowProvider = {
            param($providerRequest)
            $state.startedAt = [Diagnostics.Stopwatch]::GetTimestamp()
            Start-Sleep -Seconds 3
            $state.completed = $true
            return [pscustomobject][ordered]@{ findings = @(); analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery') }
        }.GetNewClosure()
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Provider $slowProvider -TimeoutSeconds 1
        $returnedAt = [Diagnostics.Stopwatch]::GetTimestamp()
        $callbackElapsedSeconds = if ([long]$state.startedAt -gt 0) {
            [double]($returnedAt - [long]$state.startedAt) / [double][Diagnostics.Stopwatch]::Frequency
        }
        else { [double]::PositiveInfinity }
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'A provider callback beyond its deadline unexpectedly passed.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The timed provider callback was not actually invoked.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'A timed provider callback emitted evidence.'
        Assert-TestCondition ($callbackElapsedSeconds -lt 2.5) 'The bridge waited for the provider callback after its deadline.'
        Start-Sleep -Milliseconds 250
        Assert-TestCondition (-not [bool]$state.completed) 'A timed-out provider callback continued and produced late output.'
    }

    # Scenario: Provider work completes, but the caller-supplied signer blocks beyond the same local deadline.
    # Purpose: Signing has an explicit fail-closed boundary and cannot emit an unsigned or late PASS artifact.
    It 'InterT140_signer_callback_deadline_fails_closed' {
        $fixture = New-TestSemanticFixture
        $state = [hashtable]@{ completed = $false; startedAt = [long]0 }
        $slowSigner = {
            param($signerRequest)
            $state.startedAt = [Diagnostics.Stopwatch]::GetTimestamp()
            Start-Sleep -Seconds 3
            $state.completed = $true
            return [pscustomobject][ordered]@{ keyId = 'fixture-key'; algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'; signature = 'AA==' }
        }.GetNewClosure()
        $run = Invoke-TestSemanticBridge -Fixture $fixture -Signer $slowSigner -TimeoutSeconds 1
        $returnedAt = [Diagnostics.Stopwatch]::GetTimestamp()
        $callbackElapsedSeconds = if ([long]$state.startedAt -gt 0) {
            [double]($returnedAt - [long]$state.startedAt) / [double][Diagnostics.Stopwatch]::Frequency
        }
        else { [double]::PositiveInfinity }
        Assert-TestCondition ([string]$run.status -ceq 'FAILED') 'A signer callback beyond its deadline unexpectedly passed.'
        Assert-TestCondition ([int]$run.providerCallCount -eq 1) 'The signer timeout did not preserve the completed provider-call count.'
        Assert-TestCondition ($null -eq $run.evidenceBytes) 'A timed signer callback emitted evidence.'
        Assert-TestCondition ($callbackElapsedSeconds -lt 2.5) 'The bridge waited for the signer callback after its deadline.'
        Start-Sleep -Milliseconds 250
        Assert-TestCondition (-not [bool]$state.completed) 'A timed-out signer callback continued and produced late output.'
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
