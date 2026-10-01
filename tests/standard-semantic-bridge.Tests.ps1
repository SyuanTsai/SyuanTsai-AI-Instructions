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
