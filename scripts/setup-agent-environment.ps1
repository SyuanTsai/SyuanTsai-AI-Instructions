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
    [switch] $Canonical,
    [string] $RuntimeReceiptPath
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
$script:SetupEarlyExitCodes = @{
    'internal-error' = 1; 'usage' = 10; 'missing-dependency' = 14; 'commit-mismatch' = 15
    'runtime-baseline-unavailable' = 24
}
$script:SetupReceiptFields = @(
    'schemaVersion','kind','phase','mode','result','code','exitCode','os','architecture','rid',
    'setupCommit','runtimeCommit','policySha256','setupRoot','codexHome','powerShell','dotNetVersion',
    'capabilities','steps','recoverCommand'
)

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

function New-SetupEarlyReceiptLine {
    param([Parameter(Mandatory = $true)][string] $Code,[Parameter(Mandatory = $true)][int] $ExitCode)
    $value = [pscustomobject][ordered]@{
        schemaVersion = 1; kind = 'agent-environment-setup-receipt'; phase = 'p10a'; mode = $null
        result = 'refused'; code = $Code; exitCode = $ExitCode; os = $null; architecture = $null; rid = $null
        setupCommit = $null; runtimeCommit = $null; policySha256 = $null; setupRoot = $null; codexHome = $null
        powerShell = $null; dotNetVersion = $null; capabilities = @(); steps = @(); recoverCommand = $null
    }
    return ($value | ConvertTo-Json -Depth 4 -Compress)
}

function New-SetupEarlyFailure {
    param([Parameter(Mandatory = $true)][string] $Code,[Parameter(Mandatory = $true)][string] $Message)
    $failure = [InvalidOperationException]::new($Message)
    $failure.Data['Code'] = $Code
    return $failure
}

function Invoke-SetupVerifierGit {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $Binary
    )
    $start = [Diagnostics.ProcessStartInfo]::new($GitPath)
    foreach ($prefix in @('-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C',$RepositoryRoot)) { [void]$start.ArgumentList.Add($prefix) }
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $path = [Environment]::GetEnvironmentVariable('PATH')
    $homeValue = [Environment]::GetEnvironmentVariable('HOME')
    $start.Environment.Clear()
    if (-not [string]::IsNullOrEmpty($path)) { $start.Environment['PATH'] = $path }
    if (-not [string]::IsNullOrEmpty($homeValue)) { $start.Environment['HOME'] = $homeValue }
    $start.Environment['LC_ALL'] = 'C'
    $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $start.Environment['GIT_CONFIG_GLOBAL'] = '/dev/null'
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $start.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($Binary) {
            $stream = [IO.MemoryStream]::new()
            try {
                $process.StandardOutput.BaseStream.CopyTo($stream)
                $process.WaitForExit()
                return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $stream.ToArray(); Error = $stderrTask.Result }
            } finally { $stream.Dispose() }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Text = $stdoutTask.Result.TrimEnd("`r","`n"); Error = $stderrTask.Result }
    } finally { $process.Dispose() }
}

