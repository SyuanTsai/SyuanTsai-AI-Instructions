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

function ConvertTo-SetupTestDiagnosticStderr {
    param([AllowNull()][string]$Stderr)
    if ([string]::IsNullOrEmpty($Stderr)) { return '<empty>' }
    $cultureInvariant = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $sanitized = [regex]::Replace($Stderr,'(?i)\b((?:proxy-)?authorization["'']?[^\S\r\n]*[:=][^\S\r\n]*)[^\r\n]*','$1[REDACTED]',$cultureInvariant)
    $sanitized = [regex]::Replace($sanitized,'(?im)\b(token|secret|password|passwd|api[_-]?key|credential)(\s*[:=]\s*)([^\s;]+)','$1$2[REDACTED]')
    $sanitized = [regex]::Replace($sanitized,'(?i)\bBearer\s+[^\s;]+','Bearer [REDACTED]',$cultureInvariant)
    $sanitized = [regex]::Replace($sanitized,'(?i)\bBasic[^\S\r\n]+[^\s;]+','Basic [REDACTED]',$cultureInvariant)
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($utf8.GetByteCount($sanitized) -le 4096) { return $sanitized }
    $low = 0
    $high = $sanitized.Length
    while ($low -lt $high) {
        $middle = [int][Math]::Ceiling(($low + $high) / 2.0)
        if ($utf8.GetByteCount($sanitized.Substring(0,$middle)) -le 4079) { $low = $middle } else { $high = $middle - 1 }
    }
    while ($low -gt 0 -and [char]::IsHighSurrogate($sanitized[$low - 1])) { $low-- }
    return $sanitized.Substring(0,$low) + "`n...[truncated]"
}

