# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# SYP-354 P10a shared setup decisions. The two entry points
# (setup-agent-environment.sh / setup-agent-environment.ps1) stay thin; every
# setup/readiness judgement and the typed exit-code table live here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AgentEnvironmentSetupPlatformRuntime = @(Import-Module -Name (Join-Path $PSScriptRoot 'platform-runtime.psd1') -PassThru -DisableNameChecking -ErrorAction Stop)[0]
& $script:AgentEnvironmentSetupPlatformRuntime.ExportedCommands['Assert-PlatformRuntimeInventory'] | Out-Null

# L5: the one typed exit-code table shared by the POSIX shell edge and the
# PowerShell entry. README and the shell constants are asserted against it.
$script:AgentEnvironmentSetupExitCodes = [ordered]@{
    'success' = 0
    'internal-error' = 1
    'usage' = 10
    'unsupported-platform' = 11
    'home-invalid' = 12
    'unsafe-path' = 13
    'missing-dependency' = 14
    'commit-mismatch' = 15
    'policy-invalid' = 16
    'download-failed' = 17
    'archive-hash-mismatch' = 18
    'archive-unsafe' = 19
    'cache-missing' = 20
    'runtime-missing' = 21
    'runtime-incomplete' = 22
    'runtime-verification-failed' = 23
    'runtime-baseline-unavailable' = 24
    'capability-unavailable' = 25
    'concurrent' = 26
    'interrupted-install' = 27
    'codex-home-conflict' = 28
}

# K2/K4: the six files bound to --expected-commit.
$script:AgentEnvironmentSetupBoundFiles = @(
    'scripts/setup-agent-environment.policy.json',
    'scripts/setup-agent-environment.policy.tsv',
    'scripts/setup-agent-environment.policy.schema.json',
    'scripts/setup-agent-environment.sh',
    'scripts/setup-agent-environment.ps1',
    'scripts/agent-environment-setup.psm1'
)
$script:AgentEnvironmentSetupRids = @('win-x64','win-arm64','linux-x64','linux-arm64','osx-x64','osx-arm64')
$script:AgentEnvironmentSetupRelativeRoot = '.local/share/ai-instructions-setup'
# L4: only capabilities with a real probe. powershell-resolution and
# pester-initialization are permanently 'unverified'; directory-publication is
# intentionally unavailable on Unix; Pester is not needed by setup.
$script:AgentEnvironmentSetupRequiredCapabilities = @(
    'directory-lease','file-lease','file-identity','lock','publication','owned-file-removal',
    'permissions','owned-process','process-cleanup','powershell-runtime','process-environment'
)
$script:AgentEnvironmentSetupDeferredSteps = @('S7','S8','S9')
$script:AgentEnvironmentSetupReceiptFields = @(
    'schemaVersion','kind','phase','mode','result','code','exitCode','os','architecture','rid',
    'setupCommit','runtimeCommit','policySha256','setupRoot','codexHome','powerShell','dotNetVersion',
    'capabilities','steps','recoverCommand'
)

function Get-AgentEnvironmentSetupExitCodeTable {
    $copy = [ordered]@{}
    foreach ($key in $script:AgentEnvironmentSetupExitCodes.Keys) { $copy[$key] = $script:AgentEnvironmentSetupExitCodes[$key] }
    return $copy
}

function Get-AgentEnvironmentSetupExitCode {
    param([Parameter(Mandatory = $true)][string] $Code)
    if (-not $script:AgentEnvironmentSetupExitCodes.Contains($Code)) { return [int]$script:AgentEnvironmentSetupExitCodes['internal-error'] }
    return [int]$script:AgentEnvironmentSetupExitCodes[$Code]
}

function Get-AgentEnvironmentSetupBoundFiles { return [string[]]@($script:AgentEnvironmentSetupBoundFiles) }
function Get-AgentEnvironmentSetupRequiredCapabilities { return [string[]]@($script:AgentEnvironmentSetupRequiredCapabilities) }
function Get-AgentEnvironmentSetupReceiptFieldNames { return [string[]]@($script:AgentEnvironmentSetupReceiptFields) }

function New-AgentEnvironmentSetupRefusal {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message, [string] $RecoverCommand)
    if (-not $script:AgentEnvironmentSetupExitCodes.Contains($Code) -or $Code -ceq 'success') { throw [ArgumentException]::new("Unknown setup refusal code '$Code'.") }
    $exception = [InvalidOperationException]::new("$Message [agent-environment-setup-code=$Code]")
    $exception.Data['Code'] = $Code
    $exception.Data['RecoverCommand'] = $RecoverCommand
    return $exception
}

function Get-AgentEnvironmentSetupRefusalCode {
    param([AllowNull()][object] $ErrorRecordOrException)
    $candidate = $ErrorRecordOrException
    if ($candidate -is [Management.Automation.ErrorRecord]) { $candidate = $candidate.Exception }
    while ($candidate -is [Exception]) {
        if ($candidate.Data.Contains('Code') -and $script:AgentEnvironmentSetupExitCodes.Contains([string]$candidate.Data['Code'])) { return [string]$candidate.Data['Code'] }
        $candidate = $candidate.InnerException
    }
    return 'internal-error'
}

