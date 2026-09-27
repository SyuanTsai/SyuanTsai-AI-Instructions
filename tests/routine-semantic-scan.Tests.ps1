Describe 'routine semantic standing grant and run derivation' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $repositoryRoot 'scripts/RoutineSemanticScan.psm1') -Force -ErrorAction Stop

        function New-TestEnvelope {
            param($Payload, [Security.Cryptography.RSACryptoServiceProvider] $Key)
            $json = $Payload | ConvertTo-Json -Depth 12 -Compress
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
            return [pscustomobject]@{
                schemaVersion = 1
                keyId = 'fixture'
                payloadBase64 = [Convert]::ToBase64String($bytes)
                signatureBase64 = [Convert]::ToBase64String($Key.SignData($bytes, 'SHA256'))
            }
        }

        function New-TestCase {
            $key = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
            $now = [DateTime]::UtcNow
            $grant = [ordered]@{
                schemaVersion = 1
                grantType = 'routine-semantic-standing-grant-v1'
                grantId = '11111111-1111-4111-8111-111111111111'
                repository = 'https://example.test/repo.git'
                pathPrefixes = @('skills/')
                dataCategories = @('skill-instructions')
                provider = 'fixture-provider'
                account = 'fixture-account'
                modelFamily = 'fixture-model'
                purpose = 'routine semantic review'
                dataHandlingSha256 = ('a' * 64)
                approvalEvidenceSha256 = ('b' * 64)
                maxSourceBytes = 2048
                maxCalls = 3
                notBefore = $now.AddHours(-1).ToString('o')
                expiresAt = $now.AddHours(1).ToString('o')
            }
            $revocations = [ordered]@{
                schemaVersion = 1
                registryType = 'routine-semantic-revocations-v1'
                sequence = 1
                updatedAt = $now.AddMinutes(-1).ToString('o')
                expiresAt = $now.AddMinutes(15).ToString('o')
                revokedGrantIds = @()
            }
            $candidate = [pscustomobject]@{
                repository = 'https://example.test/repo.git'
                sourceRevision = ('c' * 40)
                candidateId = ('d' * 64)
                inputInventorySha256 = ('e' * 64)
                toolReceiptSha256 = ('f' * 64)
                paths = @('skills/example/SKILL.md')
                dataCategory = 'skill-instructions'
                provider = 'fixture-provider'
                account = 'fixture-account'
                modelFamily = 'fixture-model'
                purpose = 'routine semantic review'
                dataHandlingSha256 = ('a' * 64)
                sourceBytes = 100
                plannedCalls = 1
            }
            return [pscustomobject]@{
                Key = $key
                Now = $now
                Grant = $grant
                Revocations = $revocations
                Candidate = $candidate
            }
        }

        function Invoke-TestDecision {
            param($Case, $GrantEnvelope, $RevocationEnvelope)
            if ($null -eq $GrantEnvelope) { $GrantEnvelope = New-TestEnvelope -Payload $Case.Grant -Key $Case.Key }
            if ($null -eq $RevocationEnvelope) { $RevocationEnvelope = New-TestEnvelope -Payload $Case.Revocations -Key $Case.Key }
            return Test-RoutineSemanticAuthorization `
                -GrantEnvelope $GrantEnvelope `
                -RevocationEnvelope $RevocationEnvelope `
                -Candidate $Case.Candidate `
                -FixturePublicKeyXml $Case.Key.ToXmlString($false) `
                -DevelopmentHarness `
                -Now $Case.Now
        }
    }

    # Scenario: One signed standing grant covers two separate immutable revisions in the same approved scope.
    # Purpose: A new SHA derives its own candidate-bound decision without asking for a duplicate grant.
    It 'UnitT10_derives_distinct_decisions_for_two_revisions_under_one_grant' {
        $case = New-TestCase
        try {
            $first = Invoke-TestDecision -Case $case
            $case.Candidate.sourceRevision = '1' * 40
            $case.Candidate.candidateId = '2' * 64
            $case.Candidate.inputInventorySha256 = '3' * 64
            $second = Invoke-TestDecision -Case $case
            if (-not $first.scopeAllowed -or -not $second.scopeAllowed) { throw 'A valid standing grant must cover both candidates.' }
            if ($first.decisionId -ceq $second.decisionId) { throw 'Different candidate bytes must not share a decision identity.' }
            if ($first.grantSha256 -cne $second.grantSha256) { throw 'Both decisions must bind the same approved grant.' }
            if ($first.egressAuthorized -or $second.egressAuthorized -or $first.releaseEligible -or $second.releaseEligible) { throw 'Fixture decisions must not authorize real egress or release.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: The exact same candidate and standing grant are derived again without changing any input.
    # Purpose: Repeated preparation keeps a stable idempotency identity and does not claim a second scan.
    It 'UnitT20_is_idempotent_for_identical_frozen_inputs' {
        $case = New-TestCase
        try {
            $first = Invoke-TestDecision -Case $case
            $second = Invoke-TestDecision -Case $case
            if ($first.decisionId -cne $second.decisionId) { throw 'Identical frozen inputs must keep one decision identity.' }
            if ($first.scanExecuted -or $second.scanExecuted) { throw 'Preparation must not claim a provider scan.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: A missing or tampered standing grant is presented before any provider execution.
    # Purpose: Caller-controlled consent flags or altered approval bytes cannot self-authorize a scan.
    It 'UnitT30_rejects_missing_and_tampered_grants' {
        $case = New-TestCase
        try {
            $missingFailed = $false
            try { [void](Test-RoutineSemanticAuthorization -GrantEnvelope $null -RevocationEnvelope (New-TestEnvelope $case.Revocations $case.Key) -Candidate $case.Candidate -FixturePublicKeyXml $case.Key.ToXmlString($false) -DevelopmentHarness -Now $case.Now) } catch { $missingFailed = $true }
            $grantEnvelope = New-TestEnvelope $case.Grant $case.Key
            $grantEnvelope.payloadBase64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes('{"consentGranted":true}'))
            $tamperedFailed = $false
            try { [void](Invoke-TestDecision -Case $case -GrantEnvelope $grantEnvelope) } catch { $tamperedFailed = $true }
            if (-not $missingFailed -or -not $tamperedFailed) { throw 'Missing or tampered grant was accepted.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: A signed registry revokes the grant after the grant was originally approved.
    # Purpose: Revocation stops new derived decisions even for an otherwise in-scope candidate.
    It 'UnitT40_rejects_revoked_or_expired_grants' {
        $case = New-TestCase
        try {
            $case.Revocations.revokedGrantIds = @($case.Grant.grantId)
            $revokedFailed = $false
            try { [void](Invoke-TestDecision -Case $case) } catch { $revokedFailed = $true }
            $case.Revocations.revokedGrantIds = @()
            $case.Grant.expiresAt = $case.Now.AddSeconds(-1).ToString('o')
            $expiredFailed = $false
            try { [void](Invoke-TestDecision -Case $case) } catch { $expiredFailed = $true }
            if (-not $revokedFailed -or -not $expiredFailed) { throw 'Revoked or expired grant was accepted.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: The candidate changes its repository, path, provider route, handling, or requested budget.
    # Purpose: Material scope changes fail before a new candidate decision can be issued.
    It 'UnitT50_rejects_scope_route_and_budget_expansion' {
        foreach ($change in @(
            @{ Name = 'repository'; Value = 'https://example.test/other.git' },
            @{ Name = 'paths'; Value = @('private/secret.txt') },
            @{ Name = 'paths'; Value = @('skills/../private/secret.txt') },
            @{ Name = 'provider'; Value = 'other-provider' },
            @{ Name = 'account'; Value = 'other-account' },
            @{ Name = 'modelFamily'; Value = 'other-model' },
            @{ Name = 'dataCategory'; Value = 'user-message' },
            @{ Name = 'purpose'; Value = 'other purpose' },
            @{ Name = 'dataHandlingSha256'; Value = '9' * 64 },
            @{ Name = 'sourceBytes'; Value = 2049 },
            @{ Name = 'plannedCalls'; Value = 4 }
        )) {
            $case = New-TestCase
            try {
                $case.Candidate.($change.Name) = $change.Value
                $failed = $false
                try { [void](Invoke-TestDecision -Case $case) } catch { $failed = $true }
                if (-not $failed) { throw "Scope expansion '$($change.Name)' was accepted." }
            }
            finally { $case.Key.Dispose() }
        }
    }

    # Scenario: The registry signature is altered while the standing grant remains intact.
    # Purpose: A caller cannot suppress revocation by supplying a forged empty registry.
    It 'UnitT60_rejects_forged_revocation_registry' {
        $case = New-TestCase
        try {
            $registry = New-TestEnvelope $case.Revocations $case.Key
            $registry.signatureBase64 = [Convert]::ToBase64String((New-Object byte[] 256))
            $failed = $false
            try { [void](Invoke-TestDecision -Case $case -RevocationEnvelope $registry) } catch { $failed = $true }
            if (-not $failed) { throw 'Forged revocation registry was accepted.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: A fixture-signed grant is supplied without the development harness boundary.
    # Purpose: Synthetic keys must never authorize production preparation, egress, CI admission, or release.
    It 'UnitT70_rejects_fixture_grant_in_production' {
        $case = New-TestCase
        try {
            $failed = $false
            try {
                [void](Test-RoutineSemanticAuthorization `
                    -GrantEnvelope (New-TestEnvelope $case.Grant $case.Key) `
                    -RevocationEnvelope (New-TestEnvelope $case.Revocations $case.Key) `
                    -Candidate $case.Candidate `
                    -FixturePublicKeyXml $case.Key.ToXmlString($false) `
                    -Now $case.Now)
            }
            catch { $failed = $true }
            if (-not $failed) { throw 'A fixture grant passed the production boundary.' }
        }
        finally { $case.Key.Dispose() }
    }

    # Scenario: A valid fixture key signs JSON with duplicate decoded property names.
    # Purpose: Different JSON parsers must not silently choose different authorization scopes.
    It 'UnitT80_rejects_ambiguous_signed_json_properties' {
        foreach ($name in @('purpose', '\u0070urpose', 'Purpose')) {
            $case = New-TestCase
            try {
                $valid = $case.Grant | ConvertTo-Json -Depth 12 -Compress
                $ambiguous = '{"' + $name + '":"other purpose",' + $valid.Substring(1)
                $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($ambiguous)
                $envelope = [pscustomobject]@{
                    schemaVersion = 1
                    keyId = 'fixture'
                    payloadBase64 = [Convert]::ToBase64String($bytes)
                    signatureBase64 = [Convert]::ToBase64String($case.Key.SignData($bytes, 'SHA256'))
                }
                $failed = $false
                try { [void](Invoke-TestDecision -Case $case -GrantEnvelope $envelope) } catch { $failed = $true }
                if (-not $failed) { throw "Ambiguous signed JSON property '$name' was accepted." }
            }
            finally { $case.Key.Dispose() }
        }
    }

    # Scenario: The signed grant itself contains a path prefix that traverses out of scope.
    # Purpose: A trusted signature cannot make an unsafe path prefix safe to match.
    It 'UnitT90_rejects_unsafe_signed_path_prefix' {
        $case = New-TestCase
        try {
            $case.Grant.pathPrefixes = @('skills/../')
            $case.Candidate.paths = @('skills/example/SKILL.md')
            $failed = $false
            try { [void](Invoke-TestDecision -Case $case) } catch { $failed = $true }
            if (-not $failed) { throw 'Unsafe signed path prefix was accepted.' }
        }
        finally { $case.Key.Dispose() }
    }
}

Describe 'routine semantic immutable Git input preparation' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $repositoryRoot 'scripts/RoutineSemanticScan.psm1') -Force -ErrorAction Stop
        function New-InventoryRepo {
            $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
            [void](New-Item -ItemType Directory -Path (Join-Path $root 'skills/example') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $root 'private') -Force)
            [IO.File]::WriteAllText((Join-Path $root 'skills/example/SKILL.md'), 'first committed skill', (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $root 'private/secret.txt'), 'excluded fixture', (New-Object Text.UTF8Encoding($false)))
            & git -C $root init -q
            & git -C $root -c user.name=Fixture -c user.email=fixture@example.test add -- .
            & git -C $root -c user.name=Fixture -c user.email=fixture@example.test commit -qm fixture
            return [pscustomobject]@{ Root = $root; Revision = (& git -C $root rev-parse HEAD).Trim() }
        }
    }

    # Scenario: The working tree changes after a skill was committed, while an excluded file also exists.
    # Purpose: Preparation reads exact immutable Git bytes and lists only complete approved prefix contents.
    It 'InterT10_freezes_complete_committed_prefix_without_worktree_or_private_bytes' {
        $fixture = New-InventoryRepo
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'skills/example/SKILL.md'), 'uncommitted changed text')
        $inventory = Get-RoutineSemanticGitInventory -RepositoryRoot $fixture.Root -Revision $fixture.Revision -PathPrefixes @('skills/') -MaximumBytes 2048
        if ($inventory.files.Count -ne 1 -or $inventory.files[0].path -cne 'skills/example/SKILL.md') { throw 'Inventory was incomplete or included an excluded path.' }
        if ($inventory.files[0].sha256 -cne 'a0d43e94b57a5cc0d44b22288720eab2f42a2e7e17ccb2f55f51ae2953cc42a4') { throw 'Inventory did not freeze committed bytes.' }
        if ($inventory.sourceBytes -ne 21 -or $inventory.sourceRevision -cne $fixture.Revision) { throw 'Inventory totals or revision are incorrect.' }
    }

    # Scenario: The selected Git tree exceeds the grant byte budget or contains invalid UTF-8.
    # Purpose: Preparation must fail rather than truncate or silently skip selected source files.
    It 'InterT20_rejects_oversize_or_non_utf8_selected_blobs' {
        $fixture = New-InventoryRepo
        $oversizeFailed = $false
        try { [void](Get-RoutineSemanticGitInventory -RepositoryRoot $fixture.Root -Revision $fixture.Revision -PathPrefixes @('skills/') -MaximumBytes 20) } catch { $oversizeFailed = $_.Exception.Message -like 'SOURCE_BUDGET_EXCEEDED*' }
        [IO.File]::WriteAllBytes((Join-Path $fixture.Root 'skills/example/SKILL.md'), [byte[]]@(0xC3, 0x28))
        & git -C $fixture.Root add -- skills/example/SKILL.md
        & git -C $fixture.Root -c user.name=Fixture -c user.email=fixture@example.test commit -qm invalid
        $badRevision = (& git -C $fixture.Root rev-parse HEAD).Trim()
        $encodingFailed = $false
        try { [void](Get-RoutineSemanticGitInventory -RepositoryRoot $fixture.Root -Revision $badRevision -PathPrefixes @('skills/') -MaximumBytes 2048) } catch { $encodingFailed = $_.Exception.Message -like 'SOURCE_ENCODING_INVALID*' }
        if (-not $oversizeFailed -or -not $encodingFailed) { throw 'Preparation accepted oversized or invalid text.' }
    }

    # Scenario: A signed fixture grant covers a committed repository prefix and a declared provider route.
    # Purpose: The controller must derive candidate identity, paths, and byte count from Git, not caller claims.
    It 'InterT30_derives_prepared_plan_from_git_and_signed_scope' {
        $fixture = New-InventoryRepo
        & git -C $fixture.Root remote add origin https://example.test/repo.git
        $key = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            $now = [DateTime]::UtcNow
            $grant = [ordered]@{
                schemaVersion = 1; grantType = 'routine-semantic-standing-grant-v1'; grantId = '11111111-1111-4111-8111-111111111111'
                repository = 'https://example.test/repo.git'; pathPrefixes = @('skills/'); dataCategories = @('skill-instructions')
                provider = 'fixture-provider'; account = 'fixture-account'; modelFamily = 'fixture-model'; purpose = 'routine semantic review'
                dataHandlingSha256 = ('a' * 64); approvalEvidenceSha256 = ('b' * 64); maxSourceBytes = 2048; maxCalls = 3
                notBefore = $now.AddHours(-1).ToString('o'); expiresAt = $now.AddHours(1).ToString('o')
            }
            $registry = [ordered]@{
                schemaVersion = 1; registryType = 'routine-semantic-revocations-v1'; sequence = 1
                updatedAt = $now.AddMinutes(-1).ToString('o'); expiresAt = $now.AddMinutes(15).ToString('o'); revokedGrantIds = @()
            }
            function New-LocalEnvelope($payload, $rsa) {
                $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($payload | ConvertTo-Json -Depth 12 -Compress))
                return [pscustomobject]@{ schemaVersion = 1; keyId = 'fixture'; payloadBase64 = [Convert]::ToBase64String($bytes); signatureBase64 = [Convert]::ToBase64String($rsa.SignData($bytes, 'SHA256')) }
            }
            $params = @{
                RepositoryRoot = $fixture.Root; Revision = $fixture.Revision; Repository = 'https://example.test/repo.git'
                PathPrefixes = @('skills/'); DataCategory = 'skill-instructions'; Provider = 'fixture-provider'
                Account = 'fixture-account'; ModelFamily = 'fixture-model'; Purpose = 'routine semantic review'
                DataHandlingSha256 = ('a' * 64); ToolReceiptSha256 = ('f' * 64); PlannedCalls = 1; MaximumBytes = 2048
                GrantEnvelope = (New-LocalEnvelope $grant $key); RevocationEnvelope = (New-LocalEnvelope $registry $key)
                FixturePublicKeyXml = $key.ToXmlString($false); DevelopmentHarness = $true; Now = $now
            }
            $plan = New-RoutineSemanticPreparation @params
            if ($plan.sourceInventory.sourceBytes -ne 21 -or $plan.sourceInventory.files.Count -ne 1) { throw 'Controller did not derive actual committed source.' }
            if ($plan.decision.candidateId -cne $plan.candidateId -or $plan.decision.inputInventorySha256 -cne $plan.sourceInventory.inputInventorySha256) { throw 'Plan bindings are inconsistent.' }
            if ($plan.scanStatus -cne 'NOT_RUN' -or $plan.ciAdmission -cne 'BLOCKED' -or $plan.payloadComplete) { throw 'Prepared plan claimed an executed scan or complete payload.' }
            $consumerPath = Join-Path $fixture.Root 'consumer-plan.json'
            $grantPath = Join-Path $fixture.Root 'fixture-grant.json'
            $revocationPath = Join-Path $fixture.Root 'fixture-revocations.json'
            $keyPath = Join-Path $fixture.Root 'fixture-public-key.xml'
            $outputPath = Join-Path $fixture.Root 'prepared-plan.json'
            $consumer = [ordered]@{
                schemaVersion = 1; artifactType = 'standard-validation-consumer-run-plan-v1'; runId = ('3' * 32)
                source = [ordered]@{ repository = 'https://example.test/repo.git'; revision = $fixture.Revision }
                candidate = [ordered]@{ candidateId = ('4' * 64); contentSha256 = ('5' * 64) }
            }
            [IO.File]::WriteAllText($consumerPath, ($consumer | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($grantPath, ($params.GrantEnvelope | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($revocationPath, ($params.RevocationEnvelope | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($keyPath, $params.FixturePublicKeyXml, (New-Object Text.UTF8Encoding($false)))
            $entrypoint = Join-Path $repositoryRoot 'scripts/Invoke-RoutineSemanticScan.ps1'
            & pwsh -NoProfile -File $entrypoint -Mode Prepare -PlanPath $consumerPath -OutputPath $outputPath `
                -SourceRoot $fixture.Root -GrantPath $grantPath -RevocationPath $revocationPath `
                -FixturePublicKeyPath $keyPath -PathPrefixes 'skills/' -DataCategory 'skill-instructions' `
                -Provider 'fixture-provider' -Account 'fixture-account' -ModelFamily 'fixture-model' `
                -Purpose 'routine semantic review' -DataHandlingSha256 ('a' * 64) -ToolReceiptSha256 ('f' * 64) `
                -PlannedCalls 1 -MaximumBytes 2048 -DevelopmentHarness
            if ($LASTEXITCODE -ne 0) { throw 'Prepare entrypoint failed for a complete fixture.' }
            $cliPlan = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
            if ($cliPlan.consumerBinding.runId -cne ('3' * 32) -or $cliPlan.consumerBinding.candidateId -cne ('4' * 64) -or
                $cliPlan.candidateId -cne $plan.candidateId -or $cliPlan.ciAdmission -cne 'BLOCKED') { throw 'Prepare entrypoint lost one candidate identity.' }
            $params.Repository = 'https://example.test/other.git'
            $mismatchFailed = $false
            try { [void](New-RoutineSemanticPreparation @params) } catch { $mismatchFailed = $_.Exception.Message -like 'SOURCE_REPOSITORY_MISMATCH*' }
            if (-not $mismatchFailed) { throw 'Caller repository mismatch passed preparation.' }
        }
        finally { $key.Dispose() }
    }
}
