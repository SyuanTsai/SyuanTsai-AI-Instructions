# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# SYP-354 P10a PowerShell entry (S5/S6). Invoked by setup-agent-environment.sh
# with a bootstrap pwsh expanded in the setup temp directory, or directly with
# pwsh on Windows (-ArchivePath <local official zip>). It prepares or re-verifies
# the canonical pwsh under ~/.local/share/ai-instructions-setup, re-executes
# itself with that canonical pwsh (-Canonical), and prints one JSON receipt line.
# S7-S9 (installer, USER projections, readiness) are P10b and are reported as
# 'not-implemented-until-p10b'. This script never calls an installer, updater
# or coordinator, never modifies a shell profile and never writes CODEX_HOME.
[CmdletBinding()]
param(
    [switch] $Prepare,
    [switch] $Offline,
    [string] $ExpectedCommit,
    [string] $ArchivePath,
    [switch] $Canonical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
# Must equal the 'runtime-baseline-unavailable' row of the shared exit-code table;
# it is used before the shared module can be loaded.
$script:SetupBaselineExitCode = 24
$script:SetupInternalExitCode = 1

function Write-SetupLine {
    param([Parameter(Mandatory = $true)][string] $Text)
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
}

function Write-SetupDiagnostic {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    [Console]::Error.WriteLine('setup-agent-environment: ' + $Text)
    [Console]::Error.Flush()
}

$modeName = if ($Offline -and -not $Prepare) { 'offline' } else { 'prepare' }
$exitCode = $script:SetupInternalExitCode
$lock = $null
$setupLease = $null
$userHome = $null
$rid = $null
$policyInfo = $null
$moduleLoaded = $false
$recoverCommand = $null

if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or [Environment]::Version.Major -lt 8) {
    Write-SetupDiagnostic 'PowerShell 7 on .NET 8 or later is required.'
    Write-SetupLine ('{"schemaVersion":1,"kind":"agent-environment-setup-receipt","phase":"p10a","result":"refused","code":"runtime-baseline-unavailable","exitCode":' + $script:SetupBaselineExitCode + '}')
    exit $script:SetupBaselineExitCode
}