function Get-AgentEnvironmentSetupSha256Text {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text.Replace("`r`n","`n")))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-AgentEnvironmentSetupSha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-AgentEnvironmentSetupPropertySet {
    param($Object,[string[]]$Expected,[string]$Context)
    if ($Object -isnot [Management.Automation.PSCustomObject]) { throw (New-AgentEnvironmentSetupRefusal policy-invalid "$Context must be a JSON object.") }
    $names = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $expectedText = (@($Expected | Sort-Object -CaseSensitive) -join ',')
    $actualText = (@($names | Sort-Object -CaseSensitive) -join ',')
    if ($expectedText -cne $actualText) { throw (New-AgentEnvironmentSetupRefusal policy-invalid "$Context properties must be exactly: $($Expected -join ', ').") }
}

# Mirrors setup-agent-environment.policy.schema.json and adds the cross-field
# rules JSON Schema cannot express (unique RIDs, name bound to version and RID).
function Assert-AgentEnvironmentSetupPolicy {
    param([Parameter(Mandatory = $true)][AllowNull()] $Policy)
    Assert-AgentEnvironmentSetupPropertySet $Policy @('schemaVersion','powerShell') 'Setup policy'
    $schemaVersion = $Policy.schemaVersion
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [long]$schemaVersion -ne 1) { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'Setup policy schemaVersion is unknown; only 1 is supported.') }
    $root = $Policy.powerShell
    Assert-AgentEnvironmentSetupPropertySet $root @('version','downloadUrlTemplate','assets') 'Setup policy powerShell'
    if ($root.version -isnot [string] -or [string]$root.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'Setup policy version must be a pinned MAJOR.MINOR.PATCH value.') }
    if ($root.downloadUrlTemplate -isnot [string] -or [string]$root.downloadUrlTemplate -cnotmatch '^https://[^\s{}]+/v\{version\}/\{assetName\}$') { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'Setup policy downloadUrlTemplate must be an https URL ending in /v{version}/{assetName}.') }
    $assets = $root.assets
    if ($assets -isnot [object[]] -or @($assets).Count -ne $script:AgentEnvironmentSetupRids.Count) { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'Setup policy assets must list each supported RID exactly once.') }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $version = [string]$root.version
    foreach ($asset in @($assets)) {
        Assert-AgentEnvironmentSetupPropertySet $asset @('rid','name','sha256') 'Setup policy asset'
        $rid = [string]$asset.rid
        if ($asset.rid -isnot [string] -or $rid -cnotin $script:AgentEnvironmentSetupRids -or -not $seen.Add($rid)) { throw (New-AgentEnvironmentSetupRefusal policy-invalid "Setup policy asset RID '$rid' is unknown or duplicated.") }
        $expectedName = if ($rid.StartsWith('win-',[StringComparison]::Ordinal)) { "PowerShell-$version-$rid.zip" } else { "powershell-$version-$rid.tar.gz" }
        if ($asset.name -isnot [string] -or [string]$asset.name -cne $expectedName) { throw (New-AgentEnvironmentSetupRefusal policy-invalid "Setup policy asset name for '$rid' must be '$expectedName'.") }
        if ($asset.sha256 -isnot [string] -or [string]$asset.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw (New-AgentEnvironmentSetupRefusal policy-invalid "Setup policy asset SHA-256 for '$rid' must be 64 lowercase hex characters.") }
    }
    return $Policy
}

function Read-AgentEnvironmentSetupPolicy {
    param([Parameter(Mandatory = $true)][string] $Path)
    try { $text = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true)) }
    catch { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'The setup policy cannot be read as UTF-8.') }
    try { $policy = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'The setup policy is not valid JSON.') }
    [void](Assert-AgentEnvironmentSetupPolicy $policy)
    return [pscustomobject]@{ Policy = $policy; Sha256 = (Get-AgentEnvironmentSetupSha256Text $text); Text = $text.Replace("`r`n","`n") }
}

# K2: the shell reads this derived TSV, never the JSON policy.
function ConvertTo-AgentEnvironmentSetupPolicyTsv {
    param([Parameter(Mandatory = $true)] $Policy)
    [void](Assert-AgentEnvironmentSetupPolicy $Policy)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Generated from scripts/setup-agent-environment.policy.json by ConvertTo-AgentEnvironmentSetupPolicyTsv; edit the JSON policy, then regenerate.')
    $lines.Add("#schemaVersion`t1")
    $lines.Add("#version`t$([string]$Policy.powerShell.version)")
    $lines.Add("#downloadUrlTemplate`t$([string]$Policy.powerShell.downloadUrlTemplate)")
    foreach ($rid in $script:AgentEnvironmentSetupRids) {
        $asset = @($Policy.powerShell.assets | Where-Object { [string]$_.rid -ceq $rid })[0]
        $lines.Add("$rid`t$([string]$asset.name)`t$([string]$asset.sha256)")
    }
    return (($lines.ToArray() -join "`n") + "`n")
}

function Assert-AgentEnvironmentSetupPolicyTsv {
    param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)][string] $TsvPath)
    try { $actual = [IO.File]::ReadAllText($TsvPath,[Text.UTF8Encoding]::new($false,$true)).Replace("`r`n","`n") }
    catch { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'The derived setup policy TSV cannot be read.') }
    if ($actual -cne (ConvertTo-AgentEnvironmentSetupPolicyTsv $Policy)) { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'The setup policy TSV differs from the JSON policy.') }
}

