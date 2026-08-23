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
        $installCalls = 0

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { param($request) 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { $script:installCalls++ }

        $result.outcome | Should Be 'current'
        $installCalls | Should Be 0
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
            -InstallCandidate { param($request) $script:installCalls++ }

        $result.outcome | Should Be 'installed'
        $script:installCalls | Should Be 1
        $result.archiveSha256 | Should Be ('c' * 64)
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

    # Scenario: GitHub responds but the configured channel cannot produce a valid candidate.
    # Purpose: Do not disguise integrity or configuration failures as harmless offline operation.
    It 'UnitT47_records_non_network_candidate_resolution_errors_as_failed' {
        $codexHome = Join-Path $TestDrive 'invalid-candidate-source'
        New-TestUpdaterHome -Path $codexHome -Mode 'auto-install-approved'

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -ForceCheck `
            -ResolveCandidate { throw 'GitHub release response has no valid tag' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'failed'
        $result.message | Should Match 'no valid tag'
    }

    # Scenario: A successful update check occurred inside the configured minimum interval.
    # Purpose: Rate-limit bootstrap-triggered network checks while keeping a manual force option.
    It 'UnitT50_rate_limits_automatic_checks' {
        $codexHome = Join-Path $TestDrive 'rate-limit'
        New-TestUpdaterHome -Path $codexHome
        $receipt = [ordered]@{
            schemaVersion=1; checkedAtUtc='2026-08-23T04:00:00.0000000Z'; mode='notify-only';
            channel='protected-branch'; ref='main'; currentCommit=('a' * 40); candidateCommit=('a' * 40);
            outcome='current'; archiveSha256=$null; message='current'
        }
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-update-receipt.json'), (($receipt | ConvertTo-Json -Depth 5) + "`n"))

        $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $codexHome -NowUtc ([datetime]'2026-08-23T04:30:00Z') `
            -ResolveCandidate { throw 'resolver must not run' } `
            -AcquireCandidate { throw 'archive must not be acquired' } `
            -InstallCandidate { throw 'installer must not run' }

        $result.outcome | Should Be 'rate-limit'
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
}
