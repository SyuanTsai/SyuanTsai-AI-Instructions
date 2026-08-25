$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeContractModule = Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1'
$script:UpdaterModule = Join-Path $script:RepositoryRoot 'scripts\ai-instructions-updater.psm1'
$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function New-TestUpdaterHome {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('notify-only','auto-install-approved')][string] $Mode = 'notify-only',
        [string] $Commit = ('a' * 40)
    )

    $runtimeRoot = Join-Path $Path 'hooks\ai-instructions-runtime'
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'), "Write-Output 'ok'`n")
    $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 -CatalogRepository $script:CanonicalRepository -CatalogRef $Commit
    $configuration.updates.mode = $Mode
    $configurationJson = ($configuration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $Path 'ai-instructions-sync.json'), $configurationJson)
    $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit $Commit -Acquisition git-checkout
    $bundleJson = ($bundle | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime-bundle.json'), $bundleJson)
}

Describe 'AI instructions updater workflow' {
    BeforeAll {
        Import-Module $script:RuntimeContractModule -Force
        Import-Module $script:UpdaterModule -Force
    }

    # Scenario: The canonical protected ref still resolves to the installed commit.
    # Purpose: Record a successful check without downloading or mutating the runtime.
    It 'UnitT10_reports_current_without_installing' {
        $codexHome = Join-Path $TestDrive 'current'
        New-TestUpdaterHome -Path $codexHome
        $script:installCalls = 0

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { $script:installCalls++ }

        $result.outcome | Should Be 'current'
        $result.candidateCommit | Should BeNullOrEmpty
        $script:installCalls | Should Be 0
    }

    # Scenario: Two forced checks consecutively confirm that the installed immutable runtime is current.
    # Purpose: Replace the prior audit receipt atomically instead of bricking every check after the first write.
    It 'UnitT12_replaces_an_existing_receipt_after_a_repeated_current_check' {
        $codexHome = Join-Path $TestDrive 'repeated-current'
        New-TestUpdaterHome -Path $codexHome

        $first = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }
        $second = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $first.outcome | Should Be 'current'
        $second.outcome | Should Be 'current'
        $receipt = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json
        $receipt.outcome | Should Be 'current'
        $receipt.candidateCommit | Should BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $codexHome -Force -File | Where-Object { $_.Name -like '.ai-instructions-update-receipt.json.*' }).Count | Should Be 0
    }

    # Scenario: A newer candidate exists while the user retains the default notify-only mode.
    # Purpose: Surface availability without downloading or installing unapproved bytes.
    It 'UnitT20_reports_available_in_notify_only_mode' {
        $codexHome = Join-Path $TestDrive 'available'
        New-TestUpdaterHome -Path $codexHome

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'available'
        $result.candidateCommit | Should Be ('b' * 40)
    }

    # Scenario: The configured mutable ref resolves behind or off the installed immutable history.
    # Purpose: Refuse downgrades and divergent candidates before acquisition in every update mode.
    It 'UnitT25_reports_a_stale_non_forward_candidate_without_installing' {
        $codexHome = Join-Path $TestDrive 'stale'
        New-TestUpdaterHome -Path $codexHome -Mode auto-install-approved
        $script:installCalls = 0

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { [pscustomobject]@{ Commit=('b' * 40); Relation='behind' } } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { $script:installCalls++ }

        $result.outcome | Should Be 'stale'
        $result.message | Should Match 'downgrade or divergent installation was refused'
        $script:installCalls | Should Be 0
    }

    # Scenario: A newer candidate remains stable across acquisition and auto-install is approved.
    # Purpose: Install only after a second immutable-ref resolution rules out candidate drift.
    It 'UnitT30_installs_an_approved_stable_candidate' {
        $codexHome = Join-Path $TestDrive 'installed'
        New-TestUpdaterHome -Path $codexHome -Mode auto-install-approved
        $script:installCalls = 0
        $package = [pscustomobject]@{ SourceRoot='C:\fixture'; ArchivePath='C:\fixture.zip'; ArchiveSha256=('c' * 64) }

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' } `
            -AcquireCandidate { param($request) $package } `
            -InstallCandidate {
                param($request)
                $script:installCalls++
                New-TestUpdaterHome -Path $request.CodexHome -Mode auto-install-approved -Commit $request.CandidateCommit
            }

        $result.outcome | Should Be 'installed'
        $script:installCalls | Should Be 1
        $result.archiveSha256 | Should Be ('c' * 64)
    }

    # Scenario: An installer callback returns without activating the selected candidate runtime.
    # Purpose: Record success only after the active runtime bundle proves the candidate is actually installed.
    It 'UnitT35_rejects_an_installer_that_does_not_activate_the_candidate' {
        $codexHome = Join-Path $TestDrive 'installer-no-op'
        New-TestUpdaterHome -Path $codexHome -Mode auto-install-approved
        $package = [pscustomobject]@{ SourceRoot='C:\fixture'; ArchivePath='C:\fixture.zip'; ArchiveSha256=('c' * 64) }

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' } `
            -AcquireCandidate { param($request) $package } `
            -InstallCandidate { param($request) }

        $result.outcome | Should Be 'failed'
        $result.message | Should Match 'active runtime|candidate'
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json).outcome | Should Be 'failed'
    }

    # Scenario: The network is unavailable while resolving the configured update source.
    # Purpose: Preserve the current verified runtime and leave auditable offline evidence.
    It 'UnitT40_falls_back_offline_without_mutation' {
        $codexHome = Join-Path $TestDrive 'offline'
        New-TestUpdaterHome -Path $codexHome -Mode auto-install-approved

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) throw 'offline fixture' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'offline'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | Should Be $true
    }

    # Scenario: Candidate resolution succeeds but the immutable archive download loses network access.
    # Purpose: Keep the current verified runtime usable for transient failures anywhere in acquisition.
    It 'UnitT45_falls_back_offline_when_candidate_acquisition_loses_network_access' {
        $codexHome = Join-Path $TestDrive 'offline-acquisition'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'
        $script:installCalls = 0

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { '2222222222222222222222222222222222222222' } `
            -AcquireCandidate { throw [System.Net.WebException]::new('connection unavailable') } `
            -InstallCandidate { $script:installCalls++ }

        $result.outcome | Should Be 'offline'
        $script:installCalls | Should Be 0
        [string]$result.currentCommit | Should Be ('a' * 40)
    }

    # Scenario: A candidate acquisition adapter returns a package object whose archive hash is not valid evidence.
    # Purpose: Persist a schema-valid failure receipt without laundering the unverified hash into audit state.
    It 'UnitT46_records_an_invalid_candidate_package_as_a_schema_valid_failure' {
        $codexHome = Join-Path $TestDrive 'invalid-package'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'
        $candidate = '2222222222222222222222222222222222222222'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { [pscustomobject]@{ Commit=$candidate; Relation='ahead' } } `
            -AcquireCandidate { [pscustomobject]@{ ArchiveSha256='not-a-hash'; CleanupRoot=$null } } `
            -InstallCandidate { throw 'The installer must not run for invalid candidate evidence.' }

        $result.outcome | Should Be 'failed'
        $result.archiveSha256 | Should BeNullOrEmpty
        $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json
        { Assert-AiInstructionsUpdateReceiptV1 -Receipt $receipt } | Should Not Throw
        $receipt.archiveSha256 | Should BeNullOrEmpty
    }

    # Scenario: A candidate acquisition adapter returns an object without archive hash evidence.
    # Purpose: Keep StrictMode property access from masking the original acquisition contract failure.
    It 'UnitT47_records_a_candidate_package_missing_its_hash_as_a_schema_valid_failure' {
        $codexHome = Join-Path $TestDrive 'missing-package-hash'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { [pscustomobject]@{ Commit=('2' * 40); Relation='ahead' } } `
            -AcquireCandidate { [pscustomobject]@{ CleanupRoot=$null } } `
            -InstallCandidate { throw 'The installer must not run without candidate hash evidence.' }

        $result.outcome | Should Be 'failed'
        $result.archiveSha256 | Should BeNullOrEmpty
        $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json
        { Assert-AiInstructionsUpdateReceiptV1 -Receipt $receipt } | Should Not Throw
    }

    # Scenario: Resolver and acquisition adapters return singleton arrays in fields that must be scalar evidence.
    # Purpose: Reject PowerShell string coercion at the immutable candidate boundary.
    It 'UnitT48_rejects_singleton_arrays_in_candidate_evidence' {
        $candidateHome = Join-Path $TestDrive 'candidate-array'
        New-TestUpdaterHome -Path $candidateHome -Mode 'auto-install-approved'
        $candidateResult = Invoke-AiInstructionsUpdateWorkflow -CodexHome $candidateHome -ForceCheck `
            -ResolveCandidate { [pscustomobject]@{ Commit=@(('2' * 40)); Relation='ahead' } } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }
        $candidateResult.outcome | Should Be 'failed'
        $candidateResult.message | Should Match 'scalar string'

        $packageHome = Join-Path $TestDrive 'package-array'
        New-TestUpdaterHome -Path $packageHome -Mode 'auto-install-approved'
        $packageResult = Invoke-AiInstructionsUpdateWorkflow -CodexHome $packageHome -ForceCheck `
            -ResolveCandidate { [pscustomobject]@{ Commit=('2' * 40); Relation='ahead' } } `
            -AcquireCandidate { [pscustomobject]@{ ArchiveSha256=@(('b' * 64)); CleanupRoot=$null } } `
            -InstallCandidate { throw 'installer must not run' }
        $packageResult.outcome | Should Be 'failed'
        $packageResult.archiveSha256 | Should BeNullOrEmpty
    }

    # Scenario: GitHub responds but the configured channel cannot produce a valid candidate.
    # Purpose: Do not disguise integrity or configuration failures as harmless offline operation.
    It 'UnitT49_records_non_network_candidate_resolution_errors_as_failed' {
        $codexHome = Join-Path $TestDrive 'invalid-candidate-source'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { throw 'GitHub release response has no valid tag' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'failed'
        $result.message | Should Match 'no valid tag'
    }

    # Scenario: GitHub responds with a permanent client error such as a missing commit or unauthorized repository.
    # Purpose: Record actionable API/configuration failures instead of disguising them as transient offline operation.
    It 'UnitT50_records_http_client_errors_as_failed' {
        $codexHome = Join-Path $TestDrive 'http-client-error'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { throw [System.Net.WebException]::new('HTTP 404 Not Found') } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'failed'
        $result.message | Should Match '404'
    }

    # Scenario: GitHub temporarily refuses an unauthenticated API request because its request quota is exhausted.
    # Purpose: Keep the verified installed runtime usable instead of treating a transient service limit as integrity failure.
    It 'UnitT51_treats_a_GitHub_API_rate_limit_as_transient_offline_operation' {
        $codexHome = Join-Path $TestDrive 'github-rate-limit'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { throw [System.Net.WebException]::new('GitHub API rate limit exceeded (HTTP 403)') } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'offline'
        $result.message | Should Match 'rate limit'
    }

    # Scenario: PowerShell 7 exposes a GitHub 403 response through its native HttpResponseException and rate-limit header.
    # Purpose: Exercise the actual Invoke-RestMethod exception shape instead of a WebException test double.
    It 'UnitT52_treats_a_PowerShell_7_HttpResponseException_rate_limit_as_offline' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $codexHome = Join-Path $TestDrive 'github-rate-limit-ps7'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'
        Get-Command Invoke-RestMethod | Out-Null
        $exceptionType = ([System.Management.Automation.PSTypeName]'Microsoft.PowerShell.Commands.HttpResponseException').Type
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
        [void]$response.Headers.TryAddWithoutValidation('X-RateLimit-Remaining','0')
        $script:httpResponseException = [Activator]::CreateInstance(
            $exceptionType,
            [object[]]@('Response status code does not indicate success: 403 (Forbidden).',$response)
        )

        try {
            $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
                -ResolveCandidate { throw $script:httpResponseException } `
                -AcquireCandidate { throw 'archive must not be acquired' } `
                -InstallCandidate { throw 'installer must not run' }
        }
        finally {
            $response.Dispose()
            $script:httpResponseException = $null
        }

        $result.outcome | Should Be 'offline'
    }

    # Scenario: A successful update check occurred inside the configured minimum interval.
    # Purpose: Rate-limit bootstrap-triggered network checks while keeping a manual force option.
    It 'UnitT53_rate_limits_automatic_checks' {
        $codexHome = Join-Path $TestDrive 'rate-limit'
        New-TestUpdaterHome -Path $codexHome
        $receipt = [ordered]@{
            schemaVersion=1; checkedAtUtc='2026-08-23T04:00:00.0000000Z'; mode='notify-only';
            channel='protected-branch'; ref='main'; currentCommit=('a' * 40); candidateCommit=$null;
            outcome='current'; archiveSha256=$null; message='current'
        }
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-update-receipt.json'), (($receipt | ConvertTo-Json -Depth 5) + "`n"))

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -NowUtc ([datetime]'2026-08-23T04:30:00Z') `
            -ResolveCandidate { throw 'resolver must not run' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'rate-limit'
    }

    # Scenario: A prior process interruption leaves a malformed noncritical update receipt.
    # Purpose: Quarantine stale evidence and continue from the verified installed runtime instead of bricking bootstrap.
    It 'UnitT55_self_heals_a_malformed_update_receipt' {
        $codexHome = Join-Path $TestDrive 'malformed-receipt'
        New-TestUpdaterHome -Path $codexHome
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-update-receipt.json'),'{not-json')

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -NowUtc ([datetime]'2026-08-23T05:00:00Z') `
            -ResolveCandidate { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'current'
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json).outcome | Should Be 'current'
        @(Get-ChildItem -LiteralPath $codexHome -File -Filter 'ai-instructions-update-receipt.invalid-*.json').Count | Should Be 1
    }

    # Scenario: A manual forced check starts while the prior noncritical update receipt is malformed.
    # Purpose: Preserve the same quarantine evidence on ForceCheck before writing the new verified receipt.
    It 'UnitT56_force_check_quarantines_a_malformed_receipt_before_replacement' {
        $codexHome = Join-Path $TestDrive 'forced-malformed-receipt'
        New-TestUpdaterHome -Path $codexHome
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-update-receipt.json'),'{forced-not-json')

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'current'
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json).outcome | Should Be 'current'
        $quarantineFiles = @(Get-ChildItem -LiteralPath $codexHome -File -Filter 'ai-instructions-update-receipt.invalid-*.json')
        $quarantineFiles.Count | Should Be 1
        (Get-Content -Raw -LiteralPath $quarantineFiles[0].FullName) | Should Be '{forced-not-json'
    }

    # Scenario: A syntactically valid receipt omits its v1 contract and claims an implausible future check time.
    # Purpose: Quarantine semantic corruption instead of suppressing autonomous checks until the forged timestamp.
    It 'UnitT57_self_heals_a_schema_invalid_or_future_update_receipt' {
        $codexHome = Join-Path $TestDrive 'invalid-receipt-contract'
        New-TestUpdaterHome -Path $codexHome
        [System.IO.File]::WriteAllText(
            (Join-Path $codexHome 'ai-instructions-update-receipt.json'),
            '{"checkedAtUtc":"9999-01-01T00:00:00Z"}'
        )

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -NowUtc ([datetime]'2026-08-23T05:00:00Z') `
            -ResolveCandidate { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'current'
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | ConvertFrom-Json).outcome | Should Be 'current'
        @(Get-ChildItem -LiteralPath $codexHome -File -Filter 'ai-instructions-update-receipt.invalid-*.json').Count | Should Be 1
    }

    # Scenario: The protected ref moves after candidate validation but before installation.
    # Purpose: Stop rather than installing a candidate selected from stale mutable-ref state.
    It 'UnitT60_stops_on_candidate_drift' {
        $codexHome = Join-Path $TestDrive 'drift'
        New-TestUpdaterHome -Path $codexHome -Mode auto-install-approved
        $script:resolveCalls = 0
        $script:installCalls = 0
        $package = [pscustomobject]@{ SourceRoot='C:\fixture'; ArchivePath='C:\fixture.zip'; ArchiveSha256=('d' * 64) }

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate {
                param($request)
                $script:resolveCalls++
                if ($script:resolveCalls -eq 1) { return ('b' * 40) }
                return ('c' * 40)
            } `
            -AcquireCandidate { param($request) $package } `
            -InstallCandidate { param($request) $script:installCalls++ }

        $result.outcome | Should Be 'drift'
        $script:installCalls | Should Be 0
    }

    # Scenario: The production updater delegates installation after selecting a candidate under an approved update policy.
    # Purpose: Pass the expected runtime and policy identity so the installer can revalidate both under its lock.
    It 'UnitT65_passes_the_expected_runtime_and_update_policy_to_the_installer' {
        $sourceRoot = Join-Path $TestDrive 'installer-contract'
        $scriptsRoot = Join-Path $sourceRoot 'scripts'
        New-Item -ItemType Directory -Force -Path $scriptsRoot | Out-Null
        $fakeInstaller = @'
param(
    [string]$RepositoryRoot,[string]$CodexHome,[string]$SourceRepository,[string]$SourceCommit,
    [string]$Acquisition,[string]$ArchiveSha256,[string]$SourceArchivePath,[string]$ExpectedCurrentCommit,
    [string]$ExpectedUpdateMode,[string]$ExpectedUpdateChannel,[string]$ExpectedUpdateRef
)
[System.IO.File]::WriteAllText(
    (Join-Path $RepositoryRoot 'expected-state.txt'),
    (@($ExpectedCurrentCommit,$ExpectedUpdateMode,$ExpectedUpdateChannel,$ExpectedUpdateRef) -join "`n")
)
'@
        [System.IO.File]::WriteAllText((Join-Path $scriptsRoot 'install-ai-instructions-bootstrap.ps1'),$fakeInstaller)
        $request = [pscustomobject]@{
            CodexHome = (Join-Path $TestDrive 'installer-contract-home')
            Repository = $script:CanonicalRepository
            CurrentCommit = ('a' * 40)
            CandidateCommit = ('b' * 40)
            Mode = 'auto-install-approved'
            Channel = 'protected-branch'
            Ref = 'main'
            Package = [pscustomobject]@{ SourceRoot=$sourceRoot; ArchivePath='C:\fixture.zip'; ArchiveSha256=('c' * 64) }
        }

        Install-AiInstructionsCandidatePackage -Request $request

        [System.IO.File]::ReadAllText((Join-Path $sourceRoot 'expected-state.txt')) |
            Should Be ((@(('a' * 40),'auto-install-approved','protected-branch','main') -join "`n"))
    }

    # Scenario: Another updater process holds the per-home update lock.
    # Purpose: Prevent concurrent staging or runtime swap operations.
    It 'UnitT70_reports_concurrent_when_the_update_lock_is_held' {
        $codexHome = Join-Path $TestDrive 'concurrent'
        New-TestUpdaterHome -Path $codexHome
        $lockPath = Join-Path $codexHome 'ai-instructions-update.lock'
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
                -ResolveCandidate { throw 'resolver must not run' } `
                -AcquireCandidate { throw 'archive must not be acquired' } `
                -InstallCandidate { throw 'installer must not run' }
        }
        finally {
            $lockStream.Dispose()
        }

        $result.outcome | Should Be 'concurrent'
    }

    # Scenario: A manual installer is swapping the active runtime while an update check starts.
    # Purpose: Avoid reading a mixed runtime/config identity and let the next bootstrap retry safely.
    It 'UnitT75_reports_concurrent_when_the_install_lock_is_held' {
        $codexHome = Join-Path $TestDrive 'concurrent-install'
        New-TestUpdaterHome -Path $codexHome
        $lockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
                -ResolveCandidate { throw 'resolver must not run' } `
                -AcquireCandidate { throw 'archive must not be acquired' } `
                -InstallCandidate { throw 'installer must not run' }
        }
        finally {
            $lockStream.Dispose()
        }

        $result.outcome | Should Be 'concurrent'
    }

    # Scenario: A manual installer tries to start only after updater preflight, while the remote candidate is being resolved.
    # Purpose: Keep the install-state lock through resolution and receipt persistence so a late installer cannot swap the active runtime.
    It 'UnitT76_keeps_the_install_lock_while_resolving_and_recording_the_candidate' {
        $codexHome = Join-Path $TestDrive 'late-concurrent-install'
        New-TestUpdaterHome -Path $codexHome
        $script:lateInstallerLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $script:lateInstallerLockStream = $null
        $script:lateInstallerLockAcquired = $false
        try {
            $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
                -ResolveCandidate {
                    try {
                        $script:lateInstallerLockStream = [System.IO.File]::Open(
                            $script:lateInstallerLockPath,
                            [System.IO.FileMode]::OpenOrCreate,
                            [System.IO.FileAccess]::ReadWrite,
                            [System.IO.FileShare]::None
                        )
                        $script:lateInstallerLockAcquired = $true
                    }
                    catch [System.IO.IOException] {
                        $script:lateInstallerLockAcquired = $false
                    }
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                } `
                -AcquireCandidate { throw 'archive must not be acquired' } `
                -InstallCandidate { throw 'installer must not run' }
        }
        finally {
            if ($null -ne $script:lateInstallerLockStream) { $script:lateInstallerLockStream.Dispose() }
            $script:lateInstallerLockStream = $null
        }

        $script:lateInstallerLockAcquired | Should Be $false
        $result.outcome | Should Be 'current'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-update-receipt.json') | Should Be $true
    }

    # Scenario: The manual update entry point encounters a concurrent installer while a launcher is waiting on it.
    # Purpose: Return a failing process status so the launcher cannot continue fan-out during runtime swap.
    It 'UnitT77_manual_update_command_fails_closed_on_concurrent_state' {
        $codexHome = Join-Path $TestDrive 'concurrent-command'
        New-TestUpdaterHome -Path $codexHome
        $lockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $script:RepositoryRoot 'scripts\update-ai-instructions.ps1') `
                -CodexHome $codexHome `
                -ForceCheck 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $lockStream.Dispose()
        }

        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'concurrent|installer is already running'
    }
}