function Get-AgentEnvironmentSetupRid {
    $os = if ($IsWindows) { 'win' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'osx' } else { $null }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if ($null -eq $os -or $architecture -cnotin @('x64','arm64')) { throw (New-AgentEnvironmentSetupRefusal unsupported-platform 'The host OS or architecture has no pinned PowerShell asset.') }
    if ($IsLinux -and @(Get-ChildItem -Force -LiteralPath '/lib' -Filter 'ld-musl-*' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw (New-AgentEnvironmentSetupRefusal unsupported-platform 'musl-based Linux has no pinned PowerShell asset.')
    }
    return "$os-$architecture"
}

function Get-AgentEnvironmentSetupPolicyAsset {
    param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)][string] $Rid)
    $matches = @($Policy.powerShell.assets | Where-Object { [string]$_.rid -ceq $Rid })
    if ($matches.Count -ne 1) { throw (New-AgentEnvironmentSetupRefusal unsupported-platform "The setup policy has no asset for '$Rid'.") }
    return [pscustomobject]@{ Rid = $Rid; Version = [string]$Policy.powerShell.version; Name = [string]$matches[0].name; Sha256 = [string]$matches[0].sha256 }
}

function Get-AgentEnvironmentSetupPathComparison {
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-AgentEnvironmentSetupLayout {
    param([Parameter(Mandatory = $true)][string] $UserHome, [Parameter(Mandatory = $true)][string] $Rid, [Parameter(Mandatory = $true)][string] $Version)
    $homePath = [IO.Path]::GetFullPath($UserHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $setupRoot = [IO.Path]::GetFullPath((Join-Path $homePath $script:AgentEnvironmentSetupRelativeRoot))
    $runtimeLeaf = "$Version-$Rid"
    return [pscustomobject][ordered]@{
        UserHome = $homePath
        SetupRoot = $setupRoot
        CodexHome = [IO.Path]::GetFullPath((Join-Path $homePath '.codex'))
        RuntimeRelativePath = "pwsh/$runtimeLeaf"
        RuntimeDirectory = [IO.Path]::GetFullPath((Join-Path (Join-Path $setupRoot 'pwsh') $runtimeLeaf))
        RuntimeExecutable = [IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $setupRoot 'pwsh') $runtimeLeaf) $(if ($Rid.StartsWith('win-',[StringComparison]::Ordinal)) { 'pwsh.exe' } else { 'pwsh' })))
        ReceiptDirectory = [IO.Path]::GetFullPath((Join-Path $setupRoot 'receipts'))
        RuntimeReceiptLeaf = "runtime-$runtimeLeaf.json"
        SetupReceiptLeaf = 'setup-receipt.json'
        LockLeaf = 'setup.lock'
    }
}