try {
    Import-Module (Join-Path $PSScriptRoot 'agent-environment-setup.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'platform-runtime.psd1') -DisableNameChecking -ErrorAction Stop
    $moduleLoaded = $true
    if ($Prepare -eq $Offline) { throw (New-AgentEnvironmentSetupRefusal usage 'Exactly one of -Prepare or -Offline is required.') }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { throw (New-AgentEnvironmentSetupRefusal usage '-ArchivePath is required.') }
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw (New-AgentEnvironmentSetupRefusal usage '-ExpectedCommit must be a 40-character lowercase hexadecimal commit.') }
    $mode = if ($Prepare) { 'Prepare' } else { 'Offline' }
    $repositoryRoot = Split-Path -Parent $PSScriptRoot

    # S1 (PowerShell side): host RID, HOME, link-free ancestors, CODEX_HOME (H5).
    $rid = Get-AgentEnvironmentSetupRid
    $userHome = Get-AgentEnvironmentSetupUserHome
    $codexHome = Assert-AgentEnvironmentSetupCodexHome $userHome
    $policyInfo = Read-AgentEnvironmentSetupPolicy (Join-Path $PSScriptRoot 'setup-agent-environment.policy.json')
    Assert-AgentEnvironmentSetupPolicyTsv $policyInfo.Policy (Join-Path $PSScriptRoot 'setup-agent-environment.policy.tsv')
    $asset = Get-AgentEnvironmentSetupPolicyAsset $policyInfo.Policy $rid
    $layout = Get-AgentEnvironmentSetupLayout $userHome $rid $asset.Version
    foreach ($pair in @(@($userHome,'HOME'),@($layout.SetupRoot,'The setup root'),@($codexHome,'CODEX_HOME'))) { Assert-AgentEnvironmentSetupPhysicalPath $pair[0] $pair[1] }
    $archive = [IO.Path]::GetFullPath($ArchivePath)

    if ($Canonical) {
        # Canonical stage: read-only. The bootstrap stage holds the setup lock.
        $processPath = [Environment]::ProcessPath
        if ([string]::IsNullOrEmpty($processPath) -or -not (Test-AgentEnvironmentSetupSameFile $processPath $layout.RuntimeExecutable)) {
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage is not running on the canonical pwsh.')
        }
        $stored = Read-AgentEnvironmentSetupFile $layout.SetupRoot 'receipts' $layout.RuntimeReceiptLeaf
        if ($null -eq $stored) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete 'The canonical runtime receipt is missing.') }
        try {
            $runtimeReceipt = ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt ([Text.UTF8Encoding]::new($false,$true).GetString($stored.Bytes) | ConvertFrom-Json) $userHome
            [void](Assert-PlatformPowerShellRuntime -Policy $policyInfo.Policy -Receipt $runtimeReceipt)
        } catch {
            if ((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error') { throw }
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('Canonical runtime re-verification failed: ' + $_.Exception.Message))
        }
        try { $capabilities = Get-PlatformCapabilities -Required (Get-AgentEnvironmentSetupRequiredCapabilities) }
        catch { throw (New-AgentEnvironmentSetupRefusal capability-unavailable ('A required platform capability is unavailable: ' + $_.Exception.Message)) }
        # S6: process scope only; nothing is persisted (D4).
        [void](Set-PlatformProcessEnvironment -Name CODEX_HOME -Value $codexHome)
        Write-SetupLine (ConvertTo-AgentEnvironmentSetupJsonLine ([pscustomobject][ordered]@{
            schemaVersion = 1; stage = 'canonical'
            executablePath = (ConvertTo-AgentEnvironmentSetupHomePath $layout.RuntimeExecutable $userHome)
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            dotNetVersion = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            codexHome = (ConvertTo-AgentEnvironmentSetupHomePath ([Environment]::GetEnvironmentVariable('CODEX_HOME')) $userHome)
            processPathVerified = $true
            capabilities = @($capabilities.capabilities | ForEach-Object { [pscustomobject][ordered]@{ name = [string]$_.name; status = [string]$_.status } })
        }))
        $exitCode = 0
    } else {

    # K4: pinned revision before any mutation.
    Assert-AgentEnvironmentSetupCommit $repositoryRoot $ExpectedCommit

    # M4/M8: private setup root, serialized by an exclusive platform lock.
    $setupLease = Open-PlatformDirectory -Root $userHome -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate
    try { $lock = Enter-PlatformLock -ParentLease $setupLease -Leaf $layout.LockLeaf -Mode Exclusive -Timeout ([TimeSpan]::Zero) }
    catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [TimeoutException]) { throw (New-AgentEnvironmentSetupRefusal concurrent 'Another agent environment setup holds the setup lock.') }
        throw
    }

    # K7: read-only plan before any runtime mutation.
    $plan = Get-AgentEnvironmentSetupPlan -Policy $policyInfo.Policy -UserHome $userHome -CodexHome $codexHome -Mode $mode -ArchivePath $archive -Rid $rid
    if ($plan.decision -ceq 'refuse') { throw (New-AgentEnvironmentSetupRefusal ([string]$plan.code) ([string]$plan.reason) ([string]$plan.recoverCommand)) }
    $archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([IO.Path]::GetFileName($archive) -cne $asset.Name -or $archiveSha256 -cne $asset.Sha256) {
        throw (New-AgentEnvironmentSetupRefusal archive-hash-mismatch 'The PowerShell archive name or SHA-256 does not match the setup policy.')
    }

    # S5: create the canonical runtime once; afterwards only re-verify (K15/K16).
    if ($plan.decision -ceq 'resolve-runtime') {
        $runtimeLease = Open-PlatformDirectory -Root $layout.SetupRoot -RelativePath $layout.RuntimeRelativePath -CreatePrivate
        try {
            try { $runtimeReceipt = Resolve-PlatformPowerShell -Policy $policyInfo.Policy -DestinationLease $runtimeLease -OfflineCache $archive }
            catch { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('The canonical runtime could not be prepared: ' + $_.Exception.Message)) }
        } finally { $runtimeLease.Dispose() }
        $stored = ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt $runtimeReceipt $userHome
        Publish-AgentEnvironmentSetupFile -SetupRoot $layout.SetupRoot -Directory 'receipts' -Leaf $layout.RuntimeReceiptLeaf -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-AgentEnvironmentSetupJsonLine $stored) + "`n")) -NoReplace
        $runtimeAction = 'resolved'
    } else {
        $storedFile = Read-AgentEnvironmentSetupFile $layout.SetupRoot 'receipts' $layout.RuntimeReceiptLeaf
        if ($null -eq $storedFile) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete 'The canonical runtime receipt is missing.') }
        try {
            $stored = [Text.UTF8Encoding]::new($false,$true).GetString($storedFile.Bytes) | ConvertFrom-Json
            $runtimeReceipt = Assert-PlatformPowerShellRuntime -Policy $policyInfo.Policy -Receipt (ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt $stored $userHome)
        } catch {
            if ((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error') { throw }
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('Canonical runtime re-verification failed; setup does not reinstall automatically: ' + $_.Exception.Message) "Inspect or remove $($plan.runtimeDirectory) and $($plan.runtimeReceipt), then rerun setup with --prepare.")
        }
        $runtimeAction = 'reverified'
    }

    # S5 re-exec: the canonical pwsh re-verifies itself as an owned process with
    # an explicit environment allowlist (M5).
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'setup-agent-environment.ps1'),'-Canonical',$(if ($Prepare) { '-Prepare' } else { '-Offline' }),'-ExpectedCommit',$ExpectedCommit,'-ArchivePath',$archive)
    $child = Invoke-PlatformPreparationCommand -Command $layout.RuntimeExecutable -Arguments $arguments -Environment (Get-AgentEnvironmentSetupChildEnvironment $layout.RuntimeDirectory $userHome) -WorkingDirectory $layout.SetupRoot -TimeoutMilliseconds 1800000
    if (-not [string]::IsNullOrWhiteSpace([string]$child.stderr)) { Write-SetupDiagnostic ('canonical stage: ' + (ConvertTo-AgentEnvironmentSetupSanitizedText ([string]$child.stderr).Trim() $userHome)) }
    $childLines = @(([string]$child.stdout).Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Length -gt 0 })
    if ($childLines.Count -ne 1) { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage did not return exactly one JSON line.') }
    try { $childResult = $childLines[0] | ConvertFrom-Json -ErrorAction Stop } catch { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage returned invalid JSON.') }
    if ([int]$child.exitCode -ne 0) {
        $childCode = if ($null -ne $childResult.PSObject.Properties['code']) { [string]$childResult.code } else { 'internal-error' }
        if ((Get-AgentEnvironmentSetupExitCode $childCode) -ne [int]$child.exitCode) { $childCode = 'internal-error' }
        $recoverCommand = if ($null -ne $childResult.PSObject.Properties['recoverCommand']) { [string]$childResult.recoverCommand } else { $null }
        throw (New-AgentEnvironmentSetupRefusal $childCode 'The canonical stage refused.' $recoverCommand)
    }
    if ([string]$childResult.stage -cne 'canonical' -or $childResult.processPathVerified -isnot [bool] -or -not $childResult.processPathVerified -or [string]$childResult.powerShellVersion -cne $asset.Version -or [string]$childResult.codexHome -cne '~/.codex' -or [string]$childResult.executablePath -cne (ConvertTo-AgentEnvironmentSetupHomePath $layout.RuntimeExecutable $userHome)) {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage evidence does not match the pinned runtime.')
    }

    $powerShell = [pscustomobject][ordered]@{
        version = [string]$runtimeReceipt.version
        assetName = [string]$runtimeReceipt.assetName
        archiveSha256 = [string]$runtimeReceipt.archiveSha256
        executablePath = (ConvertTo-AgentEnvironmentSetupHomePath $layout.RuntimeExecutable $userHome)
        executableSha256 = [string]$runtimeReceipt.executableSha256
        runtimeClosureSha256 = [string]$runtimeReceipt.runtimeClosure.sha256
        processPathVerified = [bool]$childResult.processPathVerified
        runtimeAction = $runtimeAction
    }
    $receipt = New-AgentEnvironmentSetupReceipt -Mode $modeName -Result $(if ($Prepare) { 'prepared-runtime-only' } else { 'verified-runtime-only' }) -Rid $rid `
        -SetupCommit $ExpectedCommit -PolicySha256 $policyInfo.Sha256 -PowerShell $powerShell -DotNetVersion ([string]$childResult.dotNetVersion) `
        -Capabilities @($childResult.capabilities) -RuntimeAction $runtimeAction
    $line = ConvertTo-AgentEnvironmentSetupJsonLine $receipt
    Publish-AgentEnvironmentSetupFile -SetupRoot $layout.SetupRoot -Directory 'receipts' -Leaf $layout.SetupReceiptLeaf -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line + "`n"))
    Write-SetupLine $line
    $exitCode = 0
    }
}
catch {
    $code = if ($moduleLoaded) { Get-AgentEnvironmentSetupRefusalCode $_ } else { 'internal-error' }
    $message = [string]$_.Exception.Message
    if ($null -ne $userHome) { $message = ConvertTo-AgentEnvironmentSetupSanitizedText $message $userHome }
    Write-SetupDiagnostic $message
    if ($moduleLoaded) {
        $cause = $_.Exception
        while ($null -ne $cause -and -not $cause.Data.Contains('RecoverCommand')) { $cause = $cause.InnerException }
        if ($null -ne $cause -and -not [string]::IsNullOrEmpty([string]$cause.Data['RecoverCommand'])) { $recoverCommand = [string]$cause.Data['RecoverCommand'] }
        $refusal = New-AgentEnvironmentSetupReceipt -Mode $modeName -Result refused -Code $code -Rid $rid -SetupCommit $(if ($ExpectedCommit -cmatch '^[0-9a-f]{40}$') { $ExpectedCommit } else { $null }) `
            -PolicySha256 $(if ($null -ne $policyInfo) { $policyInfo.Sha256 } else { $null }) -RecoverCommand $recoverCommand
        Write-SetupLine (ConvertTo-AgentEnvironmentSetupJsonLine $refusal)
        $exitCode = Get-AgentEnvironmentSetupExitCode $code
    } else {
        Write-SetupLine ('{"schemaVersion":1,"kind":"agent-environment-setup-receipt","phase":"p10a","result":"refused","code":"internal-error","exitCode":' + $script:SetupInternalExitCode + '}')
        $exitCode = $script:SetupInternalExitCode
    }
}
finally {
    # L3: no lock is held when the process exits.
    if ($null -ne $lock) { $lock.Dispose() }
    if ($null -ne $setupLease) { $setupLease.Dispose() }
}
exit $exitCode
