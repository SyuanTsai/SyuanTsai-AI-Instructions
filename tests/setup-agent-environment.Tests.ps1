# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# SYP-354 P10a: disposable cloud setup edge. Unit and static cases run on every
# host. Native integration cases are registered only on their native host; no
# case is skipped at run time.
Set-StrictMode -Version Latest

$setupTestIsWindows = [bool]$IsWindows
$setupTestIsUnix = [bool]($IsLinux -or $IsMacOS)
$setupTestUnixUid = if ($setupTestIsUnix) { [string](& id -u) } else { '' }

function Get-SetupTestRepositoryRoot { return (Split-Path -Parent $PSScriptRoot) }

Describe 'setup-agent-environment policy, plan, receipt and static contract (SYP-354 P10a)' {
    BeforeAll {
        $script:SetupRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SetupScripts = Join-Path $script:SetupRepositoryRoot 'scripts'
        Import-Module (Join-Path $script:SetupScripts 'agent-environment-setup.psm1') -DisableNameChecking -Force
        $script:SetupPolicyPath = Join-Path $script:SetupScripts 'setup-agent-environment.policy.json'
        $script:SetupSchemaPath = Join-Path $script:SetupScripts 'setup-agent-environment.policy.schema.json'
        $script:SetupTsvPath = Join-Path $script:SetupScripts 'setup-agent-environment.policy.tsv'
        $script:SetupShellPath = Join-Path $script:SetupScripts 'setup-agent-environment.sh'
        $script:SetupEntryPath = Join-Path $script:SetupScripts 'setup-agent-environment.ps1'
        $script:SetupPolicyText = [IO.File]::ReadAllText($script:SetupPolicyPath)
        $script:SetupSchemaText = [IO.File]::ReadAllText($script:SetupSchemaPath)
        $script:SetupShellText = [IO.File]::ReadAllText($script:SetupShellPath)
        $script:SetupFixtureRid = 'linux-x64'

        function Get-SetupTestPolicy { return ($script:SetupPolicyText | ConvertFrom-Json) }

        function Get-SetupTestRefusalCode {
            param([scriptblock]$Action)
            try { & $Action | Out-Null } catch { return (Get-AgentEnvironmentSetupRefusalCode $_) }
            return $null
        }

        function Test-SetupTestSchema {
            param([string]$Json)
            return [bool](Test-Json -Json $Json -Schema $script:SetupSchemaText -ErrorAction SilentlyContinue)
        }

        function New-SetupTestHome {
            param([string]$Name)
            $root = Join-Path $TestDrive $Name
            [void][IO.Directory]::CreateDirectory($root)
            $userHome = Join-Path $root 'home'
            [void][IO.Directory]::CreateDirectory($userHome)
            $policy = Get-SetupTestPolicy
            $asset = Get-AgentEnvironmentSetupPolicyAsset $policy $script:SetupFixtureRid
            $archive = Join-Path $root $asset.Name
            [IO.File]::WriteAllText($archive,'fixture archive bytes')
            $layout = Get-AgentEnvironmentSetupLayout $userHome $script:SetupFixtureRid $asset.Version
            return [pscustomobject]@{ Root = $root; Home = $userHome; CodexHome = (Join-Path $userHome '.codex'); Archive = $archive; Policy = $policy; Layout = $layout }
        }

        function Get-SetupTestPlan {
            param($Fixture,[string]$Mode='Prepare',[string]$ArchivePath)
            if (-not $PSBoundParameters.ContainsKey('ArchivePath')) { $ArchivePath = $Fixture.Archive }
            return Get-AgentEnvironmentSetupPlan -Policy $Fixture.Policy -UserHome $Fixture.Home -CodexHome $Fixture.CodexHome -Mode $Mode -ArchivePath $ArchivePath -Rid $script:SetupFixtureRid
        }

        function New-SetupTestRuntime {
            param($Fixture,[switch]$Directory,[switch]$Receipt)
            if ($Directory) { [void][IO.Directory]::CreateDirectory($Fixture.Layout.RuntimeDirectory) }
            if ($Receipt) { [void][IO.Directory]::CreateDirectory($Fixture.Layout.ReceiptDirectory); [IO.File]::WriteAllText((Join-Path $Fixture.Layout.ReceiptDirectory $Fixture.Layout.RuntimeReceiptLeaf),'{}') }
        }

        function Get-SetupTestTreeSnapshot {
            param([string]$Root)
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($Root.Length)
                if ($item.PSIsContainer) { "D $relative" } else { "F $relative $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)" }
            }
            return (@($lines) -join "`n")
        }

        function Initialize-SetupTestGitRepository {
            param([string]$Root)
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'scripts'))
            foreach ($relative in @(Get-AgentEnvironmentSetupBoundFiles)) {
                Copy-Item -LiteralPath (Join-Path $script:SetupRepositoryRoot $relative) -Destination (Join-Path $Root $relative)
            }
            & git -C $Root init -q 2>$null | Out-Null
            & git -C $Root -c core.autocrlf=false add -A 2>$null | Out-Null
            & git -C $Root -c user.name=setup-test -c user.email=setup-test@example.invalid -c core.autocrlf=false commit -q -m fixture 2>$null | Out-Null
            return [string](& git -C $Root rev-parse HEAD)
        }
    }

    AfterAll { Remove-Module agent-environment-setup -Force -ErrorAction SilentlyContinue }

    # Scenario: The production policy is loaded exactly as the PowerShell entry loads it.
    # Purpose: Pin PowerShell 7.6.6 with one lowercase SHA-256 per supported RID, accepted by schema and validator.
    It 'UnitT1_pins_powershell_7_6_6_for_six_rids_in_a_schema_valid_policy' {
        $read = Read-AgentEnvironmentSetupPolicy $script:SetupPolicyPath
        $read.Policy.schemaVersion | Should Be 1
        $read.Policy.powerShell.version | Should Be '7.6.6'
        $read.Policy.powerShell.downloadUrlTemplate | Should BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v{version}/{assetName}'
        (@($read.Policy.powerShell.assets.rid | Sort-Object) -join ',') | Should BeExactly 'linux-arm64,linux-x64,osx-arm64,osx-x64,win-arm64,win-x64'
        foreach ($asset in @($read.Policy.powerShell.assets)) { $asset.sha256 | Should MatchExactly '^[a-f0-9]{64}$' }
        $read.Sha256 | Should MatchExactly '^[a-f0-9]{64}$'
        Test-SetupTestSchema $script:SetupPolicyText | Should Be $true
    }

    # Scenario: Policy variants violate the schema or the cross-field rules.
    # Purpose: Reject unknown schemaVersion, extra fields, bad hashes, missing or unknown RIDs and mismatched names in schema and validator alike.
    It 'UnitT2_rejects_invalid_policy_variants_in_schema_and_validator' {
        $cases = @(
            @{ Name='unknown-schema-version'; Schema=$true; Mutate={ param($p) $p.schemaVersion = 2 } },
            @{ Name='extra-top-level'; Schema=$true; Mutate={ param($p) $p | Add-Member -NotePropertyName extra -NotePropertyValue 1 } },
            @{ Name='extra-powershell-field'; Schema=$true; Mutate={ param($p) $p.powerShell | Add-Member -NotePropertyName latest -NotePropertyValue $true } },
            @{ Name='extra-asset-field'; Schema=$true; Mutate={ param($p) $p.powerShell.assets[0] | Add-Member -NotePropertyName url -NotePropertyValue 'https://example.invalid' } },
            @{ Name='uppercase-hash'; Schema=$true; Mutate={ param($p) $p.powerShell.assets[0].sha256 = $p.powerShell.assets[0].sha256.ToUpperInvariant() } },
            @{ Name='short-hash'; Schema=$true; Mutate={ param($p) $p.powerShell.assets[1].sha256 = 'abc' } },
            @{ Name='missing-rid'; Schema=$true; Mutate={ param($p) $p.powerShell.assets = @($p.powerShell.assets | Select-Object -Skip 1) } },
            @{ Name='unknown-rid'; Schema=$true; Mutate={ param($p) $p.powerShell.assets[2].rid = 'linux-musl-x64' } },
            @{ Name='floating-version'; Schema=$true; Mutate={ param($p) $p.powerShell.version = 'latest' } },
            @{ Name='plain-http-template'; Schema=$true; Mutate={ param($p) $p.powerShell.downloadUrlTemplate = 'http://github.com/PowerShell/PowerShell/releases/download/v{version}/{assetName}' } },
            @{ Name='non-official-https-template'; Schema=$true; Mutate={ param($p) $p.powerShell.downloadUrlTemplate = 'https://example.com/releases/download/v{version}/{assetName}' } },
            @{ Name='missing-assets'; Schema=$true; Mutate={ param($p) $p.powerShell.PSObject.Properties.Remove('assets') } },
            @{ Name='duplicate-rid'; Schema=$false; Mutate={ param($p) $p.powerShell.assets[1].rid = 'win-x64'; $p.powerShell.assets[1].name = $p.powerShell.assets[0].name } },
            @{ Name='name-not-bound-to-version'; Schema=$false; Mutate={ param($p) $p.powerShell.assets[2].name = 'powershell-7.6.5-linux-x64.tar.gz' } }
        )
        foreach ($case in $cases) {
            $policy = Get-SetupTestPolicy
            & $case.Mutate $policy
            $json = $policy | ConvertTo-Json -Depth 8
            (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupPolicy ($json | ConvertFrom-Json) }) | Should Be 'policy-invalid'
            if ($case.Schema) { Test-SetupTestSchema $json | Should Be $false }
        }
    }

    # Scenario: The shell reads the derived TSV, while PowerShell reads the JSON policy.
    # Purpose: Keep the TSV a byte-for-byte derivation of the JSON policy.
    It 'UnitT3_keeps_the_shell_tsv_identical_to_the_json_derivation' {
        $policy = Get-SetupTestPolicy
        ([IO.File]::ReadAllText($script:SetupTsvPath).Replace("`r`n","`n")) | Should BeExactly (ConvertTo-AgentEnvironmentSetupPolicyTsv $policy)
        { Assert-AgentEnvironmentSetupPolicyTsv $policy $script:SetupTsvPath } | Should Not Throw
        $drift = Join-Path $TestDrive 'drift.tsv'
        [IO.File]::WriteAllText($drift,(ConvertTo-AgentEnvironmentSetupPolicyTsv $policy).Replace($policy.powerShell.assets[2].sha256,('0'*64)))
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupPolicyTsv $policy $drift }) | Should Be 'policy-invalid'
    }

    # Scenario: Standards conformance downloads the same PowerShell 7.6.6 assets.
    # Purpose: Keep win-x64, linux-x64 and osx-arm64 hashes synchronized with the workflow after case normalization.
    It 'UnitT4_matches_the_standards_conformance_workflow_hashes' {
        $workflow = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot '.github/workflows/standards-conformance.yml'))
        $pairs = @{}
        foreach ($match in [regex]::Matches($workflow,'asset:\s*(\S+)\s*\r?\n\s*sha256:\s*([0-9A-Fa-f]{64})')) { $pairs[$match.Groups[1].Value] = $match.Groups[2].Value.ToLowerInvariant() }
        $policy = Get-SetupTestPolicy
        foreach ($rid in @('win-x64','linux-x64','osx-arm64')) {
            $asset = Get-AgentEnvironmentSetupPolicyAsset $policy $rid
            $pairs.ContainsKey($asset.Name) | Should Be $true
            $pairs[$asset.Name] | Should BeExactly $asset.Sha256
        }
    }

    # Scenario: Resolve-PlatformPowerShell selects the asset from the same policy object.
    # Purpose: Prove the policy shape is accepted by the platform-runtime asset selector for every RID.
    It 'UnitT5_is_accepted_by_the_platform_runtime_asset_selector_for_every_rid' {
        $preparation = @(Import-Module (Join-Path $script:SetupScripts 'platform/RuntimePreparation.psm1') -PassThru -DisableNameChecking)[0]
        $policy = Get-SetupTestPolicy
        foreach ($pair in @(@('windows','win'),@('linux','linux'),@('macos','osx'))) {
            foreach ($architecture in @('x64','arm64')) {
                $selected = & $preparation { param($p,$platform,$arch) Get-PlatformPowerShellAsset $p $platform $arch $null } $policy $pair[0] $architecture
                $expected = Get-AgentEnvironmentSetupPolicyAsset $policy "$($pair[1])-$architecture"
                $selected.Name | Should BeExactly $expected.Name
                $selected.Sha256 | Should BeExactly $expected.Sha256
                $selected.Version | Should BeExactly '7.6.6'
            }
        }
    }

    # Scenario: No canonical runtime exists yet.
    # Purpose: Prepare resolves it, while Offline refuses instead of updating (K16).
    It 'UnitT10_plans_resolution_only_for_prepare_when_the_runtime_is_absent' {
        $fixture = New-SetupTestHome 'plan-absent'
        $prepare = Get-SetupTestPlan $fixture 'Prepare'
        $prepare.decision | Should Be 'resolve-runtime'
        $prepare.runtimeState | Should Be 'absent'
        $prepare.code | Should BeNullOrEmpty
        (@($prepare.deferredSteps) -join ',') | Should Be 'S7,S8,S9'
        $offline = Get-SetupTestPlan $fixture 'Offline'
        $offline.decision | Should Be 'refuse'
        $offline.code | Should Be 'runtime-missing'
    }

    # Scenario: A canonical runtime and its receipt already exist.
    # Purpose: Reruns and offline runs only re-verify; they never call Resolve again.
    It 'UnitT11_plans_reverification_for_an_existing_runtime_in_both_modes' {
        $fixture = New-SetupTestHome 'plan-present'
        New-SetupTestRuntime $fixture -Directory -Receipt
        foreach ($mode in @('Prepare','Offline')) {
            $plan = Get-SetupTestPlan $fixture $mode
            $plan.decision | Should Be 'verify-runtime'
            $plan.runtimeState | Should Be 'present'
        }
    }

    # Scenario: Only the runtime directory or only its receipt exists.
    # Purpose: Fail closed as runtime-incomplete instead of reinstalling automatically.
    It 'UnitT12_refuses_an_incomplete_runtime_without_reinstalling' {
        $directoryOnly = New-SetupTestHome 'plan-directory-only'; New-SetupTestRuntime $directoryOnly -Directory
        $receiptOnly = New-SetupTestHome 'plan-receipt-only'; New-SetupTestRuntime $receiptOnly -Receipt
        foreach ($fixture in @($directoryOnly,$receiptOnly)) {
            $plan = Get-SetupTestPlan $fixture 'Prepare'
            $plan.decision | Should Be 'refuse'
            $plan.code | Should Be 'runtime-incomplete'
            $plan.recoverCommand | Should Match 'rerun setup with --prepare'
        }
    }

    # Scenario: CODEX_HOME holds an install transaction store (directory or file).
    # Purpose: K7 refuses before any installer call and names the pwsh 7 installer recovery command.
    It 'UnitT13_refuses_codex_home_transaction_residue_with_the_installer_recovery' {
        foreach ($kind in @('directory','file')) {
            $fixture = New-SetupTestHome "plan-codex-txn-$kind"
            New-SetupTestRuntime $fixture -Directory -Receipt
            [void][IO.Directory]::CreateDirectory($fixture.CodexHome)
            $store = Join-Path $fixture.CodexHome '.ai-instructions-txn'
            if ($kind -eq 'directory') { [void][IO.Directory]::CreateDirectory((Join-Path $store ('a'*32))) } else { [IO.File]::WriteAllText($store,'x') }
            $plan = Get-SetupTestPlan $fixture 'Offline'
            $plan.decision | Should Be 'refuse'
            $plan.code | Should Be 'interrupted-install'
            (@($plan.residue) -join ',') | Should BeExactly '~/.codex/.ai-instructions-txn'
            $plan.recoverCommand | Should Match '^pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap\.ps1 -CodexHome ~/\.codex$'
        }
    }

    # Scenario: Legacy .ai-instructions-install-* or .ai-instructions-backup-* residue exists in CODEX_HOME.
    # Purpose: K7 refuses legacy residue too, pointing to manual inspection and the installer.
    It 'UnitT14_refuses_legacy_install_and_backup_residue' {
        foreach ($leaf in @('.ai-instructions-install-1234','.ai-instructions-backup-5678')) {
            $fixture = New-SetupTestHome "plan-legacy$leaf"
            [void][IO.Directory]::CreateDirectory((Join-Path $fixture.CodexHome $leaf))
            $plan = Get-SetupTestPlan $fixture 'Prepare'
            $plan.code | Should Be 'interrupted-install'
            (@($plan.residue) -join ',') | Should BeExactly "~/.codex/$leaf"
            $plan.reason | Should Match 'inspect it manually'
            $plan.recoverCommand | Should Match 'install-ai-instructions-bootstrap\.ps1'
        }
    }

    # Scenario: The USER home holds an agent-environment transaction store.
    # Purpose: K7 refuses and names update-agent-environment.ps1 -Recover instead of recovering automatically.
    It 'UnitT15_refuses_user_home_transaction_residue_with_the_recover_command' {
        $fixture = New-SetupTestHome 'plan-user-txn'
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Home '.ai-instructions-txn'))
        $plan = Get-SetupTestPlan $fixture 'Prepare'
        $plan.code | Should Be 'interrupted-install'
        (@($plan.residue) -join ',') | Should BeExactly '~/.ai-instructions-txn'
        $plan.recoverCommand | Should BeExactly 'pwsh -NoProfile -NonInteractive -File ~/.codex/hooks/update-agent-environment.ps1 -Recover'
    }

    # Scenario: The archive is absent, empty-path or a directory with the asset name.
    # Purpose: Refuse as cache-missing in both modes; never substitute an unverified archive.
    It 'UnitT16_refuses_a_missing_or_non_regular_archive_as_cache_missing' {
        $fixture = New-SetupTestHome 'plan-cache'
        Remove-Item -LiteralPath $fixture.Archive
        (Get-SetupTestPlan $fixture 'Offline').code | Should Be 'cache-missing'
        (Get-SetupTestPlan $fixture 'Prepare' '').code | Should Be 'cache-missing'
        [void][IO.Directory]::CreateDirectory($fixture.Archive)
        (Get-SetupTestPlan $fixture 'Prepare').code | Should Be 'cache-missing'
    }

    # Scenario: Residue, a missing cache and an absent runtime are all present.
    # Purpose: K7 residue wins, so no later step can run an installer path that would auto-recover.
    It 'UnitT17_checks_interrupted_install_residue_before_cache_and_runtime_state' {
        $fixture = New-SetupTestHome 'plan-precedence'
        Remove-Item -LiteralPath $fixture.Archive
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.CodexHome '.ai-instructions-txn'))
        (Get-SetupTestPlan $fixture 'Offline').code | Should Be 'interrupted-install'
    }

    # Scenario: Plans are computed over every decision-table state.
    # Purpose: Get-AgentEnvironmentSetupPlan is purely read-only; the tree is byte-identical afterwards.
    It 'UnitT18_keeps_plan_evaluation_read_only' {
        $fixture = New-SetupTestHome 'plan-read-only'
        New-SetupTestRuntime $fixture -Directory
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.CodexHome '.ai-instructions-install-1'))
        $before = Get-SetupTestTreeSnapshot $fixture.Root
        foreach ($mode in @('Prepare','Offline')) { [void](Get-SetupTestPlan $fixture $mode) }
        Remove-Item -LiteralPath (Join-Path $fixture.CodexHome '.ai-instructions-install-1')
        $middle = Get-SetupTestTreeSnapshot $fixture.Root
        foreach ($mode in @('Prepare','Offline')) { [void](Get-SetupTestPlan $fixture $mode) }
        (Get-SetupTestTreeSnapshot $fixture.Root) | Should BeExactly $middle
        $before | Should Not BeExactly $middle
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($setupTestIsUnix) {
    # Scenario: Residue or a setup-root ancestor is a dangling symbolic link.
    # Purpose: Directory enumeration sees dangling links, so residue is refused and the path walk rejects the link.
    It 'UnitT19_detects_dangling_symbolic_link_residue_and_ancestors_on_unix' {
        $fixture = New-SetupTestHome 'plan-dangling'
        [void][IO.Directory]::CreateDirectory($fixture.CodexHome)
        [void][IO.File]::CreateSymbolicLink((Join-Path $fixture.CodexHome '.ai-instructions-txn'),(Join-Path $fixture.Root 'missing-target'))
        (Get-SetupTestPlan $fixture 'Prepare').code | Should Be 'interrupted-install'
        $other = New-SetupTestHome 'path-dangling'
        [void][IO.Directory]::CreateSymbolicLink((Join-Path $other.Home '.local'),(Join-Path $other.Root 'missing-local'))
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupPhysicalPath $other.Layout.SetupRoot 'The setup root' }) | Should Be 'unsafe-path'
    }
    }

    # Scenario: Success and refusal receipts are rendered for the same RID.
    # Purpose: Lock the versioned receipt field set, runtimeCommit=null (K12) and the P10b placeholders (K10).
    It 'UnitT20_renders_the_versioned_receipt_field_set_for_success_and_refusal' {
        $expected = @(Get-AgentEnvironmentSetupReceiptFieldNames)
        $success = New-AgentEnvironmentSetupReceipt -Mode prepare -Result prepared-runtime-only -Rid linux-x64 -SetupCommit ('a'*40) -PolicySha256 ('b'*64) -DotNetVersion '.NET 9.0.0' -Capabilities @([pscustomobject]@{name='lock';status='available';evidence='/home/private/path'}) -RuntimeAction resolved
        $refusal = New-AgentEnvironmentSetupReceipt -Mode offline -Result refused -Code cache-missing -Rid osx-arm64 -RecoverCommand 'Rerun setup with --prepare while network access is allowed.'
        foreach ($receipt in @($success,$refusal)) {
            (@($receipt.PSObject.Properties.Name) -join ',') | Should BeExactly ($expected -join ',')
            $receipt.runtimeCommit | Should BeNullOrEmpty
            $receipt.setupRoot | Should BeExactly '~/.local/share/ai-instructions-setup'
            $receipt.codexHome | Should BeExactly '~/.codex'
            (@($receipt.steps | Where-Object step -in @('S7','S8','S9') | ForEach-Object status | Select-Object -Unique) -join ',') | Should BeExactly 'not-implemented-until-p10b'
        }
        $success.result | Should Be 'prepared-runtime-only'; $success.exitCode | Should Be 0; $success.code | Should BeNullOrEmpty; $success.os | Should Be 'linux'; $success.architecture | Should Be 'x64'
        $success.recoverCommand | Should BeNullOrEmpty
        (@($success.capabilities[0].PSObject.Properties.Name) -join ',') | Should BeExactly 'name,status'
        $refusal.result | Should Be 'refused'; $refusal.code | Should Be 'cache-missing'; $refusal.exitCode | Should Be 20; $refusal.os | Should Be 'macos'
        (ConvertTo-AgentEnvironmentSetupJsonLine $success) | Should Not Match "`n"
    }

    # Scenario: A Resolve-shaped runtime receipt is stored and loaded again.
    # Purpose: M2 stores '~/...' paths only and restores the exact absolute paths needed for re-verification.
    It 'UnitT21_stores_runtime_receipts_home_relative_and_restores_absolute_paths' {
        $fixture = New-SetupTestHome 'receipt-paths'
        $executable = Join-Path $fixture.Layout.RuntimeDirectory 'pwsh'
        $receipt = [pscustomobject][ordered]@{ apiVersion='1.0'; version='7.6.6'; assetName='powershell-7.6.6-linux-x64.tar.gz'; archiveSha256=('c'*64); executablePath=$executable; executableSha256=('d'*64)
            runtimeClosure=[pscustomobject]@{ rootPath=$fixture.Layout.RuntimeDirectory; sha256=('e'*64); files=@([pscustomobject]@{path='pwsh';sha256=('d'*64)}); directories=@(); directorySha256=('0'*64) }
            environmentAllowlist=@('PATH'); warningCount=1; warnings=@("warning about $($fixture.Home)"); protectionBoundary='A1'; os='linux'; architecture='x64' }
        $stored = ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt $receipt $fixture.Home
        $json = ConvertTo-AgentEnvironmentSetupJsonLine $stored
        $json.Contains($fixture.Home) | Should Be $false
        $json.Contains($fixture.Home.Replace('\','/')) | Should Be $false
        $stored.executablePath | Should BeExactly '~/.local/share/ai-instructions-setup/pwsh/7.6.6-linux-x64/pwsh'
        $restored = ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt ($json | ConvertFrom-Json) $fixture.Home
        $restored.executablePath | Should BeExactly ([IO.Path]::GetFullPath($executable))
        $restored.runtimeClosure.rootPath | Should BeExactly ([IO.Path]::GetFullPath($fixture.Layout.RuntimeDirectory))
        (Get-SetupTestRefusalCode { ConvertFrom-AgentEnvironmentSetupHomePath '~/../escape' $fixture.Home }) | Should Be 'runtime-verification-failed'
        (Get-SetupTestRefusalCode { ConvertTo-AgentEnvironmentSetupHomePath $fixture.Root $fixture.Home }) | Should Be 'unsafe-path'
    }

    # Scenario: Secret-looking and loader variables are present in the parent environment.
    # Purpose: The owned-child allowlist drops loader/runtime overrides and markers; receipts never carry environment values.
    It 'UnitT22_never_forwards_loader_overrides_or_leaks_secret_markers' {
        $marker = 'p10a-secret-marker-' + [guid]::NewGuid().ToString('N')
        $names = @('SYP_P10A_SECRET_TOKEN','DOTNET_STARTUP_HOOKS','LD_PRELOAD','DYLD_INSERT_LIBRARIES','POWERSHELL_TELEMETRY_OPTOUT','PSModulePath','ATLASSIAN_API_TOKEN')
        $previous = @{}; foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$marker) }
            $fixture = New-SetupTestHome 'receipt-secrets'
            $environment = Get-AgentEnvironmentSetupChildEnvironment $fixture.Layout.RuntimeDirectory $fixture.Home
            foreach ($name in $names) { if ($name -cne 'PSModulePath') { $environment.Contains($name) | Should Be $false } }
            $environment['PSModulePath'] | Should BeExactly (Join-Path $fixture.Layout.RuntimeDirectory 'Modules')
            $environment['HOME'] | Should BeExactly $fixture.Home
            (@($environment.Values) -join "`n").Contains($marker) | Should Be $false
            $receipt = New-AgentEnvironmentSetupReceipt -Mode prepare -Result prepared-runtime-only -Rid linux-x64 -SetupCommit ('a'*40) -PolicySha256 ('b'*64) -Capabilities @([pscustomobject]@{name='lock';status='available';evidence=$marker})
            (ConvertTo-AgentEnvironmentSetupJsonLine $receipt).Contains($marker) | Should Be $false
            (ConvertTo-AgentEnvironmentSetupSanitizedText "failed below $($fixture.Home)/x" $fixture.Home) | Should BeExactly 'failed below ~/x'
        } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name]) } }
    }

    # Scenario: The shell edge, the PowerShell entry and both README tables define exit codes.
    # Purpose: L5 keeps one unique typed exit-code table everywhere.
    It 'UnitT23_shares_one_typed_exit_code_table_across_shell_ps1_and_readme' {
        $table = Get-AgentEnvironmentSetupExitCodeTable
        (@($table.Values | Select-Object -Unique)).Count | Should Be $table.Count
        $shell = [ordered]@{}
        foreach ($match in [regex]::Matches($script:SetupShellText,'(?m)^EXIT_([A-Z_]+)=([0-9]+)$')) { $shell[$match.Groups[1].Value.ToLowerInvariant().Replace('_','-')] = [int]$match.Groups[2].Value }
        (($shell.Keys | ForEach-Object { "$_=$($shell[$_])" }) -join ',') | Should BeExactly (($table.Keys | ForEach-Object { "$_=$($table[$_])" }) -join ',')
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        $rows = [regex]::Matches($readme,'(?m)^\| ([0-9]+) \| `([a-z0-9-]+)` \|')
        $rows.Count | Should Be (2 * $table.Count)
        foreach ($half in @(0,1)) {
            $slice = @($rows | Select-Object -Skip ($half * $table.Count) -First $table.Count | ForEach-Object { "$($_.Groups[2].Value)=$($_.Groups[1].Value)" })
            ($slice -join ',') | Should BeExactly (($table.Keys | ForEach-Object { "$_=$($table[$_])" }) -join ',')
        }
        $entry = [IO.File]::ReadAllText($script:SetupEntryPath)
        $entry | Should Match ('(?m)^\$script:SetupBaselineExitCode = ' + $table['runtime-baseline-unavailable'] + '$')
        $entry | Should Match ('(?m)^\$script:SetupInternalExitCode = ' + $table['internal-error'] + '$')
    }

    # Scenario: CODEX_HOME is unset, set to ~/.codex, or set elsewhere.
    # Purpose: H5/S6 accept only ~/.codex and refuse any other pre-set value as codex-home-conflict.
    It 'UnitT24_refuses_a_preset_codex_home_outside_the_fixed_location' {
        $fixture = New-SetupTestHome 'codex-home'
        $previous = [Environment]::GetEnvironmentVariable('CODEX_HOME')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_HOME',$null)
            Assert-AgentEnvironmentSetupCodexHome $fixture.Home | Should BeExactly ([IO.Path]::GetFullPath($fixture.CodexHome))
            [Environment]::SetEnvironmentVariable('CODEX_HOME',$fixture.CodexHome)
            Assert-AgentEnvironmentSetupCodexHome $fixture.Home | Should BeExactly ([IO.Path]::GetFullPath($fixture.CodexHome))
            foreach ($value in @((Join-Path $fixture.Root 'elsewhere'),'relative/.codex')) {
                [Environment]::SetEnvironmentVariable('CODEX_HOME',$value)
                (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCodexHome $fixture.Home }) | Should Be 'codex-home-conflict'
            }
        } finally { [Environment]::SetEnvironmentVariable('CODEX_HOME',$previous) }
    }

    # Scenario: A git checkout holds the six bound files at a pinned commit.
    # Purpose: K4 accepts only HEAD == --expected-commit with tracked, unmodified bound files.
    It 'UnitT25_binds_head_and_the_six_bound_files_to_the_expected_commit' {
        $root = Join-Path $TestDrive 'k4-repository'
        $commit = Initialize-SetupTestGitRepository $root
        $commit | Should MatchExactly '^[0-9a-f]{40}$'
        { Assert-AgentEnvironmentSetupCommit $root $commit } | Should Not Throw
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root ('0'*40) }) | Should Be 'commit-mismatch'
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root $commit.ToUpperInvariant() }) | Should Be 'usage'
        $policyPath = Join-Path $root 'scripts/setup-agent-environment.policy.json'
        $original = [IO.File]::ReadAllBytes($policyPath)
        [IO.File]::AppendAllText($policyPath,' ')
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root $commit }) | Should Be 'commit-mismatch'
        [IO.File]::WriteAllBytes($policyPath,$original)
        & git -C $root rm -q --cached -- scripts/setup-agent-environment.policy.tsv 2>$null | Out-Null
        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root $commit }) | Should Be 'commit-mismatch'
        (@(Get-AgentEnvironmentSetupBoundFiles) -join ' ') | Should BeExactly ([regex]::Match($script:SetupShellText,"(?m)^BOUND_FILES='([^']+)'$").Groups[1].Value)
    }

    # Scenario: The platform runtime manifest and shell trust list are compared ordinally, including a manifest-only negative fixture.
    # Purpose: G9 prevents a newly imported platform member from escaping the shell's pre-import K4 trust closure.
    It 'UnitT25a_keeps_platform_bound_files_exactly_equal_to_the_manifest_file_list' {
        function Assert-PlatformBoundFileParity {
            param([string]$ManifestText,[string]$ShellText)
            $manifestMatch = [regex]::Match($ManifestText,'(?ms)\bFileList\s*=\s*@\((.*?)\)\s*\r?\n\s*PrivateData\s*=')
            $shellMatch = [regex]::Match($ShellText,"(?m)^PLATFORM_BOUND_FILES='([^']+)'$")
            if (-not $manifestMatch.Success -or -not $shellMatch.Success) { throw 'The platform trust inventories cannot be parsed.' }
            $manifestFiles = @([regex]::Matches($manifestMatch.Groups[1].Value,"'([^']+)'",[Text.RegularExpressions.RegexOptions]::CultureInvariant) | ForEach-Object { 'scripts/' + $_.Groups[1].Value })
            $shellFiles = @($shellMatch.Groups[1].Value.Split(' ',[StringSplitOptions]::RemoveEmptyEntries))
            if (@($manifestFiles | Select-Object -Unique).Count -ne $manifestFiles.Count -or @($shellFiles | Select-Object -Unique).Count -ne $shellFiles.Count) { throw 'The platform trust inventory contains duplicates.' }
            $manifestSorted = [string[]]$manifestFiles.Clone(); [Array]::Sort($manifestSorted,[StringComparer]::Ordinal)
            $shellSorted = [string[]]$shellFiles.Clone(); [Array]::Sort($shellSorted,[StringComparer]::Ordinal)
            if (($manifestSorted -join "`n") -cne ($shellSorted -join "`n")) { throw 'The shell and manifest platform trust inventories differ.' }
        }
        $manifestText = [IO.File]::ReadAllText((Join-Path $script:SetupScripts 'platform-runtime.psd1'))
        { Assert-PlatformBoundFileParity $manifestText $script:SetupShellText } | Should Not Throw
        $negative = $manifestText.Replace("        'platform-runtime.psm1',","        'platform-runtime.psm1',`n        'platform/NewAdapter.psm1',")
        { Assert-PlatformBoundFileParity $negative $script:SetupShellText } | Should Throw
    }

    # Scenario: A stored runtime receipt points at a byte-identical copy instead of the selected canonical layout.
    # Purpose: F3 binds both receipt paths ordinally to RuntimeDirectory/RuntimeExecutable before K15 or re-exec.
    It 'UnitT26_binds_runtime_receipt_paths_to_the_canonical_layout' {
        $fixture = New-SetupTestHome 'receipt-layout-binding'
        $valid = [pscustomobject]@{ executablePath=$fixture.Layout.RuntimeExecutable; runtimeClosure=[pscustomobject]@{ rootPath=$fixture.Layout.RuntimeDirectory } }
        { Assert-AgentEnvironmentSetupRuntimeReceiptLayout $valid $fixture.Layout } | Should Not Throw
        foreach ($mutate in @(
            { param($r,$f) $r.executablePath = Join-Path $f.Root 'copy/pwsh' },
            { param($r,$f) $r.runtimeClosure.rootPath = Join-Path $f.Root 'copy' }
        )) {
            $receipt = $valid | ConvertTo-Json -Depth 4 | ConvertFrom-Json
            & $mutate $receipt $fixture
            (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupRuntimeReceiptLayout $receipt $fixture.Layout }) | Should Be 'runtime-verification-failed'
        }
    }

    # Scenario: A prior setup publication left its own transaction store under setup root.
    # Purpose: F5 includes setup-root residue in K7 planning and routes it to lock-held recovery.
    It 'UnitT27_routes_setup_publication_residue_to_locked_recovery' {
        $fixture = New-SetupTestHome 'plan-setup-residue'
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn/deadbeefdeadbeefdeadbeefdeadbeef'))
        $before = Get-SetupTestTreeSnapshot $fixture.Root
        $plan = Get-SetupTestPlan $fixture 'Prepare'
        $plan.decision | Should Be 'recover-setup'
        $plan.code | Should BeNullOrEmpty
        (@($plan.residue) -join ',') | Should BeExactly '~/.local/share/ai-instructions-setup/.ai-instructions-txn'
        (Get-SetupTestTreeSnapshot $fixture.Root) | Should BeExactly $before
    }

    # Scenario: A process died before WAL creation (journal-stage or legacy payload-stage state) or after WAL deletion (empty transaction).
    # Purpose: G2 gives every proven no-journal crash window one safe cleanup decision instead of a permanent interrupted-install refusal.
    It 'UnitT28_cleans_proven_no_journal_crash_states' {
        foreach ($members in @(@(),@('stage'),@('journal.stage'))) {
            $fixture = New-SetupTestHome ('publication-no-journal-' + $(if($members.Count -eq 0){'empty'}else{$members[0].Replace('.','-')}))
            $transaction = Join-Path $fixture.Layout.SetupRoot ('.ai-instructions-txn/' + ('a'*32))
            [void][IO.Directory]::CreateDirectory($transaction)
            if($members.Count -gt 0){[IO.File]::WriteAllText((Join-Path $transaction $members[0]),'unpublished')}
            Repair-AgentEnvironmentSetupTransactions $fixture.Layout.SetupRoot
            Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $false
        }
    }

    # Scenario: The shell edge is read as text on every host.
    # Purpose: Require a POSIX sh shebang, strict mode, umask 077, LF-only ASCII bytes.
    It 'UnitT30_uses_posix_sh_strict_mode_umask_and_lf_ascii_bytes' {
        $bytes = [IO.File]::ReadAllBytes($script:SetupShellPath)
        @($bytes | Where-Object { $_ -eq 13 -or $_ -gt 127 }).Count | Should Be 0
        $script:SetupShellText.StartsWith("#!/bin/sh`n",[StringComparison]::Ordinal) | Should Be $true
        $script:SetupShellText | Should Match '(?m)^set -eu$'
        $script:SetupShellText | Should Match '(?m)^umask 077$'
        $script:SetupShellText | Should Match '(?m)^trap cleanup EXIT$'
    }

    # Scenario: The shell edge is scanned for forbidden constructs.
    # Purpose: No privilege elevation, pipe-to-shell, eval or shell profile edits.
    It 'UnitT31_contains_no_elevation_pipe_to_shell_eval_or_profile_edits' {
        foreach ($pattern in @('\bsudo\b','\|\s*(ba|z|da)?sh\b','\beval\b','\bsource\b','\.bashrc','\.bash_profile','\.zshrc','\.profile\b','/etc/profile','\bdoas\b','\bsu\s+-')) {
            $script:SetupShellText | Should Not Match $pattern
        }
    }

    # Scenario: The shell edge is scanned for bash-only syntax on hosts without a native sh.
    # Purpose: Keep the bootstrap edge POSIX-only (text rules complement sh -n on native hosts).
    It 'UnitT32_avoids_bash_only_syntax' {
        $code = ($script:SetupShellText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        foreach ($pattern in @('\[\[','(?m)^\s*function\s','\blocal\s','<<<','\$\{[A-Za-z_][A-Za-z0-9_]*//','\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]','\bdeclare\b','\btypeset\b','pipefail','\$''','&>','\[ [^\]]*==','\b[A-Za-z_][A-Za-z0-9_]*=\(','\bshopt\b','\$RANDOM','\breadarray\b','\bmapfile\b')) {
            $code | Should Not Match $pattern
        }
    }

    # Scenario: The shell edge downloads and hands off to PowerShell.
    # Purpose: L7 https-only bounded downloads, M5 env -i allowlist, fixed setup root without XDG.
    It 'UnitT33_uses_https_only_bounded_downloads_and_an_environment_allowlist' {
        $script:SetupShellText | Should Match "curl --proto '=https' --proto-redir '=https' --tlsv1\.2"
        $script:SetupShellText | Should Match '--max-time [0-9]+'
        $script:SetupShellText | Should Match 'wget --https-only --secure-protocol=TLSv1_2 --timeout=[0-9]+'
        $script:SetupShellText | Should Match '(?m)^env -i "\$@" "\$bootstrap/pwsh" -NoLogo -NoProfile -NonInteractive -File '
        $script:SetupShellText | Should Match 'setup_root="\$home/\.local/share/ai-instructions-setup"'
        foreach ($pattern in @('XDG_','DOTNET_','LD_','DYLD_','POWERSHELL_')) { $script:SetupShellText | Should Not Match $pattern }
        $script:SetupShellText | Should Match 'mv -f "\$download" "\$archive"'
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($setupTestIsUnix) {
    # Scenario: A native POSIX sh parses the shell edge.
    # Purpose: sh -n proves the file is syntactically valid for the host shell.
    It 'UnitT34_parses_with_the_native_posix_sh' {
        $output = @(& sh -n $script:SetupShellPath 2>&1)
        $LASTEXITCODE | Should Be 0
        (@($output) -join "`n") | Should BeNullOrEmpty
    }
    }

    # Scenario: The reviewed policy exposes only glibc-compatible Linux RIDs and no musl RID.
    # Purpose: Keep the policy side of K2 closed; native behavior is verified with a controllable loader probe.
    It 'UnitT35_exposes_no_musl_policy_asset' {
        $policy=Get-SetupTestPolicy
        @($policy.powerShell.assets.rid | Where-Object {$_ -match 'musl'}).Count | Should Be 0
    }

    # Scenario: A caller tries to select an automatic setup mode.
    # Purpose: K8 exposes only Prepare and Offline; neither entry point nor the pure plan accepts Auto.
    It 'UnitT36_exposes_no_auto_mode' {
        $fixture = New-SetupTestHome 'no-auto-mode'
        { Get-AgentEnvironmentSetupPlan -Policy $fixture.Policy -UserHome $fixture.Home -CodexHome $fixture.CodexHome -Mode Auto -ArchivePath $fixture.Archive -Rid $script:SetupFixtureRid } | Should Throw
        $script:SetupShellText | Should Not Match '(?i)--auto'
        ([IO.File]::ReadAllText($script:SetupEntryPath)) | Should Not Match '(?i)\[switch\]\s*\$Auto'
    }

    # Scenario: Documentation explains how to consume the home-relative receipt paths.
    # Purpose: F7 prevents '~/...' from being misrepresented as an immediately executable absolute path.
    It 'UnitT37_documents_home_expansion_for_receipt_paths_in_both_languages' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        $englishSection = $readme.IndexOf('## Cloud/Linux setup',[StringComparison]::Ordinal)
        $englishSection | Should BeGreaterThan 0
        $readme | Should Match 'Receipt paths are `~/\.\.\.`, not absolute paths'
        $examples = [regex]::Matches($readme,'pwsh_path="\$HOME/\$\{receipt_pwsh#~/\}"')
        $examples.Count | Should Be 2
        $examples[0].Index | Should BeLessThan $englishSection
        $examples[1].Index | Should BeGreaterThan $englishSection
    }
}