# M2: every path in a receipt is rendered relative to the user home ('~/...'),
# so receipts never carry a user name or machine-specific prefix.
function ConvertTo-AgentEnvironmentSetupHomePath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $UserHome)
    $homePath = [IO.Path]::GetFullPath($UserHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Path)
    $comparison = Get-AgentEnvironmentSetupPathComparison
    if ([string]::Equals($full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),$homePath,$comparison)) { return '~' }
    foreach ($separator in @([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)) {
        if ($full.StartsWith($homePath + $separator,$comparison)) { return '~/' + $full.Substring($homePath.Length + 1).Replace('\','/') }
    }
    throw (New-AgentEnvironmentSetupRefusal unsafe-path 'A receipt path is outside the user home and cannot be normalized.')
}

function ConvertFrom-AgentEnvironmentSetupHomePath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $UserHome)
    if ($Path -ceq '~') { return [IO.Path]::GetFullPath($UserHome) }
    if (-not $Path.StartsWith('~/',[StringComparison]::Ordinal) -or $Path.Contains('\') -or @($Path.Substring(2).Split('/') | Where-Object { $_ -in @('','.','..') }).Count -gt 0) {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'A stored receipt path is not a normalized home-relative path.')
    }
    return [IO.Path]::GetFullPath((Join-Path $UserHome ($Path.Substring(2).Replace('/',[IO.Path]::DirectorySeparatorChar))))
}

function ConvertTo-AgentEnvironmentSetupSanitizedText {
    param([AllowNull()][string] $Text, [Parameter(Mandatory = $true)][string] $UserHome)
    if ($null -eq $Text) { return $null }
    $homePath = [IO.Path]::GetFullPath($UserHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $options = if ($IsWindows) { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
    $result = $Text
    foreach ($variant in @($homePath,$homePath.Replace('\','/'))) { $result = [regex]::Replace($result,[regex]::Escape($variant),'~',$options) }
    return $result
}

# Runtime receipt persistence: Resolve-PlatformPowerShell returns absolute paths.
# Store them home-relative (M2) and expand them again before re-verification.
function ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt {
    param([Parameter(Mandatory = $true)] $Receipt, [Parameter(Mandatory = $true)][string] $UserHome)
    $closure = $Receipt.runtimeClosure
    return [pscustomobject][ordered]@{
        apiVersion = [string]$Receipt.apiVersion
        version = [string]$Receipt.version
        assetName = [string]$Receipt.assetName
        archiveSha256 = [string]$Receipt.archiveSha256
        executablePath = (ConvertTo-AgentEnvironmentSetupHomePath ([string]$Receipt.executablePath) $UserHome)
        executableSha256 = [string]$Receipt.executableSha256
        runtimeClosure = [pscustomobject][ordered]@{
            rootPath = (ConvertTo-AgentEnvironmentSetupHomePath ([string]$closure.rootPath) $UserHome)
            sha256 = [string]$closure.sha256
            files = @($closure.files | ForEach-Object { [pscustomobject][ordered]@{ path = [string]$_.path; sha256 = [string]$_.sha256 } })
        }
        environmentAllowlist = @($Receipt.environmentAllowlist | ForEach-Object { [string]$_ })
        warningCount = [int]$Receipt.warningCount
        warnings = @($Receipt.warnings | ForEach-Object { ConvertTo-AgentEnvironmentSetupSanitizedText ([string]$_) $UserHome })
        protectionBoundary = [string]$Receipt.protectionBoundary
        os = [string]$Receipt.os
        architecture = [string]$Receipt.architecture
    }
}

function ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt {
    param([Parameter(Mandatory = $true)] $Stored, [Parameter(Mandatory = $true)][string] $UserHome)
    foreach ($name in @('executablePath','runtimeClosure')) {
        if ($null -eq $Stored.PSObject.Properties[$name] -or $null -eq $Stored.$name) { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed "The stored runtime receipt lacks '$name'.") }
    }
    if ($null -eq $Stored.runtimeClosure.PSObject.Properties['rootPath']) { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The stored runtime receipt closure lacks rootPath.') }
    $copy = $Stored | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $copy.executablePath = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$Stored.executablePath) $UserHome
    $copy.runtimeClosure.rootPath = ConvertFrom-AgentEnvironmentSetupHomePath ([string]$Stored.runtimeClosure.rootPath) $UserHome
    return $copy
}

# Directory-entry probe that also sees dangling links (Test-Path does not).
function Get-AgentEnvironmentSetupEntry {
    param([Parameter(Mandatory = $true)][string] $Parent, [Parameter(Mandatory = $true)][string] $Leaf)
    if (-not [IO.Directory]::Exists($Parent)) { return $null }
    $comparison = Get-AgentEnvironmentSetupPathComparison
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Parent)) {
        if ([string]::Equals([IO.Path]::GetFileName($entry),$Leaf,$comparison)) {
            $info = [IO.FileInfo]::new($entry)
            $isLink = ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $info.LinkTarget
            $kind = if ($isLink) { 'link' } elseif (($info.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { 'directory' } else { 'file' }
            return [pscustomobject]@{ Path = $entry; Kind = $kind }
        }
    }
    return $null
}

function Get-AgentEnvironmentSetupResidue {
    param([Parameter(Mandatory = $true)][string] $CodexHome, [Parameter(Mandatory = $true)][string] $UserHome)
    $found = [Collections.Generic.List[object]]::new()
    $codexTxn = Get-AgentEnvironmentSetupEntry $CodexHome '.ai-instructions-txn'
    if ($null -ne $codexTxn) { $found.Add([pscustomobject]@{ Scope = 'codex-home'; Kind = 'transaction-store'; Path = $codexTxn.Path }) }
    if ([IO.Directory]::Exists($CodexHome)) {
        foreach ($entry in @([IO.Directory]::EnumerateFileSystemEntries($CodexHome) | Sort-Object)) {
            $leaf = [IO.Path]::GetFileName($entry)
            if ($leaf.StartsWith('.ai-instructions-install-',[StringComparison]::Ordinal) -or $leaf.StartsWith('.ai-instructions-backup-',[StringComparison]::Ordinal)) {
                $found.Add([pscustomobject]@{ Scope = 'codex-home'; Kind = 'legacy-install-residue'; Path = $entry })
            }
        }
    }
    $userTxn = Get-AgentEnvironmentSetupEntry $UserHome '.ai-instructions-txn'
    if ($null -ne $userTxn) { $found.Add([pscustomobject]@{ Scope = 'user-home'; Kind = 'transaction-store'; Path = $userTxn.Path }) }
    return [object[]]$found.ToArray()
}

# K7/K8/K10/K16: pure, read-only decision. It never calls an installer, updater
# or coordinator, and never mutates; the entry point acts on the returned plan.
function Get-AgentEnvironmentSetupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $UserHome,
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [Parameter(Mandatory = $true)][ValidateSet('Prepare','Offline')][string] $Mode,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ArchivePath,
        [string] $Rid
    )
    [void](Assert-AgentEnvironmentSetupPolicy $Policy)
    if ([string]::IsNullOrWhiteSpace($Rid)) { $Rid = Get-AgentEnvironmentSetupRid }
    $asset = Get-AgentEnvironmentSetupPolicyAsset $Policy $Rid
    $layout = Get-AgentEnvironmentSetupLayout $UserHome $Rid $asset.Version
    $display = { param([string]$Path) ConvertTo-AgentEnvironmentSetupHomePath $Path $layout.UserHome }
    $plan = [ordered]@{
        schemaVersion = 1; mode = $Mode.ToLowerInvariant(); rid = $Rid; decision = 'refuse'; code = $null; reason = $null; recoverCommand = $null
        residue = @(); runtimeState = $null; runtimeDirectory = (& $display $layout.RuntimeDirectory)
        runtimeReceipt = (& $display (Join-Path $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf))
        assetName = $asset.Name; deferredSteps = [string[]]@($script:AgentEnvironmentSetupDeferredSteps)
    }
    $residue = @(Get-AgentEnvironmentSetupResidue -CodexHome ([IO.Path]::GetFullPath($CodexHome)) -UserHome $layout.UserHome)
    if ($residue.Count -gt 0) {
        $plan.residue = @($residue | ForEach-Object { & $display $_.Path })
        $plan.code = 'interrupted-install'
        $codexTxn = @($residue | Where-Object { $_.Scope -ceq 'codex-home' -and $_.Kind -ceq 'transaction-store' }).Count -gt 0
        $legacy = @($residue | Where-Object { $_.Kind -ceq 'legacy-install-residue' }).Count -gt 0
        if ($codexTxn -or $legacy) {
            $plan.reason = if ($legacy) { 'Legacy install residue exists in CODEX_HOME; inspect it manually before rerunning the installer.' } else { 'An interrupted install transaction exists in CODEX_HOME.' }
            $plan.recoverCommand = 'pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap.ps1 -CodexHome ~/.codex'
        } else {
            $plan.reason = 'An interrupted USER agent-environment transaction exists in the user home.'
            $plan.recoverCommand = 'pwsh -NoProfile -NonInteractive -File ~/.codex/hooks/update-agent-environment.ps1 -Recover'
        }
        return [pscustomobject]$plan
    }
    $archiveEntry = if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $null } else { Get-AgentEnvironmentSetupEntry ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ArchivePath))) ([IO.Path]::GetFileName($ArchivePath)) }
    if ($null -eq $archiveEntry -or $archiveEntry.Kind -cne 'file') {
        $plan.code = 'cache-missing'
        $plan.reason = "The verified PowerShell archive '$($asset.Name)' is not present as a regular file."
        $plan.recoverCommand = $(if ($Mode -ceq 'Offline') { 'Rerun setup with --prepare while network access is allowed.' } else { 'Provide the official archive named in the setup policy.' })
        return [pscustomobject]$plan
    }
    $directory = Get-AgentEnvironmentSetupEntry ([IO.Path]::GetDirectoryName($layout.RuntimeDirectory)) ([IO.Path]::GetFileName($layout.RuntimeDirectory))
    $receipt = Get-AgentEnvironmentSetupEntry $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf
    if (($null -ne $directory -and $directory.Kind -cne 'directory') -or ($null -ne $receipt -and $receipt.Kind -cne 'file')) {
        $plan.code = 'unsafe-path'
        $plan.reason = 'The canonical runtime directory or its receipt is a link or has the wrong type.'
        return [pscustomobject]$plan
    }
    if ($null -ne $directory -and $null -ne $receipt) {
        $plan.runtimeState = 'present'; $plan.decision = 'verify-runtime'
        return [pscustomobject]$plan
    }
    if ($null -eq $directory -and $null -eq $receipt) {
        $plan.runtimeState = 'absent'
        if ($Mode -ceq 'Prepare') { $plan.decision = 'resolve-runtime'; return [pscustomobject]$plan }
        $plan.code = 'runtime-missing'
        $plan.reason = 'Offline mode only re-verifies an existing canonical runtime; none has been prepared.'
        $plan.recoverCommand = 'Rerun setup with --prepare first.'
        return [pscustomobject]$plan
    }
    $plan.runtimeState = 'incomplete'; $plan.code = 'runtime-incomplete'
    $plan.reason = 'The canonical runtime directory and its receipt are not both present; setup does not reinstall automatically.'
    $plan.recoverCommand = "Remove $($plan.runtimeDirectory) and $($plan.runtimeReceipt) after inspection, then rerun setup with --prepare."
    return [pscustomobject]$plan
}