function Get-SetupVerifierCanonicalSha256 {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes,[Parameter(Mandatory = $true)][string] $Context)
    try { $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes) }
    catch { throw (New-SetupEarlyFailure commit-mismatch "$Context is not canonical UTF-8 text.") }
    $canonical = [Text.UTF8Encoding]::new($false).GetBytes($text.Replace("`r`n","`n").Replace("`r","`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($canonical)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-SetupVerifierRegularFile {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $RelativePath)
    try { $info = [IO.FileInfo]::new($Path) } catch { throw (New-SetupEarlyFailure commit-mismatch "Trusted file '$RelativePath' cannot be inspected.") }
    if (-not $info.Exists -or ($info.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $info.LinkTarget) {
        throw (New-SetupEarlyFailure commit-mismatch "Trusted file '$RelativePath' is missing, linked, or not a regular file.")
    }
}

# F1 trust anchor: this verifier is intentionally self-contained. It uses only
# .NET and git, and runs before either repository module can execute.
function Assert-SetupBootstrapTrust {
    param([Parameter(Mandatory = $true)][string] $RepositoryRoot,[Parameter(Mandatory = $true)][string] $ExpectedCommit)
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw (New-SetupEarlyFailure usage '-ExpectedCommit must be a 40-character lowercase hexadecimal commit.') }
    $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($git.Count -ne 1) { throw (New-SetupEarlyFailure missing-dependency 'git is required to verify the pinned setup revision.') }
    $gitPath = [string]$git[0].Source
    $head = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('rev-parse','--verify','HEAD^{commit}')
    if ($head.ExitCode -ne 0 -or $head.Text -cne $ExpectedCommit) { throw (New-SetupEarlyFailure commit-mismatch 'HEAD does not equal -ExpectedCommit.') }

    $manifestRelative = 'scripts/platform-runtime.psd1'
    $manifestObject = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('rev-parse',"$ExpectedCommit`:$manifestRelative")
    if ($manifestObject.ExitCode -ne 0 -or $manifestObject.Text -cnotmatch '^[0-9a-f]{40,64}$') { throw (New-SetupEarlyFailure commit-mismatch 'The platform runtime manifest is not present in HEAD.') }
    $manifestBlob = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('cat-file','blob',$manifestObject.Text) -Binary
    if ($manifestBlob.ExitCode -ne 0) { throw (New-SetupEarlyFailure commit-mismatch 'The platform runtime manifest HEAD blob cannot be read.') }
    $manifestText = [Text.UTF8Encoding]::new($false,$true).GetString($manifestBlob.Bytes)
    $fileListMatch = [regex]::Match($manifestText,'(?ms)\bFileList\s*=\s*@\((.*?)\)\s*\r?\n\s*PrivateData\s*=')
    $inventoryMatch = [regex]::Match($manifestText,'(?ms)\bInventory\s*=\s*@\((.*?)\)\s*\r?\n\s*\}\s*\r?\n\s*\}')
    if (-not $fileListMatch.Success -or -not $inventoryMatch.Success) { throw (New-SetupEarlyFailure commit-mismatch 'The platform runtime manifest closure cannot be parsed by the bootstrap verifier.') }
    $fileList = @([regex]::Matches($fileListMatch.Groups[1].Value,"'([^']+)'") | ForEach-Object { [string]$_.Groups[1].Value })
    $inventory = [ordered]@{}
    foreach ($entry in [regex]::Matches($inventoryMatch.Groups[1].Value,"@\{\s*Path\s*=\s*'([^']+)'\s*;\s*Sha256\s*=\s*'([0-9a-f]{64})'\s*\}")) {
        $path = [string]$entry.Groups[1].Value
        if ($inventory.Contains($path)) { throw (New-SetupEarlyFailure commit-mismatch "The platform runtime inventory duplicates '$path'.") }
        $inventory[$path] = [string]$entry.Groups[2].Value
    }
    $expectedInventory = @($fileList | Where-Object { $_ -cne 'platform-runtime.psd1' })
    if ($fileList.Count -lt 2 -or $inventory.Count -ne $expectedInventory.Count -or
        (@($expectedInventory | Where-Object { -not $inventory.Contains($_) }).Count -ne 0)) {
        throw (New-SetupEarlyFailure commit-mismatch 'The platform runtime FileList and canonical inventory differ.')
    }

    $setupBound = @(
        'scripts/setup-agent-environment.policy.json','scripts/setup-agent-environment.policy.tsv',
        'scripts/setup-agent-environment.policy.schema.json','scripts/setup-agent-environment.sh',
        'scripts/setup-agent-environment.ps1','scripts/agent-environment-setup.psm1'
    )
    $trustFiles = @($setupBound + $manifestRelative + @($fileList | Where-Object { $_ -cne 'platform-runtime.psd1' } | ForEach-Object { 'scripts/' + $_ }) | Select-Object -Unique)
    foreach ($relative in $trustFiles) {
        $path = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relative))
        Assert-SetupVerifierRegularFile $path $relative
        # J1: direct object identity comparison never invokes attributes, clean
        # filters, textconv, diff drivers, hooks, or fsmonitor. The worktree hash
        # explicitly bypasses filters, and every Git child disables replacements.
        $expectedBlob = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('rev-parse',"$ExpectedCommit`:$relative")
        $indexEntry = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('ls-files','--stage','--',$relative)
        $rawBlob = Invoke-SetupVerifierGit $gitPath $RepositoryRoot @('hash-object','--no-filters','--',$path)
        $indexMatch = [regex]::Match([string]$indexEntry.Text,'^(?<mode>[0-9]{6}) (?<blob>[0-9a-f]{40,64}) 0\t[^\r\n]+$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if ($expectedBlob.ExitCode -ne 0 -or $expectedBlob.Text -cnotmatch '^[0-9a-f]{40,64}$' -or
            $indexEntry.ExitCode -ne 0 -or -not $indexMatch.Success -or $rawBlob.ExitCode -ne 0 -or
            $expectedBlob.Text -cne $indexMatch.Groups['blob'].Value -or $expectedBlob.Text -cne $rawBlob.Text) {
            throw (New-SetupEarlyFailure commit-mismatch "Trusted file '$relative' expected, index, and raw worktree blobs differ.")
        }
    }

    $manifestDisk = [IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $manifestRelative))
    if ((Get-SetupVerifierCanonicalSha256 $manifestDisk $manifestRelative) -cne (Get-SetupVerifierCanonicalSha256 $manifestBlob.Bytes "$manifestRelative HEAD blob")) {
        throw (New-SetupEarlyFailure commit-mismatch 'The platform runtime manifest canonical hash differs from HEAD.')
    }
    foreach ($relative in $inventory.Keys) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path (Join-Path $RepositoryRoot 'scripts') $relative))
        if ((Get-SetupVerifierCanonicalSha256 $bytes $relative) -cne $inventory[$relative]) { throw (New-SetupEarlyFailure commit-mismatch "Platform runtime inventory verification failed for '$relative'.") }
    }
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
    Write-SetupLine (New-SetupEarlyReceiptLine runtime-baseline-unavailable $script:SetupBaselineExitCode)
    exit $script:SetupBaselineExitCode
}