# Register only on the native host; keep this file's Core CI skip count at zero.
if ($setupTestIsWindows) {
Describe 'setup-agent-environment Windows native fixture (SYP-354 P10a)' {
    BeforeAll {
        $script:WinRepositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:WinRepositoryRoot 'scripts/agent-environment-setup.psm1') -DisableNameChecking -Force
        Import-Module (Join-Path $script:WinRepositoryRoot 'scripts/platform-runtime.psd1') -DisableNameChecking
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:WinRoot = [IO.Path]::GetFullPath((Join-Path $TestDrive 'win-setup'))
        [void][IO.Directory]::CreateDirectory($script:WinRoot)
        $script:WinVersion = $PSVersionTable.PSVersion.ToString()
        $script:WinRid = Get-AgentEnvironmentSetupRid
        $script:WinPwsh = [Environment]::ProcessPath

        # Fixture archive: the running PowerShell's root runtime files are enough
        # to launch the canonical child; bundled modules are unrelated to these
        # setup-edge cases and would multiply every independent HOME's cost.
        $script:WinArchive = Join-Path $script:WinRoot "PowerShell-$($script:WinVersion)-$($script:WinRid).zip"
        $fixtureRuntime = Join-Path $script:WinRoot 'fixture-runtime'
        [void][IO.Directory]::CreateDirectory($fixtureRuntime)
        foreach ($file in @(Get-ChildItem -LiteralPath $PSHOME -File -Force)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $fixtureRuntime $file.Name) }
        [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRuntime 'Modules'))
        foreach ($moduleName in @('Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility')) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $PSHOME 'Modules') $moduleName) -Destination (Join-Path $fixtureRuntime 'Modules') -Recurse
        }
        Copy-Item -LiteralPath (Join-Path $PSHOME 'ref') -Destination $fixtureRuntime -Recurse
        [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRuntime,$script:WinArchive,[IO.Compression.CompressionLevel]::NoCompression,$false)
        $archiveHash = (Get-FileHash -LiteralPath $script:WinArchive -Algorithm SHA256).Hash.ToLowerInvariant()

        # Fixture repository: platform-runtime closure plus the six bound files, with a
        # fixture policy whose hash points at the fixture archive (production policy untouched).
        $script:WinRepo = Join-Path $script:WinRoot 'repo'
        $scriptsTarget = Join-Path $script:WinRepo 'scripts'
        [void][IO.Directory]::CreateDirectory($scriptsTarget)
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:WinRepositoryRoot 'scripts/platform-runtime.psd1')
        $files = @(@($manifest.FileList) + @(Get-AgentEnvironmentSetupBoundFiles | ForEach-Object { $_.Substring('scripts/'.Length) }))
        foreach ($relative in $files) {
            $target = Join-Path $scriptsTarget $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath (Join-Path (Join-Path $script:WinRepositoryRoot 'scripts') $relative) -Destination $target
        }
        $policy = [IO.File]::ReadAllText((Join-Path $script:WinRepositoryRoot 'scripts/setup-agent-environment.policy.json')) | ConvertFrom-Json
        $policy.powerShell.version = $script:WinVersion
        foreach ($asset in @($policy.powerShell.assets)) {
            $asset.name = if ($asset.rid.StartsWith('win-')) { "PowerShell-$($script:WinVersion)-$($asset.rid).zip" } else { "powershell-$($script:WinVersion)-$($asset.rid).tar.gz" }
            if ($asset.rid -ceq $script:WinRid) { $asset.sha256 = $archiveHash }
        }
        [IO.File]::WriteAllText((Join-Path $scriptsTarget 'setup-agent-environment.policy.json'),($policy | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $scriptsTarget 'setup-agent-environment.policy.tsv'),(ConvertTo-AgentEnvironmentSetupPolicyTsv $policy),[Text.UTF8Encoding]::new($false))
        & git -C $script:WinRepo init -q 2>$null | Out-Null
        & git -C $script:WinRepo -c core.autocrlf=false add -A 2>$null | Out-Null
        & git -C $script:WinRepo -c user.name=setup-test -c user.email=setup-test@example.invalid -c core.autocrlf=false commit -q -m fixture 2>$null | Out-Null
        $script:WinCommit = [string](& git -C $script:WinRepo rev-parse HEAD)
        $script:WinEntry = Join-Path $scriptsTarget 'setup-agent-environment.ps1'
        $script:WinHomeCounter = 0
        function New-WinFixture {
            param([string]$Name)
            $script:WinHomeCounter++
            $userHome = Join-Path $script:WinRoot ('h{0:D3}' -f $script:WinHomeCounter)
            [void][IO.Directory]::CreateDirectory($userHome)
            return [pscustomobject]@{ Home=$userHome; Layout=(Get-AgentEnvironmentSetupLayout $userHome $script:WinRid $script:WinVersion) }
        }

        function Invoke-WinSetup {
            param([string[]]$Arguments,[Parameter(Mandatory = $true)][string]$UserHome,[hashtable]$Environment=@{},[string]$EntryPath=$script:WinEntry,[string]$Executable=$script:WinPwsh)
            $start = [Diagnostics.ProcessStartInfo]::new($Executable)
            $hostArguments = @('-NoLogo','-NoProfile','-NonInteractive')
            if ([IO.Path]::GetFileName($Executable) -ieq 'powershell.exe') { $hostArguments += @('-ExecutionPolicy','Bypass') }
            foreach ($argument in $hostArguments + @('-File',$EntryPath) + $Arguments) { $start.ArgumentList.Add($argument) }
            $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $start.Environment['HOME'] = $UserHome
            [void]$start.Environment.Remove('CODEX_HOME')
            foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
            $process = [Diagnostics.Process]::Start($start)
            try {
                $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(900000)) { $process.Kill($true); throw 'Setup fixture run timed out.' }
                $process.WaitForExit()
                $lines = @($stdoutTask.Result.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Length -gt 0 })
                return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; Json = $(if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }) }
            } finally { $process.Dispose() }
        }

        function Start-WinSetup {
            param([string[]]$Arguments,[Parameter(Mandatory=$true)][string]$UserHome,[hashtable]$Environment=@{},[string]$EntryPath=$script:WinEntry)
            $start=[Diagnostics.ProcessStartInfo]::new($script:WinPwsh)
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$EntryPath)+$Arguments){$start.ArgumentList.Add($argument)}
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['HOME']=$UserHome;[void]$start.Environment.Remove('CODEX_HOME')
            foreach($key in $Environment.Keys){$start.Environment[$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::Start($start)
            return [pscustomobject]@{Process=$process;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync()}
        }

        function Complete-WinSetup {
            param($Running)
            try{
                if(-not $Running.Process.WaitForExit(900000)){$Running.Process.Kill($true);throw 'Setup fixture run timed out.'}
                $Running.Process.WaitForExit()
                $stdout=$Running.Stdout.Result;$stderr=$Running.Stderr.Result
                $lines=@($stdout.Split("`n")|ForEach-Object{$_.TrimEnd("`r")}|Where-Object{$_.Length -gt 0})
                return [pscustomobject]@{ExitCode=$Running.Process.ExitCode;Lines=$lines;Stdout=$stdout;Stderr=$stderr;Json=$(if($lines.Count -eq 1){$lines[0]|ConvertFrom-Json}else{$null})}
            }finally{$Running.Process.Dispose()}
        }

        function Wait-WinBarrierReady {
            param([string]$Directory)
            [void][IO.Directory]::CreateDirectory($Directory)
            $ready=Join-Path $Directory 'ready'
            if([IO.File]::Exists($ready)){return}
            $watcher=[IO.FileSystemWatcher]::new($Directory,'ready');$watcher.EnableRaisingEvents=$true
            try{
                if([IO.File]::Exists($ready)){return}
                $change=$watcher.WaitForChanged([IO.WatcherChangeTypes]::Created,120000)
                if($change.TimedOut -or -not [IO.File]::Exists($ready)){throw 'Setup barrier did not become ready.'}
            }finally{$watcher.Dispose()}
        }

        function Get-WinRuntimeSnapshot {
            param($Fixture)
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Fixture.Layout.SetupRoot -Force -Recurse | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($Fixture.Layout.SetupRoot.Length)
                if ($relative -like '\receipts\setup-receipt.json' -or $relative -like '\setup.lock') { continue }
                if ($item.PSIsContainer) { "D $relative" } else { "F $relative $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)" }
            }
            return (@($lines) -join "`n")
        }

        function Get-WinTreeSnapshot {
            param([string]$Root)
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($Root.Length)
                if ($item.PSIsContainer) { "D $relative" } else { "F $relative $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)" }
            }
            return (@($lines) -join "`n")
        }

        function Assert-WinLockReleased {
            param($Fixture)
            $lease = Open-PlatformDirectory -Root $Fixture.Layout.SetupRoot -RootOnly
            try { $lock = Enter-PlatformLock -ParentLease $lease -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero); $lock.Dispose() }
            finally { $lease.Dispose() }
        }

        function Assert-WinSuccessReceipt {
            param($Run,$Fixture,[string]$Result,[string]$Action)
            $Run.ExitCode | Should Be 0
            $Run.Lines.Count | Should Be 1
            $Run.Json.result | Should Be $Result
            $Run.Json.exitCode | Should Be 0
            $Run.Json.setupCommit | Should BeExactly $script:WinCommit
            $Run.Json.runtimeCommit | Should BeNullOrEmpty
            $Run.Json.powerShell.runtimeAction | Should Be $Action
            $Run.Json.powerShell.version | Should Be $script:WinVersion
            $Run.Json.powerShell.processPathVerified | Should Be $true
            $Run.Json.powerShell.executablePath | Should BeExactly "~/.local/share/ai-instructions-setup/pwsh/$($script:WinVersion)-$($script:WinRid)/pwsh.exe"
            (@($Run.Json.PSObject.Properties.Name) -join ',') | Should BeExactly (@(Get-AgentEnvironmentSetupReceiptFieldNames) -join ',')
            foreach ($name in @(Get-AgentEnvironmentSetupRequiredCapabilities)) { @($Run.Json.capabilities | Where-Object { $_.name -ceq $name -and $_.status -ceq 'available' }).Count | Should Be 1 }
            foreach ($forbidden in @($Fixture.Home,$Fixture.Home.Replace('\','/'),[Environment]::UserName)) { $Run.Stdout.Contains($forbidden) | Should Be $false }
            $stored = [IO.File]::ReadAllText((Join-Path $Fixture.Layout.ReceiptDirectory 'setup-receipt.json'))
            $stored.TrimEnd("`n") | Should BeExactly $Run.Lines[0]
            Test-Path -LiteralPath (Join-Path $Fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $false
            Assert-WinLockReleased $Fixture
        }

        function Assert-WinReceiptFieldSet {
            param($Run)
            $Run.Lines.Count | Should Be 1
            (@($Run.Json.PSObject.Properties.Name) -join ',') | Should BeExactly (@(Get-AgentEnvironmentSetupReceiptFieldNames) -join ',')
        }

        $script:WinPublicationCrashScript = Join-Path $script:WinRoot 'invoke-publication-crash.ps1'
        [IO.File]::WriteAllText($script:WinPublicationCrashScript,@'
param([string]$RuntimeManifest,[string]$SetupModule,[string]$SetupRoot,[string]$Leaf,[string]$PayloadPath)
Import-Module -Name $RuntimeManifest -DisableNameChecking -Force
Import-Module -Name $SetupModule -DisableNameChecking -Force
Publish-AgentEnvironmentSetupFile -SetupRoot $SetupRoot -Directory receipts -Leaf $Leaf -Bytes ([IO.File]::ReadAllBytes($PayloadPath))
'@,[Text.UTF8Encoding]::new($false))

        function Invoke-WinPublicationCrash {
            param($Fixture,[string]$Leaf,[string]$Point)
            $targetPath=Join-Path $Fixture.Layout.ReceiptDirectory $Leaf
            $payloadPath=Join-Path $script:WinRoot ('publication-payload-'+[guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($payloadPath,[IO.File]::ReadAllBytes($targetPath))
            $start=[Diagnostics.ProcessStartInfo]::new($script:WinPwsh)
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$script:WinPublicationCrashScript,
                (Join-Path $script:WinRepo 'scripts/platform-runtime.psd1'),(Join-Path $script:WinRepo 'scripts/agent-environment-setup.psm1'),
                $Fixture.Layout.SetupRoot,$Leaf,$payloadPath)){$start.ArgumentList.Add($argument)}
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT']=$Point
            $start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF']=$Leaf
            $process=[Diagnostics.Process]::Start($start)
            try{
                $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(900000)){$process.Kill($true);throw 'Publication crash fixture timed out.'}
                $process.WaitForExit()
                return [pscustomobject]@{ExitCode=$process.ExitCode;Stdout=$stdout.Result;Stderr=$stderr.Result}
            }finally{$process.Dispose();Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue}
        }

        function Get-WinPublicationTransactionState {
            param($Fixture)
            $store=Join-Path $Fixture.Layout.SetupRoot '.ai-instructions-txn'
            $transactions=@(Get-ChildItem -LiteralPath $store -Directory -Force)
            $transactions.Count | Should Be 1
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transactions[0].FullName 'journal.json') | ConvertFrom-Json
            $stage=Get-Item -LiteralPath (Join-Path $transactions[0].FullName 'stage')
            return [pscustomobject]@{Journal=$journal;Stage=$stage}
        }
    }

    AfterAll {
        Remove-Module agent-environment-setup -Force -ErrorAction SilentlyContinue
    }

    # Scenario: First --prepare with a local fixture zip and fixture policy, no network.
    # Purpose: Resolve the canonical runtime once, re-exec it, and publish a home-relative receipt without holding the lock.
    It 'InterT1_prepares_the_canonical_runtime_and_publishes_a_home_relative_receipt' {
        $fixture = New-WinFixture 'first-prepare'
        $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        if ($run.ExitCode -ne 0) { Write-Host $run.Stdout; Write-Host $run.Stderr }
        Assert-WinSuccessReceipt $run $fixture 'prepared-runtime-only' 'resolved'
        Test-Path -LiteralPath $fixture.Layout.RuntimeExecutable -PathType Leaf | Should Be $true
        $runtimeReceipt = [IO.File]::ReadAllText((Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf))
        $runtimeReceipt.Contains($fixture.Home) | Should Be $false
        ($runtimeReceipt | ConvertFrom-Json).executablePath | Should BeExactly $run.Json.powerShell.executablePath
    }

    # Scenario: --prepare runs again while secret markers sit in the caller environment.
    # Purpose: Re-verify without Resolve, keep runtime bytes unchanged and never leak the markers.
    It 'InterT2_reruns_prepare_as_reverification_with_unchanged_runtime_bytes_and_no_secret_leak' {
        $fixture = New-WinFixture 'prepare-rerun'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $before = Get-WinRuntimeSnapshot $fixture
        $marker = 'p10a-secret-' + [guid]::NewGuid().ToString('N')
        # DOTNET_STARTUP_HOOKS is exercised after host startup by UnitT22. An
        # invalid hook injected into ProcessStartInfo is consumed by .NET before
        # this script can run, so it cannot test the setup re-exec allowlist.
        $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home -Environment @{ SYP_P10A_SECRET_TOKEN=$marker; HTTPS_PROXY="http://user:$marker@127.0.0.1:9"; POWERSHELL_TELEMETRY_OPTOUT=$marker }
        Assert-WinSuccessReceipt $run $fixture 'prepared-runtime-only' 'reverified'
        (Get-WinRuntimeSnapshot $fixture) | Should BeExactly $before
        $run.Stdout.Contains($marker) | Should Be $false
        foreach ($file in @(Get-ChildItem -LiteralPath $fixture.Layout.ReceiptDirectory -File)) { [IO.File]::ReadAllText($file.FullName).Contains($marker) | Should Be $false }
    }

    # Scenario: --offline after a prepared runtime exists.
    # Purpose: K16 only re-verifies and reports verified-runtime-only with runtime bytes unchanged.
    It 'InterT3_offline_rerun_reports_verified_runtime_only_without_mutation' {
        $fixture = New-WinFixture 'offline-rerun'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $before = Get-WinRuntimeSnapshot $fixture
        $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $run $fixture 'verified-runtime-only' 'reverified'
        $run.Json.mode | Should Be 'offline'
        (Get-WinRuntimeSnapshot $fixture) | Should BeExactly $before
    }

    # Scenario: --offline in a fresh home that was never prepared.
    # Purpose: Refuse as runtime-missing without creating a runtime or receipts.
    It 'InterT4_offline_without_a_prepared_runtime_refuses_runtime_missing' {
        $fixture = New-WinFixture 'offline-fresh'
        $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        $run.ExitCode | Should Be 21
        $run.Json.result | Should Be 'refused'
        $run.Json.code | Should Be 'runtime-missing'
        Test-Path -LiteralPath $fixture.Layout.RuntimeDirectory | Should Be $false
        Test-Path -LiteralPath $fixture.Layout.ReceiptDirectory | Should Be $false
        Assert-WinLockReleased $fixture
    }

    # Scenario: An interrupted install journal is left in CODEX_HOME or the USER home.
    # Purpose: K7 refuses before any mutation; every byte under the home stays unchanged.
    It 'InterT5_refuses_interrupted_install_residue_with_bytes_unchanged' {
        foreach ($scope in @('codex','user')) {
            $fixture = New-WinFixture "residue-$scope"
            $store = if ($scope -ceq 'codex') { Join-Path $fixture.Home ('.codex/.ai-instructions-txn/' + ('b'*32)) } else { Join-Path $fixture.Home '.ai-instructions-txn' }
            [void][IO.Directory]::CreateDirectory($store)
            [IO.File]::WriteAllText((Join-Path $store 'journal.json'),'{"kind":"residue"}')
            $before = Get-WinTreeSnapshot $fixture.Home
            $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 27
            $run.Json.code | Should Be 'interrupted-install'
            $run.Json.recoverCommand | Should Match $(if ($scope -ceq 'codex') { 'install-ai-instructions-bootstrap\.ps1' } else { 'update-agent-environment\.ps1 -Recover$' })
            (Get-WinTreeSnapshot $fixture.Home) | Should BeExactly $before
            Test-Path -LiteralPath (Join-Path $fixture.Home '.local') | Should Be $false
        }
    }

    # Scenario: Another process holds the setup lock.
    # Purpose: M8 serializes setup runs and reports a busy lock as the typed concurrent refusal.
    It 'InterT6_refuses_a_busy_setup_lock_as_concurrent' {
        $fixture = New-WinFixture 'busy-lock'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $lease = Open-PlatformDirectory -Root $fixture.Layout.SetupRoot -RootOnly
        $lock = Enter-PlatformLock -ParentLease $lease -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        try {
            $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 26
            $run.Json.code | Should Be 'concurrent'
        } finally { $lock.Dispose(); $lease.Dispose() }
        Assert-WinLockReleased $fixture
    }

    # Scenario: CODEX_HOME points elsewhere, the commit differs, or a bound file is modified.
    # Purpose: H5 and K4 refuse with typed exit codes before any setup mutation.
    It 'InterT7_refuses_codex_home_conflicts_and_unpinned_revisions' {
        $fixture = New-WinFixture 'early-refusals'
        $before = Get-WinTreeSnapshot $fixture.Home
        $conflict = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home -Environment @{ CODEX_HOME = (Join-Path $script:WinRoot 'other-codex') }
        $conflict.ExitCode | Should Be 28
        $conflict.Json.code | Should Be 'codex-home-conflict'
        $wrong = Invoke-WinSetup @('-Offline','-ExpectedCommit',('0'*40),'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        $wrong.ExitCode | Should Be 15
        $usage = Invoke-WinSetup @('-Offline','-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        $usage.ExitCode | Should Be 10
        Assert-WinReceiptFieldSet $usage
        $schema = Join-Path $script:WinRepo 'scripts/setup-agent-environment.policy.schema.json'
        $original = [IO.File]::ReadAllBytes($schema)
        try {
            [IO.File]::AppendAllText($schema,' ')
            $modified = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $modified.ExitCode | Should Be 15
            $modified.Json.code | Should Be 'commit-mismatch'
        } finally { [IO.File]::WriteAllBytes($schema,$original) }
        (Get-WinTreeSnapshot $fixture.Home) | Should BeExactly $before
    }

    # Scenario: A canonical runtime closure file is altered after preparation.
    # Purpose: Re-verification fails closed as runtime-verification-failed and setup does not reinstall.
    It 'InterT8_fails_closed_on_a_tampered_canonical_runtime_without_reinstalling' {
        $fixture = New-WinFixture 'runtime-tamper'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $victim = @(Get-ChildItem -LiteralPath $fixture.Layout.RuntimeDirectory -File -Filter '*.json' | Sort-Object Length | Select-Object -First 1)[0]
        $original = [IO.File]::ReadAllBytes($victim.FullName)
        try {
            [IO.File]::AppendAllText($victim.FullName,' ')
            $before = Get-WinRuntimeSnapshot $fixture
            $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 23
            $run.Json.code | Should Be 'runtime-verification-failed'
            $run.Json.recoverCommand | Should Match 'rerun setup with --prepare'
            (Get-WinRuntimeSnapshot $fixture) | Should BeExactly $before
        } finally { [IO.File]::WriteAllBytes($victim.FullName,$original) }
        Assert-WinLockReleased $fixture
    }

    # Scenario: The committed platform façade is modified to create a side-effect marker when imported.
    # Purpose: F1 rejects the untrusted closure before any repository module executes.
    It 'InterT9_rejects_platform_runtime_tampering_before_import_side_effects' {
        $fixture = New-WinFixture 'pre-import-tamper'
        $platformPath = Join-Path $script:WinRepo 'scripts/platform-runtime.psm1'
        $marker = Join-Path $script:WinRoot ('pre-import-marker-' + [guid]::NewGuid().ToString('N'))
        $original = [IO.File]::ReadAllBytes($platformPath)
        try {
            $escapedMarker = $marker.Replace("'","''")
            $tampered = "[IO.File]::WriteAllText('$escapedMarker','executed')`n" + [Text.UTF8Encoding]::new($false,$true).GetString($original)
            [IO.File]::WriteAllText($platformPath,$tampered,[Text.UTF8Encoding]::new($false))
            $before = Get-WinTreeSnapshot $fixture.Home
            $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 15
            $run.Json.code | Should Be 'commit-mismatch'
            Assert-WinReceiptFieldSet $run
            Test-Path -LiteralPath $marker | Should Be $false
            (Get-WinTreeSnapshot $fixture.Home) | Should BeExactly $before
        } finally { [IO.File]::WriteAllBytes($platformPath,$original) }
    }

    # Scenario: A stored runtime receipt is rewritten to verify a copied runtime tree.
    # Purpose: F3 refuses the copy before K15 and re-exec can diverge from the canonical layout.
    It 'InterT10_refuses_a_runtime_receipt_redirected_to_a_copy' {
        $fixture = New-WinFixture 'receipt-copy'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $copyDirectory = Join-Path $fixture.Layout.SetupRoot 'runtime-copy'
        Copy-Item -LiteralPath $fixture.Layout.RuntimeDirectory -Destination $copyDirectory -Recurse
        $receiptPath = Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf
        $stored = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
        $stored.runtimeClosure.rootPath = ConvertTo-AgentEnvironmentSetupHomePath $copyDirectory $fixture.Home
        $stored.executablePath = ConvertTo-AgentEnvironmentSetupHomePath (Join-Path $copyDirectory 'pwsh.exe') $fixture.Home
        [IO.File]::WriteAllText($receiptPath,(ConvertTo-Json $stored -Depth 8 -Compress) + "`n",[Text.UTF8Encoding]::new($false))
        $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        $run.ExitCode | Should Be 23
        $run.Json.code | Should Be 'runtime-verification-failed'
        Assert-WinReceiptFieldSet $run
        Assert-WinLockReleased $fixture
    }

    # Scenario: The entry refuses before the shared module loads, at baseline, and after a committed module-load failure.
    # Purpose: F6 keeps the same versioned fixed receipt fields on every externally visible refusal path.
    It 'InterT11_emits_the_fixed_receipt_fields_for_baseline_and_module_load_failures' {
        $baselineFixture = New-WinFixture 'baseline-envelope'
        $windowsPowerShell = @(Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        $windowsPowerShell.Count | Should Be 1
        $baseline = Invoke-WinSetup @('-Offline') -UserHome $baselineFixture.Home -Executable $windowsPowerShell[0].Source
        $baseline.ExitCode | Should Be 24
        $baseline.Json.code | Should Be 'runtime-baseline-unavailable'
        Assert-WinReceiptFieldSet $baseline

        $badRoot = Join-Path $script:WinRoot ('bad-module-repo-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($badRoot)
        Copy-Item -LiteralPath (Join-Path $script:WinRepo 'scripts') -Destination (Join-Path $badRoot 'scripts') -Recurse
        [IO.File]::AppendAllText((Join-Path $badRoot 'scripts/agent-environment-setup.psm1'),"`nthis is not valid {{{`n",[Text.UTF8Encoding]::new($false))
        & git -C $badRoot init -q 2>$null | Out-Null
        & git -C $badRoot -c core.autocrlf=false add -A 2>$null | Out-Null
        & git -C $badRoot -c user.name=setup-test -c user.email=setup-test@example.invalid -c core.autocrlf=false commit -q -m bad-module 2>$null | Out-Null
        $badCommit = [string](& git -C $badRoot rev-parse HEAD)
        $badFixture = New-WinFixture 'module-envelope'
        $failure = Invoke-WinSetup @('-Offline','-ExpectedCommit',$badCommit,'-ArchivePath',$script:WinArchive) -UserHome $badFixture.Home -EntryPath (Join-Path $badRoot 'scripts/setup-agent-environment.ps1')
        $failure.ExitCode | Should Be 1
        $failure.Json.code | Should Be 'internal-error'
        Assert-WinReceiptFieldSet $failure
    }

    # Scenario: Each setup receipt publication crash point terminates a real child process, then the real entry is rerun.
    # Purpose: G1/G2/G3/G10 prove lock-held WAL recovery for pre-journal, journaled, post-rename and post-journal states.
    It 'InterT12_recovers_every_setup_publication_crash_point_through_the_real_entry' {
        $fixture=New-WinFixture 'publication-crashes'
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        $initial=Invoke-WinSetup $arguments -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $runtimeBefore=Get-WinRuntimeSnapshot $fixture
        foreach($point in @('after-transaction-directory','after-journal-stage','after-journal','after-parent-directory','during-stage-write','after-stage','after-rename','after-displaced-cleanup','after-journal-cleanup','after-transaction-cleanup')){
            $targetPath=Join-Path $fixture.Layout.ReceiptDirectory 'setup-receipt.json'
            $targetBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))
            $crashed=Invoke-WinSetup $arguments -UserHome $fixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT=$point;AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF='setup-receipt.json'}
            $crashed.ExitCode | Should Not Be 0
            Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath)) | Should BeExactly $targetBefore
            Assert-WinLockReleased $fixture
            if($point -ceq 'during-stage-write'){
                $transaction=Get-WinPublicationTransactionState $fixture
                $transaction.Stage.Length | Should BeGreaterThan 0
                $transaction.Stage.Length | Should BeLessThan ([int64]$transaction.Journal.desiredState.length)
            }
            $recovered=Invoke-WinSetup $arguments -UserHome $fixture.Home
            Assert-WinSuccessReceipt $recovered $fixture 'prepared-runtime-only' 'reverified'
            (Get-WinRuntimeSnapshot $fixture) | Should BeExactly $runtimeBefore
        }
    }

    # Scenario: Runtime receipt publication is interrupted after a complete stage and halfway through a replacement stage.
    # Purpose: Cover both stage-write outcomes for the other journaled payload and recover them through the real setup entry.
    It 'InterT12a_recovers_complete_and_torn_runtime_receipt_stages_through_the_real_entry' {
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)

        $completeFixture=New-WinFixture 'runtime-receipt-complete-stage'
        $completeCrash=Invoke-WinSetup $arguments -UserHome $completeFixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='after-stage';AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$completeFixture.Layout.RuntimeReceiptLeaf}
        $completeCrash.ExitCode | Should Not Be 0
        Test-Path -LiteralPath (Join-Path $completeFixture.Layout.ReceiptDirectory $completeFixture.Layout.RuntimeReceiptLeaf) | Should Be $false
        $completeTransaction=Get-WinPublicationTransactionState $completeFixture
        $completeTransaction.Stage.Length | Should Be ([int64]$completeTransaction.Journal.desiredState.length)
        Assert-WinLockReleased $completeFixture
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $completeFixture.Home) $completeFixture 'prepared-runtime-only' 'reverified'

        $tornFixture=New-WinFixture 'runtime-receipt-torn-stage'
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $tornFixture.Home) $tornFixture 'prepared-runtime-only' 'resolved'
        $runtimePath=Join-Path $tornFixture.Layout.ReceiptDirectory $tornFixture.Layout.RuntimeReceiptLeaf
        $targetBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimePath))
        $identityBefore=(Read-AgentEnvironmentSetupFile $tornFixture.Layout.SetupRoot 'receipts' $tornFixture.Layout.RuntimeReceiptLeaf).State.identity
        $tornCrash=Invoke-WinPublicationCrash $tornFixture $tornFixture.Layout.RuntimeReceiptLeaf 'during-stage-write'
        $tornCrash.ExitCode | Should Not Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimePath)) | Should BeExactly $targetBefore
        $tornTransaction=Get-WinPublicationTransactionState $tornFixture
        $tornTransaction.Stage.Length | Should BeGreaterThan 0
        $tornTransaction.Stage.Length | Should BeLessThan ([int64]$tornTransaction.Journal.desiredState.length)
        Assert-WinLockReleased $tornFixture
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $tornFixture.Home) $tornFixture 'prepared-runtime-only' 'reverified'
        $identityAfter=(Read-AgentEnvironmentSetupFile $tornFixture.Layout.SetupRoot 'receipts' $tornFixture.Layout.RuntimeReceiptLeaf).State.identity
        [string]$identityAfter.kind | Should BeExactly ([string]$identityBefore.kind)
        [string]$identityAfter.device | Should BeExactly ([string]$identityBefore.device)
        [string]$identityAfter.fileId | Should BeExactly ([string]$identityBefore.fileId)
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimePath)) | Should BeExactly $targetBefore
    }

    # Scenario: A torn setup-receipt stage exists but the target no longer matches either journal identity.
    # Purpose: Preserve fail-closed recovery when the exact expected-target precondition is not satisfied.
    It 'InterT12b_refuses_a_torn_stage_when_the_target_no_longer_matches_the_journal' {
        $fixture=New-WinFixture 'torn-stage-target-mismatch'
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $fixture.Home) $fixture 'prepared-runtime-only' 'resolved'
        $targetPath=Join-Path $fixture.Layout.ReceiptDirectory 'setup-receipt.json'
        $crashed=Invoke-WinSetup $arguments -UserHome $fixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='during-stage-write';AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF='setup-receipt.json'}
        $crashed.ExitCode | Should Not Be 0
        [IO.File]::WriteAllText($targetPath,"{}`n",[Text.UTF8Encoding]::new($false))
        $refused=Invoke-WinSetup $arguments -UserHome $fixture.Home
        $refused.ExitCode | Should Be 27
        $refused.Json.code | Should Be 'interrupted-install'
        Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $true
        [IO.File]::ReadAllText($targetPath) | Should BeExactly "{}`n"
        Assert-WinLockReleased $fixture
    }

    # Scenario: The target was displaced and the child died before the staged receipt rename, using a committed adapter shim.
    # Purpose: G1 gives the two-rename gap a unique recovery decision through the real entry point.
    It 'InterT13_recovers_the_between_renames_crash_state_through_the_real_entry' {
        $fixture=New-WinFixture 'publication-between-renames'
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $fixture.Home) $fixture 'prepared-runtime-only' 'resolved'
        $shimRepo=Join-Path $script:WinRoot ('between-renames-repo-'+[guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:WinRepo -Destination $shimRepo -Recurse
        $adapter=Join-Path $shimRepo 'scripts/platform/Windows.psm1'
        $text=[IO.File]::ReadAllText($adapter)
        $match=[regex]::Match($text,'(?m)^(\s*\$displaced=\$true)\r?$')
        $match.Success | Should Be $true
        $indent=[regex]::Match($match.Groups[1].Value,'^\s*').Value
        $injection=$match.Groups[1].Value+"`n"+$indent+"if([Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_FAILPOINT') -ceq 'after-displace' -and `$Leaf -ceq 'setup-receipt.json'){[Environment]::FailFast('between setup receipt renames')}"
        $text=$text.Remove($match.Index,$match.Length).Insert($match.Index,$injection)
        [IO.File]::WriteAllText($adapter,$text,[Text.UTF8Encoding]::new($false))
        $manifestPath=Join-Path $shimRepo 'scripts/platform-runtime.psd1'
        $manifestText=[IO.File]::ReadAllText($manifestPath)
        $hash=Get-AgentEnvironmentSetupSha256Text ([IO.File]::ReadAllText($adapter))
        $manifestText=[regex]::Replace($manifestText,"(?m)(Path = 'platform/Windows\.psm1'; Sha256 = ')[a-f0-9]{64}(')",('${1}'+$hash+'$2'))
        [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
        & git -C $shimRepo init -q 2>$null | Out-Null
        & git -C $shimRepo add -A 2>$null | Out-Null
        & git -C $shimRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m between-renames 2>$null | Out-Null
        $shimCommit=[string](& git -C $shimRepo rev-parse HEAD)
        $shimCommit | Should MatchExactly '^[0-9a-f]{40}$'
        $shimEntry=Join-Path $shimRepo 'scripts/setup-agent-environment.ps1'
        $shimArguments=@('-Prepare','-ExpectedCommit',$shimCommit,'-ArchivePath',$script:WinArchive)
        $crashed=Invoke-WinSetup $shimArguments -UserHome $fixture.Home -EntryPath $shimEntry -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='after-displace'}
        $crashed.ExitCode | Should Not Be 0
        Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $true
        $recovered=Invoke-WinSetup $shimArguments -UserHome $fixture.Home -EntryPath $shimEntry
        $recovered.ExitCode | Should Be 0
        $recovered.Json.powerShell.runtimeAction | Should Be 'reverified'
        Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $false
        Assert-WinLockReleased $fixture
    }

    # Scenario: Process A holds setup.lock after creating the runtime directory; process B starts from the real entry.
    # Purpose: G4 uses a synchronization barrier and requires the concurrent run to return 26 rather than runtime-incomplete.
    It 'InterT14_reports_concurrent_while_the_runtime_is_transient_under_the_lock' {
        $fixture=New-WinFixture 'concurrency-barrier'
        $barrier=Join-Path $script:WinRoot ('barrier-'+[guid]::NewGuid().ToString('N'))
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        $first=Start-WinSetup $arguments -UserHome $fixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_BARRIER='after-runtime-directory';AI_INSTRUCTIONS_SETUP_BARRIER_DIRECTORY=$barrier}
        try{
            Wait-WinBarrierReady $barrier
            $second=Invoke-WinSetup $arguments -UserHome $fixture.Home
            $second.ExitCode | Should Be 26
            $second.Json.code | Should Be 'concurrent'
            [IO.File]::WriteAllText((Join-Path $barrier 'release'),'release')
            $completed=Complete-WinSetup $first;$first=$null
            Assert-WinSuccessReceipt $completed $fixture 'prepared-runtime-only' 'resolved'
        }finally{
            if($null -ne $first){[IO.File]::WriteAllText((Join-Path $barrier 'release'),'release');[void](Complete-WinSetup $first)}
        }
    }
}
}