# Walk every ancestor without following links; any reparse point (Windows) or
# symbolic link, including a dangling one, refuses the path (S1, A1 boundary).
function Assert-AgentEnvironmentSetupPhysicalPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    $full = [IO.Path]::GetFullPath($Path)
    $current = [IO.Path]::GetPathRoot($full)
    foreach ($part in $full.Substring($current.Length).Split([char[]]@('/','\'),[StringSplitOptions]::RemoveEmptyEntries)) {
        $entry = Get-AgentEnvironmentSetupEntry $current $part
        if ($null -eq $entry) { return }
        if ($entry.Kind -ceq 'link') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "$Context has a link ancestor; setup does not follow or realpath links.") }
        if ($entry.Kind -cne 'directory') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "$Context has a non-directory ancestor.") }
        $current = $entry.Path
    }
}

function Get-AgentEnvironmentSetupUserHome {
    $candidate = [Environment]::GetEnvironmentVariable('HOME')
    if ([string]::IsNullOrWhiteSpace($candidate) -and $IsWindows) { $candidate = [Environment]::GetEnvironmentVariable('USERPROFILE') }
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathFullyQualified($candidate) -or $candidate.IndexOfAny([char[]]@("`n","`r","`t")) -ge 0) {
        throw (New-AgentEnvironmentSetupRefusal home-invalid 'HOME must be an absolute path.')
    }
    $full = [IO.Path]::GetFullPath($candidate).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($full) -or $full.Length -le ([IO.Path]::GetPathRoot($full)).TrimEnd('\','/').Length -or -not [IO.Directory]::Exists($full)) {
        throw (New-AgentEnvironmentSetupRefusal home-invalid 'HOME must be an existing directory below a filesystem root.')
    }
    return $full
}