function Assert-SetupTestExitCode {
    param([Parameter(Mandatory=$true)]$Run,[Parameter(Mandatory=$true)][int]$Expected)
    try { $Run.ExitCode | Should Be $Expected }
    catch {
        $diagnostic = ConvertTo-SetupTestDiagnosticStderr ([string]$Run.Stderr)
        throw [Exception]::new("$($_.Exception.Message)`nSetup stderr (sanitized, max 4 KiB):`n$diagnostic",$_.Exception)
    }
}

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
            $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $Fixture.Layout $script:SetupFixtureRid
            if ($Directory) { [void][IO.Directory]::CreateDirectory($attempt.RuntimeDirectory) }
            if ($Receipt) { [void][IO.Directory]::CreateDirectory($Fixture.Layout.ReceiptDirectory); [IO.File]::WriteAllText((Join-Path $Fixture.Layout.ReceiptDirectory $Fixture.Layout.RuntimeReceiptLeaf),'{}') }
            return $attempt
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

        function Get-SetupTestEntryFunctionSource {
            param([Parameter(Mandatory=$true)][string]$Name,[switch]$AllowMissing)
            $tokens=$null;$parseErrors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($script:SetupEntryPath,[ref]$tokens,[ref]$parseErrors)
            if(@($parseErrors).Count-ne0){throw 'The setup entry could not be parsed for a behavioral unit test.'}
            $functions=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$Name},$true))
            if($functions.Count-eq0-and$AllowMissing){return $null}
            if($functions.Count-ne1){throw "Expected exactly one setup entry function named '$Name'."}
            return [string]$functions[0].Extent.Text
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

    # Scenario: A runtime pointer receipt already exists while unrelated runtime directories may also exist.
    # Purpose: H1 makes the receipt the only pointer; reruns only re-verify the directory it names.
    It 'UnitT11_plans_reverification_for_an_existing_runtime_in_both_modes' {
        $fixture = New-SetupTestHome 'plan-present'
        [void](New-SetupTestRuntime $fixture -Directory -Receipt)
        foreach ($mode in @('Prepare','Offline')) {
            $plan = Get-SetupTestPlan $fixture $mode
            $plan.decision | Should Be 'verify-runtime'
            $plan.runtimeState | Should Be 'present'
        }
    }

    # Scenario: An unreferenced runtime directory exists without a receipt, or a receipt exists without a fixed directory name.
    # Purpose: H1 ignores the orphan directory and uses only the receipt to select verification.
    It 'UnitT12_uses_only_the_runtime_receipt_as_the_pointer' {
        $directoryOnly = New-SetupTestHome 'plan-directory-only'; $orphan = New-SetupTestRuntime $directoryOnly -Directory
        (Get-SetupTestPlan $directoryOnly 'Prepare').decision | Should Be 'resolve-runtime'
        (Get-SetupTestPlan $directoryOnly 'Offline').code | Should Be 'runtime-missing'
        Test-Path -LiteralPath $orphan.RuntimeDirectory -PathType Container | Should Be $true
        $receiptOnly = New-SetupTestHome 'plan-receipt-only'; [void](New-SetupTestRuntime $receiptOnly -Receipt)
        (Get-SetupTestPlan $receiptOnly 'Prepare').decision | Should Be 'verify-runtime'
        (Get-SetupTestPlan $receiptOnly 'Offline').decision | Should Be 'verify-runtime'
    }

    # Scenario: CODEX_HOME holds the empty physical store left by a committed install, or real residue (an entry or a file).
    # Purpose: K7 accepts only the committed empty-container state and refuses every ambiguous store before any installer call.
    It 'UnitT13_refuses_codex_home_transaction_residue_with_the_installer_recovery' {
        $empty = New-SetupTestHome 'plan-codex-txn-empty'
        [void][IO.Directory]::CreateDirectory((Join-Path $empty.CodexHome '.ai-instructions-txn'))
        [void][IO.Directory]::CreateDirectory((Join-Path $empty.Home '.ai-instructions-txn'))
        [void][IO.Directory]::CreateDirectory((Join-Path $empty.Layout.SetupRoot '.ai-instructions-txn'))
        $setupModule = Get-Module agent-environment-setup
        $emptyResidue = @(& $setupModule {
            param($CodexHome,$UserHome,$SetupRoot)
            Get-AgentEnvironmentSetupResidue -CodexHome $CodexHome -UserHome $UserHome -SetupRoot $SetupRoot
        } $empty.CodexHome $empty.Home $empty.Layout.SetupRoot)
        $emptyResidue.Count | Should Be 0

        foreach ($kind in @('directory','file')) {
            $fixture = New-SetupTestHome "plan-codex-txn-$kind"
            [void](New-SetupTestRuntime $fixture -Directory -Receipt)
            [void][IO.Directory]::CreateDirectory($fixture.CodexHome)
            $store = Join-Path $fixture.CodexHome '.ai-instructions-txn'
            if ($kind -eq 'directory') { [void][IO.Directory]::CreateDirectory((Join-Path $store ('a'*32))) } else { [IO.File]::WriteAllText($store,'x') }
            $plan = Get-SetupTestPlan $fixture 'Offline'
            $plan.decision | Should Be 'refuse'
            $plan.code | Should Be 'interrupted-install'
            (@($plan.residue) -join ',') | Should BeExactly '~/.codex/.ai-instructions-txn'
            $plan.recoverCommand | Should Match '^pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap\.ps1 -CodexHome ~/\.codex$'
        }
        $linkFixture = New-SetupTestHome 'plan-codex-txn-link'
        [void](New-SetupTestRuntime $linkFixture -Directory -Receipt)
        [void][IO.Directory]::CreateDirectory($linkFixture.CodexHome)
        $linkTarget = Join-Path $linkFixture.Root 'transaction-link-target'
        [void][IO.Directory]::CreateDirectory($linkTarget)
        $linkPath = Join-Path $linkFixture.CodexHome '.ai-instructions-txn'
        try { [void][IO.Directory]::CreateSymbolicLink($linkPath,$linkTarget) } catch { }
        $linkItem = Get-Item -Force -LiteralPath $linkPath -ErrorAction SilentlyContinue
        if ($null -ne $linkItem -and $null -ne $linkItem.PSObject.Properties['LinkType'] -and $linkItem.LinkType) {
            (Get-SetupTestPlan $linkFixture 'Offline').code | Should Be 'interrupted-install'
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
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Home '.ai-instructions-txn/entry'))
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
        (Get-SetupTestPlan $fixture 'Offline').code | Should Be 'runtime-missing'
        (Get-SetupTestPlan $fixture 'Prepare' '').code | Should Be 'cache-missing'
        [void][IO.Directory]::CreateDirectory($fixture.Archive)
        (Get-SetupTestPlan $fixture 'Prepare').code | Should Be 'cache-missing'
    }

    # Scenario: Residue, a missing cache and an absent runtime are all present.
    # Purpose: K7 residue wins, so no later step can run an installer path that would auto-recover.
    It 'UnitT17_checks_interrupted_install_residue_before_cache_and_runtime_state' {
        $fixture = New-SetupTestHome 'plan-precedence'
        Remove-Item -LiteralPath $fixture.Archive
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.CodexHome '.ai-instructions-txn/entry'))
        (Get-SetupTestPlan $fixture 'Offline').code | Should Be 'interrupted-install'
    }

    # Scenario: Plans are computed over every decision-table state.
    # Purpose: Get-AgentEnvironmentSetupPlan is purely read-only; the tree is byte-identical afterwards.
    It 'UnitT18_keeps_plan_evaluation_read_only' {
        $fixture = New-SetupTestHome 'plan-read-only'
        [void](New-SetupTestRuntime $fixture -Directory)
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.CodexHome '.ai-instructions-install-1'))
        $before = Get-SetupTestTreeSnapshot $fixture.Root
        foreach ($mode in @('Prepare','Offline')) { [void](Get-SetupTestPlan $fixture $mode) }
        Remove-Item -LiteralPath (Join-Path $fixture.CodexHome '.ai-instructions-install-1') -Force
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
        $linkTarget = Join-Path $fixture.Root 'physical-transaction-store'
        [void][IO.Directory]::CreateDirectory($linkTarget)
        [void][IO.Directory]::CreateSymbolicLink((Join-Path $fixture.CodexHome '.ai-instructions-txn'),$linkTarget)
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
        $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $fixture.Layout $script:SetupFixtureRid
        $executable = Join-Path $attempt.RuntimeDirectory 'pwsh'
        $receipt = [pscustomobject][ordered]@{ apiVersion='1.0'; version='7.6.6'; assetName='powershell-7.6.6-linux-x64.tar.gz'; archiveSha256=('c'*64); executablePath=$executable; executableSha256=('d'*64)
            runtimeClosure=[pscustomobject]@{ rootPath=$attempt.RuntimeDirectory; sha256=('e'*64); files=@([pscustomobject]@{path='pwsh';sha256=('d'*64)}); directories=@(); directorySha256=('0'*64) }
            environmentAllowlist=@('PATH'); warningCount=1; warnings=@("warning about $($fixture.Home)"); protectionBoundary='A1'; os='linux'; architecture='x64' }
        $stored = ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt $receipt $fixture.Home
        $json = ConvertTo-AgentEnvironmentSetupJsonLine $stored
        $json.Contains($fixture.Home) | Should Be $false
        $json.Contains($fixture.Home.Replace('\','/')) | Should Be $false
        $stored.executablePath | Should BeExactly ('~/.local/share/ai-instructions-setup/pwsh/' + $attempt.RuntimeLeaf + '/pwsh')
        $restored = ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt ($json | ConvertFrom-Json) $fixture.Home
        $restored.executablePath | Should BeExactly ([IO.Path]::GetFullPath($executable))
        $restored.runtimeClosure.rootPath | Should BeExactly ([IO.Path]::GetFullPath($attempt.RuntimeDirectory))
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
            $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $fixture.Layout $script:SetupFixtureRid
            $environment = Get-AgentEnvironmentSetupChildEnvironment $attempt.RuntimeDirectory $fixture.Home
            foreach ($name in $names) { if ($name -cne 'PSModulePath') { $environment.Contains($name) | Should Be $false } }
            $environment['PSModulePath'] | Should BeExactly (Join-Path $attempt.RuntimeDirectory 'Modules')
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

    # Scenario: A replace ref maps the pinned commit to a malicious tree whose bound-file bytes are also staged and present in the worktree.
    # Purpose: J1 requires the module verifier to resolve the expected commit without replacements and compare expected, index, and raw worktree blobs directly.
    It 'UnitT25b_rejects_replace_objects_before_loading_repository_code' {
        $root = Join-Path $TestDrive 'k4-replace-repository'
        $expected = Initialize-SetupTestGitRepository $root
        $target = Join-Path $root 'scripts/setup-agent-environment.policy.json'
        [IO.File]::AppendAllText($target,"`n")
        & git -C $root add -- scripts/setup-agent-environment.policy.json 2>$null | Out-Null
        & git -C $root -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m malicious 2>$null | Out-Null
        $malicious = [string](& git -C $root rev-parse HEAD)
        $maliciousBytes = [IO.File]::ReadAllBytes($target)
        & git -C $root replace $expected $malicious 2>$null | Out-Null
        $previousNoReplace = [Environment]::GetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS')
        try {
            [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS','1')
            & git -C $root checkout -q --detach $expected 2>$null | Out-Null
        } finally { [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS',$previousNoReplace) }
        [IO.File]::WriteAllBytes($target,$maliciousBytes)
        & git -C $root add -- scripts/setup-agent-environment.policy.json 2>$null | Out-Null

        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root $expected }) | Should Be 'commit-mismatch'
    }

    # Scenario: Repository-local attributes select a clean filter that can hide tampered bound bytes and writes a marker whenever it executes.
    # Purpose: J1 compares raw blobs without consulting filters, attributes, textconv, diff drivers, hooks, or fsmonitor, so the marker never runs and HOME stays unchanged.
    It 'UnitT25c_rejects_a_filter_hidden_tamper_without_invoking_the_filter' {
        $root = Join-Path $TestDrive 'k4-filter-repository'
        $expected = Initialize-SetupTestGitRepository $root
        $testHome = Join-Path $TestDrive 'k4-filter-home'
        [void][IO.Directory]::CreateDirectory($testHome)
        [IO.File]::WriteAllText((Join-Path $testHome 'sentinel'),'unchanged')
        $before = Get-SetupTestTreeSnapshot $testHome
        $target = Join-Path $root 'scripts/setup-agent-environment.policy.json'
        $original = Join-Path $root 'original-policy.json'
        [IO.File]::WriteAllBytes($original,[IO.File]::ReadAllBytes($target))
        [IO.File]::AppendAllText($target,"`n")
        $marker = Join-Path $root 'filter-marker'
        $filter = Join-Path $root 'filter.sh'
        $filterText = "#!/bin/sh`nprintf invoked > '$marker'`ncat '$original'`n"
        [IO.File]::WriteAllText($filter,$filterText,[Text.UTF8Encoding]::new($false))
        $filterCommand = 'sh "' + $filter.Replace('\','/') + '"'
        & git -C $root config filter.hide.clean $filterCommand 2>$null | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.git/info/attributes'),"scripts/setup-agent-environment.policy.json filter=hide`n",[Text.UTF8Encoding]::new($false))
        & git -C $root hash-object --path scripts/setup-agent-environment.policy.json -- $target 2>$null | Out-Null
        Test-Path -LiteralPath $marker | Should Be $true
        Remove-Item -LiteralPath $marker -Force

        (Get-SetupTestRefusalCode { Assert-AgentEnvironmentSetupCommit $root $expected }) | Should Be 'commit-mismatch'
        Test-Path -LiteralPath $marker | Should Be $false
        (Get-SetupTestTreeSnapshot $testHome) | Should BeExactly $before
    }

    # Scenario: A stored runtime receipt points outside the unique receipt-addressed layout.
    # Purpose: H1 binds both receipt paths to pwsh/<version>-<rid>-<attemptId> before K15 or re-exec.
    It 'UnitT26_binds_runtime_receipt_paths_to_the_canonical_layout' {
        $fixture = New-SetupTestHome 'receipt-layout-binding'
        $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $fixture.Layout $script:SetupFixtureRid
        $valid = [pscustomobject]@{ os='linux'; executablePath=$attempt.RuntimeExecutable; runtimeClosure=[pscustomobject]@{ rootPath=$attempt.RuntimeDirectory } }
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
            $transactionStore = Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn'
            $transaction = Join-Path $transactionStore ('a'*32)
            [void][IO.Directory]::CreateDirectory($transaction)
            if($setupTestIsUnix){
                [IO.File]::SetUnixFileMode($transactionStore,[IO.UnixFileMode]448)
                [IO.File]::SetUnixFileMode($transaction,[IO.UnixFileMode]448)
            }
            if($members.Count -gt 0){
                $memberPath = Join-Path $transaction $members[0]
                [IO.File]::WriteAllText($memberPath,'unpublished')
                if($setupTestIsUnix){[IO.File]::SetUnixFileMode($memberPath,[IO.UnixFileMode]384)}
            }
            Repair-AgentEnvironmentSetupTransactions $fixture.Layout.SetupRoot
            Test-Path -LiteralPath (Join-Path $fixture.Layout.SetupRoot '.ai-instructions-txn') | Should Be $false
        }
    }

    # Scenario: macOS copyfile metadata creates a sidecar for the policy-bound archive snapshot or download.
    # Purpose: Keep cleanup restricted to the two exact inventory-derived AppleDouble leaves without scanning the run tree.
    It 'UnitT29_cleans_only_the_known_archive_AppleDouble_companions' {
        $script:SetupShellText | Should Match ([regex]::Escape('"$run_tmp/._$asset_name"'))
        $script:SetupShellText | Should Match ([regex]::Escape('"$run_tmp/download/._$asset_name"'))
        $script:SetupShellText | Should Not Match '\$run_tmp/\.\*_'
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

    # Scenario: The shell edge downloads and hands off to PowerShell through a persistent setup-owned private child temp directory.
    # Purpose: L7 bounded HTTPS and M5 env -i keep unbounded .NET runtime state outside the exactly reclaimed per-run directory.
    It 'UnitT33_uses_https_only_bounded_downloads_and_an_environment_allowlist' {
        $script:SetupShellText | Should Match "curl -q --proto '=https' --proto-redir '=https' --tlsv1\.2"
        $script:SetupShellText | Should Match '--max-time [0-9]+'
        $script:SetupShellText | Should Match 'wget --no-config --https-only --secure-protocol=TLSv1_2 --timeout=[0-9]+'
        $script:SetupShellText | Should Match ([regex]::Escape('pwsh_tmp="$setup_root/pwsh-tmp"'))
        $script:SetupShellText | Should Match ([regex]::Escape('if [ -L "$pwsh_tmp" ]; then refuse unsafe-path'))
        $script:SetupShellText | Should Match ([regex]::Escape('[ -d "$pwsh_tmp" ] || refuse unsafe-path'))
        $script:SetupShellText | Should Match ([regex]::Escape('run_clean mkdir "$pwsh_tmp"'))
        $script:SetupShellText | Should Match ([regex]::Escape('find "$pwsh_tmp" -prune -type d -user "$uid" -perm 0700 -print'))
        $script:SetupShellText | Should Match ([regex]::Escape('"TMPDIR=$pwsh_tmp"'))
        $script:SetupShellText | Should Not Match ([regex]::Escape('run_clean mkdir "$run_tmp/pwsh-tmp"'))
        $script:SetupShellText | Should Not Match ([regex]::Escape('run_clean rmdir "$run_tmp/pwsh-tmp'))
        $script:SetupShellText | Should Not Match '"TMPDIR=\$run_tmp"'
        $script:SetupShellText | Should Match '(?m)^"\$env_path" -i "\$@" "\$bootstrap/pwsh" -NoLogo -NoProfile -NonInteractive -File '
        $script:SetupShellText | Should Match 'setup_root="\$home/\.local/share/ai-instructions-setup"'
        foreach ($pattern in @('XDG_','DOTNET_','LD_','DYLD_','POWERSHELL_')) { $script:SetupShellText | Should Not Match $pattern }
        $script:SetupShellText | Should Not Match 'mv -f "\$download" "\$archive"'
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

    # Scenario: A Linux caller omits the mode, while macOS and the PowerShell entry keep their explicit-mode contract.
    # Purpose: Make the cloud command non-interactive by default on Linux without adding Auto or changing Windows/macOS behavior.
    It 'UnitT36_defaults_only_the_Linux_shell_entry_to_prepare_without_exposing_Auto' {
        $fixture = New-SetupTestHome 'no-auto-mode'
        { Get-AgentEnvironmentSetupPlan -Policy $fixture.Policy -UserHome $fixture.Home -CodexHome $fixture.CodexHome -Mode Auto -ArchivePath $fixture.Archive -Rid $script:SetupFixtureRid } | Should Throw
        $script:SetupShellText | Should Not Match '(?i)--auto'
        $script:SetupShellText | Should Match '\[ -n "\$mode" \] \|\| \[ "\$os_token" != linux \] \|\| mode=prepare'
        $script:SetupShellText | Should Match '\[ -n "\$mode" \] \|\| refuse usage'
        ([IO.File]::ReadAllText($script:SetupEntryPath)) | Should Not Match '(?i)\[switch\]\s*\$Auto'
    }

    # Scenario: Documentation explains how to consume a random receipt-selected home-relative runtime path.
    # Purpose: H1/F7 prevents either '~/...' or the former fixed runtime path from being treated as an executable path authority.
    It 'UnitT37_documents_receipt_selected_runtime_paths_in_both_languages' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        $englishSection = $readme.IndexOf('## Linux/macOS setup',[StringComparison]::Ordinal)
        $englishSection | Should BeGreaterThan 0
        $readme | Should Match 'Receipt paths are `~/\.\.\.`, not absolute paths'
        $readme | Should Match '必須讀取 `runtime-<version>-<rid>\.json` 的 `executablePath`'
        $readme | Should Match 'Read `executablePath` from `runtime-<version>-<rid>\.json`'
        $readme | Should Not Match 'pwsh/7\.6\.6-(?:linux|osx|win)-x64/pwsh'
    }

    # Scenario: The Chinese and English runtime crash-state tables describe both pre-WAL and complete-WAL windows after durable directory publication.
    # Purpose: J2/J4 keep parent durability, orphan retry, and original-pointer recovery semantics synchronized in both languages.
    It 'UnitT38_documents_both_runtime_receipt_WAL_crash_states_in_both_languages' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        @([regex]::Matches($readme,'receipt WAL stage',[Text.RegularExpressions.RegexOptions]::CultureInvariant)).Count | Should Be 2
        @([regex]::Matches($readme,'resolver',[Text.RegularExpressions.RegexOptions]::CultureInvariant)).Count | Should BeGreaterThan 1
        @([regex]::Matches($readme,'durably flush(?:es)?',[Text.RegularExpressions.RegexOptions]::CultureInvariant)).Count | Should BeGreaterThan 1
        $readme | Should Match 'no recoverable receipt WAL yet'
        $readme | Should Match 'complete receipt WAL stage committed'
    }

    # Scenario: A setup child exits with the wrong code and its stderr contains a credential-shaped value plus more than 4 KiB of text.
    # Purpose: Make CI failures actionable while bounding diagnostics and redacting secret-shaped values.
    It 'UnitT39_reports_bounded_sanitized_stderr_for_an_exit_code_mismatch' {
        $run = [pscustomobject]@{ ExitCode = 23; Stderr = "token=do-not-leak`n" + ('x' * 5000) }
        $failure = $null
        try { Assert-SetupTestExitCode $run 0 } catch { $failure = $_ }
        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match 'Setup stderr'
        $failure.Exception.Message | Should Match '\[REDACTED\]'
        $failure.Exception.Message | Should Match '\.\.\.\[truncated\]'
        $failure.Exception.Message | Should Not Match 'do-not-leak'
        [Text.Encoding]::UTF8.GetByteCount((ConvertTo-SetupTestDiagnosticStderr $run.Stderr)) | Should BeLessOrEqual 4096
    }

    # Scenario: A USER projection target already contains unmanaged bytes.
    # Purpose: Give the cloud setup edge a stable typed refusal distinct from an unexpected internal failure.
    It 'UnitT40_assigns_a_shared_typed_exit_code_to_projection_collisions' {
        $table = Get-AgentEnvironmentSetupExitCodeTable
        $table['projection-collision'] | Should Be 29
        $script:SetupShellText | Should Match '(?m)^EXIT_PROJECTION_COLLISION=29$'
        ([IO.File]::ReadAllText($script:SetupEntryPath)) | Should Match "New-AgentEnvironmentSetupRefusal projection-collision"
    }

    # Scenario: The canonical Linux stage sees no installed runtime under the isolated CODEX_HOME.
    # Purpose: Wire the first install to the existing installer with the explicit V3V5 writer and both production USER projections.
    It 'UnitT41_wires_the_Linux_first_install_to_explicit_V3V5_and_USER_projection_apply' {
        $entry = [IO.File]::ReadAllText($script:SetupEntryPath)
        $entry | Should Match '\$rid\.StartsWith\(''linux-'''
        $entry | Should Match "install-ai-instructions-bootstrap\.ps1"
        $entry | Should Match "'-WriterSchema','V3V5'"
        $entry | Should Match "update-agent-environment\.ps1"
        $entry | Should Match 'Invoke-SetupCoordinatorChild.*?-Mode Apply'
        $entry | Should Match "'user-agents','user-claude'"
    }

    # Scenario: Linux setup runs against an installed runtime at the same pin or an ancestor pin whose platform build differs.
    # Purpose: Keep same-pin validation read-only and isolate the new-pin updater workflow in an owned pwsh child.
    It 'UnitT42_routes_Linux_reruns_and_new_pins_through_the_updater_workflow' {
        $entry = [IO.File]::ReadAllText($script:SetupEntryPath)
        $entry | Should Match 'Invoke-AiInstructionsUpdateWorkflow'
        $entry | Should Match "-ForceCheck\s+-InstallApproved"
        $cloudFunction = [regex]::Match($entry,'(?s)function Invoke-SetupLinuxCloudWiring \{.*?(?=\r?\n\$modeName =)').Value
        $cloudFunction | Should Not Match 'Import-Module\s+\$updaterPath'
        $entry | Should Match 'Invoke-SetupLinuxUpdaterChild'
        $entry | Should Match 'Linux updater workflow child'
        $entry | Should Match "(?s)bootstrap-ai-instructions\.ps1.*?-ValidateOnly"
        $entry | Should Match "'-ExpectedCurrentCommit'"
        $entry | Should Match "'-ExpectedCurrentGeneration','v3v5'"
        $entry | Should Match "'-WriterSchema','Auto'"
        $entry | Should Match "merge-base.*--is-ancestor"
    }

    # Scenario: Projection preflight/Apply succeeds, collides, or leaves drift, with every child launched without inherited stdin.
    # Purpose: Refuse collision before installer/updater mutation, retain Apply as a second line, and verify readiness afterward.
    It 'UnitT43_maps_projection_collision_and_verifies_readiness_non_interactively' {
        $entry = [IO.File]::ReadAllText($script:SetupEntryPath)
        $module = [IO.File]::ReadAllText((Join-Path $script:SetupScripts 'agent-environment-setup.psm1'))
        $module | Should Match 'unmanaged-collision'
        $entry | Should Match 'Invoke-SetupCoordinatorChild.*?-Mode VerifyOnly'
        $entry | Should Match 'Invoke-SetupCoordinatorChild.*?-Mode WhatIf'
        $entry | Should Match '(?s)Invoke-SetupProjectionCollisionPreflight.*?if\(\$cloudPlan\.action-ceq''install''\)'
        $entry | Should Match 'Invoke-PlatformPreparationCommand'
        $entry | Should Match 'projection-collision'
        $entry | Should Match 'projection-failed'
    }

    # Scenario: Linux completes runtime install/update plus USER projection readiness, while other OS receipts retain the P10a shape.
    # Purpose: Record the immutable runtime pin and completed S7-S9 evidence without changing the Windows/macOS receipt contract.
    It 'UnitT44_renders_completed_Linux_cloud_receipts_and_preserves_legacy_receipts' {
        $legacy = New-AgentEnvironmentSetupReceipt -Mode prepare -Result prepared-runtime-only -Rid win-x64 -SetupCommit ('a' * 40) -PolicySha256 ('b' * 64) -RuntimeAction resolved
        $legacy.phase | Should BeExactly 'p10a'
        $legacy.runtimeCommit | Should BeNullOrEmpty
        (@($legacy.steps | Where-Object step -in @('S7','S8','S9') | Select-Object -ExpandProperty status) -join ',') | Should BeExactly 'not-implemented-until-p10b,not-implemented-until-p10b,not-implemented-until-p10b'

        $cloud = New-AgentEnvironmentSetupReceipt -Mode prepare -Result completed -Rid linux-x64 -SetupCommit ('a' * 40) -RuntimeCommit ('c' * 40) -PolicySha256 ('b' * 64) -RuntimeAction reverified -InstallAction current -ProjectionAction current
        $cloud.phase | Should BeExactly 'p9d'
        $cloud.result | Should BeExactly 'completed'
        $cloud.runtimeCommit | Should BeExactly ('c' * 40)
        (@($cloud.steps | Where-Object step -in @('S7','S8','S9') | Select-Object -ExpandProperty status) -join ',') | Should BeExactly 'completed,completed,completed'
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        [regex]::Matches($readme,'(?m)^\| 0 \| `success` \|.*`completed`').Count | Should Be 2
    }

    # Scenario: D13 remains owned by SYP-535 after Linux cloud wiring is enabled.
    # Purpose: Keep K13 explicit and prevent this ticket from claiming that managed CLAUDE.md rules work without pwsh on PATH.
    It 'UnitT45_documents_the_open_K13_limit_without_claiming_P10b_is_unwired' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        $readme | Should Match 'K13.*SYP-535'
        $readme | Should Match 'rules.*cannot run.*PATH.*pwsh'
        $readme | Should Not Match 'P10b (?:尚未接線|is not wired yet)'
    }

    # Scenario: The same immutable source pin is evaluated for Linux first install, rerun, update, macOS and Windows.
    # Purpose: Keep the OS boundary and update-vs-install decision in one deterministic setup planner.
    It 'UnitT46_plans_cloud_wiring_only_for_Linux_and_routes_every_rerun_to_update' {
        $expected = 'a' * 40
        (Get-AgentEnvironmentSetupCloudPlan -Rid linux-x64 -ExpectedCommit $expected -InstalledBundle $null).action | Should BeExactly 'install'
        $current = [pscustomobject]@{ schemaVersion=3; commit=$expected }
        $same = Get-AgentEnvironmentSetupCloudPlan -Rid linux-x64 -ExpectedCommit $expected -InstalledBundle $current
        $same.action | Should BeExactly 'update'
        $same.candidateState | Should BeExactly 'current'
        $older = [pscustomobject]@{ schemaVersion=3; commit=('b' * 40) }
        $move = Get-AgentEnvironmentSetupCloudPlan -Rid linux-arm64 -ExpectedCommit $expected -InstalledBundle $older
        $move.action | Should BeExactly 'update'
        $move.candidateState | Should BeExactly 'new-pin'
        (Get-AgentEnvironmentSetupCloudPlan -Rid osx-arm64 -ExpectedCommit $expected -InstalledBundle $null).action | Should BeExactly 'none'
        (Get-AgentEnvironmentSetupCloudPlan -Rid win-x64 -ExpectedCommit $expected -InstalledBundle $null).action | Should BeExactly 'none'
    }

    # Scenario: The public USER coordinator returns current, applied, concurrent, unmanaged collision, or another failure.
    # Purpose: Translate existing coordinator evidence into stable setup actions and typed exit codes without weakening its assertions.
    It 'UnitT47_maps_existing_projection_results_to_setup_actions_and_typed_refusals' {
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='current';exitCode=0;failureDetails=@()}) -AllowedActions current).action | Should BeExactly 'current'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='applied';exitCode=0;failureDetails=@()}) -AllowedActions @('applied','current')).action | Should BeExactly 'applied'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='planned';exitCode=0;failureDetails=@()}) -AllowedActions @('planned','current')).action | Should BeExactly 'planned'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='planned';exitCode=0;failureDetails=@()}) -AllowedActions @('applied','current')).code | Should BeExactly 'projection-failed'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='failed';exitCode=1;failureDetails=@([pscustomobject]@{code='unmanaged-collision'})}) -AllowedActions @('planned','current')).code | Should BeExactly 'projection-collision'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='concurrent';exitCode=3;failureDetails=@()}) -AllowedActions @('planned','current')).code | Should BeExactly 'concurrent'
        (Resolve-AgentEnvironmentSetupProjectionResult ([pscustomobject]@{outcome='failed';exitCode=1;failureDetails=@([pscustomobject]@{code='mutation-failure'})}) -AllowedActions @('planned','current')).code | Should BeExactly 'projection-failed'
    }

    # Scenario: A verified config excludes one default Skill, while a descendant Catalog retires an installed Skill in favor of its replacement.
    # Purpose: Derive preflight targets with the production selection resolver so excludes and lifecycle migration cannot become false collision/update failures.
    It 'UnitT48_resolves_exact_configured_and_lifecycle_migrated_projection_skill_ids' {
        $catalogText = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'catalog/skills-catalog.json'))
        $selectionSource = [IO.File]::ReadAllText((Join-Path $script:SetupScripts 'skills-selection.psm1'))
        $savedEvidence = [Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE')
        try {
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE',$null)
            $catalog = $catalogText | ConvertFrom-Json
            $configured = [pscustomobject]@{ profiles=@('core'); includeSkills=@(); excludeSkills=@('plan-production-change') }
            $selected = @(Resolve-AgentEnvironmentSetupSkillIds -Catalog $catalog -Selection $configured -CapabilityEvidence @() -InstalledSkillIds @('plan-production-change') -SelectionSource $selectionSource)
            ($selected -join ',') | Should BeExactly 'verify-data-access-performance'

            $retiredCatalog = $catalogText | ConvertFrom-Json
            $retired = @($retiredCatalog.skills | Where-Object id -eq 'plan-production-change')[0]
            $replacement = @($retiredCatalog.skills | Where-Object id -eq 'verify-data-access-performance')[0]
            $retired.lifecycle.status = 'removed'
            $retired.lifecycle | Add-Member -NotePropertyName replacementId -NotePropertyValue 'verify-data-access-performance'
            $replacement.lifecycle.aliases = @('plan-production-change')
            @($retiredCatalog.profiles | Where-Object id -eq 'core')[0].includes = @('verify-data-access-performance')
            $defaults = [pscustomobject]@{ profiles=@(); includeSkills=@(); excludeSkills=@() }
            $migrated = @(Resolve-AgentEnvironmentSetupSkillIds -Catalog $retiredCatalog -Selection $defaults -CapabilityEvidence @() -InstalledSkillIds @('plan-production-change') -SelectionSource $selectionSource)
            ($migrated -join ',') | Should BeExactly 'verify-data-access-performance'

            $absentCatalog = $retiredCatalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $absentCatalog.skills = @($absentCatalog.skills | Where-Object id -ne 'plan-production-change')
            $aliasMigrated = @(Resolve-AgentEnvironmentSetupSkillIds -Catalog $absentCatalog -Selection $defaults -CapabilityEvidence @() -InstalledSkillIds @('plan-production-change') -SelectionSource $selectionSource)
            ($aliasMigrated -join ',') | Should BeExactly 'verify-data-access-performance'
        }
        finally { [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE',$savedEvidence) }
    }

    # Scenario: Child stderr is serialized CLIXML and stdout contains multiple unexpected lines including HOME and a long payload.
    # Purpose: Decode the first human-readable record and report a sanitized, bounded stdout summary without weakening the one-JSON-line contract.
    It 'UnitT49_decodes_serialized_child_errors_and_bounds_unexpected_stdout_diagnostics' {
        $diagnosticHome = Join-Path $TestDrive 'diagnostic-home'
        [void][IO.Directory]::CreateDirectory($diagnosticHome)
        $record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("first $diagnosticHome failure"),'fixture-child',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
        $clixml="#< CLIXML`n"+[Management.Automation.PSSerializer]::Serialize($record)
        (Get-AgentEnvironmentSetupChildErrorLine -Stderr $clixml -UserHome $diagnosticHome) | Should BeExactly 'first ~ failure'

        $textError = "`e[31;1mOperationStopped: $diagnosticHome/install.ps1:825`e[0m`nLine |`n 825 | throw 'fixture'`n     | ~~~~~~~~~~~~~~~`n     | closure-invalid token=fixture-secret"
        $textDiagnostic = Get-AgentEnvironmentSetupChildErrorLine -Stderr $textError -UserHome $diagnosticHome
        $textDiagnostic | Should Match 'OperationStopped: ~/install.ps1:825'
        $textDiagnostic | Should Match 'closure-invalid token=\[REDACTED\]'
        $textDiagnostic | Should Not Match ([regex]::Escape([string][char]27))
        $textDiagnostic | Should Not Match 'fixture-secret'
        $textDiagnostic.Length | Should BeLessOrEqual 512

        . ([scriptblock]::Create((Get-SetupTestEntryFunctionSource ConvertFrom-SetupOwnedJsonResult)))
        $run=[pscustomobject]@{stdout="unexpected $diagnosticHome line`n$((('x'*900)))`n{`"outcome`":`"planned`",`"exitCode`":0}";stderr=''}
        $failure=$null
        try{ConvertFrom-SetupOwnedJsonResult $run projection-failed 'fixture child' $diagnosticHome|Out-Null}catch{$failure=$_}
        $failure|Should Not BeNullOrEmpty
        $failure.Exception.Message|Should Match 'Child stdout summary: unexpected ~ line'
        $failure.Exception.Message.Length|Should BeLessOrEqual 900
    }

    # Scenario: A clean same-pin rerun has no changes, while a missing manifest-owned file is managed drift and personal bytes coexist outside the managed inventory.
    # Purpose: Document the controller decision that same-pin Apply is self-healing only when drift exists and leaves unmanaged bytes untouched.
    It 'UnitT50_documents_clean_idempotence_and_managed_drift_self_healing_in_both_languages' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:SetupRepositoryRoot 'README.md'))
        $readme | Should Match 'clean same-pin rerun.*byte-identical.*managed drift.*repairs'
        $readme | Should Match '乾淨的相同 pin 重跑.*byte-identical.*受管 drift.*修復'
    }

    # Scenario: A real ShouldProcess-aware cmdlet writes WhatIf through the host, while an Apply-mode error uses PowerShell's error stream and a direct encoded child throws.
    # Purpose: Exercise the production encoded child launch so host UI cannot pollute stdout, error records fail closed with matching JSON/process exits, and raw stderr stays Text rather than CLIXML.
    It 'UnitT51_runs_the_coordinator_in_a_hostless_text_child_for_every_mode' {
        function Invoke-SetupOwnedCommand {
            param([string]$RuntimeExecutable,[string[]]$Arguments,[Collections.IDictionary]$Environment,[string]$WorkingDirectory,[string]$FailureCode,[string]$Context,[switch]$AllowNonZero)
            $start=[Diagnostics.ProcessStartInfo]::new($RuntimeExecutable)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$WorkingDirectory
            foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
            foreach($key in $Environment.Keys){$start.Environment[[string]$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            try{
                if(-not$process.Start()){throw 'fixture child could not start'}
                $process.StandardInput.Close()
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
                return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdoutTask.Result;stderr=$stderrTask.Result}
            }finally{$process.Dispose()}
        }

        $encodedSource=Get-SetupTestEntryFunctionSource Invoke-SetupEncodedChild -AllowMissing
        if($null-ne$encodedSource){. ([scriptblock]::Create($encodedSource))}
        . ([scriptblock]::Create((Get-SetupTestEntryFunctionSource Invoke-SetupCoordinatorChild)))
        $probePath=Join-Path $TestDrive 'whatif-must-not-exist'
        $fixturePath=Join-Path $TestDrive 'fixture-coordinator.ps1'
        [IO.File]::WriteAllText($fixturePath,@'
[CmdletBinding(SupportsShouldProcess=$true)]param([string]$CodexHome,[string]$UserHome,[switch]$Apply,[switch]$VerifyOnly,[string]$OutputFormat)
if($WhatIfPreference){New-Item -ItemType Directory -Path ([string]$env:AI_SETUP_TEST_WHATIF_PATH)|Out-Null}
if($Apply-and-not$WhatIfPreference){Write-Error 'fixture apply diagnostic' -ErrorAction Continue}
$outcome=if($WhatIfPreference){'planned'}elseif($Apply){'applied'}else{'current'}
[pscustomobject]@{outcome=$outcome;exitCode=0;failureDetails=@()}|ConvertTo-Json -Compress
exit 0
'@,[Text.UTF8Encoding]::new($false))
        $environment=[ordered]@{HOME=$TestDrive;AI_SETUP_TEST_WHATIF_PATH=$probePath}
        foreach($case in @(@{Mode='WhatIf';Outcome='planned';ExitCode=0},@{Mode='Apply';Outcome='applied';ExitCode=1},@{Mode='VerifyOnly';Outcome='current';ExitCode=0})){
            $run=Invoke-SetupCoordinatorChild -RuntimeExecutable ([Environment]::ProcessPath) -EntryPath $fixturePath -CodexHome (Join-Path $TestDrive '.codex') -UserHome $TestDrive -Mode $case.Mode -Environment $environment -WorkingDirectory $TestDrive
            $run.exitCode|Should Be $case.ExitCode
            $lines=@(([string]$run.stdout).Split("`n")|ForEach-Object{$_.Trim()}|Where-Object{$_.Length-gt0})
            $lines.Count|Should Be 1
            $json=$lines[0]|ConvertFrom-Json
            $json.outcome|Should BeExactly $case.Outcome
            [int]$json.exitCode|Should Be $case.ExitCode
            if($case.Mode-ceq'Apply'){
                $run.stderr|Should Match 'fixture apply diagnostic'
                (Resolve-AgentEnvironmentSetupProjectionResult $json -AllowedActions @('applied','current')).code|Should BeExactly 'projection-failed'
            }
        }
        Test-Path -LiteralPath $probePath|Should Be $false

        $directError=Invoke-SetupEncodedChild -RuntimeExecutable ([Environment]::ProcessPath) -Script "throw [InvalidOperationException]::new('fixture encoded diagnostic')" -Environment $environment -WorkingDirectory $TestDrive -FailureCode projection-failed -Context 'fixture encoded child' -AllowNonZero
        $directError.exitCode|Should Not Be 0
        $directError.stderr|Should Match 'fixture encoded diagnostic'
        $directError.stderr|Should Not Match '^#< CLIXML'
    }
    # Scenario: A failed coordinator result includes five details, HOME paths and credential-shaped values.
    # Purpose: Keep the first failure and three actionable details visible in a bounded, sanitized single line.
    It 'UnitT52_summarizes_failed_projection_JSON_without_exposing_HOME_or_secrets' {
        $diagnosticHome = Join-Path $TestDrive 'projection-summary-home'
        $details = @(1..5 | ForEach-Object {
            [pscustomobject]@{code="detail-$_";skillId="skill-$_";path="$diagnosticHome/.claude/x";evidence="token=fixture-secret`n evidence";remediation=@("repair $_`nsecond-line",'later-remediation')}
        })
        $result = [pscustomobject]@{outcome='failed';exitCode=1;Code='some-code';failed=@('first failure','later failure');failureDetails=$details}
        $summary = Get-AgentEnvironmentSetupProjectionResultSummary -Result $result -UserHome $diagnosticHome
        $summary | Should Match 'outcome=failed; exitCode=1; Code=some-code'
        $summary | Should Match 'failed=first failure'
        foreach ($number in 1..3) { $summary | Should Match "code=detail-$number" }
        $summary | Should Match 'skillId=skill-1'
        $summary | Should Match 'path=~/.claude/x'
        $summary | Should Match 'evidence=token=\[REDACTED\] evidence'
        $summary | Should Match 'remediation=repair 1'
        $summary | Should Match '\(\+2 more\)'
        $summary | Should Not Match 'detail-[45]|later failure|second-line|later-remediation|fixture-secret|[\r\n]'
        $summary | Should Not Match ([regex]::Escape($diagnosticHome))
        $summary.Length | Should BeLessOrEqual 1024
    }

    # Scenario: Coordinator JSON has absent/null fields, scalar collections or a single detail object.
    # Purpose: Ensure diagnostics never obscure a refusal by throwing on incomplete or oddly typed JSON.
    It 'UnitT53_tolerates_missing_null_and_scalar_projection_result_fields' {
        foreach ($result in @($null,[pscustomobject]@{},42,[pscustomobject]@{Code=$null;failed=42;failureDetails='odd'},[pscustomobject]@{Code=$null;failureDetails=@($null,42)})) {
            { Get-AgentEnvironmentSetupProjectionResultSummary -Result $result -UserHome $TestDrive } | Should Not Throw
            $summary = Get-AgentEnvironmentSetupProjectionResultSummary -Result $result -UserHome $TestDrive
            $summary | Should Match 'outcome=<none>; exitCode=<none>; Code=<none>'
        }
        $single = [pscustomobject]@{Code=$null;failureDetails=[pscustomobject]@{code='single-detail';remediation="first line`nsecond line"}}
        $summary = Get-AgentEnvironmentSetupProjectionResultSummary -Result $single -UserHome $TestDrive
        $summary | Should Match 'Code=<none>'
        $summary | Should Match 'code=single-detail; skillId=<none>; path=<none>; evidence=<none>; remediation=first line'
        $summary | Should Not Match 'second line'
    }

    # Scenario: Every coordinator field is longer than a diagnostic line and five details are returned.
    # Purpose: Cap individual fields and the entire summary while retaining the omitted-detail count.
    It 'UnitT54_bounds_projection_summary_fields_and_retains_the_truncation_marker' {
        $long = 'x' * 2000
        $result = [pscustomobject]@{outcome=$long;exitCode=$long;Code=$long;failed=$long;failureDetails=@(1..5 | ForEach-Object { [pscustomobject]@{code=$long;skillId=$long;path=$long;evidence=$long;remediation=$long} })}
        $summary = Get-AgentEnvironmentSetupProjectionResultSummary -Result $result -UserHome $TestDrive
        $summary.Length | Should BeLessOrEqual 1024
        $summary | Should Match 'outcome=x{157}\.\.\.;'
        $summary | Should Not Match 'x{158}'
        $summary | Should Match '\.\.\..*\(\+2 more\)$'
    }

    # Scenario: The real coordinator child emits failed JSON with empty stderr during WhatIf.
    # Purpose: Execute the production preflight's coordinator/refusal tail, isolating earlier install/bootstrap work, and preserve its typed refusal with sanitized JSON evidence.
    It 'UnitT55_reports_failed_WhatIf_JSON_in_the_production_refusal_with_empty_stderr' {
        function Invoke-SetupOwnedCommand {
            param([string]$RuntimeExecutable,[string[]]$Arguments,[Collections.IDictionary]$Environment,[string]$WorkingDirectory,[string]$FailureCode,[string]$Context,[switch]$AllowNonZero)
            $start=[Diagnostics.ProcessStartInfo]::new($RuntimeExecutable)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$WorkingDirectory
            foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
            foreach($key in $Environment.Keys){$start.Environment[[string]$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            try{
                if(-not$process.Start()){throw 'fixture child could not start'}
                $process.StandardInput.Close()
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
                return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdoutTask.Result;stderr=$stderrTask.Result}
            }finally{$process.Dispose()}
        }
        foreach ($name in @('Invoke-SetupEncodedChild','Invoke-SetupCoordinatorChild','ConvertFrom-SetupOwnedJsonResult')) {
            . ([scriptblock]::Create((Get-SetupTestEntryFunctionSource $name)))
        }
        $UserHome = Join-Path $TestDrive 'refusal-home'
        [void][IO.Directory]::CreateDirectory($UserHome)
        $CodexHome = Join-Path $UserHome '.codex'
        $RepositoryRoot = $TestDrive
        $RuntimeExecutable = [Environment]::ProcessPath
        $Environment = [ordered]@{HOME=$UserHome;USERPROFILE=$UserHome;CODEX_HOME=$CodexHome}
        $environmentEntry = Join-Path $TestDrive 'fixture-refusing-coordinator.ps1'
        [IO.File]::WriteAllText($environmentEntry,@'
[CmdletBinding(SupportsShouldProcess=$true)]param([string]$CodexHome,[string]$UserHome,[switch]$Apply,[switch]$VerifyOnly,[string]$OutputFormat)
[pscustomobject]@{outcome='failed';exitCode=1;Code='some-code';failureDetails=@([pscustomobject]@{code='mutation-failure';path="$UserHome/.claude/x";evidence='token=fixture-secret'})}|ConvertTo-Json -Depth 5 -Compress
exit 1
'@,[Text.UTF8Encoding]::new($false))
        $preflightSource = Get-SetupTestEntryFunctionSource Invoke-SetupProjectionCollisionPreflight
        $start = $preflightSource.IndexOf('$preflightRun=Invoke-SetupCoordinatorChild',[StringComparison]::Ordinal)
        $start | Should BeGreaterThan 0
        $refusalTail = $preflightSource.Substring($start,$preflightSource.LastIndexOf('}')-$start)
        $failure = $null
        try { & ([scriptblock]::Create($refusalTail)) } catch { $failure = $_ }
        $failure | Should Not BeNullOrEmpty
        $message = $failure.Exception.Message
        $message | Should Match '^USER projection WhatIf was refused before runtime mutation\.'
        foreach ($expected in @('Child result:','outcome=failed','Code=some-code','mutation-failure','~/.claude/x','token=[REDACTED]','Child stderr: <empty>','[agent-environment-setup-code=projection-failed]')) {
            $message | Should Match ([regex]::Escape($expected))
        }
        $message | Should Not Match ([regex]::Escape($UserHome))
        $message | Should Not Match 'fixture-secret'
        (Get-AgentEnvironmentSetupRefusalCode $failure) | Should BeExactly 'projection-failed'
    }

    # Scenario: The coordinator emits only a failed reason for a 403 archive download, with no failureDetails and empty stderr.
    # Purpose: Preserve that reason in the production WhatIf refusal and the result summary shared by Apply and VerifyOnly.
    It 'UnitT56_reports_failed_only_WhatIf_JSON_in_the_production_refusal_with_empty_stderr' {
        $coordinatorRuns = [Collections.Generic.List[object]]::new()
        function Invoke-SetupOwnedCommand {
            param([string]$RuntimeExecutable,[string[]]$Arguments,[Collections.IDictionary]$Environment,[string]$WorkingDirectory,[string]$FailureCode,[string]$Context,[switch]$AllowNonZero)
            $start=[Diagnostics.ProcessStartInfo]::new($RuntimeExecutable)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$WorkingDirectory
            foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
            foreach($key in $Environment.Keys){$start.Environment[[string]$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            try{
                if(-not$process.Start()){throw 'fixture child could not start'}
                $process.StandardInput.Close()
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
                $run=[pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdoutTask.Result;stderr=$stderrTask.Result}
                $coordinatorRuns.Add($run)
                return $run
            }finally{$process.Dispose()}
        }
        foreach ($name in @('Invoke-SetupEncodedChild','Invoke-SetupCoordinatorChild','ConvertFrom-SetupOwnedJsonResult')) {
            . ([scriptblock]::Create((Get-SetupTestEntryFunctionSource $name)))
        }
        $UserHome = Join-Path $TestDrive 'failed-only-refusal-home'
        [void][IO.Directory]::CreateDirectory($UserHome)
        $CodexHome = Join-Path $UserHome '.codex'
        $RepositoryRoot = $TestDrive
        $RuntimeExecutable = [Environment]::ProcessPath
        $Environment = [ordered]@{HOME=$UserHome;USERPROFILE=$UserHome;CODEX_HOME=$CodexHome}
        $failedJson = '{"schemaVersion":1,"outcome":"failed","exitCode":1,"Code":null,"runtimeCommit":null,"catalogCommit":null,"installed":[],"updated":[],"removed":[],"preserved":[],"failed":["Response status code does not indicate success: 403 (Forbidden)."],"rollbackState":"not-started","backupPath":null}'
        $environmentEntry = Join-Path $TestDrive 'fixture-failed-only-coordinator.ps1'
        $fixtureSource = @(
            '[CmdletBinding(SupportsShouldProcess=$true)]param([string]$CodexHome,[string]$UserHome,[switch]$Apply,[switch]$VerifyOnly,[string]$OutputFormat)'
            "'$failedJson'"
            'exit 1'
        ) -join "`n"
        [IO.File]::WriteAllText($environmentEntry,$fixtureSource,[Text.UTF8Encoding]::new($false))
        $failedReason = 'failed=Response status code does not indicate success: 403 (Forbidden).'
        # Apply and VerifyOnly use the same summary for this result shape.
        $summary = Get-AgentEnvironmentSetupProjectionResultSummary -Result ($failedJson | ConvertFrom-Json) -UserHome $UserHome
        $summary | Should Match ([regex]::Escape($failedReason))

        $preflightSource = Get-SetupTestEntryFunctionSource Invoke-SetupProjectionCollisionPreflight
        $start = $preflightSource.IndexOf('$preflightRun=Invoke-SetupCoordinatorChild',[StringComparison]::Ordinal)
        $start | Should BeGreaterThan 0
        $refusalTail = $preflightSource.Substring($start,$preflightSource.LastIndexOf('}')-$start)
        $failure = $null
        try { & ([scriptblock]::Create($refusalTail)) } catch { $failure = $_ }
        $coordinatorRuns.Count | Should Be 1
        $coordinatorRuns[0].exitCode | Should Be 1
        $coordinatorRuns[0].stdout | Should BeExactly ($failedJson + [Environment]::NewLine)
        $coordinatorRuns[0].stderr | Should BeExactly ''
        $failure | Should Not BeNullOrEmpty
        $message = $failure.Exception.Message
        $message | Should Match '^USER projection WhatIf was refused before runtime mutation\.'
        foreach ($expected in @('outcome=failed','Code=<none>',$failedReason,'Child stderr: <empty>','[agent-environment-setup-code=projection-failed]')) {
            $message | Should Match ([regex]::Escape($expected))
        }
        $message | Should Not Match 'failureDetails\['
        (Get-AgentEnvironmentSetupRefusalCode $failure) | Should BeExactly 'projection-failed'
    }

    # Scenario: A default stderr line exceeds 160 characters and a canonical refusal carries a failure reason after character 1500.
    # Purpose: Preserve the default truncation while larger bounds retain the full refusal with HOME and secrets sanitized.
    It 'UnitT57_preserves_default_child_error_bounds_and_full_sanitized_canonical_refusals' {
        (Get-AgentEnvironmentSetupChildErrorLine -Stderr ('x' * 200) -UserHome $TestDrive) | Should BeExactly (('x' * 157) + '...')

        $diagnosticHome = Join-Path $TestDrive 'canonical-refusal-home'
        $prefix = 'setup-agent-environment: USER projection WhatIf was refused before runtime mutation. Child result: ' + ('x' * 1450)
        $failedReason = 'failed=Response status code does not indicate success: 403 (Forbidden).'
        $refusal = "$prefix; $failedReason Child stderr: $diagnosticHome/.claude/x token=fixture-secret [agent-environment-setup-code=projection-failed]"
        $refusal.IndexOf($failedReason,[StringComparison]::Ordinal) | Should BeGreaterThan 1500
        $summary = Get-AgentEnvironmentSetupChildErrorLine -Stderr $refusal -UserHome $diagnosticHome -MaxLineLength 2048 -MaxLength 4096
        $summary | Should BeExactly "$prefix; $failedReason Child stderr: ~/.claude/x token=[REDACTED] [agent-environment-setup-code=projection-failed]"
        $summary | Should Match ([regex]::Escape($failedReason))
        $summary | Should Not Match ([regex]::Escape($diagnosticHome))
        $summary | Should Not Match 'fixture-secret'
    }

    # Scenario: The outer stage summarizes the canonical child's stderr before reporting or rethrowing its refusal.
    # Purpose: Keep that call site's bounds large enough for the canonical refusal instead of applying the default 160/512 caps again.
    It 'UnitT58_uses_larger_child_error_bounds_only_at_the_outer_canonical_stage' {
        $entryText = [IO.File]::ReadAllText($script:SetupEntryPath)
        $canonicalCalls = @([regex]::Matches($entryText,'(?m)^\s*\$canonicalChildError\s*=\s*(Get-AgentEnvironmentSetupChildErrorLine[^\r\n]*)'))
        $canonicalCalls.Count | Should Be 1
        $callSource = $canonicalCalls[0].Groups[1].Value
        $callSource | Should Match '-Stderr\s+\(\[string\]\$child\.stderr\)'
        $callSource | Should Match '-UserHome\s+\$userHome\b'
        $callSource | Should Match '-MaxLineLength\s+2048\b'
        $callSource | Should Match '-MaxLength\s+4096\b'
        @([regex]::Matches($entryText,'Get-AgentEnvironmentSetupChildErrorLine[^\r\n]*-MaxLineLength')).Count | Should Be 1
    }

    # Scenario: Linux cloud wiring chooses a first install, a new-pin update, or a same-pin validation.
    # Purpose: Require the shared blob verifier before either installer execution path and keep it out of same-pin validation.
    It 'UnitT59_verifies_the_installer_before_each_cloud_execution_path' {
        $cloudFunction = Get-SetupTestEntryFunctionSource Invoke-SetupLinuxCloudWiring
        $installBranch = [regex]::Match($cloudFunction,'(?s)if\(\$cloudPlan\.action-ceq''install''\)\{(.*?)\r?\n    \}else\{').Groups[1].Value
        $samePinBranch = [regex]::Match($cloudFunction,'(?s)if\(\$current-ceq\$ExpectedCommit\)\{(.*?)\r?\n        \}else\{').Groups[1].Value
        $updateBranch = [regex]::Match($cloudFunction,'(?s)\$installAction=''current''\s*\}else\{(.*?)\r?\n        \}').Groups[1].Value

        $installBranch | Should Match '(?s)Assert-SetupVerifierTrustedBlob.*?Invoke-SetupOwnedCommand[^\r\n]*Linux V3V5 installer'
        $samePinBranch | Should Match 'Linux same-pin validation child'
        $samePinBranch | Should Not Match 'Assert-SetupVerifierTrustedBlob'
        $updateBranch | Should Match '(?s)Assert-SetupVerifierTrustedBlob.*?Invoke-SetupLinuxUpdaterChild'
        (Get-SetupTestEntryFunctionSource Assert-SetupBootstrapTrust) | Should Match 'Assert-SetupVerifierTrustedBlob'
    }

    # Scenario: A committed file is verified, edited, staged, and restored in a disposable Git repository.
    # Purpose: Detect both raw worktree drift and staged substitutions, and verify clean bytes repeatedly.
    It 'UnitT60_compares_expected_index_and_raw_worktree_blobs' {
        foreach ($name in @('New-SetupEarlyFailure','Invoke-SetupVerifierGit','Assert-SetupVerifierRegularFile','Assert-SetupVerifierTrustedBlob')) {
            . ([scriptblock]::Create((Get-SetupTestEntryFunctionSource $name)))
        }
        $gitPath = [string](Get-Command git -CommandType Application | Select-Object -First 1).Source
        $root = Join-Path $TestDrive 'trusted-blob'
        [void][IO.Directory]::CreateDirectory($root)
        $relative = 'installer.ps1'
        $path = Join-Path $root $relative
        [IO.File]::WriteAllText($path, '# original')
        & $gitPath -C $root init -q
        $LASTEXITCODE | Should Be 0
        & $gitPath -C $root add -- $relative
        $LASTEXITCODE | Should Be 0
        & $gitPath -C $root -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m fixture
        $LASTEXITCODE | Should Be 0
        $expected = [string](& $gitPath -C $root rev-parse HEAD)
        $verify = { Assert-SetupVerifierTrustedBlob -GitPath $gitPath -RepositoryRoot $root -ExpectedCommit $expected -RelativePath $relative }

        $verify | Should Not Throw
        [IO.File]::WriteAllText($path, '# changed')
        $verify | Should Throw
        & $gitPath -C $root add -- $relative
        $LASTEXITCODE | Should Be 0
        $verify | Should Throw

        & $gitPath -C $root checkout $expected -- $relative
        $LASTEXITCODE | Should Be 0
        $verify | Should Not Throw
        $verify | Should Not Throw
    }

    # Scenario: Setup and test diagnostics contain authorization headers and standalone authentication schemes.
    # Purpose: Redact complete header values, preserve line boundaries, and keep repeated sanitization stable.
    It 'UnitT61_redacts_complete_authorization_values_in_setup_and_test_diagnostics' {
        $cases = @(
            @{ Input = 'Authorization: Bearer example-token'; Expected = 'Authorization: [REDACTED]' }
            @{ Input = 'Proxy-Authorization: Basic example-credential'; Expected = 'Proxy-Authorization: [REDACTED]' }
            @{ Input = 'authorization: bearer x'; Expected = 'authorization: [REDACTED]' }
            @{ Input = 'authorization=Basic x'; Expected = 'authorization=[REDACTED]' }
            @{ Input = 'authorization=''Basic abc'''; Expected = 'authorization=[REDACTED]' }
            @{ Input = '{"Authorization": "Bearer abc123"}'; Expected = '{"Authorization": [REDACTED]' }
            @{ Input = 'Basic dXNlcjpwYXNz'; Expected = 'Basic [REDACTED]' }
            @{ Input = 'Bearer abc'; Expected = 'Bearer [REDACTED]' }
            @{ Input = "first line ok`r`nAUTHORIZATION: Custom value with spaces`r`nnext line ok`nlast line ok"; Expected = "first line ok`r`nAUTHORIZATION: [REDACTED]`r`nnext line ok`nlast line ok" }
            @{ Input = 'token=example-token; next field ok'; Expected = 'token=[REDACTED]; next field ok' }
        )
        foreach ($case in $cases) {
            $setup = ConvertTo-AgentEnvironmentSetupSanitizedText $case.Input $TestDrive
            $diagnostic = ConvertTo-SetupTestDiagnosticStderr $case.Input
            $setup | Should BeExactly $case.Expected
            $diagnostic | Should BeExactly $case.Expected
            (ConvertTo-AgentEnvironmentSetupSanitizedText $setup $TestDrive) | Should BeExactly $setup
            (ConvertTo-SetupTestDiagnosticStderr $diagnostic) | Should BeExactly $diagnostic
        }

        $url = ConvertTo-AgentEnvironmentSetupSanitizedText 'https://user:pass@example.test/path' $TestDrive
        $url | Should BeExactly 'https://[REDACTED]@example.test/path'
        (ConvertTo-AgentEnvironmentSetupSanitizedText $url $TestDrive) | Should BeExactly $url
    }
}

# Register only on the native host; keep this file's Core CI skip count at zero.
if ($setupTestIsWindows) {
Describe 'setup-agent-environment Git for Windows autocrlf trust closure (SYP-518)' {
    BeforeAll {
        $script:AutoCrlfRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $entryText = [IO.File]::ReadAllText((Join-Path $script:AutoCrlfRepositoryRoot 'scripts/setup-agent-environment.ps1'))
        $setupBoundMatch = [regex]::Match($entryText,'(?ms)\$setupBound\s*=\s*@\((.*?)\)\s*\r?\n\s*\$trustFiles')
        if (-not $setupBoundMatch.Success) { throw 'The setup verifier trust closure cannot be parsed.' }
        $setupBound = @([regex]::Matches($setupBoundMatch.Groups[1].Value,"'([^']+)'") | ForEach-Object { [string]$_.Groups[1].Value })
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:AutoCrlfRepositoryRoot 'scripts/platform-runtime.psd1')
        $script:AutoCrlfTrustClosure = @($setupBound + @($manifest.FileList | ForEach-Object { 'scripts/' + [string]$_ }) | Select-Object -Unique)

        $script:AutoCrlfFixtureSource = Join-Path $TestDrive 'autocrlf-source'
        $script:AutoCrlfFixtureClone = Join-Path $TestDrive 'autocrlf-clone'
        [void][IO.Directory]::CreateDirectory($script:AutoCrlfFixtureSource)
        Copy-Item -LiteralPath (Join-Path $script:AutoCrlfRepositoryRoot '.gitattributes') -Destination $script:AutoCrlfFixtureSource
        foreach ($relative in $script:AutoCrlfTrustClosure) {
            $target = Join-Path $script:AutoCrlfFixtureSource $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath (Join-Path $script:AutoCrlfRepositoryRoot $relative) -Destination $target
        }
        [IO.File]::WriteAllText((Join-Path $script:AutoCrlfFixtureSource 'uncovered.txt'),"negative`ncontrol`n",[Text.UTF8Encoding]::new($false))
        & git -C $script:AutoCrlfFixtureSource init -q 2>$null | Out-Null
        & git -C $script:AutoCrlfFixtureSource -c core.autocrlf=false add -A 2>$null | Out-Null
        & git -C $script:AutoCrlfFixtureSource -c user.name=setup-test -c user.email=setup-test@example.invalid -c core.autocrlf=false commit -q -m fixture 2>$null | Out-Null
        & git -c core.autocrlf=true clone -q --no-local $script:AutoCrlfFixtureSource $script:AutoCrlfFixtureClone 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The core.autocrlf=true fixture clone failed.' }
    }

    # Scenario: Git for Windows checks out a fresh repository with core.autocrlf=true while the setup verifier hashes raw worktree bytes.
    # Purpose: Keep every verifier-derived trust-closure file byte-identical to its committed blob, with an uncovered text file proving the negative control converts to CRLF.
    It 'InterT10_keeps_the_raw_setup_trust_closure_equal_to_HEAD_in_an_autocrlf_clone' {
        $mismatches = foreach ($relative in $script:AutoCrlfTrustClosure) {
            $expected = [string](& git -C $script:AutoCrlfFixtureClone rev-parse "HEAD:$relative" 2>$null)
            $raw = [string](& git -C $script:AutoCrlfFixtureClone hash-object --no-filters -- (Join-Path $script:AutoCrlfFixtureClone $relative) 2>$null)
            if ($expected -cne $raw) { $relative }
        }
        @($mismatches).Count | Should Be 0

        $negativeExpected = [string](& git -C $script:AutoCrlfFixtureClone rev-parse 'HEAD:uncovered.txt' 2>$null)
        $negativeRaw = [string](& git -C $script:AutoCrlfFixtureClone hash-object --no-filters -- (Join-Path $script:AutoCrlfFixtureClone 'uncovered.txt') 2>$null)
        $negativeRaw | Should Not BeExactly $negativeExpected
        [string](& git -C $script:AutoCrlfFixtureClone ls-files --eol -- uncovered.txt 2>$null) | Should Match 'w/crlf'
    }
}

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
            $Run.Json.powerShell.executablePath | Should Match ("^~/\.local/share/ai-instructions-setup/pwsh/" + [regex]::Escape("$($script:WinVersion)-$($script:WinRid)-") + '[a-f0-9]{32}/pwsh\.exe$')
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

        function Set-WinSetupDurabilityHook {
            param([AllowNull()][scriptblock]$Hook)
            $setupModules = @(Get-Module agent-environment-setup)
            if ($setupModules.Count -ne 1) { throw "Expected one loaded agent-environment-setup module; found $($setupModules.Count)." }
            $runtimeModule = & $setupModules[0] { $script:AgentEnvironmentSetupPlatformRuntime }
            if ($null -eq $runtimeModule) { throw 'The setup module has no bound platform-runtime module instance.' }
            $windowsPath = [IO.Path]::GetFullPath((Join-Path $runtimeModule.ModuleBase 'platform/Windows.psm1'))
            $windowsModules = @($runtimeModule.NestedModules | Where-Object {
                $_.Name -ceq 'Windows' -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$_.Path),$windowsPath)
            })
            if ($windowsModules.Count -ne 1) { throw "Expected one Windows nested module at '$windowsPath'; found $($windowsModules.Count)." }
            & $windowsModules[0] { param($Value) $script:WindowsPublicationDurabilityTestHook = $Value } $Hook
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
        $runtimeReceipt = [IO.File]::ReadAllText((Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf))
        $runtimeReceipt.Contains($fixture.Home) | Should Be $false
        $runtimeReceiptObject = $runtimeReceipt | ConvertFrom-Json
        $runtimeReceiptObject.executablePath | Should BeExactly $run.Json.powerShell.executablePath
        Test-Path -LiteralPath (ConvertFrom-AgentEnvironmentSetupHomePath $runtimeReceiptObject.executablePath $fixture.Home) -PathType Leaf | Should Be $true
    }

    # Scenario: --prepare runs again while secret markers and malicious Git configuration sit in the caller environment.
    # Purpose: H4 re-verifies without Resolve under isolated Git helpers, keeps runtime bytes unchanged and never leaks the markers.
    It 'InterT2_reruns_prepare_as_reverification_with_unchanged_runtime_bytes_and_no_secret_leak' {
        $fixture = New-WinFixture 'prepare-rerun'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $before = Get-WinRuntimeSnapshot $fixture
        $marker = 'p10a-secret-' + [guid]::NewGuid().ToString('N')
        $gitConfig = Join-Path $script:WinRoot ('poison-git-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($gitConfig,"this is not valid git config`n")
        # DOTNET_STARTUP_HOOKS is exercised after host startup by UnitT22. An
        # invalid hook injected into ProcessStartInfo is consumed by .NET before
        # this script can run, so it cannot test the setup re-exec allowlist.
        $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home -Environment @{
            SYP_P10A_SECRET_TOKEN=$marker; HTTPS_PROXY="http://user:$marker@127.0.0.1:9"; POWERSHELL_TELEMETRY_OPTOUT=$marker
            GIT_CONFIG_GLOBAL=$gitConfig; GIT_CONFIG_NOSYSTEM='0'; GIT_DIR=(Join-Path $script:WinRoot 'not-a-repository')
            GIT_WORK_TREE=(Join-Path $script:WinRoot 'not-a-worktree'); GIT_CONFIG_COUNT='1'; GIT_CONFIG_KEY_0='core.fsmonitor'; GIT_CONFIG_VALUE_0=$gitConfig
        }
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
        Test-Path -LiteralPath $fixture.Layout.RuntimeParentDirectory | Should Be $false
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
        $runtimeReceipt = Get-Content -Raw -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | ConvertFrom-Json
        $runtimeRoot = ConvertFrom-AgentEnvironmentSetupHomePath $runtimeReceipt.runtimeClosure.rootPath $fixture.Home
        $victim = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Filter '*.json' | Sort-Object Length | Select-Object -First 1)[0]
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
        $runtimeReceipt = Get-Content -Raw -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | ConvertFrom-Json
        $runtimeRoot = ConvertFrom-AgentEnvironmentSetupHomePath $runtimeReceipt.runtimeClosure.rootPath $fixture.Home
        Copy-Item -LiteralPath $runtimeRoot -Destination $copyDirectory -Recurse
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
        foreach($point in @('after-transaction-directory','after-transaction-directory-durable','after-journal-stage','after-journal','after-parent-directory','after-parent-directory-durable','during-stage-write','after-stage','after-rename','after-displaced-cleanup','after-journal-cleanup','after-transaction-cleanup')){
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

    # Scenario: The real entry process aborts after a unique runtime directory is renamed into pwsh/ but before its pointer receipt is published.
    # Purpose: H1 proves the next real entry uses a new directory, leaves the unreferenced orphan untouched, publishes a valid pointer, and releases the lock.
    It 'InterT15_recovers_a_post_directory_publish_abort_with_a_new_receipt_pointer' {
        $fixture = New-WinFixture 'runtime-pointer-abort'
        $crashed = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home -Environment @{ AI_INSTRUCTIONS_SETUP_FAILPOINT='after-runtime-directory-published' }
        $crashed.ExitCode | Should Not Be 0
        $published = @(Get-ChildItem -LiteralPath $fixture.Layout.RuntimeParentDirectory -Directory -Force | Where-Object { $_.Name.StartsWith($fixture.Layout.RuntimeLeafPrefix,[StringComparison]::Ordinal) })
        $published.Count | Should Be 1
        $orphan = $published[0]
        $orphanSnapshot = Get-WinTreeSnapshot $orphan.FullName
        $orphanMtime = $orphan.LastWriteTimeUtc.Ticks
        Test-Path -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | Should Be $false

        $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $run $fixture 'prepared-runtime-only' 'resolved'
        $stored = Get-Content -Raw -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | ConvertFrom-Json
        $currentRoot = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$stored.runtimeClosure.rootPath) $fixture.Home
        $currentRoot | Should Not Be $orphan.FullName
        Test-Path -LiteralPath $orphan.FullName -PathType Container | Should Be $true
        (Get-WinTreeSnapshot $orphan.FullName) | Should BeExactly $orphanSnapshot
        (Get-Item -LiteralPath $orphan.FullName).LastWriteTimeUtc.Ticks | Should Be $orphanMtime
        Assert-WinLockReleased $fixture
    }

    # Scenario: Real child processes abort before stage creation, after a verified stage, and after the pointer receipt rename.
    # Purpose: H1 gives every runtime-publication crash point exactly one decision: fresh attempt, preserve stage orphan, or reverify the receipt-named runtime.
    It 'InterT15a_models_each_runtime_publication_crash_state_through_the_real_entry' {
        $arguments = @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)

        $beforeFixture = New-WinFixture 'runtime-before-stage-abort'
        $beforeCrash = Invoke-WinSetup $arguments -UserHome $beforeFixture.Home -Environment @{ AI_INSTRUCTIONS_SETUP_FAILPOINT='before-runtime-stage-created'; AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$beforeFixture.Layout.RuntimeReceiptLeaf }
        $beforeCrash.ExitCode | Should Not Be 0
        @(Get-ChildItem -LiteralPath $beforeFixture.Layout.RuntimeParentDirectory -Force).Count | Should Be 0
        Assert-WinLockReleased $beforeFixture
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $beforeFixture.Home) $beforeFixture 'prepared-runtime-only' 'resolved'

        $stageFixture = New-WinFixture 'runtime-stage-abort'
        $stageCrash = Invoke-WinSetup $arguments -UserHome $stageFixture.Home -Environment @{ AI_INSTRUCTIONS_SETUP_FAILPOINT='after-runtime-stage-verified'; AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$stageFixture.Layout.RuntimeReceiptLeaf }
        $stageCrash.ExitCode | Should Not Be 0
        $stages = @(Get-ChildItem -LiteralPath $stageFixture.Layout.RuntimeParentDirectory -Directory -Force -Recurse | Where-Object { $_.Name -match '^\.stage-[a-f0-9]{32}$' })
        $stages.Count | Should Be 1
        $stageSnapshot = Get-WinTreeSnapshot $stages[0].FullName
        $stageMtime = $stages[0].LastWriteTimeUtc.Ticks
        Assert-WinLockReleased $stageFixture
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $stageFixture.Home) $stageFixture 'prepared-runtime-only' 'resolved'
        (Get-WinTreeSnapshot $stages[0].FullName) | Should BeExactly $stageSnapshot
        (Get-Item -LiteralPath $stages[0].FullName).LastWriteTimeUtc.Ticks | Should Be $stageMtime

        $receiptFixture = New-WinFixture 'runtime-receipt-published-abort'
        $receiptCrash = Invoke-WinSetup $arguments -UserHome $receiptFixture.Home -Environment @{ AI_INSTRUCTIONS_SETUP_FAILPOINT='after-rename'; AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$receiptFixture.Layout.RuntimeReceiptLeaf }
        $receiptCrash.ExitCode | Should Not Be 0
        $receiptPath = Join-Path $receiptFixture.Layout.ReceiptDirectory $receiptFixture.Layout.RuntimeReceiptLeaf
        Test-Path -LiteralPath $receiptPath -PathType Leaf | Should Be $true
        $receiptBefore = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
        $rootBefore = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$receiptBefore.runtimeClosure.rootPath) $receiptFixture.Home
        Assert-WinLockReleased $receiptFixture
        $recovered = Invoke-WinSetup $arguments -UserHome $receiptFixture.Home
        Assert-WinSuccessReceipt $recovered $receiptFixture 'prepared-runtime-only' 'reverified'
        $receiptAfter = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
        (ConvertFrom-AgentEnvironmentSetupHomePath ([string]$receiptAfter.runtimeClosure.rootPath) $receiptFixture.Home) | Should BeExactly $rootBefore
    }

    # Scenario: HOME exists on Windows but its DACL denies this user permission to create the setup root.
    # Purpose: H6 maps the setup-root access denial to the shared home-invalid typed refusal instead of internal-error.
    It 'InterT16_refuses_an_unwritable_windows_HOME_as_home_invalid' {
        $fixture = New-WinFixture 'unwritable-home'
        $homeLease = Open-PlatformDirectory -Root $fixture.Home -RootOnly
        $snapshot = $null
        try {
            $snapshot = Get-PlatformPermissions -Lease $homeLease
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            [void](Set-PlatformPermissions -Lease $homeLease -Policy @{ Sddl="D:P(D;;DCLC;;;$sid)(A;OICI;FA;;;$sid)"; ReadOnly=$false })
            $before = Get-WinTreeSnapshot $fixture.Home
            $run = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 12
            $run.Json.code | Should Be 'home-invalid'
            (Get-WinTreeSnapshot $fixture.Home) | Should BeExactly $before
        } finally {
            if ($null -ne $snapshot) { [void](Set-PlatformPermissions -Lease $homeLease -Snapshot $snapshot) }
            $homeLease.Dispose()
        }
    }

    # Scenario: The receipt-named runtime root keeps its contents but its private permissions drift before an offline rerun.
    # Purpose: H5 ensures the real --offline entry refuses permission drift through K15 rather than re-executing the runtime.
    It 'InterT17_offline_refuses_receipt_named_runtime_permission_drift' {
        $fixture = New-WinFixture 'offline-permission-drift'
        $initial = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $initial $fixture 'prepared-runtime-only' 'resolved'
        $stored = Get-Content -Raw -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | ConvertFrom-Json
        $runtimeRoot = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$stored.runtimeClosure.rootPath) $fixture.Home
        $runtimeLease = Open-PlatformDirectory -Root $runtimeRoot -RootOnly
        $snapshot = $null
        try {
            $snapshot = Get-PlatformPermissions -Lease $runtimeLease
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            [void](Set-PlatformPermissions -Lease $runtimeLease -Policy @{ Sddl="D:P(A;OICI;FA;;;$sid)(A;OICI;FA;;;WD)"; ReadOnly=$false })
            $run = Invoke-WinSetup @('-Offline','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
            $run.ExitCode | Should Be 23
            $run.Json.code | Should Be 'runtime-verification-failed'
        } finally {
            if ($null -ne $snapshot) { [void](Set-PlatformPermissions -Lease $runtimeLease -Snapshot $snapshot) }
            $runtimeLease.Dispose()
        }
        Assert-WinLockReleased $fixture
    }

    # Scenario: One prepare owns setup.lock before cache publication while a second prepare races with the same archive.
    # Purpose: H2 proves the losing process cannot create or replace shared cache state before acquiring the lock.
    It 'InterT18_does_not_publish_shared_cache_before_lock_ownership' {
        $fixture = New-WinFixture 'cache-lock-order'
        $barrier = Join-Path $script:WinRoot ('cache-lock-' + [guid]::NewGuid().ToString('N'))
        $arguments = @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        $cache = Join-Path (Join-Path $fixture.Layout.SetupRoot 'cache') ([IO.Path]::GetFileName($script:WinArchive))
        $setup = Open-PlatformDirectory -Root $fixture.Home -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate
        $setup.Dispose()
        [void](Publish-AgentEnvironmentSetupArchiveCache -SetupRoot $fixture.Layout.SetupRoot -Leaf ([IO.Path]::GetFileName($script:WinArchive)) -ArchivePath $script:WinArchive -ExpectedSha256 ((Get-FileHash -LiteralPath $script:WinArchive -Algorithm SHA256).Hash.ToLowerInvariant()))
        $cacheHash = (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash
        $cacheMtime = (Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks
        $first = Start-WinSetup $arguments -UserHome $fixture.Home -Environment @{ AI_INSTRUCTIONS_SETUP_BARRIER='after-lock-acquired'; AI_INSTRUCTIONS_SETUP_BARRIER_DIRECTORY=$barrier }
        try {
            Wait-WinBarrierReady $barrier
            (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash | Should BeExactly $cacheHash
            (Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks | Should Be $cacheMtime
            $second = Invoke-WinSetup $arguments -UserHome $fixture.Home
            $second.ExitCode | Should Be 26
            $second.Json.code | Should Be 'concurrent'
            (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash | Should BeExactly $cacheHash
            (Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks | Should Be $cacheMtime
            [IO.File]::WriteAllText((Join-Path $barrier 'release'),'release')
            $completed = Complete-WinSetup $first; $first = $null
            Assert-WinSuccessReceipt $completed $fixture 'prepared-runtime-only' 'resolved'
            (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash | Should BeExactly $cacheHash
            (Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks | Should Be $cacheMtime
        } finally {
            if ($null -ne $first) { [IO.File]::WriteAllText((Join-Path $barrier 'release'),'release'); [void](Complete-WinSetup $first) }
        }
    }

    # Scenario: Removing and reimporting the setup module preserves platform-runtime while hiding its nested Windows module from Get-Module -All.
    # Purpose: The durability hook resolves the exact nested module instance retained by the runtime instead of relying on session visibility.
    It 'InterT18a_resolves_the_runtime_nested_Windows_module_after_setup_module_reimport' {
        Remove-Module agent-environment-setup -Force
        Import-Module (Join-Path $script:WinRepositoryRoot 'scripts/agent-environment-setup.psm1') -DisableNameChecking -Force
        $runtimeModule = @(Get-Module platform-runtime)[0]
        (& $runtimeModule { @(Get-Module -All Windows).Count }) | Should Be 0
        @($runtimeModule.NestedModules | Where-Object { $_.Name -ceq 'Windows' }).Count | Should Be 1
        { Set-WinSetupDurabilityHook $null } | Should Not Throw
    }

    # Scenario: The create-only runtime rename succeeds, then the platform primitive injects a failure at the pwsh parent-directory flush.
    # Purpose: J2 publishes no pointer, leaves the durable-state-unknown runtime as an untouched orphan, and a real-entry rerun uses a new attempt.
    It 'InterT19_recovers_from_runtime_parent_flush_failure_with_a_new_attempt' {
        $fixture = New-WinFixture 'runtime-parent-flush-failure'
        $policyInfo = Read-AgentEnvironmentSetupPolicy (Join-Path $script:WinRepo 'scripts/setup-agent-environment.policy.json')
        $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $fixture.Layout $script:WinRid
        $lease = Open-PlatformDirectory -Root $fixture.Home -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate
        $lease.Dispose()
        foreach ($relative in @($fixture.Layout.RuntimeParentRelativePath,$attempt.TransactionStoreRelativePath,$attempt.TransactionRelativePath)) {
            $lease = Open-PlatformDirectory -Root $fixture.Layout.SetupRoot -RelativePath $relative -CreatePrivate
            $lease.Dispose()
        }
        $stageLease = Open-PlatformDirectory -Root $fixture.Layout.SetupRoot -RelativePath $attempt.StageRelativePath -CreatePrivate
        try { $runtimeReceipt = Resolve-PlatformPowerShell -Policy $policyInfo.Policy -DestinationLease $stageLease -OfflineCache $script:WinArchive }
        finally { $stageLease.Dispose() }
        Confirm-AgentEnvironmentSetupRuntimeTreeDurability -Layout $fixture.Layout -Attempt $attempt -Receipt $runtimeReceipt
        $hookState = @{ PostRenameParent = 0 }
        Set-WinSetupDurabilityHook ({
            param($point,$operation,$role,$lease)
            if ($point -ceq 'post-rename' -and $operation -ceq 'directory-publication' -and $role -ceq 'parent') {
                $hookState.PostRenameParent++
                if ($hookState.PostRenameParent -eq 2) { throw 'injected runtime parent flush failure' }
            }
        }.GetNewClosure())
        $refusalCode = $null
        try {
            try { Publish-AgentEnvironmentSetupRuntimeDirectory -Layout $fixture.Layout -Attempt $attempt -Receipt $runtimeReceipt -Policy $policyInfo.Policy | Out-Null }
            catch { $refusalCode = Get-AgentEnvironmentSetupRefusalCode $_ }
            $refusalCode | Should Be 'runtime-verification-failed'
        } finally { Set-WinSetupDurabilityHook $null }
        Test-Path -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | Should Be $false
        Test-Path -LiteralPath $attempt.RuntimeDirectory -PathType Container | Should Be $true
        $before = Get-WinTreeSnapshot $attempt.RuntimeDirectory
        $mtime = (Get-Item -LiteralPath $attempt.RuntimeDirectory).LastWriteTimeUtc.Ticks

        $rerun = Invoke-WinSetup @('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive) -UserHome $fixture.Home
        Assert-WinSuccessReceipt $rerun $fixture 'prepared-runtime-only' 'resolved'
        $stored = Get-Content -Raw -LiteralPath (Join-Path $fixture.Layout.ReceiptDirectory $fixture.Layout.RuntimeReceiptLeaf) | ConvertFrom-Json
        $selected = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$stored.runtimeClosure.rootPath) $fixture.Home
        $selected | Should Not BeExactly $attempt.RuntimeDirectory
        (Get-WinTreeSnapshot $attempt.RuntimeDirectory) | Should BeExactly $before
        (Get-Item -LiteralPath $attempt.RuntimeDirectory).LastWriteTimeUtc.Ticks | Should Be $mtime
    }

    # Scenario: Real entry processes abort immediately after the setup-root path or runtime transaction path has completed directory flush/readback.
    # Purpose: Prove the additive durability close precedes lock/WAL or runtime staging and that either pre-marker abort is safely rerunnable.
    It 'InterT20_reruns_after_durable_setup_and_runtime_transaction_path_aborts' {
        $arguments=@('-Prepare','-ExpectedCommit',$script:WinCommit,'-ArchivePath',$script:WinArchive)
        $rootFixture=New-WinFixture 'durable-setup-root-abort'
        $rootCrash=Invoke-WinSetup $arguments -UserHome $rootFixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='after-setup-root-durable';AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$rootFixture.Layout.LockLeaf}
        $rootCrash.ExitCode | Should Not Be 0
        Test-Path -LiteralPath $rootFixture.Layout.SetupRoot -PathType Container | Should Be $true
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $rootFixture.Home) $rootFixture 'prepared-runtime-only' 'resolved'

        $transactionFixture=New-WinFixture 'durable-runtime-transaction-abort'
        $transactionCrash=Invoke-WinSetup $arguments -UserHome $transactionFixture.Home -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='after-runtime-transaction-durable';AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF=$transactionFixture.Layout.RuntimeReceiptLeaf}
        $transactionCrash.ExitCode | Should Not Be 0
        Test-Path -LiteralPath (Join-Path $transactionFixture.Layout.RuntimeParentDirectory '.ai-instructions-txn') -PathType Container | Should Be $true
        Assert-WinLockReleased $transactionFixture
        Assert-WinSuccessReceipt (Invoke-WinSetup $arguments -UserHome $transactionFixture.Home) $transactionFixture 'prepared-runtime-only' 'resolved'
    }
}
}

# Register only on the native host; keep this file's Core CI skip count at zero.
if ($setupTestIsUnix) {
Describe 'setup-agent-environment POSIX shell native fixture (SYP-354 P10a)' {
    BeforeAll {
        $script:UnixRepositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/agent-environment-setup.psm1') -DisableNameChecking -Force
        Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/platform-runtime.psd1') -DisableNameChecking
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
        # Linux cloud fixture seam: the setup edge invokes these committed fixture
        # programs exactly as it invokes the production installer/updater/coordinator,
        # while source acquisition remains local and every HOME stays under TestDrive.
        $fixtureUpdater = @'
if (Get-Module -Name platform-runtime) { throw 'fixture updater was loaded in the setup process instead of an isolated child' }
function Invoke-AiInstructionsUpdateWorkflow {
    param([string]$CodexHome,[switch]$ForceCheck,[switch]$InstallApproved,[scriptblock]$ResolveCandidate,[scriptblock]$AcquireCandidate,[scriptblock]$InstallCandidate)
    if (Test-Path -LiteralPath (Join-Path $CodexHome 'fixture-updater-concurrent')) { return [pscustomobject]@{ outcome='concurrent'; exitCode=3 } }
    $bundle = Get-Content -Raw -LiteralPath (Join-Path $CodexHome 'hooks/ai-instructions-runtime/runtime-bundle.json') | ConvertFrom-Json
    $configuration = Get-Content -Raw -LiteralPath (Join-Path $CodexHome 'ai-instructions-sync.json') | ConvertFrom-Json
    $request = [pscustomobject]@{ CodexHome=$CodexHome; CurrentCommit=[string]$bundle.commit; Mode=[string]$configuration.updates.mode; Channel=[string]$configuration.updates.channel; Ref=[string]$configuration.updates.ref }
    $candidate = & $ResolveCandidate $request
    if ([string]$candidate.Commit -ceq [string]$bundle.commit) {
        [IO.File]::WriteAllText((Join-Path $CodexHome 'ai-instructions-update-receipt.json'),('{"outcome":"current","checkedAtUtc":"' + [DateTime]::UtcNow.ToString('o') + '"}'))
        return [pscustomobject]@{ outcome='current' }
    }
    $request | Add-Member CandidateCommit ([string]$candidate.Commit)
    $package = & $AcquireCandidate $request
    $again = & $ResolveCandidate $request
    if ([string]$again.Commit -cne [string]$candidate.Commit) { return [pscustomobject]@{ outcome='drift' } }
    & $InstallCandidate ([pscustomobject]@{ CurrentCommit=[string]$bundle.commit; CandidateCommit=[string]$candidate.Commit; Mode=$request.Mode; Channel=$request.Channel; Ref=$request.Ref; Package=$package })
    return [pscustomobject]@{ outcome='installed' }
}
Export-ModuleMember -Function Invoke-AiInstructionsUpdateWorkflow
'@
        $fixtureCoordinator = @'
[CmdletBinding(SupportsShouldProcess=$true)] param([string]$CodexHome,[string]$UserHome,[switch]$Apply,[switch]$VerifyOnly,[string]$OutputFormat)
$runtime = Join-Path $CodexHome 'hooks/ai-instructions-runtime'
$bundle = Get-Content -Raw -LiteralPath (Join-Path $runtime 'runtime-bundle.json') | ConvertFrom-Json
$catalog = Get-Content -Raw -LiteralPath (Join-Path $runtime 'catalog/skills-catalog.json') | ConvertFrom-Json
$configuration = Get-Content -Raw -LiteralPath (Join-Path $CodexHome 'ai-instructions-sync.json') | ConvertFrom-Json
$selectionModule = Import-Module (Join-Path $runtime 'skills-selection.psm1') -Force -PassThru
$manifest = Join-Path $UserHome '.agents/catalog-skills.manifest.json'
$claude = Join-Path $UserHome '.claude/CLAUDE.md'
$section = [IO.File]::ReadAllText((Join-Path $runtime 'bootstrap-section.md'))
$existing = if (Test-Path -LiteralPath $manifest -PathType Leaf) { Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json } else { $null }
[string[]]$installed = @(); if ($null -ne $existing) { $installed = @($existing.files | ForEach-Object { [string]$_.skillId } | Sort-Object -Unique) }
[object[]]$evidence = @(); if ($null -ne $configuration.PSObject.Properties['capabilityEvidence']) { $evidence = @($configuration.capabilityEvidence) }
$resolver = $selectionModule.ExportedCommands['Resolve-SkillsSelection']
$selected = @(& $resolver -Catalog $catalog -Selection $configuration.catalog -CapabilityEvidence $evidence -InstalledSkillIds $installed -WarningAction SilentlyContinue)
$desiredFiles = [Collections.Generic.List[object]]::new()
foreach ($skillId in $selected) {
    foreach ($projection in @('user-agents','user-claude')) {
        $root = if ($projection -ceq 'user-agents') { '.agents/skills' } else { '.claude/skills' }
        $target = "$root/$skillId/SKILL.md"
        $desiredFiles.Add([pscustomobject]@{ skillId=$skillId; projectionId=$projection; targetPath=$target; content="fixture skill=$skillId commit=$($bundle.commit)`n" })
    }
}
$owned = @{}
if ($null -ne $existing) { foreach ($file in @($existing.files)) { $owned[[string]$file.targetPath] = $true } }
$desiredPaths = @{}; foreach ($file in $desiredFiles) { $desiredPaths[[string]$file.targetPath] = $true }
$collision = $false
foreach ($file in $desiredFiles) {
    $full = Join-Path $UserHome ([string]$file.targetPath)
    if ((Test-Path -LiteralPath $full) -and -not $owned.ContainsKey([string]$file.targetPath)) { $collision = $true }
}
if (Test-Path -LiteralPath (Join-Path $UserHome '.agents/fixture-coordinator-concurrent')) {
    if ($WhatIfPreference) { New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) 'fixture-coordinator-concurrent-never-created') | Out-Null }
    [pscustomobject]@{ outcome='concurrent'; exitCode=3; failureDetails=@() } | ConvertTo-Json -Compress
    exit 3
}
if ($WhatIfPreference) {
    # Match production: ShouldProcess writes through the host UI rather than
    # information stream 6 when WhatIfPreference reaches New-Item.
    New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) 'fixture-coordinator-whatif-never-created') | Out-Null
    if ($collision) {
        [pscustomobject]@{ outcome='failed'; exitCode=1; failureDetails=@([pscustomobject]@{code='unmanaged-collision'}) } | ConvertTo-Json -Compress -Depth 5
        exit 1
    }
    [pscustomobject]@{ outcome='planned'; exitCode=0; failureDetails=@() } | ConvertTo-Json -Compress
    exit 0
}
if ($Apply) {
    if ($collision) {
        [pscustomobject]@{ outcome='failed'; exitCode=1; failureDetails=@([pscustomobject]@{code='unmanaged-collision'}) } | ConvertTo-Json -Compress -Depth 5
        exit 1
    }
    foreach ($targetPath in @($owned.Keys)) {
        if ($desiredPaths.ContainsKey([string]$targetPath)) { continue }
        $full = Join-Path $UserHome ([string]$targetPath)
        if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
        $parent = [IO.Path]::GetDirectoryName($full)
        if ([IO.Directory]::Exists($parent) -and @([IO.Directory]::EnumerateFileSystemEntries($parent)).Count -eq 0) { [IO.Directory]::Delete($parent) }
    }
    foreach ($file in $desiredFiles) {
        $full = Join-Path $UserHome ([string]$file.targetPath)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)); [IO.File]::WriteAllText($full,[string]$file.content)
    }
    $manifestDocument = [pscustomobject][ordered]@{ schemaVersion=3; projections=@('user-agents','user-claude'); files=@($desiredFiles | ForEach-Object { [pscustomobject]@{skillId=$_.skillId;projectionId=$_.projectionId;targetPath=$_.targetPath} }) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($manifest)); [IO.File]::WriteAllText($manifest,($manifestDocument | ConvertTo-Json -Depth 6 -Compress))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($claude)); [IO.File]::WriteAllText($claude,$section)
    [pscustomobject]@{ outcome='applied'; exitCode=0; failureDetails=@() } | ConvertTo-Json -Compress
    exit 0
}
$current = (Test-Path -LiteralPath $manifest -PathType Leaf) -and (Test-Path -LiteralPath $claude -PathType Leaf) -and ([IO.File]::ReadAllText($claude) -ceq $section)
foreach ($file in $desiredFiles) {
    $full = Join-Path $UserHome ([string]$file.targetPath)
    $current = $current -and (Test-Path -LiteralPath $full -PathType Leaf) -and ([IO.File]::ReadAllText($full) -ceq [string]$file.content)
}
[pscustomobject]@{ outcome=$(if($current){'current'}else{'failed'}); exitCode=$(if($current){0}else{1}); failureDetails=@() } | ConvertTo-Json -Compress
exit $(if($current){0}else{1})
'@
        $fixtureLauncher = @'