try {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    Assert-SetupBootstrapTrust $repositoryRoot $ExpectedCommit
    Import-Module (Join-Path $PSScriptRoot 'agent-environment-setup.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'platform-runtime.psd1') -DisableNameChecking -ErrorAction Stop
    $moduleLoaded = $true
    if ($Prepare -eq $Offline) { throw (New-AgentEnvironmentSetupRefusal usage 'Exactly one of -Prepare or -Offline is required.') }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { throw (New-AgentEnvironmentSetupRefusal usage '-ArchivePath is required.') }
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw (New-AgentEnvironmentSetupRefusal usage '-ExpectedCommit must be a 40-character lowercase hexadecimal commit.') }
    $mode = if ($Prepare) { 'Prepare' } else { 'Offline' }

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
        $expectedRuntimeReceiptPath = [IO.Path]::GetFullPath((Join-Path $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf))
        if ([string]::IsNullOrWhiteSpace($RuntimeReceiptPath) -or
            -not [string]::Equals([IO.Path]::GetFullPath($RuntimeReceiptPath),$expectedRuntimeReceiptPath,[StringComparison]::Ordinal)) {
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage did not receive the verified runtime receipt path.')
        }
        $stored = Read-AgentEnvironmentSetupFile $layout.SetupRoot 'receipts' $layout.RuntimeReceiptLeaf
        if ($null -eq $stored) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete 'The canonical runtime receipt is missing.') }
        try {
            $runtimeReceipt = ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt ([Text.UTF8Encoding]::new($false,$true).GetString($stored.Bytes) | ConvertFrom-Json) $userHome
            [void](Assert-AgentEnvironmentSetupRuntimeReceiptLayout $runtimeReceipt $layout)
            [void](Assert-PlatformPowerShellRuntime -Policy $policyInfo.Policy -Receipt $runtimeReceipt)
        } catch {
            if ((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error') { throw }
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('Canonical runtime re-verification failed: ' + $_.Exception.Message))
        }
        $processPath = [Environment]::ProcessPath
        if ([string]::IsNullOrEmpty($processPath) -or -not (Test-AgentEnvironmentSetupSameFile $processPath ([string]$runtimeReceipt.executablePath))) {
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage is not running on the receipt-named pwsh.')
        }
        try { $capabilities = Get-PlatformCapabilities -Required (Get-AgentEnvironmentSetupRequiredCapabilities) }
        catch { throw (New-AgentEnvironmentSetupRefusal capability-unavailable ('A required platform capability is unavailable: ' + $_.Exception.Message)) }
        # S6: process scope only; nothing is persisted (D4).
        [void](Set-PlatformProcessEnvironment -Name CODEX_HOME -Value $codexHome)
        Write-SetupLine (ConvertTo-AgentEnvironmentSetupJsonLine ([pscustomobject][ordered]@{
            schemaVersion = 1; stage = 'canonical'
            executablePath = (ConvertTo-AgentEnvironmentSetupHomePath ([string]$runtimeReceipt.executablePath) $userHome)
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

    # G4: before the lock, inspect only external K7 state. Runtime, receipt and
    # setup-owned WAL state are transient and are decided only under setup.lock.
    $plan = Get-AgentEnvironmentSetupPlan -Policy $policyInfo.Policy -UserHome $userHome -CodexHome $codexHome -Mode $mode -ArchivePath $archive -Rid $rid -ExternalOnly
    if ($plan.decision -ceq 'refuse') { throw (New-AgentEnvironmentSetupRefusal ([string]$plan.code) ([string]$plan.reason) ([string]$plan.recoverCommand)) }

    # M4/M8: private setup root, serialized by an exclusive platform lock.
    try { $setupLease = Open-PlatformDirectory -Root $userHome -RelativePath '.local/share/ai-instructions-setup' -CreatePrivate }
    catch { throw (New-AgentEnvironmentSetupRefusal home-invalid ('HOME is not writable for the private setup root: ' + $_.Exception.Message)) }
    Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $userHome -RelativePath '.local/share/ai-instructions-setup'
    Invoke-AgentEnvironmentSetupFailpoint 'after-setup-root-durable' $layout.LockLeaf
    try { $lock = Enter-PlatformLock -ParentLease $setupLease -Leaf $layout.LockLeaf -Mode Exclusive -Timeout ([TimeSpan]::Zero) }
    catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [TimeoutException]) { throw (New-AgentEnvironmentSetupRefusal concurrent 'Another agent environment setup holds the setup lock.') }
        throw
    }
    Invoke-AgentEnvironmentSetupBarrier 'after-lock-acquired'

    # K7/F5/G1-G4: setup-owned WAL and all runtime/receipt decisions are inside
    # the exclusive lock. External transactions remain refusals.
    $plan = Get-AgentEnvironmentSetupPlan -Policy $policyInfo.Policy -UserHome $userHome -CodexHome $codexHome -Mode $mode -ArchivePath $archive -Rid $rid
    if ($plan.decision -ceq 'recover-setup') {
        Repair-AgentEnvironmentSetupTransactions $layout.SetupRoot
        $plan = Get-AgentEnvironmentSetupPlan -Policy $policyInfo.Policy -UserHome $userHome -CodexHome $codexHome -Mode $mode -ArchivePath $archive -Rid $rid
    }
    if ($plan.decision -ceq 'refuse') { throw (New-AgentEnvironmentSetupRefusal ([string]$plan.code) ([string]$plan.reason) ([string]$plan.recoverCommand)) }
    if ($plan.decision -ceq 'recover-setup') { throw (New-AgentEnvironmentSetupRefusal interrupted-install 'A setup publication residue remained after recovery.' 'Inspect ~/.local/share/ai-instructions-setup/.ai-instructions-txn, then rerun setup.') }
    $archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([IO.Path]::GetFileName($archive) -cne $asset.Name -or $archiveSha256 -cne $asset.Sha256) {
        throw (New-AgentEnvironmentSetupRefusal archive-hash-mismatch 'The PowerShell archive name or SHA-256 does not match the setup policy.')
    }
    if ($Prepare) {
        [void](Publish-AgentEnvironmentSetupArchiveCache -SetupRoot $layout.SetupRoot -Leaf $asset.Name -ArchivePath $archive -ExpectedSha256 $asset.Sha256)
    }

    # H1/S5: each prepare attempt resolves into a new private stage, verifies it,
    # publishes a unique directory with one rename, then atomically publishes the
    # receipt as the only pointer. Unreferenced directories are preserved orphans.
    if ($plan.decision -ceq 'resolve-runtime') {
        $attempt = New-AgentEnvironmentSetupRuntimeAttemptLayout $layout $rid
        $runtimeParentLease = Open-PlatformDirectory -Root $layout.SetupRoot -RelativePath $layout.RuntimeParentRelativePath -CreatePrivate
        $runtimeParentLease.Dispose()
        Invoke-AgentEnvironmentSetupFailpoint 'before-runtime-stage-created' $layout.RuntimeReceiptLeaf
        $runtimeTransactionStoreLease = Open-PlatformDirectory -Root $layout.SetupRoot -RelativePath $attempt.TransactionStoreRelativePath -CreatePrivate
        $runtimeTransactionStoreLease.Dispose()
        $runtimeTransactionLease = Open-PlatformDirectory -Root $layout.SetupRoot -RelativePath $attempt.TransactionRelativePath -CreatePrivate
        $runtimeTransactionLease.Dispose()
        Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $layout.SetupRoot -RelativePath $attempt.TransactionRelativePath
        Invoke-AgentEnvironmentSetupFailpoint 'after-runtime-transaction-durable' $layout.RuntimeReceiptLeaf
        $runtimeLease = Open-PlatformDirectory -Root $layout.SetupRoot -RelativePath $attempt.StageRelativePath -CreatePrivate
        Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $layout.SetupRoot -RelativePath $attempt.StageRelativePath
        Invoke-AgentEnvironmentSetupBarrier 'after-runtime-directory'
        try {
            try { $runtimeReceipt = Resolve-PlatformPowerShell -Policy $policyInfo.Policy -DestinationLease $runtimeLease -OfflineCache $archive }
            catch { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('The canonical runtime could not be prepared: ' + $_.Exception.Message)) }
        } finally { $runtimeLease.Dispose() }
        Confirm-AgentEnvironmentSetupRuntimeTreeDurability -Layout $layout -Attempt $attempt -Receipt $runtimeReceipt
        [void](Assert-PlatformPowerShellRuntime -Policy $policyInfo.Policy -Receipt $runtimeReceipt)
        Invoke-AgentEnvironmentSetupFailpoint 'after-runtime-stage-verified' $layout.RuntimeReceiptLeaf
        $runtimeReceipt = Publish-AgentEnvironmentSetupRuntimeDirectory -Layout $layout -Attempt $attempt -Receipt $runtimeReceipt -Policy $policyInfo.Policy
        Invoke-AgentEnvironmentSetupFailpoint 'after-runtime-directory-published' $layout.RuntimeReceiptLeaf
        $stored = ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt $runtimeReceipt $userHome
        Publish-AgentEnvironmentSetupFile -SetupRoot $layout.SetupRoot -Directory 'receipts' -Leaf $layout.RuntimeReceiptLeaf -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-AgentEnvironmentSetupJsonLine $stored) + "`n")) -NoReplace
        $runtimeAction = 'resolved'
    } else {
        $storedFile = Read-AgentEnvironmentSetupFile $layout.SetupRoot 'receipts' $layout.RuntimeReceiptLeaf
        if ($null -eq $storedFile) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete 'The canonical runtime receipt is missing.') }
        try {
            $stored = [Text.UTF8Encoding]::new($false,$true).GetString($storedFile.Bytes) | ConvertFrom-Json
            $runtimeReceipt = ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt $stored $userHome
            [void](Assert-AgentEnvironmentSetupRuntimeReceiptLayout $runtimeReceipt $layout)
            $runtimeReceipt = Assert-PlatformPowerShellRuntime -Policy $policyInfo.Policy -Receipt $runtimeReceipt
        } catch {
            if ((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error') { throw }
            throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('Receipt-named runtime re-verification failed; setup does not reinstall automatically: ' + $_.Exception.Message) "Inspect the runtime named by $($plan.runtimeReceipt), then rerun setup with --prepare after resolving the receipt safely.")
        }
        $runtimeAction = 'reverified'
    }

    # S5 re-exec: the canonical pwsh re-verifies itself as an owned process with
    # an explicit environment allowlist (M5).
    $verifiedRuntimeReceiptPath = [IO.Path]::GetFullPath((Join-Path $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf))
    $runtimeExecutable = [string]$runtimeReceipt.executablePath
    $runtimeDirectory = [string]$runtimeReceipt.runtimeClosure.rootPath
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'setup-agent-environment.ps1'),'-Canonical',$(if ($Prepare) { '-Prepare' } else { '-Offline' }),'-ExpectedCommit',$ExpectedCommit,'-ArchivePath',$archive,'-RuntimeReceiptPath',$verifiedRuntimeReceiptPath)
    $child = Invoke-PlatformPreparationCommand -Command $runtimeExecutable -Arguments $arguments -Environment (Get-AgentEnvironmentSetupChildEnvironment $runtimeDirectory $userHome) -WorkingDirectory $layout.SetupRoot -TimeoutMilliseconds 1800000
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
    if ([string]$childResult.stage -cne 'canonical' -or $childResult.processPathVerified -isnot [bool] -or -not $childResult.processPathVerified -or [string]$childResult.powerShellVersion -cne $asset.Version -or [string]$childResult.codexHome -cne '~/.codex' -or [string]$childResult.executablePath -cne (ConvertTo-AgentEnvironmentSetupHomePath $runtimeExecutable $userHome)) {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The canonical stage evidence does not match the pinned runtime.')
    }

    $powerShell = [pscustomobject][ordered]@{
        version = [string]$runtimeReceipt.version
        assetName = [string]$runtimeReceipt.assetName
        archiveSha256 = [string]$runtimeReceipt.archiveSha256
        executablePath = (ConvertTo-AgentEnvironmentSetupHomePath $runtimeExecutable $userHome)
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
        $earlyCode = 'internal-error'
        $cause = $_.Exception
        while ($null -ne $cause) {
            if ($cause.Data.Contains('Code') -and $script:SetupEarlyExitCodes.ContainsKey([string]$cause.Data['Code'])) { $earlyCode = [string]$cause.Data['Code']; break }
            $cause = $cause.InnerException
        }
        $exitCode = [int]$script:SetupEarlyExitCodes[$earlyCode]
        Write-SetupLine (New-SetupEarlyReceiptLine $earlyCode $exitCode)
    }
}
finally {
    # L3: no lock is held when the process exits.
    if ($null -ne $lock) { $lock.Dispose() }
    if ($null -ne $setupLease) { $setupLease.Dispose() }
}
exit $exitCode