# H5/S6: CODEX_HOME is fixed to ~/.codex for the setup process tree.
function Assert-AgentEnvironmentSetupCodexHome {
    param([Parameter(Mandatory = $true)][string] $UserHome)
    $expected = [IO.Path]::GetFullPath((Join-Path $UserHome '.codex'))
    $external = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    if (-not [string]::IsNullOrEmpty($external)) {
        $same = $false
        if ([IO.Path]::IsPathFullyQualified($external)) {
            $same = [string]::Equals([IO.Path]::GetFullPath($external).TrimEnd('\','/'),$expected,(Get-AgentEnvironmentSetupPathComparison))
        }
        if (-not $same) { throw (New-AgentEnvironmentSetupRefusal codex-home-conflict 'CODEX_HOME is already set to a different location; setup only uses ~/.codex.' 'Unset CODEX_HOME or set it to ~/.codex, then rerun setup.') }
    }
    return $expected
}

# K4: HEAD and the six bound files must equal --expected-commit.
function Assert-AgentEnvironmentSetupCommit {
    param([Parameter(Mandatory = $true)][string] $RepositoryRoot, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedCommit)
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw (New-AgentEnvironmentSetupRefusal usage '-ExpectedCommit must be a 40-character lowercase hexadecimal commit.') }
    $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($git.Count -eq 0) { throw (New-AgentEnvironmentSetupRefusal missing-dependency 'git is required to verify the pinned setup revision.') }
    $gitPath = [string]$git[0].Source
    $invoke = {
        param([string[]]$Arguments)
        $output = @(& $gitPath -c core.fsmonitor=false -C $RepositoryRoot @Arguments 2>$null)
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
    }
    # --show-prefix is empty only at the work-tree top level; this avoids comparing
    # path spellings (8.3 or case variants) between git and the caller.
    $inside = & $invoke @('rev-parse','--is-inside-work-tree')
    $prefix = & $invoke @('rev-parse','--show-prefix')
    if ($inside.ExitCode -ne 0 -or (@($inside.Output) -join '') -cne 'true' -or $prefix.ExitCode -ne 0 -or (@($prefix.Output) -join '').Length -ne 0) {
        throw (New-AgentEnvironmentSetupRefusal commit-mismatch 'The setup scripts are not the top level of a git checkout.')
    }
    $head = & $invoke @('rev-parse','--verify','HEAD^{commit}')
    if ($head.ExitCode -ne 0 -or $head.Output.Count -ne 1 -or $head.Output[0] -cne $ExpectedCommit) { throw (New-AgentEnvironmentSetupRefusal commit-mismatch 'HEAD does not equal --expected-commit.') }
    foreach ($relative in $script:AgentEnvironmentSetupBoundFiles) {
        $entry = Get-AgentEnvironmentSetupEntry ([IO.Path]::GetDirectoryName((Join-Path $RepositoryRoot $relative))) ([IO.Path]::GetFileName($relative))
        if ($null -eq $entry -or $entry.Kind -cne 'file') { throw (New-AgentEnvironmentSetupRefusal commit-mismatch "Bound setup file '$relative' is missing or not a regular file.") }
        $tracked = & $invoke @('ls-files','--error-unmatch','--',$relative)
        $others = & $invoke @('ls-files','--others','--',$relative)
        $diff = & $invoke @('diff','--quiet','HEAD','--',$relative)
        if ($tracked.ExitCode -ne 0 -or $others.ExitCode -ne 0 -or $others.Output.Count -ne 0 -or $diff.ExitCode -ne 0) {
            throw (New-AgentEnvironmentSetupRefusal commit-mismatch "Bound setup file '$relative' differs from --expected-commit.")
        }
    }
}

# Same physical file by platform identity (volume/file ID or device/inode), so a
# path-spelling difference (for example a Windows 8.3 alias) is not a mismatch.
function Test-AgentEnvironmentSetupSameFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Expected)
    if ([string]::Equals([IO.Path]::GetFullPath($Path),[IO.Path]::GetFullPath($Expected),(Get-AgentEnvironmentSetupPathComparison))) { return $true }
    $identities = foreach ($candidate in @($Path,$Expected)) {
        $full = [IO.Path]::GetFullPath($candidate)
        $parent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($full)) -RootOnly
        try {
            $lease = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access Read -CreateMode OpenExisting
            try { '{0}:{1}' -f [uint64]$lease.Observation.Device,[uint64]$lease.Observation.Inode } finally { $lease.Dispose() }
        } finally { $parent.Dispose() }
    }
    return ([string]$identities[0] -ceq [string]$identities[1])
}

# M5: explicit allowlist for owned child processes (re-exec included). Loader,
# runtime and module-search overrides (DOTNET_*, LD_*, DYLD_*, POWERSHELL_*,
# PSModulePath) are never inherited; PSModulePath is set to the verified runtime.
function Get-AgentEnvironmentSetupChildEnvironment {
    param([Parameter(Mandatory = $true)][string] $RuntimeDirectory, [Parameter(Mandatory = $true)][string] $UserHome)
    $names = @('PATH','LANG','LC_ALL','TMPDIR','TMP','TEMP','HTTPS_PROXY','HTTP_PROXY','NO_PROXY','https_proxy','http_proxy','no_proxy','SSL_CERT_FILE','SSL_CERT_DIR','CODEX_HOME')
    if ($IsWindows) { $names += @('USERPROFILE','APPDATA','LOCALAPPDATA','SystemRoot','SystemDrive','windir','ComSpec','PATHEXT') }
    $values = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value -and -not $values.Contains($name)) { $values[$name] = $value }
    }
    $values['HOME'] = $UserHome
    $values['PSModulePath'] = Join-Path $RuntimeDirectory 'Modules'
    return $values
}