[CmdletBinding()] param([switch]$ValidateOnly)
if (-not $ValidateOnly) { throw 'fixture launcher supports only -ValidateOnly' }
exit 0
'@
        $fixtureInstaller = @'
[CmdletBinding()] param([string]$RepositoryRoot,[string]$CodexHome,[string]$SourceCommit,[string]$ExpectedCurrentCommit,[string]$ExpectedUpdateMode,[string]$ExpectedUpdateChannel,[string]$ExpectedUpdateRef,[string]$ExpectedCurrentGeneration,[string]$WriterSchema)
$runtime = Join-Path $CodexHome 'hooks/ai-instructions-runtime'; [void][IO.Directory]::CreateDirectory($runtime)
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-ai-instructions-updater.psm1') -Destination (Join-Path $runtime 'ai-instructions-updater.psm1') -Force
[void][IO.Directory]::CreateDirectory((Join-Path $runtime 'catalog'))
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $runtime 'catalog/skills-catalog.json') -Force
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/skills-selection.psm1') -Destination (Join-Path $runtime 'skills-selection.psm1') -Force
[void][IO.Directory]::CreateDirectory((Join-Path $CodexHome 'hooks'))
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-update-agent-environment.ps1') -Destination (Join-Path $CodexHome 'hooks/update-agent-environment.ps1') -Force
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-bootstrap-ai-instructions.ps1') -Destination (Join-Path $CodexHome 'hooks/bootstrap-ai-instructions.ps1') -Force
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'instructions/common/bootstrap-section.md') -Destination (Join-Path $runtime 'bootstrap-section.md') -Force
[void][IO.Directory]::CreateDirectory((Join-Path $CodexHome '.ai-instructions-txn'))
$configurationPath = Join-Path $CodexHome 'ai-instructions-sync.json'
$catalogSelection = if (Test-Path -LiteralPath $configurationPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json).catalog } else { [pscustomobject]@{repository='https://example.com/catalog.git';ref=$SourceCommit;profiles=@();includeSkills=@();excludeSkills=@()} }
$catalogSelection.ref = $SourceCommit
$configuration = [pscustomobject][ordered]@{schemaVersion=5;catalog=$catalogSelection;updates=[pscustomobject]@{mode='notify-only';channel='protected-branch';ref='main'};projections=[pscustomobject]@{user=@('user-agents','user-claude');project=@()}}
[IO.File]::WriteAllText($configurationPath,($configuration | ConvertTo-Json -Depth 8 -Compress))
[IO.File]::WriteAllText((Join-Path $runtime 'runtime-bundle.json'),('{"schemaVersion":3,"commit":"' + $SourceCommit + '"}'))
'@
        [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-ai-instructions-updater.psm1'),$fixtureUpdater,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-update-agent-environment.ps1'),$fixtureCoordinator,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-bootstrap-ai-instructions.ps1'),$fixtureLauncher,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/install-ai-instructions-bootstrap.ps1'),$fixtureInstaller,[Text.UTF8Encoding]::new($false))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'catalog'))
        Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $script:UnixRepo 'catalog/skills-catalog.json')
        Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot 'scripts/skills-selection.psm1') -Destination (Join-Path $script:UnixRepo 'scripts/skills-selection.psm1')
        [void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'instructions/common'))
        Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot 'instructions/common/bootstrap-section.md') -Destination (Join-Path $script:UnixRepo 'instructions/common/bootstrap-section.md')
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
            param([string]$UserHome,[string[]]$Arguments,[string]$Kind='runtime',[hashtable]$Environment=@{},[string]$ExpectedCommit=$script:UnixCommits[$Kind],[switch]$NoCheckout,[switch]$UnsetHome,[string]$EntryPath=$script:UnixShell)
            if (-not $NoCheckout) { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits[$Kind] 2>$null | Out-Null }
            $start = [Diagnostics.ProcessStartInfo]::new('sh')
            foreach ($argument in @($EntryPath,'--expected-commit',$ExpectedCommit) + $Arguments) { $start.ArgumentList.Add($argument) }
            $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
            if($UnsetHome){[void]$start.Environment.Remove('HOME')}else{$start.Environment['HOME'] = $UserHome}
            # Any accidental network use fails fast instead of reaching the internet.
            $start.Environment['HTTPS_PROXY'] = 'http://127.0.0.1:9'
            [void]$start.Environment.Remove('CODEX_HOME')
            foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
            $process = [Diagnostics.Process]::Start($start)
            $process.StandardInput.Close()
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
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
            $start.Environment['HOME']=$UserHome;$start.Environment['HTTPS_PROXY']='http://127.0.0.1:9';[void]$start.Environment.Remove('CODEX_HOME')
            foreach($key in $Environment.Keys){$start.Environment[$key]=[string]$Environment[$key]}
            $process=[Diagnostics.Process]::Start($start)
            $process.StandardInput.Close()
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

        function Assert-UnixPrivatePath {
            param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Mode)
            $lease=$null;$parent=$null
            try {
                if([IO.Directory]::Exists($Path)){$lease=Open-PlatformDirectory -Root $Path -RootOnly}
                else{
                    $parent=Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($Path)) -RootOnly
                    $lease=Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($Path)) -Access Read -CreateMode OpenExisting
                }
                $permissions=Get-PlatformPermissions -Lease $lease
                ([string]$permissions.mode).TrimStart('0') | Should BeExactly $Mode.TrimStart('0')
                [string]$permissions.uid | Should BeExactly $script:SetupTestUnixUid
            } finally {
                if($null -ne $lease){$lease.Dispose()}
                if($null -ne $parent){$parent.Dispose()}
            }
        }

        function Assert-UnixSetupLockReleased {
            param([Parameter(Mandatory=$true)][string]$SetupRoot)
            $setup=Open-PlatformDirectory -Root $SetupRoot -RootOnly
            try{$lock=Enter-PlatformLock -ParentLease $setup -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero);$lock.Dispose()}
            finally{$setup.Dispose()}
        }

        function Assert-UnixSetupTransactionClean {
            param([Parameter(Mandatory=$true)][string]$SetupRoot)
            $store=Join-Path $SetupRoot '.ai-instructions-txn'
            $residue=@(Get-ChildItem -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {$_.Name -cin @('stage','displaced','journal.json')})
            $residue.Count | Should Be 0
            Test-Path -LiteralPath $store | Should Be $false
        }

        function New-UnixToolShim {
            param([string]$Name,[string[]]$Exclude=@(),[hashtable]$Replace=@{})
            $bin = Join-Path $script:UnixRoot "bin-$Name"
            [void][IO.Directory]::CreateDirectory($bin)
            foreach ($tool in @('uname','id','awk','sed','find','mkdir','rm','rmdir','chmod','env','dirname','cp','mktemp','git','tar','gzip','sha256sum','shasum','curl','wget','cat','ls','sh')) {
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
                $isLink = $null -ne $item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                if ($isLink) { "L $relative $($item.LinkTarget)"; continue }
                $mode = [Convert]::ToString([int][IO.File]::GetUnixFileMode($item.FullName),8)
                if ($item.PSIsContainer) { "D $relative $mode" } else { "F $relative $mode $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)" }
            }
            return (@($lines) -join "`n")
        }

        function Assert-UnixPreparePlatformContract {
            param([Parameter(Mandatory=$true)]$Run,[Parameter(Mandatory=$true)][string]$UserHome)
            $manifestPath = Join-Path $UserHome '.agents/catalog-skills.manifest.json'
            $claudePath = Join-Path $UserHome '.claude/CLAUDE.md'
            if ($IsLinux) {
                $Run.Json.result | Should BeExactly 'completed'
                $Run.Json.runtimeCommit | Should BeExactly $script:UnixCommits['runtime']
                (@($Run.Json.steps | Where-Object step -in @('S7','S8','S9') | Select-Object -ExpandProperty status) -join ',') | Should BeExactly 'completed,completed,completed'
                Test-Path -LiteralPath $manifestPath -PathType Leaf | Should Be $true
                $claudeBytes = [IO.File]::ReadAllBytes($claudePath)
                $runtimeBytes = [IO.File]::ReadAllBytes((Join-Path $UserHome '.codex/hooks/ai-instructions-runtime/bootstrap-section.md'))
                [Convert]::ToBase64String($claudeBytes) | Should BeExactly ([Convert]::ToBase64String($runtimeBytes))
                return
            }
            $Run.Json.result | Should BeExactly 'prepared-runtime-only'
            Test-Path -LiteralPath $manifestPath | Should Be $false
            Test-Path -LiteralPath $claudePath | Should Be $false
        }

        function Assert-NoUnixSetupRunDirectories {
            param([Parameter(Mandatory = $true)][string]$TmpRoot,[string]$PreservedPath)
            $remaining = @(Get-ChildItem -LiteralPath $TmpRoot -Directory -Force | Where-Object {
                [string]::IsNullOrEmpty($PreservedPath) -or $_.FullName -ne $PreservedPath
            })
            if ($remaining.Count -eq 0) { return }
            $bounded = [Collections.Generic.List[string]]::new()
            $pending = [Collections.Generic.Queue[object]]::new()
            foreach ($directory in @($remaining | Sort-Object Name)) {
                $pending.Enqueue([pscustomobject]@{ Item=$directory; Relative=$directory.Name; Depth=0 })
            }
            while ($pending.Count -gt 0 -and $bounded.Count -lt 16) {
                $node = $pending.Dequeue()
                $item = $node.Item
                $isLink = $null -ne $item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                $kind = if ($isLink) { 'link' } elseif ($item.PSIsContainer) { 'directory' } else { 'file' }
                $bounded.Add("$($node.Relative):$kind")
                if ($node.Depth -ge 4 -or $isLink -or -not $item.PSIsContainer) { continue }
                $remainingCapacity = 16 - $bounded.Count - $pending.Count
                if ($remainingCapacity -le 0) { continue }
                foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First $remainingCapacity)) {
                    $pending.Enqueue([pscustomobject]@{ Item=$child; Relative="$($node.Relative)/$($child.Name)"; Depth=([int]$node.Depth+1) })
                }
            }
            throw "Expected no current setup run directories under '$TmpRoot'; found $($remaining.Count). Bounded entries (depth<=4, total<=16): $($bounded -join '; ')"
        }
    }

    AfterAll {
        & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
        Remove-Module agent-environment-setup -Force -ErrorAction SilentlyContinue
    }

    if ($IsLinux) {
    # Scenario: Linux --prepare reaches the first-install branch with dirty installer bytes and an otherwise trusted setup commit.
    # Purpose: Refuse before executing the installer or publishing its CODEX_HOME runtime bundle.
    It 'InterT51_refuses_a_dirty_cloud_installer_before_runtime_installation' {
        $userHome = New-UnixHome 'cloud-dirty-installer'
        $relative = 'scripts/install-ai-instructions-bootstrap.ps1'
        & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime']
        $LASTEXITCODE | Should Be 0
        $installerPath = Join-Path $script:UnixRepo $relative
        $originalBytes = [IO.File]::ReadAllBytes($installerPath)
        try {
            [IO.File]::AppendAllText($installerPath,"`n# uncommitted installer change`n")
            $run = Invoke-UnixSetup $userHome @('--prepare') -NoCheckout
            Assert-SetupTestExitCode $run 15
            $run.Json.code | Should BeExactly 'commit-mismatch'
            $run.Stderr | Should Match 'install-ai-instructions-bootstrap\.ps1.*expected commit'
            Test-Path -LiteralPath (Join-Path $userHome '.codex/hooks/ai-instructions-runtime/runtime-bundle.json') | Should Be $false
        } finally {
            [IO.File]::WriteAllBytes($installerPath,$originalBytes)
        }
    }
    }

    # Scenario: Linux --prepare with a pre-placed verified cache completes cloud wiring, then --offline only re-verifies the runtime.
    # Purpose: Cover the V3V5 first install, both USER projections, verified D13 bytes and the unchanged Offline boundary under TestDrive.
    It 'InterT20_prepares_from_a_preplaced_cache_and_reverifies_offline_with_private_modes' {
        $userHome = New-UnixHome 'success'
        $prepare = Invoke-UnixSetup $userHome @('--prepare')
        Assert-SetupTestExitCode $prepare 0
        Assert-UnixPreparePlatformContract $prepare $userHome
        $prepare.Json.powerShell.runtimeAction | Should Be 'resolved'
        $offline = Invoke-UnixSetup $userHome @('--offline')
        Assert-SetupTestExitCode $offline 0
        $offline.Json.result | Should Be 'verified-runtime-only'
        $offline.Json.powerShell.runtimeAction | Should Be 'reverified'
        $setupRoot = Join-Path $userHome '.local/share/ai-instructions-setup'
        $runtimeReceipt = Get-Content -Raw -LiteralPath (Join-Path $setupRoot "receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json") | ConvertFrom-Json
        $runtimeRoot = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.runtimeClosure.rootPath) $userHome
        Get-UnixMode $setupRoot | Should Be '700'
        Get-UnixMode (Join-Path $setupRoot 'pwsh-tmp') | Should Be '700'
        Get-UnixMode $runtimeRoot | Should Be '700'
        Get-UnixMode (Join-Path $runtimeRoot 'pwsh') | Should Be '700'
        Get-UnixMode (Join-Path $setupRoot 'receipts/setup-receipt.json') | Should Be '600'
        Get-UnixMode (Join-Path $setupRoot "receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json") | Should Be '600'
        Assert-NoUnixSetupRunDirectories -TmpRoot (Join-Path $setupRoot 'tmp')
        $offline.Stdout.Contains($userHome) | Should Be $false
    }

    # CloudT1-T7 are Linux-only: macOS deliberately retains the runtime-only P10a contract and has no default mode.
    if ($IsLinux) {
    # Scenario: Linux setup is rerun at the same immutable commit after the first cloud projection and its committed empty transaction store.
    # Purpose: Exercise read-only same-pin validation with closed stdin and prove all CODEX_HOME/managed USER bytes remain stable.
    It 'CloudT1_reruns_the_same_pin_through_the_updater_without_managed_tree_changes' {
        $userHome = New-UnixHome 'cloud-rerun'
        $first = Invoke-UnixSetup $userHome @()
        Assert-SetupTestExitCode $first 0
        $before = @(
            Get-UnixTreeSnapshot (Join-Path $userHome '.codex')
            Get-UnixTreeSnapshot (Join-Path $userHome '.agents')
            Get-UnixTreeSnapshot (Join-Path $userHome '.claude')
        ) -join "`n"
        $again = Invoke-UnixSetup $userHome @()
        Assert-SetupTestExitCode $again 0
        $again.Json.result | Should BeExactly 'completed'
        (@($again.Json.steps | Where-Object step -eq 'S7')[0].detail) | Should BeExactly 'current'
        $after = @(
            Get-UnixTreeSnapshot (Join-Path $userHome '.codex')
            Get-UnixTreeSnapshot (Join-Path $userHome '.agents')
            Get-UnixTreeSnapshot (Join-Path $userHome '.claude')
        ) -join "`n"
        $after | Should BeExactly $before
    }

    if ($IsLinux) {
    # Scenario: A completed Linux setup emits D13 with an absolute pwsh path while neither pwsh nor pwsh.exe is available through PATH.
    # Purpose: Execute that exact command against a fully verified installed launcher, an offline update source and a read-only fan-out fixture.
    It 'CloudT1a_runs_the_generated_D13_installed_bootstrap_without_pwsh_on_PATH' {
        $userHome = New-UnixHome 'cloud-installed-bootstrap'
        $setup = Invoke-UnixSetup $userHome @()
        Assert-SetupTestExitCode $setup 0
        $setup.Json.result | Should BeExactly 'completed'
        $runtimeReceiptPath = Join-Path $userHome ".local/share/ai-instructions-setup/receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json"
        $runtimeReceipt = Get-Content -Raw -LiteralPath $runtimeReceiptPath | ConvertFrom-Json
        $physicalPowerShellPath = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.executablePath) $userHome
        $renderReceipt = [pscustomobject]@{
            os = 'linux'
            runtime = [pscustomobject]@{ powerShellExecutablePath = $physicalPowerShellPath }
            capabilities = @([pscustomobject]@{
                name = 'powershell-runtime'
                status = 'available'
                evidence = @("Physical pwsh identity and version probe passed: $physicalPowerShellPath")
            })
        }
        $runtimeContract = Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/ai-instructions-runtime-contract.psm1') -Force -PassThru
        [byte[]]$renderedSection = & $runtimeContract {
            param([byte[]]$template,[object]$receipt)
            Get-AiInstructionsBootstrapSectionBytes -TemplateBytes $template -CapabilityReceipt $receipt
        } ([IO.File]::ReadAllBytes((Join-Path $userHome '.codex/hooks/ai-instructions-runtime/bootstrap-section.md'))) $renderReceipt
        [IO.File]::WriteAllBytes((Join-Path $userHome '.claude/CLAUDE.md'),$renderedSection)

        $candidateRoot = Join-Path $script:UnixRoot 'installed-bootstrap-candidate'
        [void][IO.Directory]::CreateDirectory($candidateRoot)
        Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot 'scripts'),(Join-Path $script:UnixRepositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        [void][IO.Directory]::CreateDirectory((Join-Path $candidateRoot 'instructions/common'))
        Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot 'instructions/common/bootstrap-section.md') -Destination (Join-Path $candidateRoot 'instructions/common/bootstrap-section.md')
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
            Copy-Item -LiteralPath (Join-Path $script:UnixRepositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)
        }
        $fixtureUpdateModule = @'