# Register only on the native host; keep this file's Core CI skip count at zero.
if ($setupTestIsUnix) {
Describe 'setup-agent-environment POSIX shell native fixture (SYP-354 P10a)' {
    BeforeAll {
        $script:UnixRepositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/agent-environment-setup.psm1') -DisableNameChecking -Force
        Add-Type -AssemblyName System.Formats.Tar
        # Resolve only the trusted test anchor (macOS /var -> /private/var).
        $physical = '/'
        foreach ($part in ([IO.Path]::GetFullPath($TestDrive)).Trim('/').Split('/')) {
            $item = [IO.DirectoryInfo]::new((Join-Path $physical $part))
            $target = $item.ResolveLinkTarget($true)
            $physical = if ($null -eq $target) { $item.FullName } else { $target.FullName }
        }
        $script:UnixRoot = Join-Path $physical 'unix-setup'
        [void][IO.Directory]::CreateDirectory($script:UnixRoot)
        $script:UnixVersion = $PSVersionTable.PSVersion.ToString()
        $script:UnixRid = Get-AgentEnvironmentSetupRid
        $script:UnixAssetName = "powershell-$($script:UnixVersion)-$($script:UnixRid).tar.gz"

        function New-UnixTarball {
            param([string]$Path,[ValidateSet('runtime','symlink','parent','absolute','hardlink','device')][string]$Kind)
            $file = [IO.File]::Create($Path)
            $gzip = [IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Compress,$false)
            $writer = [System.Formats.Tar.TarWriter]::new($gzip,$false)
            try {
                if ($Kind -ceq 'runtime') {
                    # Copy bytes of every PSHOME file (links dereferenced) as regular members.
                    $root = [IO.Path]::GetFullPath($PSHOME).TrimEnd('/')
                    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
                        $relative = $item.FullName.Substring($root.Length + 1)
                        if ($item.PSIsContainer -and $null -eq $item.LinkType) {
                            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::Directory,$relative + '/')
                            $entry.Mode = [IO.UnixFileMode]448
                            $writer.WriteEntry($entry)
                            continue
                        }
                        if ($item.PSIsContainer) { continue }
                        $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,$relative)
                        $entry.Mode = [IO.UnixFileMode]448
                        $entry.DataStream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($item.FullName))
                        $writer.WriteEntry($entry)
                    }
                } else {
                    $pwsh = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,'pwsh')
                    $pwsh.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("#!/bin/sh`nexit 0`n"))
                    $writer.WriteEntry($pwsh)
                    $name = switch ($Kind) { 'parent' { '../escape' } 'absolute' { '/escape' } default { 'extra' } }
                    $type = switch ($Kind) { 'symlink' { [System.Formats.Tar.TarEntryType]::SymbolicLink } 'hardlink' { [System.Formats.Tar.TarEntryType]::HardLink } 'device' { [System.Formats.Tar.TarEntryType]::CharacterDevice } default { [System.Formats.Tar.TarEntryType]::RegularFile } }
                    $entry = [System.Formats.Tar.PaxTarEntry]::new($type,$name)
                    if ($Kind -in @('symlink','hardlink')) { $entry.LinkName = 'pwsh' }
                    elseif ($Kind -ceq 'device') { $entry.DeviceMajor = 1; $entry.DeviceMinor = 3 }
                    else { $entry.DataStream = [IO.MemoryStream]::new([byte[]]@(1)) }
                    $writer.WriteEntry($entry)
                }
            } finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
        }

        $script:UnixArchives = @{}
        foreach ($kind in @('runtime','symlink','parent','absolute','hardlink','device')) {
            $directory = Join-Path $script:UnixRoot "archive-$kind"; [void][IO.Directory]::CreateDirectory($directory)
            $path = Join-Path $directory $script:UnixAssetName
            New-UnixTarball $path $kind
            $script:UnixArchives[$kind] = [pscustomobject]@{ Path = $path; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        }

        # Fixture repository with one commit per fixture policy (hash bound to each archive).
        $script:UnixRepo = Join-Path $script:UnixRoot 'repo'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'scripts'))
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:UnixRepositoryRoot 'scripts/platform-runtime.psd1')
        $files = @(@($manifest.FileList) + @(Get-AgentEnvironmentSetupBoundFiles | ForEach-Object { $_.Substring('scripts/'.Length) }))
        foreach ($relative in $files) {
            $target = Join-Path (Join-Path $script:UnixRepo 'scripts') $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath (Join-Path (Join-Path $script:UnixRepositoryRoot 'scripts') $relative) -Destination $target
        }
        & git -C $script:UnixRepo init -q 2>$null | Out-Null
        $script:UnixCommits = @{}
        foreach ($kind in @('runtime','symlink','parent','absolute','hardlink','device')) {
            $policy = [IO.File]::ReadAllText((Join-Path $script:UnixRepositoryRoot 'scripts/setup-agent-environment.policy.json')) | ConvertFrom-Json
            $policy.powerShell.version = $script:UnixVersion
            foreach ($asset in @($policy.powerShell.assets)) {
                $asset.name = if ($asset.rid.StartsWith('win-')) { "PowerShell-$($script:UnixVersion)-$($asset.rid).zip" } else { "powershell-$($script:UnixVersion)-$($asset.rid).tar.gz" }
                if ($asset.rid -ceq $script:UnixRid) { $asset.sha256 = $script:UnixArchives[$kind].Sha256 }
            }
            [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.json'),($policy | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.tsv'),(ConvertTo-AgentEnvironmentSetupPolicyTsv $policy),[Text.UTF8Encoding]::new($false))
            & git -C $script:UnixRepo add -A 2>$null | Out-Null
            & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q --allow-empty -m $kind 2>$null | Out-Null
            $script:UnixCommits[$kind] = [string](& git -C $script:UnixRepo rev-parse HEAD)
        }
        & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
        $script:UnixShell = Join-Path $script:UnixRepo 'scripts/setup-agent-environment.sh'
        $script:UnixSentinel = Join-Path $script:UnixRoot 'outside-sentinel'
        [IO.File]::WriteAllText($script:UnixSentinel,'sentinel')

        function New-UnixHome {
            param([string]$Name,[string]$Kind='runtime',[switch]$WithoutCache)
            $userHome = Join-Path $script:UnixRoot "home-$Name"
            [void][IO.Directory]::CreateDirectory($userHome)
            [IO.File]::SetUnixFileMode($userHome,[IO.UnixFileMode]448)
            if (-not $WithoutCache) {
                $cache = Join-Path $userHome '.local/share/ai-instructions-setup/cache'
                [void][IO.Directory]::CreateDirectory($cache)
                foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup','.local/share/ai-instructions-setup/cache')) {
                    [IO.File]::SetUnixFileMode((Join-Path $userHome $relative),[IO.UnixFileMode]448)
                }
                Copy-Item -LiteralPath $script:UnixArchives[$Kind].Path -Destination (Join-Path $cache $script:UnixAssetName)
                [IO.File]::SetUnixFileMode((Join-Path $cache $script:UnixAssetName),[IO.UnixFileMode]384)
            }
            return $userHome
        }

        function Invoke-UnixSetup {
            param([string]$UserHome,[string[]]$Arguments,[string]$Kind='runtime',[hashtable]$Environment=@{},[string]$ExpectedCommit=$script:UnixCommits[$Kind],[switch]$NoCheckout,[switch]$UnsetHome)
            if (-not $NoCheckout) { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits[$Kind] 2>$null | Out-Null }
            $start = [Diagnostics.ProcessStartInfo]::new('sh')
            foreach ($argument in @($script:UnixShell,'--expected-commit',$ExpectedCommit) + $Arguments) { $start.ArgumentList.Add($argument) }
            $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            if($UnsetHome){[void]$start.Environment.Remove('HOME')}else{$start.Environment['HOME'] = $UserHome}
            # Any accidental network use fails fast instead of reaching the internet.
            $start.Environment['HTTPS_PROXY'] = 'http://127.0.0.1:9'
            [void]$start.Environment.Remove('CODEX_HOME')
            foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
            $process = [Diagnostics.Process]::Start($start)
            try {
                $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(900000)) { $process.Kill($true); throw 'Shell setup fixture run timed out.' }
                $process.WaitForExit()
                $lines = @($stdoutTask.Result.Split("`n") | Where-Object { $_.Length -gt 0 })
                return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; Json = $(if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }) }
            } finally { $process.Dispose() }
        }

        function Start-UnixSetup {
            param([string]$UserHome,[string[]]$Arguments,[hashtable]$Environment=@{})
            & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
            $start=[Diagnostics.ProcessStartInfo]::new('sh')
            foreach($argument in @($script:UnixShell,'--expected-commit',$script:UnixCommits['runtime'])+$Arguments){$start.ArgumentList.Add($argument)}
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['HOME']=$UserHome;$start.Environment['HTTPS_PROXY']='http://127.0.0.1:9';[void]$start.Environment.Remove('CODEX_HOME')
            foreach($key in $Environment.Keys){$start.Environment[$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::Start($start)
            return [pscustomobject]@{Process=$process;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync()}
        }

        function Complete-UnixSetup {
            param($Running)
            try{
                if(-not $Running.Process.WaitForExit(900000)){$Running.Process.Kill($true);throw 'Shell setup fixture run timed out.'}
                $Running.Process.WaitForExit();$stdout=$Running.Stdout.Result;$stderr=$Running.Stderr.Result
                $lines=@($stdout.Split("`n")|Where-Object{$_.Length -gt 0})
                return [pscustomobject]@{ExitCode=$Running.Process.ExitCode;Lines=$lines;Stdout=$stdout;Stderr=$stderr;Json=$(if($lines.Count -eq 1){$lines[0]|ConvertFrom-Json}else{$null})}
            }finally{$Running.Process.Dispose()}
        }

        function Get-UnixMode {
            param([string]$Path)
            return ([Convert]::ToString([int][IO.File]::GetUnixFileMode($Path),8))
        }

        function New-UnixToolShim {
            param([string]$Name,[string[]]$Exclude=@(),[hashtable]$Replace=@{})
            $bin = Join-Path $script:UnixRoot "bin-$Name"
            [void][IO.Directory]::CreateDirectory($bin)
            foreach ($tool in @('uname','id','awk','sed','find','mkdir','mv','rm','chmod','env','dirname','cp','git','tar','gzip','sha256sum','shasum','curl','wget','cat','ls','sh')) {
                if ($tool -in $Exclude) { continue }
                if ($Replace.ContainsKey($tool)) {
                    $shim = Join-Path $bin $tool
                    [IO.File]::WriteAllText($shim,"#!/bin/sh`n$($Replace[$tool])`n")
                    [IO.File]::SetUnixFileMode($shim,[IO.UnixFileMode]448)
                    continue
                }
                $source = @(Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($source.Count -eq 1) { [void][IO.File]::CreateSymbolicLink((Join-Path $bin $tool),$source[0].Source) }
            }
            return $bin
        }

        function Get-UnixTreeSnapshot {
            param([string]$Root)
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($Root.Length)
                $mode = [Convert]::ToString([int][IO.File]::GetUnixFileMode($item.FullName),8)
                if ($item.PSIsContainer) { "D $relative $mode" } elseif ($null -ne $item.LinkType) { "L $relative $mode $($item.LinkTarget)" } else { "F $relative $mode $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)" }
            }
            return (@($lines) -join "`n")
        }
    }

    AfterAll {
        & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
        Remove-Module agent-environment-setup -Force -ErrorAction SilentlyContinue
    }

    # Scenario: --prepare with a pre-placed verified cache, then --offline; no network is used.
    # Purpose: S1-S4 hand off to pwsh, which prepares and re-verifies the canonical runtime with private modes.
    It 'InterT20_prepares_from_a_preplaced_cache_and_reverifies_offline_with_private_modes' {
        $userHome = New-UnixHome 'success'
        $prepare = Invoke-UnixSetup $userHome @('--prepare')
        if ($prepare.ExitCode -ne 0) { Write-Host $prepare.Stdout; Write-Host $prepare.Stderr }
        $prepare.ExitCode | Should Be 0
        $prepare.Json.result | Should Be 'prepared-runtime-only'
        $prepare.Json.powerShell.runtimeAction | Should Be 'resolved'
        $offline = Invoke-UnixSetup $userHome @('--offline')
        $offline.ExitCode | Should Be 0
        $offline.Json.result | Should Be 'verified-runtime-only'
        $offline.Json.powerShell.runtimeAction | Should Be 'reverified'
        $setupRoot = Join-Path $userHome '.local/share/ai-instructions-setup'
        Get-UnixMode $setupRoot | Should Be '700'
        Get-UnixMode (Join-Path $setupRoot "pwsh/$($script:UnixVersion)-$($script:UnixRid)") | Should Be '700'
        Get-UnixMode (Join-Path $setupRoot "pwsh/$($script:UnixVersion)-$($script:UnixRid)/pwsh") | Should Be '700'
        Get-UnixMode (Join-Path $setupRoot 'receipts/setup-receipt.json') | Should Be '600'
        Get-UnixMode (Join-Path $setupRoot "receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json") | Should Be '600'
        @(Get-ChildItem -LiteralPath (Join-Path $setupRoot 'tmp') -Force).Count | Should Be 0
        $offline.Stdout.Contains($userHome) | Should Be $false
    }

    # Scenario: HOME is reached through a symbolic link, or a setup-root ancestor is a dangling link.
    # Purpose: S1 refuses link ancestors as unsafe-path and leaves outside bytes untouched.
    It 'InterT21_refuses_symbolic_and_dangling_link_ancestors' {
        $real = New-UnixHome 'link-real'
        $alias = Join-Path $script:UnixRoot 'home-link-alias'
        [void][IO.Directory]::CreateSymbolicLink($alias,$real)
        $run = Invoke-UnixSetup $alias @('--offline')
        $run.ExitCode | Should Be 13; $run.Json.code | Should Be 'unsafe-path'
        $dangling = New-UnixHome 'dangling' -WithoutCache
        [void][IO.Directory]::CreateSymbolicLink((Join-Path $dangling '.local'),(Join-Path $script:UnixRoot 'missing-target'))
        $run = Invoke-UnixSetup $dangling @('--prepare')
        $run.ExitCode | Should Be 13
        [IO.File]::ReadAllText($script:UnixSentinel) | Should Be 'sentinel'
        Test-Path -LiteralPath (Join-Path $script:UnixRoot 'missing-target') | Should Be $false
    }

    # Scenario: The cached archive is corrupted, or missing in --offline mode.
    # Purpose: S3 refuses archive-hash-mismatch and cache-missing without downloading or extracting.
    It 'InterT22_refuses_a_corrupted_or_missing_cache' {
        $corrupt = New-UnixHome 'corrupt'
        $cached = Join-Path $corrupt ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
        [IO.File]::AppendAllText($cached,'x')
        foreach ($mode in @('--offline','--prepare')) {
            $run = Invoke-UnixSetup $corrupt @($mode)
            $run.ExitCode | Should Be 18; $run.Json.code | Should Be 'archive-hash-mismatch'
        }
        Test-Path -LiteralPath (Join-Path $corrupt '.local/share/ai-instructions-setup/pwsh') | Should Be $false
        $missing = New-UnixHome 'missing' -WithoutCache
        $run = Invoke-UnixSetup $missing @('--offline')
        $run.ExitCode | Should Be 20; $run.Json.code | Should Be 'cache-missing'
    }

    # Scenario: Hash-valid fixture archives contain a symlink, hard link, traversal or absolute member.
    # Purpose: M9 member checks refuse archive-unsafe before any canonical runtime exists.
    It 'InterT23_refuses_tar_links_traversal_and_absolute_members' {
        foreach ($kind in @('symlink','hardlink','parent','absolute','device')) {
            $userHome = New-UnixHome "tar-$kind" -Kind $kind
            $run = Invoke-UnixSetup $userHome @('--offline') -Kind $kind
            $run.ExitCode | Should Be 19
            $run.Json.code | Should Be 'archive-unsafe'
            Test-Path -LiteralPath (Join-Path $userHome '.local/share/ai-instructions-setup/pwsh') | Should Be $false
            Test-Path -LiteralPath (Join-Path $script:UnixRoot 'escape') | Should Be $false
        }
    }

    # Scenario: PATH lacks every SHA-256 tool, or uname reports an unsupported OS or architecture.
    # Purpose: Dependencies and both RID dimensions fail with typed exits; no system package is installed.
    It 'InterT24_refuses_missing_hash_tools_and_unsupported_platforms' {
        $userHome = New-UnixHome 'tools'
        $bin = New-UnixToolShim 'no-hash' -Exclude @('sha256sum','shasum')
        $run = Invoke-UnixSetup $userHome @('--offline') -Environment @{ PATH = $bin }
        $run.ExitCode | Should Be 14; $run.Json.code | Should Be 'missing-dependency'
        $bin = New-UnixToolShim 'freebsd' -Replace @{ uname = 'echo FreeBSD' }
        $run = Invoke-UnixSetup $userHome @('--offline') -Environment @{ PATH = $bin }
        $run.ExitCode | Should Be 11; $run.Json.code | Should Be 'unsupported-platform'
        $uname=@('case "$1" in','  -s) echo Linux ;;','  -m) echo mystery-architecture ;;','esac') -join "`n"
        $bin = New-UnixToolShim 'unknown-architecture' -Replace @{ uname = $uname }
        $run = Invoke-UnixSetup $userHome @('--offline') -Environment @{ PATH = $bin }
        $run.ExitCode | Should Be 11; $run.Json.code | Should Be 'unsupported-platform'
        Test-Path -LiteralPath (Join-Path $userHome '.local/share/ai-instructions-setup/pwsh') | Should Be $false
    }

    # Scenario: Shell argument validation refuses before any PowerShell module can load.
    # Purpose: F6 keeps the shell-edge refusal on the same fixed receipt field contract.
    It 'InterT26_emits_the_fixed_receipt_fields_for_shell_edge_refusals' {
        $userHome = New-UnixHome 'shell-envelope' -WithoutCache
        $before = Get-UnixTreeSnapshot $userHome
        $run = Invoke-UnixSetup $userHome @('--prepare','--offline')
        $run.ExitCode | Should Be 10
        (@($run.Json.PSObject.Properties.Name) -join ',') | Should BeExactly (@(Get-AgentEnvironmentSetupReceiptFieldNames) -join ',')
        (Get-UnixTreeSnapshot $userHome) | Should BeExactly $before
    }

    # Scenario: Cached archives are broad-mode, hard-linked, or symbolic links.
    # Purpose: F2 rejects anything except a current-uid, single-link, mode-0600 regular cache before snapshotting.
    It 'InterT27_refuses_insecure_cache_metadata_before_private_snapshot_use' {
        foreach ($case in @('mode','hardlink','symlink')) {
            $home = if ($case -ceq 'symlink') { New-UnixHome "cache-$case" -WithoutCache } else { New-UnixHome "cache-$case" }
            $cache = Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            if ($case -ceq 'mode') { [IO.File]::SetUnixFileMode($cache,[IO.UnixFileMode]438) }
            elseif ($case -ceq 'hardlink') { [IO.File]::CreateHardLink((Join-Path $home 'cache-alias'),$cache) | Out-Null }
            else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cache))
                foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup','.local/share/ai-instructions-setup/cache')) { [IO.File]::SetUnixFileMode((Join-Path $home $relative),[IO.UnixFileMode]448) }
                [void][IO.File]::CreateSymbolicLink($cache,$script:UnixArchives['runtime'].Path)
            }
            $before = Get-UnixTreeSnapshot $home
            $run = Invoke-UnixSetup $home @('--offline')
            $run.ExitCode | Should Be 13
            $run.Json.code | Should Be 'unsafe-path'
            (Get-UnixTreeSnapshot $home) | Should BeExactly $before
        }
    }

    # Scenario: Empty caches use a local curl shim or wget shim that copies the reviewed fixture archive.
    # Purpose: F8 covers both --prepare downloaders and verifies same-filesystem cache publication at mode 0600 without network.
    It 'InterT28_prepares_through_curl_and_wget_shims_and_publishes_a_private_cache' {
        $curlScript = @('out=','while [ "$#" -gt 0 ]; do','  case "$1" in','    --output) out=$2; shift 2 ;;','    *) shift ;;','  esac','done','[ -n "$out" ] || exit 64','cp -P "$FIXTURE_ARCHIVE" "$out"') -join "`n"
        $wgetScript = @('out=','for arg in "$@"; do','  case "$arg" in --output-document=*) out=${arg#--output-document=} ;; esac','done','[ -n "$out" ] || exit 64','cp -P "$FIXTURE_ARCHIVE" "$out"') -join "`n"
        foreach ($downloader in @('curl','wget')) {
            $home = New-UnixHome "download-$downloader" -WithoutCache
            $replace = @{}; $replace[$downloader] = if ($downloader -ceq 'curl') { $curlScript } else { $wgetScript }
            $exclude = if ($downloader -ceq 'curl') { @('wget') } else { @('curl') }
            $bin = New-UnixToolShim "download-$downloader" -Exclude $exclude -Replace $replace
            $run = Invoke-UnixSetup $home @('--prepare') -Environment @{ PATH=$bin; FIXTURE_ARCHIVE=$script:UnixArchives['runtime'].Path }
            if ($run.ExitCode -ne 0) { Write-Host $run.Stdout; Write-Host $run.Stderr }
            $run.ExitCode | Should Be 0
            $run.Json.result | Should Be 'prepared-runtime-only'
            $cache = Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            Get-UnixMode $cache | Should Be '600'
            (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() | Should BeExactly $script:UnixArchives['runtime'].Sha256
        }
    }

    # Scenario: The local downloader exits nonzero or copies bytes that do not match the pinned fixture hash.
    # Purpose: F8 returns download-failed or archive-hash-mismatch and never publishes a cache/runtime.
    It 'InterT29_refuses_downloader_failure_and_downloaded_hash_mismatch' {
        foreach ($case in @('failure','hash')) {
            $home = New-UnixHome "download-$case" -WithoutCache
            $scriptText = if ($case -ceq 'failure') { 'exit 7' } else { @('out=','while [ "$#" -gt 0 ]; do','case "$1" in --output) out=$2; shift 2 ;; *) shift ;; esac','done','cp -P "$FIXTURE_ARCHIVE" "$out"') -join "`n" }
            $bin = New-UnixToolShim "download-$case" -Exclude @('wget') -Replace @{ curl=$scriptText }
            $fixtureArchive = if ($case -ceq 'failure') { $script:UnixArchives['runtime'].Path } else { $script:UnixArchives['symlink'].Path }
            $run = Invoke-UnixSetup $home @('--prepare') -Environment @{ PATH=$bin; FIXTURE_ARCHIVE=$fixtureArchive }
            $run.ExitCode | Should Be $(if ($case -ceq 'failure') { 17 } else { 18 })
            $run.Json.code | Should Be $(if ($case -ceq 'failure') { 'download-failed' } else { 'archive-hash-mismatch' })
            Test-Path -LiteralPath (Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)") | Should Be $false
            Test-Path -LiteralPath (Join-Path $home '.local/share/ai-instructions-setup/pwsh') | Should Be $false
        }
    }

    # Scenario: HEAD is wrong, a bound file is dirty, a staged deletion has an untracked substitute, or a bound file is a symlink.
    # Purpose: F9 exercises native shell K4 before setup/cache/temp/sentinel mutation.
    It 'InterT30_refuses_each_native_shell_K4_substitution_before_mutation' {
        $cases = @('wrong-head','dirty','staged-substitute','symlink','platform-side-effect')
        foreach ($case in $cases) {
            & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
            & git -C $script:UnixRepo reset -q HEAD -- . 2>$null | Out-Null
            $home = New-UnixHome "k4-$case" -WithoutCache
            $marker = Join-Path $script:UnixRoot "k4-marker-$case"
            $expected = $script:UnixCommits['runtime']
            $target = Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.schema.json'
            if ($case -ceq 'wrong-head') { $expected = '0' * 40 }
            elseif ($case -ceq 'dirty') { [IO.File]::AppendAllText($target,' ') }
            elseif ($case -ceq 'staged-substitute') { & git -C $script:UnixRepo rm -q --cached -- scripts/setup-agent-environment.policy.schema.json 2>$null | Out-Null }
            elseif ($case -ceq 'symlink') { $bytes=[IO.File]::ReadAllBytes($target); Remove-Item -LiteralPath $target; [void][IO.File]::CreateSymbolicLink($target,(Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.json')) }
            else {
                $platform = Join-Path $script:UnixRepo 'scripts/platform-runtime.psm1'
                $original = [IO.File]::ReadAllText($platform)
                [IO.File]::WriteAllText($platform,"[IO.File]::WriteAllText('$marker','executed')`n$original")
            }
            $before = Get-UnixTreeSnapshot $home
            try {
                $run = Invoke-UnixSetup $home @('--offline') -ExpectedCommit $expected -NoCheckout
                $run.ExitCode | Should Be 15
                $run.Json.code | Should Be 'commit-mismatch'
                Test-Path -LiteralPath $marker | Should Be $false
                (Get-UnixTreeSnapshot $home) | Should BeExactly $before
                [IO.File]::ReadAllText($script:UnixSentinel) | Should Be 'sentinel'
            } finally { & git -C $script:UnixRepo checkout -q --detach -f $script:UnixCommits['runtime'] 2>$null | Out-Null }
        }
    }

    # Scenario: PATH omits git, tar, gzip, or both downloaders on a fresh independent HOME.
    # Purpose: F10 table-drives typed dependency refusal with a byte-identical HOME and no residue.
    It 'InterT31_refuses_the_complete_native_dependency_matrix_without_mutation' {
        $cases = @(
            @{ Name='git'; Exclude=@('git'); Mode='--offline'; Cache=$true },
            @{ Name='tar'; Exclude=@('tar'); Mode='--offline'; Cache=$true },
            @{ Name='gzip'; Exclude=@('gzip'); Mode='--offline'; Cache=$true },
            @{ Name='downloaders'; Exclude=@('curl','wget'); Mode='--prepare'; Cache=$false }
        )
        foreach ($case in $cases) {
            $home = New-UnixHome "dependency-$($case.Name)" -WithoutCache:(!$case.Cache)
            $before = Get-UnixTreeSnapshot $home
            $bin = New-UnixToolShim "dependency-$($case.Name)" -Exclude $case.Exclude
            $run = Invoke-UnixSetup $home @($case.Mode) -Environment @{ PATH=$bin }
            $run.ExitCode | Should Be 14
            $run.Json.code | Should Be 'missing-dependency'
            (Get-UnixTreeSnapshot $home) | Should BeExactly $before
            [IO.File]::ReadAllText($script:UnixSentinel) | Should Be 'sentinel'
        }
    }

    # Scenario: CODEX_HOME, USER, or legacy external transaction residue exists in a fresh independent HOME.
    # Purpose: G3/G5 refuse only external K7 state and emit the exact shared recovery command before mutation.
    It 'InterT32_refuses_external_K7_residue_with_exact_recovery_commands_and_unchanged_HOME' {
        foreach ($scope in @('codex','user','legacy')) {
            $home = New-UnixHome "residue-$scope" -WithoutCache
            $path = switch ($scope) {
                'codex' { Join-Path $home '.codex/.ai-instructions-txn' }
                'user' { Join-Path $home '.ai-instructions-txn' }
                'legacy' { Join-Path $home '.codex/.ai-instructions-install-fixture' }
            }
            [void][IO.Directory]::CreateDirectory($path)
            [IO.File]::WriteAllText((Join-Path $path 'sentinel'),'residue')
            $before = Get-UnixTreeSnapshot $home
            $policy=[IO.File]::ReadAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.json'))|ConvertFrom-Json
            $plan=Get-AgentEnvironmentSetupPlan -Policy $policy -UserHome $home -CodexHome (Join-Path $home '.codex') -Mode Prepare -ArchivePath '' -Rid $script:UnixRid
            $run = Invoke-UnixSetup $home @('--prepare')
            $run.ExitCode | Should Be 27
            $run.Json.code | Should Be 'interrupted-install'
            $expected=if($scope -ceq 'user'){'pwsh -NoProfile -NonInteractive -File ~/.codex/hooks/update-agent-environment.ps1 -Recover'}else{'pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap.ps1 -CodexHome ~/.codex'}
            $run.Json.recoverCommand | Should BeExactly $expected
            $run.Json.recoverCommand | Should BeExactly $plan.recoverCommand
            (Get-UnixTreeSnapshot $home) | Should BeExactly $before
        }
    }

    # Scenario: HOME is unset, relative, root, newline-bearing, or a regular file instead of a directory.
    # Purpose: G12 table-drives every invalid HOME shape through the native shell entry without Skip.
    It 'InterT34_refuses_each_invalid_HOME_shape' {
        $fileHome=Join-Path $script:UnixRoot 'home-as-file';[IO.File]::WriteAllText($fileHome,'not a directory')
        $cases=@(
            @{Name='unset';Value='';Unset=$true},
            @{Name='relative';Value='relative/home';Unset=$false},
            @{Name='root';Value='/';Unset=$false},
            @{Name='newline';Value="/tmp/invalid`nhome";Unset=$false},
            @{Name='file';Value=$fileHome;Unset=$false}
        )
        foreach($case in $cases){
            $run=Invoke-UnixSetup $case.Value @('--offline') -UnsetHome:$case.Unset
            $run.ExitCode | Should Be 12
            $run.Json.code | Should Be 'home-invalid'
        }
    }

    # Scenario: The loader probe is forced to report musl, while a control probe reports no musl loader.
    # Purpose: G12 verifies behavior from the native entry instead of comparing source-code strings.
    It 'InterT35_uses_the_controllable_loader_probe_to_refuse_musl' {
        $home=New-UnixHome 'musl-probe'
        $realFind=@(Get-Command find -CommandType Application | Select-Object -First 1)[0].Source
        $findShim=@('if [ "$1" = /lib ] && [ "$2" = /usr/lib ]; then','  printf "%s\n" /lib/ld-musl-fixture.so.1','  exit 0','fi','exec "$REAL_FIND" "$@"') -join "`n"
        $bin=New-UnixToolShim 'musl-probe' -Replace @{find=$findShim}
        $run=Invoke-UnixSetup $home @('--offline') -Environment @{PATH=$bin;REAL_FIND=$realFind}
        $run.ExitCode | Should Be 11;$run.Json.code | Should Be 'unsupported-platform'
        $control=Invoke-UnixSetup $home @('--offline')
        $control.Json.code | Should Not Be 'unsupported-platform'
    }

    # Scenario: A HOME ancestor is writable by other users without sticky protection, and where possible owned by another uid.
    # Purpose: G12 rejects unsafe ancestor ownership/mode through behavior-level native fixtures.
    It 'InterT36_refuses_unsafe_ancestor_mode_and_owner' {
        $unsafeParent=Join-Path $script:UnixRoot 'unsafe-ancestor-mode';[void][IO.Directory]::CreateDirectory($unsafeParent)
        [IO.File]::SetUnixFileMode($unsafeParent,[IO.UnixFileMode]511)
        $home=Join-Path $unsafeParent 'home';[void][IO.Directory]::CreateDirectory($home);[IO.File]::SetUnixFileMode($home,[IO.UnixFileMode]448)
        try{$run=Invoke-UnixSetup $home @('--offline');$run.ExitCode | Should Be 13;$run.Json.code | Should Be 'unsafe-path'}finally{[IO.File]::SetUnixFileMode($unsafeParent,[IO.UnixFileMode]448)}
        if($script:SetupTestUnixUid -eq '0'){
            $ownerParent=Join-Path $script:UnixRoot 'unsafe-ancestor-owner';[void][IO.Directory]::CreateDirectory($ownerParent)
            $ownerHome=Join-Path $ownerParent 'home';[void][IO.Directory]::CreateDirectory($ownerHome)
            & chown 1 $ownerParent
            try{$run=Invoke-UnixSetup $ownerHome @('--offline');$run.ExitCode | Should Be 13;$run.Json.code | Should Be 'unsafe-path'}finally{& chown 0 $ownerParent}
        }
    }

    # Scenario: The cache pathname is replaced after the snapshot hash is computed but before tar or PowerShell can consume bytes.
    # Purpose: G11 uses a FIFO barrier to prove only the private snapshot is used after verification.
    It 'InterT37_uses_only_the_private_snapshot_after_a_barrier_cache_swap' {
        $home=New-UnixHome 'cache-race'
        $initial=Invoke-UnixSetup $home @('--prepare')
        $initial.ExitCode | Should Be 0
        $barrier=Join-Path $script:UnixRoot ('cache-race-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($barrier)
        $fifo=Join-Path $barrier 'release';& mkfifo $fifo;$LASTEXITCODE | Should Be 0
        $ready=Join-Path $barrier 'ready';$realHash=@(Get-Command sha256sum -CommandType Application | Select-Object -First 1)[0].Source
        $hashShim=@('result=$("$REAL_HASH" "$1")','printf ready > "$BARRIER_READY"','IFS= read -r release < "$BARRIER_FIFO"','printf "%s\n" "$result"') -join "`n"
        $bin=New-UnixToolShim 'cache-race' -Replace @{sha256sum=$hashShim}
        $running=Start-UnixSetup $home @('--offline') -Environment @{PATH=$bin;REAL_HASH=$realHash;BARRIER_READY=$ready;BARRIER_FIFO=$fifo}
        try{
            $watcher=[IO.FileSystemWatcher]::new($barrier,'ready');$watcher.EnableRaisingEvents=$true
            try{if(-not [IO.File]::Exists($ready)){[void]$watcher.WaitForChanged([IO.WatcherChangeTypes]::Created,120000)}}finally{$watcher.Dispose()}
            [IO.File]::Exists($ready) | Should Be $true
            $cache=Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            Move-Item -LiteralPath $cache -Destination ($cache+'.verified')
            Copy-Item -LiteralPath $script:UnixArchives['symlink'].Path -Destination $cache
            $writer=[IO.File]::Open($fifo,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes("release`n");$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}
            $run=Complete-UnixSetup $running;$running=$null
            $run.ExitCode | Should Be 0
            $run.Json.result | Should Be 'verified-runtime-only'
        }finally{if($null -ne $running){$running.Process.Kill($true);[void](Complete-UnixSetup $running)}}
    }

    # Scenario: The real PowerShell entry is killed after staging a setup receipt, then the documented shell entry is rerun.
    # Purpose: G3/G10 prove the shell does not refuse setup-owned WAL and reaches lock-held PowerShell recovery.
    It 'InterT38_recovers_a_setup_owned_journal_when_rerun_through_the_shell_entry' {
        $home=New-UnixHome 'shell-recovery'
        $initial=Invoke-UnixSetup $home @('--prepare');$initial.ExitCode | Should Be 0
        $cache=Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
        $start=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:UnixRepo 'scripts/setup-agent-environment.ps1'),'-Offline','-ExpectedCommit',$script:UnixCommits['runtime'],'-ArchivePath',$cache)){$start.ArgumentList.Add($argument)}
        $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.Environment['HOME']=$home;$start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT']='after-stage';$start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF']='setup-receipt.json';[void]$start.Environment.Remove('CODEX_HOME')
        $process=[Diagnostics.Process]::Start($start)
        try{$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();$process.WaitForExit(900000)|Should Be $true;$process.ExitCode|Should Not Be 0}finally{$process.Dispose()}
        Test-Path -LiteralPath (Join-Path $home '.local/share/ai-instructions-setup/.ai-instructions-txn') | Should Be $true
        $recovered=Invoke-UnixSetup $home @('--offline')
        $recovered.ExitCode | Should Be 0
        $recovered.Json.result | Should Be 'verified-runtime-only'
        Test-Path -LiteralPath (Join-Path $home '.local/share/ai-instructions-setup/.ai-instructions-txn') | Should Be $false
    }

    # Register only when the native test process can create a genuinely foreign-owned cache fixture.
    if ($setupTestUnixUid -eq '0') {
    # Scenario: A cached archive is owned by a different uid.
    # Purpose: F2 returns unsafe-path rather than consuming foreign-owned cache bytes.
    It 'InterT33_refuses_a_foreign_owned_cache_file' {
        $home = New-UnixHome 'cache-owner'
        $cache = Join-Path $home ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
        & chown 1 $cache
        $LASTEXITCODE | Should Be 0
        $before = Get-UnixTreeSnapshot $home
        $run = Invoke-UnixSetup $home @('--offline')
        $run.ExitCode | Should Be 13
        $run.Json.code | Should Be 'unsafe-path'
        (Get-UnixTreeSnapshot $home) | Should BeExactly $before
    }
    }

    # Register only on the native host; root bypasses write permission checks.
    if ($setupTestUnixUid -ne '0') {
    # Scenario: HOME is not writable, or HOME is group/world writable without the sticky bit.
    # Purpose: S1 refuses home-invalid and M7 unsafe-path with the home bytes unchanged.
    It 'InterT25_refuses_unwritable_and_unsafely_writable_homes' {
        $readOnly = New-UnixHome 'read-only' -WithoutCache
        [IO.File]::SetUnixFileMode($readOnly,[IO.UnixFileMode]320)
        try {
            $run = Invoke-UnixSetup $readOnly @('--prepare')
            $run.ExitCode | Should Be 12; $run.Json.code | Should Be 'home-invalid'
        } finally { [IO.File]::SetUnixFileMode($readOnly,[IO.UnixFileMode]448) }
        @(Get-ChildItem -LiteralPath $readOnly -Force).Count | Should Be 0
        $open = New-UnixHome 'world-writable' -WithoutCache
        [IO.File]::SetUnixFileMode($open,[IO.UnixFileMode]511)
        $run = Invoke-UnixSetup $open @('--prepare')
        $run.ExitCode | Should Be 13; $run.Json.code | Should Be 'unsafe-path'
        @(Get-ChildItem -LiteralPath $open -Force).Count | Should Be 0
    }
    }
}
}