function ConvertTo-AgentEnvironmentSetupPlatformIdentity {
    param([Parameter(Mandatory = $true)] $Observation)
    if ($IsWindows) { return [pscustomobject][ordered]@{ kind = 'windows-file-id'; device = ('0x{0:x}' -f [uint64]$Observation.Device); fileId = ('0x{0:x}' -f [uint64]$Observation.Inode) } }
    return [pscustomobject][ordered]@{ kind = 'unix-device-inode'; device = ([uint64]$Observation.Device).ToString([Globalization.CultureInfo]::InvariantCulture); fileId = ([uint64]$Observation.Inode).ToString([Globalization.CultureInfo]::InvariantCulture) }
}

function Get-AgentEnvironmentSetupFileState {
    param([Parameter(Mandatory = $true)] $Lease)
    $observed = Assert-PlatformFileIdentity -Lease $Lease -Expected $Lease.Observation -SingleLink -VerifyPath
    $bytes = [byte[]]$Lease.ReadAllBytes([int]$observed.Size)
    return [pscustomobject]@{ Bytes = $bytes; State = [pscustomobject][ordered]@{ exists = $true; sha256 = (Get-AgentEnvironmentSetupSha256Bytes $bytes); length = [int64]$observed.Size; identity = (ConvertTo-AgentEnvironmentSetupPlatformIdentity $observed) } }
}

function Read-AgentEnvironmentSetupFile {
    param([Parameter(Mandatory = $true)][string] $SetupRoot, [Parameter(Mandatory = $true)][string] $Directory, [Parameter(Mandatory = $true)][string] $Leaf)
    $entry = Get-AgentEnvironmentSetupEntry (Join-Path $SetupRoot $Directory) $Leaf
    if ($null -eq $entry) { return $null }
    if ($entry.Kind -cne 'file') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup file '$Directory/$Leaf' is not a regular file.") }
    $parent = Open-PlatformDirectory -Root $SetupRoot -RelativePath $Directory
    try {
        $lease = Open-PlatformFile -ParentLease $parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
        try { return Get-AgentEnvironmentSetupFileState $lease } finally { $lease.Dispose() }
    } finally { $parent.Dispose() }
}