function Get-AiInstructionsUpdateDisposition {
    param([string]$Outcome,[string]$Message)
    return [pscustomobject]@{classification='none';installationState='not-installed';retryable=$false}
}
function Invoke-AiInstructionsUpdateWorkflow {
    param([string]$CodexHome,[switch]$ForceCheck,[switch]$InstallApproved)
    [IO.File]::WriteAllText((Join-Path $CodexHome 'ai-instructions-update-receipt.json'),'{"outcome":"current","source":"SYP571-offline-fixture"}')
    return [pscustomobject]@{outcome='current';message='SYP571 offline fixture update source reached; runtime is current.'}
}
Export-ModuleMember -Function Get-AiInstructionsUpdateDisposition,Invoke-AiInstructionsUpdateWorkflow
'@
        $fixtureFanOut = @'
[CmdletBinding()]
param([string]$CatalogPath,[string]$LockPath,[string]$ConfigurationPath,[string]$RuntimeRoot,[string]$UserHome,[string]$TargetRoot,[switch]$WhatIf)
foreach($path in @($CatalogPath,$LockPath,$ConfigurationPath)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "SYP571 fan-out input is missing: $path"}
}
$manifest=Join-Path $UserHome '.agents/catalog-skills.manifest.json'
$claude=Join-Path $UserHome '.claude/CLAUDE.md'
if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)-or-not(Test-Path -LiteralPath $claude -PathType Leaf)){throw 'SYP571 expected setup projections are missing.'}
$document=Get-Content -Raw -LiteralPath $manifest|ConvertFrom-Json
if(@($document.files).Count-eq0){throw 'SYP571 expected projected Skills are missing.'}
Write-Output 'SYP571 read-only fan-out verified existing Skills and instructions.'
'@
        [IO.File]::WriteAllText((Join-Path $candidateRoot 'scripts/ai-instructions-updater.psm1'),$fixtureUpdateModule,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $candidateRoot 'scripts/bootstrap-ai-instructions-multisource.ps1'),$fixtureFanOut,[Text.UTF8Encoding]::new($false))
        & git -C $candidateRoot init -q 2>$null|Out-Null
        & git -C $candidateRoot remote add origin 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' 2>$null|Out-Null
        & git -C $candidateRoot add -A 2>$null|Out-Null
        & git -C $candidateRoot -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m fixture 2>$null|Out-Null
        $candidateCommit=([string](& git -C $candidateRoot rev-parse HEAD)).Trim()
        $archivePath=Join-Path $script:UnixRoot 'installed-bootstrap-candidate.zip'
        & git -C $candidateRoot archive --format=zip --prefix=candidate-root/ --output=$archivePath HEAD 2>$null
        $LASTEXITCODE|Should Be 0
        $archiveSha256=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

        $installedCodexHome=Join-Path $userHome '.codex-installed'
        $installerStart=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        foreach($argument in @(
            '-NoProfile','-NonInteractive','-File',(Join-Path $script:UnixRepositoryRoot 'scripts/install-ai-instructions-bootstrap.ps1'),
            '-RepositoryRoot',$candidateRoot,'-CodexHome',$installedCodexHome,
            '-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$candidateCommit,
            '-Acquisition','github-codeload','-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath,'-WriterSchema','V3V5'
        )){$installerStart.ArgumentList.Add($argument)}
        $installerStart.UseShellExecute=$false;$installerStart.RedirectStandardOutput=$true;$installerStart.RedirectStandardError=$true
        $fixtureConfig=Join-Path $userHome '.config';$fixtureData=Join-Path $userHome '.local/share';$fixtureCache=Join-Path $userHome '.cache'
        [void][IO.Directory]::CreateDirectory($fixtureConfig);[void][IO.Directory]::CreateDirectory($fixtureData);[void][IO.Directory]::CreateDirectory($fixtureCache)
        $installerStart.Environment['HOME']=$userHome;$installerStart.Environment['USERPROFILE']=$userHome;$installerStart.Environment['CODEX_HOME']=$installedCodexHome
        $installerStart.Environment['APPDATA']=$fixtureConfig;$installerStart.Environment['LOCALAPPDATA']=$fixtureData
        $installerStart.Environment['XDG_CONFIG_HOME']=$fixtureConfig;$installerStart.Environment['XDG_DATA_HOME']=$fixtureData;$installerStart.Environment['XDG_CACHE_HOME']=$fixtureCache
        $installerStart.Environment['HTTPS_PROXY']='http://127.0.0.1:9'
        $installerProcess=[Diagnostics.Process]::Start($installerStart)
        try{
            $installerStdout=$installerProcess.StandardOutput.ReadToEndAsync();$installerStderr=$installerProcess.StandardError.ReadToEndAsync()
            if(-not$installerProcess.WaitForExit(900000)){$installerProcess.Kill($true);throw 'SYP571 fixture installer timed out.'}
            $installerProcess.WaitForExit()
            $installerOutput=$installerStdout.Result+$installerStderr.Result
            if($installerProcess.ExitCode-ne0){throw "SYP571 fixture installer failed: $installerOutput"}
            $installerProcess.ExitCode|Should Be 0
        }finally{$installerProcess.Dispose()}

        $claudePath=Join-Path $userHome '.claude/CLAUDE.md'
        $claudeText=[IO.File]::ReadAllText($claudePath)
        $commandMatch=[regex]::Match($claudeText,'codexHome="\$\{CODEX_HOME:-\$HOME/\.codex\}"; [^`\r\n]+')
        $commandMatch.Success|Should Be $true
        $d13Command=$commandMatch.Value
        $d13Command|Should Match "^codexHome=.*'[^']+/pwsh' -NoProfile -NonInteractive -File"

        $before=@(
            Get-UnixTreeSnapshot (Join-Path $installedCodexHome 'hooks')
            Get-UnixTreeSnapshot (Join-Path $userHome '.agents')
            Get-UnixTreeSnapshot (Join-Path $userHome '.claude')
        )-join"`n"
        $shimPath=New-UnixToolShim 'installed-bootstrap-no-pwsh'
        Test-Path -LiteralPath (Join-Path $shimPath 'pwsh')|Should Be $false
        Test-Path -LiteralPath (Join-Path $shimPath 'pwsh.exe')|Should Be $false
        $bootstrapStart=[Diagnostics.ProcessStartInfo]::new('sh')
        $bootstrapStart.ArgumentList.Add('-c');$bootstrapStart.ArgumentList.Add($d13Command)
        $bootstrapStart.UseShellExecute=$false;$bootstrapStart.RedirectStandardOutput=$true;$bootstrapStart.RedirectStandardError=$true
        $bootstrapStart.Environment['HOME']=$userHome;$bootstrapStart.Environment['USERPROFILE']=$userHome;$bootstrapStart.Environment['CODEX_HOME']=$installedCodexHome;$bootstrapStart.Environment['PATH']=$shimPath
        $bootstrapStart.Environment['APPDATA']=$fixtureConfig;$bootstrapStart.Environment['LOCALAPPDATA']=$fixtureData
        $bootstrapStart.Environment['XDG_CONFIG_HOME']=$fixtureConfig;$bootstrapStart.Environment['XDG_DATA_HOME']=$fixtureData;$bootstrapStart.Environment['XDG_CACHE_HOME']=$fixtureCache
        $bootstrapStart.Environment['HTTPS_PROXY']='http://127.0.0.1:9'
        $bootstrapProcess=[Diagnostics.Process]::Start($bootstrapStart)
        try{
            $stdout=$bootstrapProcess.StandardOutput.ReadToEndAsync();$stderr=$bootstrapProcess.StandardError.ReadToEndAsync()
            if(-not$bootstrapProcess.WaitForExit(900000)){$bootstrapProcess.Kill($true);throw 'SYP571 D13 fixture run timed out.'}
            $bootstrapProcess.WaitForExit();$bootstrapOutput=$stdout.Result+$stderr.Result
            if($bootstrapProcess.ExitCode-ne0){throw "SYP571 D13 fixture run failed: $bootstrapOutput"}
            $bootstrapProcess.ExitCode|Should Be 0
        }finally{$bootstrapProcess.Dispose()}
        $bootstrapOutput|Should Not Match 'pwsh\.exe|not recognized'
        $bootstrapOutput|Should Match 'SYP571 offline fixture update source reached; runtime is current'
        $bootstrapOutput|Should Match 'SYP571 read-only fan-out verified existing Skills and instructions'
        $after=@(
            Get-UnixTreeSnapshot (Join-Path $installedCodexHome 'hooks')
            Get-UnixTreeSnapshot (Join-Path $userHome '.agents')
            Get-UnixTreeSnapshot (Join-Path $userHome '.claude')
        )-join"`n"
        $after|Should BeExactly $before
    }
    }

    # Scenario: The expected commit advances and changes both managed content and a scripts/platform build input.
    # Purpose: Require an isolated updater child, retained V3V5 projections and projection of the new immutable pin.
    It 'CloudT2_updates_to_a_descendant_pin_and_projects_the_new_verified_bytes' {
        $userHome = New-UnixHome 'cloud-new-pin'
        Assert-SetupTestExitCode (Invoke-UnixSetup $userHome @()) 0
        $sectionPath = Join-Path $script:UnixRepo 'instructions/common/bootstrap-section.md'
        $platformPath = Join-Path $script:UnixRepo 'scripts/platform/UnixNative.cs'
        $platformManifestPath = Join-Path $script:UnixRepo 'scripts/platform-runtime.psd1'
        try {
            [IO.File]::AppendAllText($sectionPath,"`nSYP-519 isolated fixture pin`n")
            [IO.File]::AppendAllText($platformPath,"`n// SYP-519 isolated platform fingerprint`n")
            $platformHash = Get-AgentEnvironmentSetupSha256Text ([IO.File]::ReadAllText($platformPath))
            $platformManifest = [IO.File]::ReadAllText($platformManifestPath)
            $platformManifest = [regex]::Replace($platformManifest,"(?m)(Path = 'platform/UnixNative\.cs'; Sha256 = ')[a-f0-9]{64}(')",('${1}' + $platformHash + '$2'))
            [IO.File]::WriteAllText($platformManifestPath,$platformManifest,[Text.UTF8Encoding]::new($false))
            & git -C $script:UnixRepo add instructions/common/bootstrap-section.md scripts/platform/UnixNative.cs scripts/platform-runtime.psd1 2>$null | Out-Null
            & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m cloud-pin 2>$null | Out-Null
            $next = [string](& git -C $script:UnixRepo rev-parse HEAD)
            $run = Invoke-UnixSetup $userHome @() -ExpectedCommit $next -NoCheckout
            Assert-SetupTestExitCode $run 0
            $run.Json.runtimeCommit | Should BeExactly $next
            (@($run.Json.steps | Where-Object step -eq 'S7')[0].detail) | Should BeExactly 'installed'
            [IO.File]::ReadAllText((Join-Path $userHome '.claude/CLAUDE.md')) | Should Match 'SYP-519 isolated fixture pin'
            ((Get-Content -Raw (Join-Path $userHome '.codex/ai-instructions-sync.json') | ConvertFrom-Json).projections.user -join ',') | Should BeExactly 'user-agents,user-claude'
        }
        finally { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null }
    }

    # Scenario: A fresh HOME contains unmanaged bytes at a selected target; a descendant pin newly selects another Skill whose target already has unmanaged bytes.
    # Purpose: Refuse with exit 29 before installer/updater mutation; the shell and every owned child observe EOF on stdin.
    It 'CloudT3_refuses_fresh_and_new_pin_projection_collisions_before_mutation' {
        $userHome = New-UnixHome 'cloud-collision'
        $collision = Join-Path $userHome '.agents/skills/plan-production-change/SKILL.md'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($collision))
        [IO.File]::WriteAllText($collision,"personal bytes`n")
        $before = (Get-FileHash -LiteralPath $collision -Algorithm SHA256).Hash
        $run = Invoke-UnixSetup $userHome @()
        Assert-SetupTestExitCode $run 29
        $run.Json.code | Should BeExactly 'projection-collision'
        (Get-FileHash -LiteralPath $collision -Algorithm SHA256).Hash | Should BeExactly $before
        Test-Path -LiteralPath (Join-Path $userHome '.codex') | Should Be $false

        $updateHome = New-UnixHome 'cloud-update-collision'
        Assert-SetupTestExitCode (Invoke-UnixSetup $updateHome @()) 0
        $updateCollision = Join-Path $updateHome '.agents/skills/manage-ai-memory/SKILL.md'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($updateCollision))
        [IO.File]::WriteAllText($updateCollision,"personal update collision bytes`n")
        $managedBefore = @(
            Get-UnixTreeSnapshot (Join-Path $updateHome '.codex')
            Get-UnixTreeSnapshot (Join-Path $updateHome '.agents')
            Get-UnixTreeSnapshot (Join-Path $updateHome '.claude')
        ) -join "`n"
        $catalogPath = Join-Path $script:UnixRepo 'catalog/skills-catalog.json'
        try {
            $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
            $core = @($catalog.profiles | Where-Object id -eq 'core')[0]
            $core.includes = @($core.includes) + 'manage-ai-memory'
            $newlySelected = @($catalog.skills | Where-Object id -eq 'manage-ai-memory')[0]
            $newlySelected.profiles = @($newlySelected.profiles) + 'core'
            [IO.File]::WriteAllText($catalogPath,(($catalog | ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
            & git -C $script:UnixRepo add catalog/skills-catalog.json 2>$null | Out-Null
            & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m collision-pin 2>$null | Out-Null
            $next = [string](& git -C $script:UnixRepo rev-parse HEAD)
            $updateRun = Invoke-UnixSetup $updateHome @() -ExpectedCommit $next -NoCheckout
            Assert-SetupTestExitCode $updateRun 29
            $updateRun.Json.code | Should BeExactly 'projection-collision'
            $managedAfter = @(
                Get-UnixTreeSnapshot (Join-Path $updateHome '.codex')
                Get-UnixTreeSnapshot (Join-Path $updateHome '.agents')
                Get-UnixTreeSnapshot (Join-Path $updateHome '.claude')
            ) -join "`n"
            $managedAfter | Should BeExactly $managedBefore
        }
        finally { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null }
    }

    # Scenario: One manifest-owned projection file is missing at the same immutable pin while unrelated personal bytes coexist outside the managed inventory.
    # Purpose: Keep a clean rerun byte-identical, but let the intentional Apply repair managed drift without changing unmanaged bytes.
    It 'CloudT4_repairs_same_pin_managed_drift_and_preserves_unmanaged_bytes' {
        $userHome = New-UnixHome 'cloud-managed-drift'
        Assert-SetupTestExitCode (Invoke-UnixSetup $userHome @()) 0
        $managed = Join-Path $userHome '.agents/skills/plan-production-change/SKILL.md'
        $expected = [IO.File]::ReadAllText($managed)
        Remove-Item -LiteralPath $managed -Force
        $personal = Join-Path $userHome '.agents/personal-notes.bin'
        [IO.File]::WriteAllBytes($personal,[byte[]]@(0,10,13,128,255))
        $personalBefore = (Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash

        $run = Invoke-UnixSetup $userHome @()

        Assert-SetupTestExitCode $run 0
        (@($run.Json.steps | Where-Object step -eq 'S8')[0].detail) | Should BeExactly 'applied'
        [IO.File]::ReadAllText($managed) | Should BeExactly $expected
        (Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash | Should BeExactly $personalBefore
    }

    # Scenario: Verified config excludes a formerly managed default Skill and personal bytes then occupy that now-unselected Skill path.
    # Purpose: Make preflight use the exact configured selection so an excluded unmanaged path is neither scanned nor mutated.
    It 'CloudT5_preserves_personal_bytes_for_an_exactly_excluded_default_skill' {
        $userHome = New-UnixHome 'cloud-config-exclude'
        Assert-SetupTestExitCode (Invoke-UnixSetup $userHome @()) 0
        $configurationPath = Join-Path $userHome '.codex/ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.excludeSkills = @('plan-production-change')
        [IO.File]::WriteAllText($configurationPath,($configuration | ConvertTo-Json -Depth 12 -Compress))
        $manifestPath = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $manifest.files = @($manifest.files | Where-Object { [string]$_.skillId -cne 'plan-production-change' })
        [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8 -Compress))
        $personalPaths = @(
            (Join-Path $userHome '.agents/skills/plan-production-change/SKILL.md'),
            (Join-Path $userHome '.claude/skills/plan-production-change/SKILL.md')
        )
        $personalHashes = @{}
        foreach ($path in $personalPaths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
            [IO.File]::WriteAllText($path,"personal excluded bytes`n")
            $personalHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }

        $run = Invoke-UnixSetup $userHome @()

        Assert-SetupTestExitCode $run 0
        foreach ($path in $personalPaths) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should BeExactly $personalHashes[$path] }
        @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).files | Where-Object { [string]$_.skillId -ceq 'plan-production-change' }).Count | Should Be 0
    }

    # Scenario: A descendant Catalog retires an installed default Skill with a valid replacement tombstone and alias.
    # Purpose: Treat removal/rename as an update, remove only prior manifest-owned bytes, and converge on the replacement rather than refusing update-failed.
    It 'CloudT6_updates_through_a_removed_default_skill_tombstone' {
        $userHome = New-UnixHome 'cloud-removed-default'
        Assert-SetupTestExitCode (Invoke-UnixSetup $userHome @()) 0
        $catalogPath = Join-Path $script:UnixRepo 'catalog/skills-catalog.json'
        try {
            $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
            $retired = @($catalog.skills | Where-Object id -eq 'plan-production-change')[0]
            $replacement = @($catalog.skills | Where-Object id -eq 'verify-data-access-performance')[0]
            $retired.profiles = @()
            $retired.lifecycle = [pscustomobject][ordered]@{status='removed';aliases=@();replacementId='verify-data-access-performance'}
            $replacement.lifecycle.aliases = @('plan-production-change')
            @($catalog.profiles | Where-Object id -eq 'core')[0].includes = @('verify-data-access-performance')
            [IO.File]::WriteAllText($catalogPath,(($catalog | ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
            & git -C $script:UnixRepo add catalog/skills-catalog.json 2>$null | Out-Null
            & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m removed-default 2>$null | Out-Null
            $next = [string](& git -C $script:UnixRepo rev-parse HEAD)

            $run = Invoke-UnixSetup $userHome @() -ExpectedCommit $next -NoCheckout

            Assert-SetupTestExitCode $run 0
            Test-Path -LiteralPath (Join-Path $userHome '.agents/skills/plan-production-change/SKILL.md') | Should Be $false
            Test-Path -LiteralPath (Join-Path $userHome '.claude/skills/plan-production-change/SKILL.md') | Should Be $false
            Test-Path -LiteralPath (Join-Path $userHome '.agents/skills/verify-data-access-performance/SKILL.md') -PathType Leaf | Should Be $true
            $manifest = Get-Content -Raw -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json') | ConvertFrom-Json
            @($manifest.files | Where-Object { [string]$_.skillId -ceq 'plan-production-change' }).Count | Should Be 0
        }
        finally { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null }
    }

    # Scenario: The USER coordinator or updater reports its normal lock-contention result during setup.
    # Purpose: Preserve the typed concurrent boundary at exit 26 instead of collapsing normal contention into projection/update failure.
    It 'CloudT7_maps_coordinator_and_updater_contention_to_concurrent' {
        $coordinatorHome = New-UnixHome 'cloud-coordinator-concurrent'
        Assert-SetupTestExitCode (Invoke-UnixSetup $coordinatorHome @()) 0
        [IO.File]::WriteAllText((Join-Path $coordinatorHome '.agents/fixture-coordinator-concurrent'),'busy')
        $coordinatorRun = Invoke-UnixSetup $coordinatorHome @()
        Assert-SetupTestExitCode $coordinatorRun 26
        $coordinatorRun.Json.code | Should BeExactly 'concurrent'

        $updaterHome = New-UnixHome 'cloud-updater-concurrent'
        Assert-SetupTestExitCode (Invoke-UnixSetup $updaterHome @()) 0
        [IO.File]::WriteAllText((Join-Path $updaterHome '.codex/fixture-updater-concurrent'),'busy')
        $sectionPath = Join-Path $script:UnixRepo 'instructions/common/bootstrap-section.md'
        try {
            [IO.File]::AppendAllText($sectionPath,"`nSYP-519 concurrent descendant`n")
            & git -C $script:UnixRepo add instructions/common/bootstrap-section.md 2>$null | Out-Null
            & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m concurrent-pin 2>$null | Out-Null
            $next = [string](& git -C $script:UnixRepo rev-parse HEAD)
            $updaterRun = Invoke-UnixSetup $updaterHome @() -ExpectedCommit $next -NoCheckout
            Assert-SetupTestExitCode $updaterRun 26
            $updaterRun.Json.code | Should BeExactly 'concurrent'
        }
        finally { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null }
    }
    }

    # Scenario: HOME is reached through a link, a setup ancestor dangles, or the persistent PowerShell temp directory is linked or non-private.
    # Purpose: S1/M7 refuse unsafe paths and modes before child runtime state can escape the setup-owned 0700 boundary.
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

        $linkedTmpHome = New-UnixHome 'linked-pwsh-tmp'
        $linkedTmp = Join-Path $linkedTmpHome '.local/share/ai-instructions-setup/pwsh-tmp'
        [void][IO.Directory]::CreateSymbolicLink($linkedTmp,$script:UnixRoot)
        $run = Invoke-UnixSetup $linkedTmpHome @('--offline')
        $run.ExitCode | Should Be 13; $run.Json.code | Should Be 'unsafe-path'

        $broadTmpHome = New-UnixHome 'broad-pwsh-tmp'
        $broadTmp = Join-Path $broadTmpHome '.local/share/ai-instructions-setup/pwsh-tmp'
        [void][IO.Directory]::CreateDirectory($broadTmp)
        [IO.File]::SetUnixFileMode($broadTmp,[IO.UnixFileMode]493)
        try {
            $run = Invoke-UnixSetup $broadTmpHome @('--offline')
            $run.ExitCode | Should Be 13; $run.Json.code | Should Be 'unsafe-path'
        } finally { [IO.File]::SetUnixFileMode($broadTmp,[IO.UnixFileMode]448) }
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
            $homePath = if ($case -ceq 'symlink') { New-UnixHome "cache-$case" -WithoutCache } else { New-UnixHome "cache-$case" }
            $cache = Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            if ($case -ceq 'mode') { [IO.File]::SetUnixFileMode($cache,[IO.UnixFileMode]438) }
            elseif ($case -ceq 'hardlink') { & /bin/ln $cache (Join-Path $homePath 'cache-alias'); $LASTEXITCODE | Should Be 0 }
            else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cache))
                foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup','.local/share/ai-instructions-setup/cache')) { [IO.File]::SetUnixFileMode((Join-Path $homePath $relative),[IO.UnixFileMode]448) }
                [void][IO.File]::CreateSymbolicLink($cache,$script:UnixArchives['runtime'].Path)
            }
            $before = Get-UnixTreeSnapshot $homePath
            $run = Invoke-UnixSetup $homePath @('--offline')
            $run.ExitCode | Should Be 13
            $run.Json.code | Should Be 'unsafe-path'
            (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
        }
    }

    # Scenario: Empty caches use curl/wget shims while malicious user config tries to redirect each downloader's output.
    # Purpose: F8/H4 requires curl -q or wget --no-config first, then publishes the reviewed fixture to a private cache without network.
    It 'InterT28_prepares_through_curl_and_wget_shims_and_publishes_a_private_cache' {
        $fixtureArchive = $script:UnixArchives['runtime'].Path
        $curlScript = @('[ "$1" = -q ] || exit 65','out=','while [ "$#" -gt 0 ]; do','  case "$1" in','    --output) out=$2; shift 2 ;;','    *) shift ;;','  esac','done','[ -n "$out" ] || exit 64',"cp -P '$fixtureArchive' `"`$out`"") -join "`n"
        $wgetScript = @('[ "$1" = --no-config ] || exit 65','out=','for arg in "$@"; do','  case "$arg" in --output-document=*) out=${arg#--output-document=} ;; esac','done','[ -n "$out" ] || exit 64',"cp -P '$fixtureArchive' `"`$out`"") -join "`n"
        foreach ($downloader in @('curl','wget')) {
            $homePath = New-UnixHome "download-$downloader" -WithoutCache
            $configMarker = Join-Path $homePath 'downloader-config-marker'
            [IO.File]::WriteAllText((Join-Path $homePath '.curlrc'),"--output $configMarker")
            [IO.File]::WriteAllText((Join-Path $homePath 'poison-wgetrc'),"output_document = $configMarker")
            $replace = @{}; $replace[$downloader] = if ($downloader -ceq 'curl') { $curlScript } else { $wgetScript }
            $exclude = if ($downloader -ceq 'curl') { @('wget') } else { @('curl') }
            $bin = New-UnixToolShim "download-$downloader" -Exclude $exclude -Replace $replace
            $run = Invoke-UnixSetup $homePath @('--prepare') -Environment @{ PATH=$bin; CURL_HOME=$homePath; WGETRC=(Join-Path $homePath 'poison-wgetrc') }
            Assert-SetupTestExitCode $run 0
            Assert-UnixPreparePlatformContract $run $homePath
            Test-Path -LiteralPath $configMarker | Should Be $false
            $cache = Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            Get-UnixMode $cache | Should Be '600'
            (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() | Should BeExactly $script:UnixArchives['runtime'].Sha256
        }
    }

    # Scenario: The local downloader exits nonzero or copies bytes that do not match the pinned fixture hash.
    # Purpose: F8 returns download-failed or archive-hash-mismatch and never publishes a cache/runtime.
    It 'InterT29_refuses_downloader_failure_and_downloaded_hash_mismatch' {
        foreach ($case in @('failure','hash')) {
            $homePath = New-UnixHome "download-$case" -WithoutCache
            $fixtureArchive = $script:UnixArchives['symlink'].Path
            $scriptText = if ($case -ceq 'failure') { 'exit 7' } else { @('out=','while [ "$#" -gt 0 ]; do','case "$1" in --output) out=$2; shift 2 ;; *) shift ;; esac','done',"cp -P '$fixtureArchive' `"`$out`"") -join "`n" }
            $bin = New-UnixToolShim "download-$case" -Exclude @('wget') -Replace @{ curl=$scriptText }
            $run = Invoke-UnixSetup $homePath @('--prepare') -Environment @{ PATH=$bin }
            $run.ExitCode | Should Be $(if ($case -ceq 'failure') { 17 } else { 18 })
            $run.Json.code | Should Be $(if ($case -ceq 'failure') { 'download-failed' } else { 'archive-hash-mismatch' })
            Test-Path -LiteralPath (Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)") | Should Be $false
            Test-Path -LiteralPath (Join-Path $homePath '.local/share/ai-instructions-setup/pwsh') | Should Be $false
        }
    }

    # Scenario: HEAD is wrong, a bound file is dirty, a staged deletion has an untracked substitute, or a bound file is a symlink.
    # Purpose: F9 exercises native shell K4 before setup/cache/temp/sentinel mutation.
    It 'InterT30_refuses_each_native_shell_K4_substitution_before_mutation' {
        $cases = @('wrong-head','dirty','staged-substitute','symlink','platform-side-effect')
        foreach ($case in $cases) {
            & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
            & git -C $script:UnixRepo reset -q HEAD -- . 2>$null | Out-Null
            $homePath = New-UnixHome "k4-$case" -WithoutCache
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
            $before = Get-UnixTreeSnapshot $homePath
            try {
                $run = Invoke-UnixSetup $homePath @('--offline') -ExpectedCommit $expected -NoCheckout
                $run.ExitCode | Should Be 15
                $run.Json.code | Should Be 'commit-mismatch'
                Test-Path -LiteralPath $marker | Should Be $false
                (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
                [IO.File]::ReadAllText($script:UnixSentinel) | Should Be 'sentinel'
            } finally { & git -C $script:UnixRepo checkout -q --detach -f $script:UnixCommits['runtime'] 2>$null | Out-Null }
        }
    }

    # Scenario: An explicit Unix mode is parsed before an early expected-commit refusal.
    # Purpose: Preserve the caller's --prepare/--offline mode in refusal receipts emitted before OS detection.
    It 'InterT30A_preserves_explicit_mode_in_early_shell_refusal_receipts' {
        foreach ($mode in @('prepare','offline')) {
            $homePath = New-UnixHome "early-mode-$mode" -WithoutCache
            $run = Invoke-UnixSetup $homePath @("--$mode") -ExpectedCommit ('z' * 40) -NoCheckout
            $run.ExitCode | Should Be 10
            $run.Json.code | Should BeExactly 'usage'
            $run.Json.mode | Should BeExactly $mode
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
            $homePath = New-UnixHome "dependency-$($case.Name)" -WithoutCache:(!$case.Cache)
            $before = Get-UnixTreeSnapshot $homePath
            $bin = New-UnixToolShim "dependency-$($case.Name)" -Exclude $case.Exclude
            $run = Invoke-UnixSetup $homePath @($case.Mode) -Environment @{ PATH=$bin }
            $run.ExitCode | Should Be 14
            $run.Json.code | Should Be 'missing-dependency'
            (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
            [IO.File]::ReadAllText($script:UnixSentinel) | Should Be 'sentinel'
        }
    }

    # Scenario: CODEX_HOME, USER, or legacy external transaction residue exists in a fresh independent HOME.
    # Purpose: G3/G5 refuse only external K7 state and emit the exact shared recovery command before mutation.
    It 'InterT32_refuses_external_K7_residue_with_exact_recovery_commands_and_unchanged_HOME' {
        foreach ($scope in @('codex','user','legacy')) {
            $homePath = New-UnixHome "residue-$scope" -WithoutCache
            $path = switch ($scope) {
                'codex' { Join-Path $homePath '.codex/.ai-instructions-txn' }
                'user' { Join-Path $homePath '.ai-instructions-txn' }
                'legacy' { Join-Path $homePath '.codex/.ai-instructions-install-fixture' }
            }
            [void][IO.Directory]::CreateDirectory($path)
            $residueLeaf = if ($scope -in @('codex','user')) { '.hidden-residue' } else { 'sentinel' }
            [IO.File]::WriteAllText((Join-Path $path $residueLeaf),'residue')
            $before = Get-UnixTreeSnapshot $homePath
            $policy=[IO.File]::ReadAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.json'))|ConvertFrom-Json
            $plan=Get-AgentEnvironmentSetupPlan -Policy $policy -UserHome $homePath -CodexHome (Join-Path $homePath '.codex') -Mode Prepare -ArchivePath '' -Rid $script:UnixRid
            $run = Invoke-UnixSetup $homePath @('--prepare')
            $run.ExitCode | Should Be 27
            $run.Json.code | Should Be 'interrupted-install'
            $expected=if($scope -ceq 'user'){'pwsh -NoProfile -NonInteractive -File ~/.codex/hooks/update-agent-environment.ps1 -Recover'}else{'pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap.ps1 -CodexHome ~/.codex'}
            $run.Json.recoverCommand | Should BeExactly $expected
            $run.Json.recoverCommand | Should BeExactly $plan.recoverCommand
            (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
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

    # Scenario: The loader probe reports musl on Linux or the same synthetic path on macOS.
    # Purpose: G12 refuses musl only for Linux, where the pinned glibc asset is incompatible, without applying Linux loader policy to macOS.
    It 'InterT35_scopes_the_controllable_musl_loader_probe_to_linux' {
        $homePath=New-UnixHome 'musl-probe'
        $realFind=@(Get-Command find -CommandType Application | Select-Object -First 1)[0].Source
        $findShim=@('if [ "$1" = /lib ] && [ "$2" = /usr/lib ]; then','  printf "%s\n" /lib/ld-musl-fixture.so.1','  exit 0','fi',"exec '$realFind' `"`$@`"") -join "`n"
        $bin=New-UnixToolShim 'musl-probe' -Replace @{find=$findShim}
        $run=Invoke-UnixSetup $homePath @('--offline') -Environment @{PATH=$bin}
        if ($IsLinux) {
            $run.ExitCode | Should Be 11;$run.Json.code | Should Be 'unsupported-platform'
            $control=Invoke-UnixSetup $homePath @('--offline')
            $control.Json.code | Should Not Be 'unsupported-platform'
        } else {
            $run.ExitCode | Should Be 21;$run.Json.code | Should Be 'runtime-missing'
        }
    }

    # Scenario: A HOME ancestor is writable by other users without sticky protection, and where possible owned by another uid.
    # Purpose: G12 rejects unsafe ancestor ownership/mode through behavior-level native fixtures.
    It 'InterT36_refuses_unsafe_ancestor_mode_and_owner' {
        $unsafeParent=Join-Path $script:UnixRoot 'unsafe-ancestor-mode';[void][IO.Directory]::CreateDirectory($unsafeParent)
        [IO.File]::SetUnixFileMode($unsafeParent,[IO.UnixFileMode]511)
        $homePath=Join-Path $unsafeParent 'home';[void][IO.Directory]::CreateDirectory($homePath);[IO.File]::SetUnixFileMode($homePath,[IO.UnixFileMode]448)
        try{$run=Invoke-UnixSetup $homePath @('--offline');$run.ExitCode | Should Be 13;$run.Json.code | Should Be 'unsafe-path'}finally{[IO.File]::SetUnixFileMode($unsafeParent,[IO.UnixFileMode]448)}
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
        $homePath=New-UnixHome 'cache-race'
        $initial=Invoke-UnixSetup $homePath @('--prepare')
        Assert-SetupTestExitCode $initial 0
        $barrier=Join-Path $script:UnixRoot ('cache-race-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($barrier)
        $fifo=Join-Path $barrier 'release';& mkfifo $fifo;$LASTEXITCODE | Should Be 0
        $ready=Join-Path $barrier 'ready';$realHash=@(Get-Command sha256sum -CommandType Application | Select-Object -First 1)[0].Source
        $hashShim=@("result=`$('$realHash' `"`$1`")","printf ready > '$ready'","IFS= read -r release < '$fifo'",'printf "%s\n" "$result"') -join "`n"
        $bin=New-UnixToolShim 'cache-race' -Replace @{sha256sum=$hashShim}
        $running=Start-UnixSetup $homePath @('--offline') -Environment @{PATH=$bin}
        try{
            $watcher=[IO.FileSystemWatcher]::new($barrier,'ready');$watcher.EnableRaisingEvents=$true
            try{if(-not [IO.File]::Exists($ready)){[void]$watcher.WaitForChanged([IO.WatcherChangeTypes]::Created,120000)}}finally{$watcher.Dispose()}
            [IO.File]::Exists($ready) | Should Be $true
            $cache=Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
            Move-Item -LiteralPath $cache -Destination ($cache+'.verified')
            Copy-Item -LiteralPath $script:UnixArchives['symlink'].Path -Destination $cache
            $writer=[IO.File]::Open($fifo,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes("release`n");$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}
            $run=Complete-UnixSetup $running;$running=$null
            Assert-SetupTestExitCode $run 0
            $run.Json.result | Should Be 'verified-runtime-only'
        }finally{if($null -ne $running){$running.Process.Kill($true);[void](Complete-UnixSetup $running)}}
    }

    # Scenario: The real PowerShell entry is killed after staging a setup receipt, then the documented shell entry is rerun.
    # Purpose: G3/G10 prove the shell does not refuse setup-owned WAL and reaches lock-held PowerShell recovery.
    It 'InterT38_recovers_a_setup_owned_journal_when_rerun_through_the_shell_entry' {
        $homePath=New-UnixHome 'shell-recovery'
        $initial=Invoke-UnixSetup $homePath @('--prepare');Assert-SetupTestExitCode $initial 0
        $cache=Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
        $start=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:UnixRepo 'scripts/setup-agent-environment.ps1'),'-Offline','-ExpectedCommit',$script:UnixCommits['runtime'],'-ArchivePath',$cache)){$start.ArgumentList.Add($argument)}
        $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.Environment['HOME']=$homePath;$start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT']='after-stage';$start.Environment['AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF']='setup-receipt.json';[void]$start.Environment.Remove('CODEX_HOME')
        $process=[Diagnostics.Process]::Start($start)
        try{$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();$process.WaitForExit(900000)|Should Be $true;$process.ExitCode|Should Not Be 0}finally{$process.Dispose()}
        Test-Path -LiteralPath (Join-Path $homePath '.local/share/ai-instructions-setup/.ai-instructions-txn') | Should Be $true
        $recovered=Invoke-UnixSetup $homePath @('--offline')
        Assert-SetupTestExitCode $recovered 0
        $recovered.Json.result | Should Be 'verified-runtime-only'
        Test-Path -LiteralPath (Join-Path $homePath '.local/share/ai-instructions-setup/.ai-instructions-txn') | Should Be $false
    }

    # Scenario: Caller-controlled shell startup and Git configuration variables are poisoned while a helper shim checks its own environment.
    # Purpose: H4 proves external helpers run from env -i with only explicit values, and Git ignores ambient config/worktree authority.
    It 'InterT39_isolates_external_helpers_from_ambient_environment_and_git_configuration' {
        $homePath = New-UnixHome 'helper-environment'
        $marker = Join-Path $script:UnixRoot 'helper-environment-marker'
        $tarAction = Join-Path $script:UnixRoot 'poison-tar-action.sh'
        $globalConfig = Join-Path $script:UnixRoot 'poison-gitconfig'
        [IO.File]::WriteAllText($tarAction,"#!/bin/sh`nprintf poisoned > '$marker'`n")
        [IO.File]::SetUnixFileMode($tarAction,[IO.UnixFileMode]448)
        [IO.File]::WriteAllText($globalConfig,"this is not valid git config`n")
        [IO.File]::WriteAllText((Join-Path $homePath '.gitconfig'),"this is also not valid git config`n")
        $realUname = @(Get-Command uname -CommandType Application | Select-Object -First 1)[0].Source
        $unameShim = @(
            '[ -z "${BASH_ENV+x}${ENV+x}${CDPATH+x}${GIT_DIR+x}${GIT_WORK_TREE+x}${GIT_CONFIG_COUNT+x}" ] || exit 91',
            "exec '$realUname' `"`$@`""
        ) -join "`n"
        $bin = New-UnixToolShim 'helper-environment' -Replace @{ uname=$unameShim }
        $run = Invoke-UnixSetup $homePath @('--prepare') -Environment @{
            PATH=$bin; CDPATH='/definitely/not/allowed'; TAR_OPTIONS="--checkpoint=1 --checkpoint-action=exec=$tarAction"
            GIT_DIR='/definitely/not/a/repository'; GIT_WORK_TREE='/definitely/not/a/worktree'
            GIT_CONFIG_GLOBAL=$globalConfig; GIT_CONFIG_NOSYSTEM='0'; GIT_CONFIG_COUNT='1'
            GIT_CONFIG_KEY_0='core.fsmonitor'; GIT_CONFIG_VALUE_0=$tarAction; CURL_HOME=$homePath; WGETRC=$globalConfig
        }
        Assert-SetupTestExitCode $run 0
        Assert-UnixPreparePlatformContract $run $homePath
        Test-Path -LiteralPath $marker | Should Be $false
    }

    # Scenario: The receipt-named Unix runtime root keeps its approved bytes but drifts from mode 0700 before an offline rerun.
    # Purpose: H5 proves the real shell-to-PowerShell offline path invokes K15 permission verification and returns the typed refusal.
    It 'InterT40_offline_refuses_unix_runtime_mode_drift' {
        $homePath = New-UnixHome 'offline-runtime-mode'
        $initial = Invoke-UnixSetup $homePath @('--prepare')
        Assert-SetupTestExitCode $initial 0
        $runtimeReceipt = Get-Content -Raw -LiteralPath (Join-Path $homePath ".local/share/ai-instructions-setup/receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json") | ConvertFrom-Json
        $runtimeRoot = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.runtimeClosure.rootPath) $homePath
        [IO.File]::SetUnixFileMode($runtimeRoot,[IO.UnixFileMode]493)
        try {
            $run = Invoke-UnixSetup $homePath @('--offline')
            $run.ExitCode | Should Be 23
            $run.Json.code | Should Be 'runtime-verification-failed'
        } finally { [IO.File]::SetUnixFileMode($runtimeRoot,[IO.UnixFileMode]448) }
    }

    # Scenario: A previous forced termination left an old run-specific tmp tree, while a mktemp shim records two current run directories before cleanup.
    # Purpose: H3/J5 proves each run uses a distinct run.<pid>.<random> directory, cleanup removes only current runs, and the old tree is unchanged.
    It 'InterT41_preserves_old_tmp_trees_while_cleaning_the_current_run' {
        $homePath = New-UnixHome 'tmp-orphan'
        $tmpRoot = Join-Path $homePath '.local/share/ai-instructions-setup/tmp'
        $old = Join-Path $tmpRoot 'run.1234.old-orphan'
        [void][IO.Directory]::CreateDirectory($old)
        [IO.File]::SetUnixFileMode($tmpRoot,[IO.UnixFileMode]448)
        [IO.File]::SetUnixFileMode($old,[IO.UnixFileMode]448)
        [IO.File]::WriteAllText((Join-Path $old 'sentinel'),'preserve')
        [IO.File]::SetUnixFileMode((Join-Path $old 'sentinel'),[IO.UnixFileMode]384)
        $before = Get-UnixTreeSnapshot $old
        $mtime = (Get-Item -LiteralPath $old).LastWriteTimeUtc.Ticks
        $record = Join-Path $script:UnixRoot 'tmp-run-names'
        $realMktemp = @(Get-Command mktemp -CommandType Application | Select-Object -First 1)[0].Source
        $mktempShim = @(
            "result=`$('$realMktemp' `"`$@`") || exit `$?",
            "printf '%s\n' `"`$result`" >> '$record'",
            "printf '%s\n' `"`$result`""
        ) -join "`n"
        $bin = New-UnixToolShim 'tmp-run-names' -Replace @{ mktemp=$mktempShim }
        $first = Invoke-UnixSetup $homePath @('--prepare') -Environment @{ PATH=$bin }
        Assert-SetupTestExitCode $first 0
        $second = Invoke-UnixSetup $homePath @('--offline') -Environment @{ PATH=$bin }
        Assert-SetupTestExitCode $second 0
        $recorded = @(Get-Content -LiteralPath $record)
        $recorded.Count | Should Be 2
        foreach ($path in $recorded) { [IO.Path]::GetFileName($path) | Should Match '^run\.[0-9]+\.[A-Za-z0-9]+$' }
        $recorded[0] | Should Not BeExactly $recorded[1]
        (Get-UnixTreeSnapshot $old) | Should BeExactly $before
        (Get-Item -LiteralPath $old).LastWriteTimeUtc.Ticks | Should Be $mtime
        Assert-NoUnixSetupRunDirectories -TmpRoot $tmpRoot -PreservedPath $old
    }

    # Scenario: The cache directory itself is a symbolic link to an external directory, or a dangling symbolic link.
    # Purpose: Refuse both intermediate-link forms as unsafe-path before reading cache bytes, while HOME and external setup state remain byte-identical.
    It 'InterT47_refuses_symbolic_and_dangling_cache_directories_without_mutation' {
        $linkedHome = New-UnixHome 'cache-directory-link' -WithoutCache
        $linkedSetupRoot = Join-Path $linkedHome '.local/share/ai-instructions-setup'
        [void][IO.Directory]::CreateDirectory($linkedSetupRoot)
        foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup')) {
            [IO.File]::SetUnixFileMode((Join-Path $linkedHome $relative),[IO.UnixFileMode]448)
        }
        $externalCache = Join-Path $script:UnixRoot 'external-cache-directory'
        [void][IO.Directory]::CreateDirectory($externalCache)
        [IO.File]::SetUnixFileMode($externalCache,[IO.UnixFileMode]448)
        Copy-Item -LiteralPath $script:UnixArchives['runtime'].Path -Destination (Join-Path $externalCache $script:UnixAssetName)
        [IO.File]::SetUnixFileMode((Join-Path $externalCache $script:UnixAssetName),[IO.UnixFileMode]384)
        [void][IO.Directory]::CreateSymbolicLink((Join-Path $linkedSetupRoot 'cache'),$externalCache)
        $linkedHomeBefore = Get-UnixTreeSnapshot $linkedHome
        $externalBefore = Get-UnixTreeSnapshot $externalCache

        $linkedRun = Invoke-UnixSetup $linkedHome @('--offline')

        $linkedRun.ExitCode | Should Be 13
        $linkedRun.Json.code | Should Be 'unsafe-path'
        (Get-UnixTreeSnapshot $linkedHome) | Should BeExactly $linkedHomeBefore
        (Get-UnixTreeSnapshot $externalCache) | Should BeExactly $externalBefore

        $danglingHome = New-UnixHome 'cache-directory-dangling' -WithoutCache
        $danglingSetupRoot = Join-Path $danglingHome '.local/share/ai-instructions-setup'
        [void][IO.Directory]::CreateDirectory($danglingSetupRoot)
        foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup')) {
            [IO.File]::SetUnixFileMode((Join-Path $danglingHome $relative),[IO.UnixFileMode]448)
        }
        $missingCache = Join-Path $script:UnixRoot 'missing-cache-directory'
        [void][IO.Directory]::CreateSymbolicLink((Join-Path $danglingSetupRoot 'cache'),$missingCache)
        $danglingBefore = Get-UnixTreeSnapshot $danglingHome

        $danglingRun = Invoke-UnixSetup $danglingHome @('--offline')

        $danglingRun.ExitCode | Should Be 13
        $danglingRun.Json.code | Should Be 'unsafe-path'
        (Get-UnixTreeSnapshot $danglingHome) | Should BeExactly $danglingBefore
        Test-Path -LiteralPath $missingCache | Should Be $false
    }

    # Scenario: macOS-compatible cp and tar shims create AppleDouble companions for the known archive snapshot and pwsh member.
    # Purpose: Cleanup removes only the exact inventory-derived sidecars and still reclaims the current run without scanning unknown entries.
    It 'InterT50_cleans_inventory_derived_AppleDouble_members_without_tree_deletion' {
        $homePath=New-UnixHome 'appledouble-cleanup'
        $realTar=@(Get-Command tar -CommandType Application | Select-Object -First 1)[0].Source
        $tarShim=@(
            "'$realTar' `"`$@`" || exit `$?",
            'extract=0; destination=',
            'while [ "$#" -gt 0 ]; do',
            '  case "$1" in',
            '    -xzf) extract=1; shift 2 ;;',
            '    -C) destination=$2; shift 2 ;;',
            '    *) shift ;;',
            '  esac',
            'done',
            'if [ "$extract" -eq 1 ] && [ -n "$destination" ]; then printf appledouble > "$destination/._pwsh"; fi'
        ) -join "`n"
        $realCp=@(Get-Command cp -CommandType Application | Select-Object -First 1)[0].Source
        $cpShim=@(
            "'$realCp' `"`$@`" || exit `$?",
            'destination=',
            'for argument do destination=$argument; done',
            'case "$destination" in',
            '  */*) directory=${destination%/*}; leaf=${destination##*/}; printf appledouble > "$directory/._$leaf" ;;',
            'esac'
        ) -join "`n"
        $bin=New-UnixToolShim 'appledouble-cleanup' -Replace @{tar=$tarShim;cp=$cpShim}
        $run=Invoke-UnixSetup $homePath @('--prepare') -Environment @{PATH=$bin}
        Assert-SetupTestExitCode $run 0
        $tmpRoot=Join-Path $homePath '.local/share/ai-instructions-setup/tmp'
        Assert-NoUnixSetupRunDirectories -TmpRoot $tmpRoot
    }

    # Register only when the native test process can create a genuinely foreign-owned cache fixture.
    if ($setupTestUnixUid -eq '0') {
    # Scenario: A cached archive is owned by a different uid.
    # Purpose: F2 returns unsafe-path rather than consuming foreign-owned cache bytes.
    It 'InterT33_refuses_a_foreign_owned_cache_file' {
        $homePath = New-UnixHome 'cache-owner'
        $cache = Join-Path $homePath ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
        & chown 1 $cache
        $LASTEXITCODE | Should Be 0
        $before = Get-UnixTreeSnapshot $homePath
        $run = Invoke-UnixSetup $homePath @('--offline')
        $run.ExitCode | Should Be 13
        $run.Json.code | Should Be 'unsafe-path'
        (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
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

Describe 'setup-agent-environment Unix null optional leaf publication (SYP-354 P10a)' -Tag 'UnixNullOptionalLeaf' {
    BeforeAll {
        $UnixFixtureName = 'unix-setup-null-optional-leaf'
        . (Join-Path $PSScriptRoot 'setup-agent-environment.UnixFixture.ps1')
    }

    AfterAll {
        & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
        Remove-Module agent-environment-setup -Force -ErrorAction SilentlyContinue
    }

    # Scenario: A lock holder publishes the first setup receipt, so both journal.json and the target have absent expected state and null displaced leaves.
    # Purpose: Protect the two Unix no-replace publication calls from null-to-empty optional-leaf coercion.
    It 'InterT42_publishes_the_first_journal_and_setup_receipt_with_null_displaced_leaves' {
        $homePath=New-UnixHome 'null-leaf-first-receipt' -WithoutCache
        $layout=Get-AgentEnvironmentSetupLayout $homePath $script:UnixRid $script:UnixVersion
        $created=Open-PlatformDirectory -Root $homePath -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate;$created.Dispose()
        $setup=Open-PlatformDirectory -Root $layout.SetupRoot -RootOnly
        $lock=Enter-PlatformLock -ParentLease $setup -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        [byte[]]$expected=[Text.UTF8Encoding]::new($false).GetBytes("{`"case`":`"first-setup-receipt`"}`n")
        try{Publish-AgentEnvironmentSetupFile -SetupRoot $layout.SetupRoot -Directory receipts -Leaf 'setup-receipt.json' -Bytes $expected -NoReplace}
        finally{$lock.Dispose();$setup.Dispose()}
        $target=Join-Path $layout.ReceiptDirectory 'setup-receipt.json'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) | Should BeExactly ([Convert]::ToBase64String($expected))
        Assert-UnixSetupTransactionClean $layout.SetupRoot
        Assert-UnixSetupLockReleased $layout.SetupRoot
        Assert-UnixPrivatePath $layout.SetupRoot '700'
        Assert-UnixPrivatePath $target '600'
    }

    # Scenario: A lock holder publishes the first runtime receipt and then the first shared archive cache into otherwise absent targets.
    # Purpose: Cover both remaining setup call sites that pass ExpectedState.exists=false, DisplacedLeaf=null, and NoReplace.
    It 'InterT43_publishes_the_first_runtime_receipt_and_shared_cache_with_null_displaced_leaves' {
        $homePath=New-UnixHome 'null-leaf-runtime-cache' -WithoutCache
        $layout=Get-AgentEnvironmentSetupLayout $homePath $script:UnixRid $script:UnixVersion
        $created=Open-PlatformDirectory -Root $homePath -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate;$created.Dispose()
        $setup=Open-PlatformDirectory -Root $layout.SetupRoot -RootOnly
        $lock=Enter-PlatformLock -ParentLease $setup -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        [byte[]]$receiptBytes=[Text.UTF8Encoding]::new($false).GetBytes("{`"case`":`"first-runtime-receipt`"}`n")
        try{
            Publish-AgentEnvironmentSetupFile -SetupRoot $layout.SetupRoot -Directory receipts -Leaf $layout.RuntimeReceiptLeaf -Bytes $receiptBytes -NoReplace
            Assert-UnixSetupTransactionClean $layout.SetupRoot
            (Publish-AgentEnvironmentSetupArchiveCache -SetupRoot $layout.SetupRoot -Leaf $script:UnixAssetName -ArchivePath $script:UnixArchives['runtime'].Path -ExpectedSha256 $script:UnixArchives['runtime'].Sha256) | Should BeExactly 'published'
        } finally {$lock.Dispose();$setup.Dispose()}
        $receipt=Join-Path $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf
        $cache=Join-Path (Join-Path $layout.SetupRoot 'cache') $script:UnixAssetName
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($receipt)) | Should BeExactly ([Convert]::ToBase64String($receiptBytes))
        (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() | Should BeExactly $script:UnixArchives['runtime'].Sha256
        Assert-UnixSetupTransactionClean $layout.SetupRoot
        Assert-UnixSetupLockReleased $layout.SetupRoot
        Assert-UnixPrivatePath $receipt '600'
        Assert-UnixPrivatePath $cache '600'
    }

    # Scenario: A real setup child aborts after displacing setup-receipt.json but before publishing its stage, then the same real shell entry is rerun.
    # Purpose: Exercise publish-after-displace with resumeExpected.exists=false and a null displaced leaf through the Unix adapter.
    It 'InterT44_recovers_publish_after_displace_with_a_null_resume_displaced_leaf' {
        $homePath=New-UnixHome 'null-leaf-publish-after-displace'
        $initial=Invoke-UnixSetup $homePath @('--prepare');Assert-SetupTestExitCode $initial 0
        $shimRepo=Join-Path $script:UnixRoot ('after-displace-repo-'+[guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:UnixRepo -Destination $shimRepo -Recurse
        $native=Join-Path $shimRepo 'scripts/platform/UnixNative.cs'
        $text=[IO.File]::ReadAllText($native)
        $needle='                        displaced = true;'
        ([regex]::Matches($text,[regex]::Escape($needle))).Count | Should Be 1
        $injection=$needle+"`n                        if (Environment.GetEnvironmentVariable(`"AI_INSTRUCTIONS_SETUP_FAILPOINT`") == `"after-displace`") Environment.FailFast(`"after Unix target displacement`");"
        $text=$text.Replace($needle,$injection)
        [IO.File]::WriteAllText($native,$text,[Text.UTF8Encoding]::new($false))
        $manifestPath=Join-Path $shimRepo 'scripts/platform-runtime.psd1'
        $manifestText=[IO.File]::ReadAllText($manifestPath)
        $hash=Get-AgentEnvironmentSetupSha256Text ([IO.File]::ReadAllText($native))
        $manifestText=[regex]::Replace($manifestText,"(?m)(Path = 'platform/UnixNative\.cs'; Sha256 = ')[a-f0-9]{64}(')",('${1}'+$hash+'$2'))
        [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
        & git -C $shimRepo add -A 2>$null | Out-Null
        & git -C $shimRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m after-displace 2>$null | Out-Null
        $shimCommit=[string](& git -C $shimRepo rev-parse HEAD)
        $shimShell=Join-Path $shimRepo 'scripts/setup-agent-environment.sh'
        $shimEntry=Join-Path $shimRepo 'scripts/setup-agent-environment.ps1'
        $crashed=Invoke-UnixSetupPowerShellChild $homePath Offline -ExpectedCommit $shimCommit -NoCheckout -EntryPath $shimEntry -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT='after-displace'}
        $crashed.ExitCode | Should Not Be 0
        $store=Join-Path $homePath '.local/share/ai-instructions-setup/.ai-instructions-txn'
        $transaction=@(Get-ChildItem -LiteralPath $store -Directory -Force);$transaction.Count | Should Be 1
        foreach($leaf in @('stage','displaced','journal.json')){Test-Path -LiteralPath (Join-Path $transaction[0].FullName $leaf) -PathType Leaf | Should Be $true}
        $target=Join-Path $homePath '.local/share/ai-instructions-setup/receipts/setup-receipt.json'
        Test-Path -LiteralPath $target | Should Be $false
        [byte[]]$expected=[IO.File]::ReadAllBytes((Join-Path $transaction[0].FullName 'stage'))
        Assert-UnixSetupLockReleased (Join-Path $homePath '.local/share/ai-instructions-setup')
        $recovered=Invoke-UnixSetup $homePath @('--offline') -ExpectedCommit $shimCommit -NoCheckout -EntryPath $shimShell
        Assert-SetupTestExitCode $recovered 0;$recovered.Json.result | Should Be 'verified-runtime-only'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) | Should BeExactly ([Convert]::ToBase64String($expected))
        $setupRoot=Join-Path $homePath '.local/share/ai-instructions-setup'
        Assert-UnixSetupTransactionClean $setupRoot
        Assert-UnixSetupLockReleased $setupRoot
        $runtimeReceipt=Get-Content -Raw -LiteralPath (Join-Path $setupRoot "receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json")|ConvertFrom-Json
        $runtimeRoot=ConvertFrom-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.runtimeClosure.rootPath) $homePath
        Assert-UnixPrivatePath $target '600';Assert-UnixPrivatePath $runtimeRoot '700'
    }

    # Scenario: Real child aborts leave stage+journal.json or displaced+journal.json, and a real entry rerun repairs each transaction.
    # Purpose: Exercise Remove-AgentEnvironmentSetupTransactionFile cleanup mode for stage, displaced, and journal.json without tombstone arguments.
    It 'InterT45_cleans_stage_displaced_and_journal_files_without_tombstone_leaves' {
        foreach($case in @(@{Point='during-stage-write';Members=@('stage','journal.json')},@{Point='after-rename';Members=@('displaced','journal.json')})){
            $homePath=New-UnixHome ('null-leaf-cleanup-'+$case.Point)
            $initial=Invoke-UnixSetup $homePath @('--prepare');Assert-SetupTestExitCode $initial 0
            $crashed=Invoke-UnixSetupPowerShellChild $homePath Offline -Environment @{AI_INSTRUCTIONS_SETUP_FAILPOINT=$case.Point;AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF='setup-receipt.json'}
            $crashed.ExitCode | Should Not Be 0
            $setupRoot=Join-Path $homePath '.local/share/ai-instructions-setup'
            $transaction=@(Get-ChildItem -LiteralPath (Join-Path $setupRoot '.ai-instructions-txn') -Directory -Force);$transaction.Count | Should Be 1
            foreach($leaf in $case.Members){Test-Path -LiteralPath (Join-Path $transaction[0].FullName $leaf) -PathType Leaf | Should Be $true}
            Assert-UnixSetupLockReleased $setupRoot
            $recovered=Invoke-UnixSetup $homePath @('--offline')
            Assert-SetupTestExitCode $recovered 0;$recovered.Json.result | Should Be 'verified-runtime-only'
            $target=Join-Path $setupRoot 'receipts/setup-receipt.json'
            [IO.File]::ReadAllText($target) | Should BeExactly ($recovered.Lines[0]+"`n")
            Assert-UnixSetupTransactionClean $setupRoot
            Assert-UnixSetupLockReleased $setupRoot
            Assert-UnixPrivatePath $target '600'
        }
    }

    # Scenario: A genuinely empty private HOME downloads only from a local fixture shim, prepares once, and then reruns offline.
    # Purpose: Prove the complete native shell entry covers every null optional leaf and leaves A6-private runtime and receipt state.
    It 'InterT46_prepares_an_empty_HOME_from_the_local_fixture_and_then_verifies_offline' {
        $homePath=New-UnixHome 'null-leaf-empty-home' -WithoutCache
        @(Get-ChildItem -LiteralPath $homePath -Force).Count | Should Be 0
        $fixtureArchive=$script:UnixArchives['runtime'].Path
        $curlScript=@('[ "$1" = -q ] || exit 65','out=','while [ "$#" -gt 0 ]; do','case "$1" in --output) out=$2; shift 2 ;; *) shift ;; esac','done','[ -n "$out" ] || exit 64',"cp -P '$fixtureArchive' `"`$out`"") -join "`n"
        $bin=New-UnixToolShim 'null-leaf-empty-home' -Exclude @('wget') -Replace @{curl=$curlScript}
        $prepare=Invoke-UnixSetup $homePath @('--prepare') -Environment @{PATH=$bin}
        Assert-SetupTestExitCode $prepare 0;Assert-UnixPreparePlatformContract $prepare $homePath
        $offline=Invoke-UnixSetup $homePath @('--offline')
        Assert-SetupTestExitCode $offline 0;$offline.Json.result | Should Be 'verified-runtime-only'
        $setupRoot=Join-Path $homePath '.local/share/ai-instructions-setup'
        $setupReceipt=Join-Path $setupRoot 'receipts/setup-receipt.json'
        $runtimeReceiptPath=Join-Path $setupRoot "receipts/runtime-$($script:UnixVersion)-$($script:UnixRid).json"
        [IO.File]::ReadAllText($setupReceipt) | Should BeExactly ($offline.Lines[0]+"`n")
        (Get-FileHash -LiteralPath (Join-Path $setupRoot "cache/$($script:UnixAssetName)") -Algorithm SHA256).Hash.ToLowerInvariant() | Should BeExactly $script:UnixArchives['runtime'].Sha256
        $runtimeReceipt=Get-Content -Raw -LiteralPath $runtimeReceiptPath|ConvertFrom-Json
        $runtimeRoot=ConvertFrom-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.runtimeClosure.rootPath) $homePath
        Test-Path -LiteralPath (Join-Path $runtimeRoot 'pwsh') -PathType Leaf | Should Be $true
        Assert-UnixSetupTransactionClean $setupRoot
        Assert-UnixSetupLockReleased $setupRoot
        foreach($directory in @($setupRoot,$runtimeRoot)){Assert-UnixPrivatePath $directory '700'}
        foreach($file in @($setupReceipt,$runtimeReceiptPath,(Join-Path $setupRoot "cache/$($script:UnixAssetName)"))){Assert-UnixPrivatePath $file '600'}
        Assert-UnixPrivatePath (Join-Path $runtimeRoot 'pwsh') '700'
    }

    # Scenario: refs/replace maps the expected commit to a malicious tree whose bound module is staged and present in the worktree.
    # Purpose: J1 makes the native shell reject before PowerShell loads, leaves HOME byte-identical, and ignores the replacement object.
    It 'InterT48_refuses_a_replace_object_before_repository_PowerShell_can_run' {
        $homePath = New-UnixHome 'replace-object'
        $before = Get-UnixTreeSnapshot $homePath
        $expected = $script:UnixCommits['runtime']
        $target = Join-Path $script:UnixRepo 'scripts/agent-environment-setup.psm1'
        $marker = Join-Path $script:UnixRoot 'replace-object-marker'
        $original = [IO.File]::ReadAllBytes($target)
        $injection = "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','loaded')`n"
        [IO.File]::WriteAllBytes($target,[Text.UTF8Encoding]::new($false).GetBytes($injection + [Text.UTF8Encoding]::new($false,$true).GetString($original)))
        & git -C $script:UnixRepo add -- scripts/agent-environment-setup.psm1 2>$null | Out-Null
        & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q -m replace-object 2>$null | Out-Null
        $malicious = [string](& git -C $script:UnixRepo rev-parse HEAD)
        $maliciousBytes = [IO.File]::ReadAllBytes($target)
        & git -C $script:UnixRepo replace $expected $malicious 2>$null | Out-Null
        $previousNoReplace = [Environment]::GetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS')
        try {
            [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS','1')
            & git -C $script:UnixRepo checkout -q --detach $expected 2>$null | Out-Null
            [IO.File]::WriteAllBytes($target,$maliciousBytes)
            & git -C $script:UnixRepo add -- scripts/agent-environment-setup.psm1 2>$null | Out-Null
            $run = Invoke-UnixSetup $homePath @('--prepare') -ExpectedCommit $expected -NoCheckout
            $run.ExitCode | Should Be 15
            $run.Json.code | Should Be 'commit-mismatch'
            Test-Path -LiteralPath $marker | Should Be $false
            (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
        } finally {
            [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS','1')
            & git -C $script:UnixRepo replace -d $expected 2>$null | Out-Null
            & git -C $script:UnixRepo checkout -q --detach $expected 2>$null | Out-Null
            [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS',$previousNoReplace)
        }
    }

    # Scenario: .git/info/attributes selects a local clean filter that hides a tampered bound module and writes an execution marker.
    # Purpose: J1 hashes raw worktree bytes without invoking the filter and refuses before any HOME mutation.
    It 'InterT49_refuses_a_filter_hidden_tamper_without_executing_the_filter' {
        $homePath = New-UnixHome 'local-clean-filter'
        $before = Get-UnixTreeSnapshot $homePath
        $expected = $script:UnixCommits['runtime']
        & git -C $script:UnixRepo checkout -q --detach $expected 2>$null | Out-Null
        $target = Join-Path $script:UnixRepo 'scripts/agent-environment-setup.psm1'
        $original = Join-Path $script:UnixRoot 'filter-original-module'
        [IO.File]::WriteAllBytes($original,[IO.File]::ReadAllBytes($target))
        [IO.File]::AppendAllText($target,"`n")
        $marker = Join-Path $script:UnixRoot 'local-clean-filter-marker'
        $filter = Join-Path $script:UnixRoot 'local-clean-filter.sh'
        [IO.File]::WriteAllText($filter,"#!/bin/sh`nprintf invoked > '$marker'`ncat '$original'`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::SetUnixFileMode($filter,[IO.UnixFileMode]448)
        & git -C $script:UnixRepo config filter.hide.clean "sh $filter" 2>$null | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:UnixRepo '.git/info/attributes'),"scripts/agent-environment-setup.psm1 filter=hide`n",[Text.UTF8Encoding]::new($false))
        & git -C $script:UnixRepo hash-object --path scripts/agent-environment-setup.psm1 -- $target 2>$null | Out-Null
        Test-Path -LiteralPath $marker | Should Be $true
        Remove-Item -LiteralPath $marker -Force
        try {
            $run = Invoke-UnixSetup $homePath @('--prepare') -ExpectedCommit $expected -NoCheckout
            $run.ExitCode | Should Be 15
            $run.Json.code | Should Be 'commit-mismatch'
            Test-Path -LiteralPath $marker | Should Be $false
            (Get-UnixTreeSnapshot $homePath) | Should BeExactly $before
        } finally {
            & git -C $script:UnixRepo config --unset-all filter.hide.clean 2>$null | Out-Null
            Remove-Item -LiteralPath (Join-Path $script:UnixRepo '.git/info/attributes') -Force -ErrorAction SilentlyContinue
            & git -C $script:UnixRepo checkout -q --detach $expected 2>$null | Out-Null
        }
    }
}
}