# M4: write setup-owned files through Publish-PlatformFile with a private
# transaction directory under the setup root (never under CODEX_HOME).
function Publish-AgentEnvironmentSetupFile {
    param(
        [Parameter(Mandatory = $true)][string] $SetupRoot,
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [switch] $NoReplace
    )
    $transactionId = [guid]::NewGuid().ToString('N')
    $transactionStore = Open-PlatformDirectory -Root $SetupRoot -RelativePath '.ai-instructions-txn' -CreatePrivate
    $transaction = $null; $parent = $null; $stage = $null; $displaced = $null
    $transactionPath = Join-Path (Join-Path $SetupRoot '.ai-instructions-txn') $transactionId
    try {
        $transaction = Open-PlatformDirectory -Root $SetupRoot -RelativePath ".ai-instructions-txn/$transactionId" -CreatePrivate
        $parent = Open-PlatformDirectory -Root $SetupRoot -RelativePath $Directory -CreatePrivate
        $current = $null
        $existing = Get-AgentEnvironmentSetupEntry (Join-Path $SetupRoot $Directory) $Leaf
        if ($null -ne $existing) {
            if ($NoReplace) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete "Setup file '$Directory/$Leaf' already exists.") }
            if ($existing.Kind -cne 'file') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup file '$Directory/$Leaf' is not a regular file.") }
            $targetLease = Open-PlatformFile -ParentLease $parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
            try { $current = (Get-AgentEnvironmentSetupFileState $targetLease).State } finally { $targetLease.Dispose() }
        }
        $stage = Open-PlatformFile -ParentLease $transaction -Leaf 'stage' -Access ReadWrite -CreateMode CreateNew
        $stage.WriteNewBytes($Bytes)
        $stageState = Get-AgentEnvironmentSetupFileState $stage
        if ($stageState.State.sha256 -cne (Get-AgentEnvironmentSetupSha256Bytes $Bytes)) { throw 'The staged setup file differs from its source bytes.' }
        $expected = if ($null -eq $current) { [pscustomobject][ordered]@{ exists = $false; sha256 = $null; length = $null; identity = $null } } else { $current }
        Publish-PlatformFile -ParentLease $parent -Leaf $Leaf -TransactionLease $transaction -StageLease $stage -ExpectedState $expected `
            -DisplacedLeaf $(if ($null -eq $current) { $null } else { 'displaced' }) -ExpectedStage $stageState.State -NoReplace:($null -eq $current) | Out-Null
        $stage.Dispose(); $stage = $null
        if ($null -ne $current) {
            $displaced = Open-PlatformFile -ParentLease $transaction -Leaf 'displaced' -Access Read -CreateMode OpenExisting
            $displacedState = (Get-AgentEnvironmentSetupFileState $displaced).State
            $displaced.Dispose(); $displaced = $null
            Remove-PlatformOwnedFile -ParentLease $transaction -Leaf 'displaced' -ExpectedState $displacedState | Out-Null
        }
    }
    finally {
        if ($null -ne $displaced) { $displaced.Dispose() }
        if ($null -ne $stage) { $stage.Dispose() }
        if ($null -ne $parent) { $parent.Dispose() }
        if ($null -ne $transaction) { $transaction.Dispose() }
        $transactionStore.Dispose()
    }
    # Only the now-empty, setup-owned transaction directory is removed; a
    # non-empty or substituted directory fails instead of being deleted recursively.
    if ([IO.Directory]::Exists($transactionPath)) { [IO.Directory]::Delete($transactionPath,$false) }
    try { [IO.Directory]::Delete((Join-Path $SetupRoot '.ai-instructions-txn'),$false) } catch [IO.IOException] { }
}

function New-AgentEnvironmentSetupReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('prepare','offline')][string] $Mode,
        [Parameter(Mandatory = $true)][ValidateSet('prepared-runtime-only','verified-runtime-only','refused')][string] $Result,
        [AllowNull()] $Code,
        [AllowNull()] $Rid,
        [AllowNull()] $SetupCommit,
        [AllowNull()] $PolicySha256,
        [AllowNull()] $PowerShell,
        [AllowNull()] $DotNetVersion,
        [AllowNull()] $Capabilities,
        [AllowNull()] $RecoverCommand,
        [AllowNull()] $RuntimeAction
    )
    # Null-or-empty optional strings are rendered as JSON null, never "".
    $optional = { param($Value) if ([string]::IsNullOrEmpty([string]$Value)) { $null } else { [string]$Value } }
    $Code = & $optional $Code; $Rid = & $optional $Rid; $SetupCommit = & $optional $SetupCommit; $PolicySha256 = & $optional $PolicySha256
    $DotNetVersion = & $optional $DotNetVersion; $RecoverCommand = & $optional $RecoverCommand; $RuntimeAction = & $optional $RuntimeAction
    $exitCode = if ($Result -ceq 'refused') { Get-AgentEnvironmentSetupExitCode $(if ([string]::IsNullOrEmpty($Code)) { 'internal-error' } else { $Code }) } else { 0 }
    $parts = if ($null -eq $Rid) { @($null,$null) } else { $Rid.Split('-',2) }
    $osName = switch ($parts[0]) { 'win' { 'windows' } 'linux' { 'linux' } 'osx' { 'macos' } default { $null } }
    $steps = [Collections.Generic.List[object]]::new()
    if ($Result -cne 'refused') {
        $steps.Add([pscustomobject][ordered]@{ step = 'S5'; status = 'completed'; detail = $(if ([string]::IsNullOrEmpty($RuntimeAction)) { $null } else { $RuntimeAction }) })
        $steps.Add([pscustomobject][ordered]@{ step = 'S6'; status = 'completed'; detail = 'process-scope' })
    }
    foreach ($step in $script:AgentEnvironmentSetupDeferredSteps) { $steps.Add([pscustomobject][ordered]@{ step = $step; status = 'not-implemented-until-p10b'; detail = $null }) }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'agent-environment-setup-receipt'
        phase = 'p10a'
        mode = $Mode
        result = $Result
        code = $(if ($Result -ceq 'refused') { $Code } else { $null })
        exitCode = $exitCode
        os = $osName
        architecture = $parts[1]
        rid = $Rid
        setupCommit = $SetupCommit
        runtimeCommit = $null
        policySha256 = $PolicySha256
        setupRoot = '~/' + $script:AgentEnvironmentSetupRelativeRoot
        codexHome = '~/.codex'
        powerShell = $PowerShell
        dotNetVersion = $DotNetVersion
        capabilities = @($(if ($null -eq $Capabilities) { @() } else { @($Capabilities | ForEach-Object { [pscustomobject][ordered]@{ name = [string]$_.name; status = [string]$_.status } }) }))
        steps = [object[]]$steps.ToArray()
        recoverCommand = $RecoverCommand
    }
}

function ConvertTo-AgentEnvironmentSetupJsonLine {
    param([Parameter(Mandatory = $true)] $Value)
    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

Export-ModuleMember -Function @(
    'Get-AgentEnvironmentSetupExitCodeTable','Get-AgentEnvironmentSetupExitCode','Get-AgentEnvironmentSetupBoundFiles',
    'Get-AgentEnvironmentSetupRequiredCapabilities','Get-AgentEnvironmentSetupReceiptFieldNames',
    'New-AgentEnvironmentSetupRefusal','Get-AgentEnvironmentSetupRefusalCode','Get-AgentEnvironmentSetupSha256Text',
    'Assert-AgentEnvironmentSetupPolicy','Read-AgentEnvironmentSetupPolicy','ConvertTo-AgentEnvironmentSetupPolicyTsv',
    'Assert-AgentEnvironmentSetupPolicyTsv','Get-AgentEnvironmentSetupRid','Get-AgentEnvironmentSetupPolicyAsset',
    'Get-AgentEnvironmentSetupLayout','ConvertTo-AgentEnvironmentSetupHomePath','ConvertFrom-AgentEnvironmentSetupHomePath',
    'ConvertTo-AgentEnvironmentSetupSanitizedText','ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt',
    'ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt','Get-AgentEnvironmentSetupPlan',
    'Assert-AgentEnvironmentSetupPhysicalPath','Get-AgentEnvironmentSetupUserHome','Assert-AgentEnvironmentSetupCodexHome',
    'Assert-AgentEnvironmentSetupCommit','Test-AgentEnvironmentSetupSameFile','Get-AgentEnvironmentSetupChildEnvironment','Read-AgentEnvironmentSetupFile',
    'Publish-AgentEnvironmentSetupFile','New-AgentEnvironmentSetupReceipt','ConvertTo-AgentEnvironmentSetupJsonLine'
)
