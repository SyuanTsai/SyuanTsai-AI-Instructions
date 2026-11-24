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
    'projection-collision' = 29
    'update-failed' = 30
    'projection-failed' = 31
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

function Get-AgentEnvironmentSetupCloudPlan {
    param(
        [Parameter(Mandatory = $true)][string] $Rid,
        [Parameter(Mandatory = $true)][string] $ExpectedCommit,
        [AllowNull()] $InstalledBundle
    )
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw (New-AgentEnvironmentSetupRefusal usage 'The cloud setup commit is invalid.') }
    if (-not $Rid.StartsWith('linux-',[StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{ action='none'; candidateState=$null; currentCommit=$null }
    }
    if ($null -eq $InstalledBundle) {
        return [pscustomobject][ordered]@{ action='install'; candidateState='absent'; currentCommit=$null }
    }
    if ($null -eq $InstalledBundle.PSObject.Properties['schemaVersion'] -or [int]$InstalledBundle.schemaVersion -ne 3 -or
        $null -eq $InstalledBundle.PSObject.Properties['commit'] -or [string]$InstalledBundle.commit -cnotmatch '^[0-9a-f]{40}$') {
        throw (New-AgentEnvironmentSetupRefusal update-failed 'Linux cloud setup requires an installed v3/v5 runtime or an empty CODEX_HOME.')
    }
    $currentCommit = [string]$InstalledBundle.commit
    return [pscustomobject][ordered]@{
        action='update'
        candidateState=$(if ($currentCommit -ceq $ExpectedCommit) { 'current' } else { 'new-pin' })
        currentCommit=$currentCommit
    }
}

function Resolve-AgentEnvironmentSetupProjectionResult {
    param([Parameter(Mandatory = $true)] $Result)
    $outcome = if ($null -ne $Result.PSObject.Properties['outcome']) { [string]$Result.outcome } else { '' }
    $exitCode = if ($null -ne $Result.PSObject.Properties['exitCode']) { [int]$Result.exitCode } else { 1 }
    if ($exitCode -eq 0 -and $outcome -cin @('applied','current')) {
        return [pscustomobject][ordered]@{ action=$outcome.ToLowerInvariant(); code=$null }
    }
    if ($exitCode -eq 3 -or $outcome -ceq 'concurrent') {
        return [pscustomobject][ordered]@{ action='refuse'; code='concurrent' }
    }
    $details = if ($null -ne $Result.PSObject.Properties['failureDetails']) { @($Result.failureDetails) } else { @() }
    if (@($details | Where-Object { $null -ne $_.PSObject.Properties['code'] -and [string]$_.code -ceq 'unmanaged-collision' }).Count -gt 0) {
        return [pscustomobject][ordered]@{ action='refuse'; code='projection-collision' }
    }
    return [pscustomobject][ordered]@{ action='refuse'; code='projection-failed' }
}

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
    if ($root.downloadUrlTemplate -isnot [string] -or [string]$root.downloadUrlTemplate -cne 'https://github.com/PowerShell/PowerShell/releases/download/v{version}/{assetName}') { throw (New-AgentEnvironmentSetupRefusal policy-invalid 'Setup policy downloadUrlTemplate must exactly name the official PowerShell GitHub release endpoint.') }
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
    $assetMatches = @($Policy.powerShell.assets | Where-Object { [string]$_.rid -ceq $Rid })
    if ($assetMatches.Count -ne 1) { throw (New-AgentEnvironmentSetupRefusal unsupported-platform "The setup policy has no asset for '$Rid'.") }
    return [pscustomobject]@{ Rid = $Rid; Version = [string]$Policy.powerShell.version; Name = [string]$assetMatches[0].name; Sha256 = [string]$assetMatches[0].sha256 }
}

function Get-AgentEnvironmentSetupPathComparison {
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-AgentEnvironmentSetupLayout {
    param([Parameter(Mandatory = $true)][string] $UserHome, [Parameter(Mandatory = $true)][string] $Rid, [Parameter(Mandatory = $true)][string] $Version)
    $homePath = [IO.Path]::GetFullPath($UserHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $setupRoot = [IO.Path]::GetFullPath((Join-Path $homePath $script:AgentEnvironmentSetupRelativeRoot))
    $runtimeLeafPrefix = "$Version-$Rid-"
    return [pscustomobject][ordered]@{
        UserHome = $homePath
        SetupRoot = $setupRoot
        CodexHome = [IO.Path]::GetFullPath((Join-Path $homePath '.codex'))
        RuntimeParentRelativePath = 'pwsh'
        RuntimeParentDirectory = [IO.Path]::GetFullPath((Join-Path $setupRoot 'pwsh'))
        RuntimeLeafPrefix = $runtimeLeafPrefix
        ReceiptDirectory = [IO.Path]::GetFullPath((Join-Path $setupRoot 'receipts'))
        RuntimeReceiptLeaf = "runtime-$Version-$Rid.json"
        SetupReceiptLeaf = 'setup-receipt.json'
        LockLeaf = 'setup.lock'
    }
}

function New-AgentEnvironmentSetupRuntimeAttemptLayout {
    param([Parameter(Mandatory = $true)] $Layout,[Parameter(Mandatory = $true)][string] $Rid)
    $attemptId = [guid]::NewGuid().ToString('N')
    $runtimeLeaf = [string]$Layout.RuntimeLeafPrefix + $attemptId
    $stageLeaf = '.stage-' + $attemptId
    $runtimeDirectory = [IO.Path]::GetFullPath((Join-Path $Layout.RuntimeParentDirectory $runtimeLeaf))
    $transactionStoreRelativePath = 'pwsh/.ai-instructions-txn'
    $transactionRelativePath = "$transactionStoreRelativePath/$attemptId"
    $transactionDirectory = [IO.Path]::GetFullPath((Join-Path $Layout.SetupRoot $transactionRelativePath))
    $stageDirectory = [IO.Path]::GetFullPath((Join-Path $Layout.RuntimeParentDirectory $stageLeaf))
    return [pscustomobject][ordered]@{
        AttemptId = $attemptId
        TransactionStoreRelativePath = $transactionStoreRelativePath
        TransactionRelativePath = $transactionRelativePath
        TransactionDirectory = $transactionDirectory
        StageLeaf = $stageLeaf
        StageRelativePath = "pwsh/$stageLeaf"
        StageDirectory = $stageDirectory
        RuntimeLeaf = $runtimeLeaf
        RuntimeRelativePath = "pwsh/$runtimeLeaf"
        RuntimeDirectory = $runtimeDirectory
        RuntimeExecutable = [IO.Path]::GetFullPath((Join-Path $runtimeDirectory $(if ($Rid.StartsWith('win-',[StringComparison]::Ordinal)) { 'pwsh.exe' } else { 'pwsh' })))
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
            directories = [string[]]@($closure.directories | ForEach-Object { [string]$_ })
            directorySha256 = [string]$closure.directorySha256
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

# F3: a valid receipt is useful only for the canonical layout selected for this
# run. Compare the un-resolved physical path spellings ordinally before K15 or
# re-exec, so a receipt cannot redirect verification to a different copy.
function Assert-AgentEnvironmentSetupRuntimeReceiptLayout {
    param([Parameter(Mandatory = $true)] $Receipt,[Parameter(Mandatory = $true)] $Layout)
    if ($null -eq $Receipt.PSObject.Properties['executablePath'] -or
        $null -eq $Receipt.PSObject.Properties['runtimeClosure'] -or
        $null -eq $Receipt.runtimeClosure -or
        $null -eq $Receipt.runtimeClosure.PSObject.Properties['rootPath']) {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The runtime receipt lacks layout binding fields.')
    }
    $executable = [IO.Path]::GetFullPath([string]$Receipt.executablePath)
    $root = [IO.Path]::GetFullPath([string]$Receipt.runtimeClosure.rootPath)
    $leaf = [IO.Path]::GetFileName($root)
    $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $root $(if ([string]$Receipt.os -ceq 'windows') { 'pwsh.exe' } else { 'pwsh' })))
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($root))
    if (-not [string]::Equals($executable,$expectedExecutable,[StringComparison]::Ordinal) -or
        -not [string]::Equals($parent,[string]$Layout.RuntimeParentDirectory,[StringComparison]::Ordinal) -or
        -not $leaf.StartsWith([string]$Layout.RuntimeLeafPrefix,[StringComparison]::Ordinal) -or
        $leaf.Substring(([string]$Layout.RuntimeLeafPrefix).Length) -cnotmatch '^[0-9a-f]{32}$') {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The runtime receipt is not bound to the canonical setup layout.')
    }
    return $Receipt
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

function Test-AgentEnvironmentSetupTransactionStoreResidue {
    param([AllowNull()] $Entry)
    if ($null -eq $Entry) { return $false }
    if ([string]$Entry.Kind -cne 'directory') { return $true }
    try {
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries([string]$Entry.Path)) {
            return $true
        }
        return $false
    }
    catch {
        # An unreadable store cannot be proven empty. Preserve fail-closed K7
        # handling and let the caller report the normal recovery command.
        return $true
    }
}

function Get-AgentEnvironmentSetupResidue {
    param(
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [Parameter(Mandatory = $true)][string] $UserHome,
        [Parameter(Mandatory = $true)][string] $SetupRoot
    )
    $found = [Collections.Generic.List[object]]::new()
    $codexTxn = Get-AgentEnvironmentSetupEntry $CodexHome '.ai-instructions-txn'
    if (Test-AgentEnvironmentSetupTransactionStoreResidue $codexTxn) { $found.Add([pscustomobject]@{ Scope = 'codex-home'; Kind = 'transaction-store'; Path = $codexTxn.Path }) }
    if ([IO.Directory]::Exists($CodexHome)) {
        foreach ($entry in @([IO.Directory]::EnumerateFileSystemEntries($CodexHome) | Sort-Object)) {
            $leaf = [IO.Path]::GetFileName($entry)
            if ($leaf.StartsWith('.ai-instructions-install-',[StringComparison]::Ordinal) -or $leaf.StartsWith('.ai-instructions-backup-',[StringComparison]::Ordinal)) {
                $found.Add([pscustomobject]@{ Scope = 'codex-home'; Kind = 'legacy-install-residue'; Path = $entry })
            }
        }
    }
    $userTxn = Get-AgentEnvironmentSetupEntry $UserHome '.ai-instructions-txn'
    if (Test-AgentEnvironmentSetupTransactionStoreResidue $userTxn) { $found.Add([pscustomobject]@{ Scope = 'user-home'; Kind = 'transaction-store'; Path = $userTxn.Path }) }
    $setupTxn = Get-AgentEnvironmentSetupEntry $SetupRoot '.ai-instructions-txn'
    if (Test-AgentEnvironmentSetupTransactionStoreResidue $setupTxn) { $found.Add([pscustomobject]@{ Scope = 'setup-root'; Kind = 'setup-publication-store'; Path = $setupTxn.Path }) }
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
        [string] $Rid,
        [switch] $ExternalOnly
    )
    [void](Assert-AgentEnvironmentSetupPolicy $Policy)
    if ([string]::IsNullOrWhiteSpace($Rid)) { $Rid = Get-AgentEnvironmentSetupRid }
    $asset = Get-AgentEnvironmentSetupPolicyAsset $Policy $Rid
    $layout = Get-AgentEnvironmentSetupLayout $UserHome $Rid $asset.Version
    $display = { param([string]$Path) ConvertTo-AgentEnvironmentSetupHomePath $Path $layout.UserHome }
    $plan = [ordered]@{
        schemaVersion = 1; mode = $Mode.ToLowerInvariant(); rid = $Rid; decision = 'refuse'; code = $null; reason = $null; recoverCommand = $null
        residue = @(); runtimeState = $null; runtimeDirectory = $null
        runtimeReceipt = (& $display (Join-Path $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf))
        assetName = $asset.Name; deferredSteps = [string[]]@($script:AgentEnvironmentSetupDeferredSteps)
    }
    $residue = @(Get-AgentEnvironmentSetupResidue -CodexHome ([IO.Path]::GetFullPath($CodexHome)) -UserHome $layout.UserHome -SetupRoot $layout.SetupRoot)
    if($ExternalOnly){$residue=@($residue | Where-Object {$_.Scope -cne 'setup-root'})}
    if ($residue.Count -gt 0) {
        $plan.residue = @($residue | ForEach-Object { & $display $_.Path })
        $externalResidue = @($residue | Where-Object { $_.Scope -cne 'setup-root' })
        if ($externalResidue.Count -eq 0) {
            $plan.decision = 'recover-setup'
            $plan.reason = 'An interrupted setup publication exists and must be recovered under the setup lock.'
            $plan.recoverCommand = 'Rerun the same setup command to recover the setup publication.'
            return [pscustomobject]$plan
        }
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
    if($ExternalOnly){$plan.decision='acquire-lock';$plan.reason='External K7 state is clear; setup-internal state must be decided under the exclusive setup lock.';return [pscustomobject]$plan}
    $receipt = Get-AgentEnvironmentSetupEntry $layout.ReceiptDirectory $layout.RuntimeReceiptLeaf
    if ($null -ne $receipt -and $receipt.Kind -cne 'file') {
        $plan.code = 'unsafe-path'
        $plan.reason = 'The canonical runtime receipt is a link or has the wrong type.'
        return [pscustomobject]$plan
    }
    if ($null -ne $receipt) {
        $plan.runtimeState = 'present'; $plan.decision = 'verify-runtime'
        return [pscustomobject]$plan
    }
    $plan.runtimeState = 'absent'
    if ($Mode -ceq 'Offline') {
        $plan.code = 'runtime-missing'
        $plan.reason = 'Offline mode requires a valid canonical runtime receipt; none has been published.'
        $plan.recoverCommand = 'Rerun setup with --prepare first.'
        return [pscustomobject]$plan
    }
    $archiveEntry = if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $null } else { Get-AgentEnvironmentSetupEntry ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ArchivePath))) ([IO.Path]::GetFileName($ArchivePath)) }
    if ($null -eq $archiveEntry -or $archiveEntry.Kind -cne 'file') {
        $plan.code = 'cache-missing'
        $plan.reason = "The verified PowerShell archive '$($asset.Name)' is not present as a regular file."
        $plan.recoverCommand = 'Provide the official archive named in the setup policy.'
        return [pscustomobject]$plan
    }
    $plan.decision = 'resolve-runtime'
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
        $start = [Diagnostics.ProcessStartInfo]::new($gitPath)
        foreach ($argument in @('-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C',$RepositoryRoot) + $Arguments) { $start.ArgumentList.Add($argument) }
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment.Clear()
        $start.Environment['PATH'] = [Environment]::GetEnvironmentVariable('PATH')
        $homeValue = [Environment]::GetEnvironmentVariable('HOME')
        if ([string]::IsNullOrWhiteSpace($homeValue)) { $homeValue = [Environment]::GetEnvironmentVariable('USERPROFILE') }
        if (-not [string]::IsNullOrWhiteSpace($homeValue)) { $start.Environment['HOME'] = $homeValue }
        $start.Environment['LC_ALL'] = 'C'
        $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
        $start.Environment['GIT_CONFIG_GLOBAL'] = '/dev/null'
        $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $start.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $lines = @($stdout.Result.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Length -gt 0 })
            [void]$stderr.Result
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = @($lines) }
        } finally { $process.Dispose() }
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
        $expectedBlob = & $invoke @('rev-parse',"$ExpectedCommit`:$relative")
        $indexEntry = & $invoke @('ls-files','--stage','--',$relative)
        $rawBlob = & $invoke @('hash-object','--no-filters','--',(Join-Path $RepositoryRoot $relative))
        $indexMatch = if ($indexEntry.Output.Count -eq 1) { [regex]::Match([string]$indexEntry.Output[0],'^(?<mode>[0-9]{6}) (?<blob>[0-9a-f]{40,64}) 0\t[^\r\n]+$',[Text.RegularExpressions.RegexOptions]::CultureInvariant) } else { $null }
        if ($expectedBlob.ExitCode -ne 0 -or $expectedBlob.Output.Count -ne 1 -or $expectedBlob.Output[0] -cnotmatch '^[0-9a-f]{40,64}$' -or
            $indexEntry.ExitCode -ne 0 -or $null -eq $indexMatch -or -not $indexMatch.Success -or
            $rawBlob.ExitCode -ne 0 -or $rawBlob.Output.Count -ne 1 -or
            $expectedBlob.Output[0] -cne $indexMatch.Groups['blob'].Value -or $expectedBlob.Output[0] -cne $rawBlob.Output[0]) {
            throw (New-AgentEnvironmentSetupRefusal commit-mismatch "Bound setup file '$relative' expected, index, and raw worktree blobs differ.")
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

# I2/M7/A6: cache reads and publication keep a no-follow platform guard on the
# real cache directory and require the same private ownership boundary used by
# setup-created directories. A missing directory is allowed only before first
# publication; links, dangling links and permission drift are typed refusals.
function Open-AgentEnvironmentSetupPrivateDirectoryGuard {
    param(
        [Parameter(Mandatory = $true)][string] $SetupRoot,
        [Parameter(Mandatory = $true)][string] $Directory,
        [switch] $AllowMissing
    )
    $entry = Get-AgentEnvironmentSetupEntry $SetupRoot $Directory
    if ($null -eq $entry) {
        if ($AllowMissing) { return $null }
        throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' is missing after publication.")
    }
    if ($entry.Kind -cne 'directory') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' is a link or is not a directory.") }
    $lease = $null
    try {
        $lease = Open-PlatformDirectory -Root $SetupRoot -RelativePath $Directory
        $permissions = Get-PlatformPermissions -Lease $lease
        if ($IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $currentSid = $identity.User.Value } finally { $identity.Dispose() }
            $tokenOwnerSid = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetCurrentProcessTokenOwnerSid()
            $ownerSid = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetOwnerSid($lease)
            if (-not [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::IsAcceptedOwnerSid($ownerSid,$currentSid,$tokenOwnerSid) -or [bool]$permissions.ReadOnly) {
                throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' must be owned by the current SID or process TokenOwner and writable by that owner.")
            }
            $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new([string]$permissions.Sddl)
            $acl = $descriptor.DiscretionaryAcl
            if ($null -eq $acl -or $acl.Count -eq 0) { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' must have a non-empty private DACL.") }
            foreach ($ace in $acl) {
                $known = $ace -as [Security.AccessControl.KnownAce]
                if ($null -eq $known -or $known.SecurityIdentifier.Value -cne $currentSid -or [string]$known.AceType -cnotin @('AccessAllowed','AccessAllowedObject')) {
                    throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' ACL grants access outside the current SID.")
                }
            }
        }
        else {
            $effectiveUid = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetEffectiveUserId()
            if ([Convert]::ToUInt32([string]$permissions.Mode,8) -ne 448 -or [uint64]$permissions.Uid -ne [uint64]$effectiveUid) {
                throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' must be owned by the effective uid with mode 0700.")
            }
        }
        $result = $lease
        $lease = $null
        return $result
    }
    catch {
        if ((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error') { throw }
        throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' could not be guarded and verified: $($_.Exception.Message)")
    }
    finally { if ($null -ne $lease) { $lease.Dispose() } }
}

# P10 fix11b closure primitive: persist every directory entry in a physical
# path, flush the final directory's own entries, and identity/path-read back
# each lease. This only composes the additive platform durability API.
function Confirm-AgentEnvironmentSetupDirectoryPathDurability {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    $parts=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath)
    $parent=$null;$child=$null
    try{
        $parent=Open-PlatformDirectory -Root $Root -RootOnly
        $prefix=[Collections.Generic.List[string]]::new()
        foreach($part in $parts){
            $prefix.Add($part)
            $child=Open-PlatformDirectory -Root $Root -RelativePath ($prefix -join [IO.Path]::DirectorySeparatorChar)
            [void](Confirm-PlatformDirectoryDurability -DirectoryLease $parent)
            [void](Assert-PlatformFileIdentity -Lease $child -Expected $child.Observation -VerifyPath)
            $parent.Dispose();$parent=$child;$child=$null
        }
        [void](Confirm-PlatformDirectoryDurability -DirectoryLease $parent)
    }
    catch{
        if((Get-AgentEnvironmentSetupRefusalCode $_) -cne 'internal-error'){throw}
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ("Setup directory durability could not be confirmed for '$RelativePath': " + $_.Exception.Message))
    }
    finally{if($null -ne $child){$child.Dispose()};if($null -ne $parent){$parent.Dispose()}}
}

function Confirm-AgentEnvironmentSetupRuntimeTreeDurability {
    param(
        [Parameter(Mandatory = $true)] $Layout,
        [Parameter(Mandatory = $true)] $Attempt,
        [Parameter(Mandatory = $true)] $Receipt
    )
    Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $Layout.SetupRoot -RelativePath ([string]$Attempt.StageRelativePath)
    foreach($directory in @($Receipt.runtimeClosure.directories)){
        $relative=[string]$directory
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($relative)
        Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $Layout.SetupRoot -RelativePath (([string]$Attempt.StageRelativePath).TrimEnd('/')+'/'+$relative)
    }
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

function Test-AgentEnvironmentSetupStateEqual {
    param([AllowNull()] $Actual,[Parameter(Mandatory = $true)] $Expected)
    if ($null -eq $Actual) { return (-not [bool]$Expected.exists) }
    if (-not [bool]$Expected.exists -or [string]$Actual.sha256 -cne [string]$Expected.sha256 -or [int64]$Actual.length -ne [int64]$Expected.length) { return $false }
    if ($null -ne $Expected.identity) {
        if ($null -eq $Actual.identity -or [string]$Actual.identity.kind -cne [string]$Expected.identity.kind -or
            [string]$Actual.identity.device -cne [string]$Expected.identity.device -or
            [string]$Actual.identity.fileId -cne [string]$Expected.identity.fileId) { return $false }
    }
    return $true
}

function Get-AgentEnvironmentSetupLeafState {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $ParentPath,[Parameter(Mandatory = $true)][string] $Leaf)
    $entry = Get-AgentEnvironmentSetupEntry $ParentPath $Leaf
    if ($null -eq $entry) { return $null }
    if ($entry.Kind -cne 'file') { throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction member '$Leaf' is not a regular file.") }
    $lease = Open-PlatformFile -ParentLease $ParentLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try { return (Get-AgentEnvironmentSetupFileState $lease).State } finally { $lease.Dispose() }
}

function Remove-AgentEnvironmentSetupTransactionFile {
    param([Parameter(Mandatory = $true)] $Transaction,[Parameter(Mandatory = $true)][string] $TransactionPath,[Parameter(Mandatory = $true)][string] $Leaf)
    $state = Get-AgentEnvironmentSetupLeafState $Transaction $TransactionPath $Leaf
    if ($null -ne $state) { Remove-PlatformOwnedFile -ParentLease $Transaction -Leaf $Leaf -ExpectedState $state | Out-Null }
}

function Invoke-AgentEnvironmentSetupFailpoint {
    param([Parameter(Mandatory = $true)][string] $Name,[string]$Leaf)
    $selectedLeaf=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF')
    if ([Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_FAILPOINT') -ceq $Name -and
        ([string]::IsNullOrEmpty($selectedLeaf) -or $selectedLeaf -ceq $Leaf)) {
        [Environment]::FailFast("Setup publication failpoint '$Name' interrupted '$Leaf'.")
    }
}

function Invoke-AgentEnvironmentSetupTornStageFailpoint {
    param([Parameter(Mandatory=$true)]$Stage,[Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$Leaf)
    $selectedLeaf=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_FAILPOINT_LEAF')
    if([Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_FAILPOINT') -cne 'during-stage-write' -or
        (-not [string]::IsNullOrEmpty($selectedLeaf) -and $selectedLeaf -cne $Leaf)){return}
    $prefixLength=[Math]::Max(1,[Math]::Floor($Bytes.Length/2))
    [byte[]]$prefix=$Bytes[0..($prefixLength-1)]
    $Stage.WriteNewBytes($prefix)
    [Environment]::FailFast("Setup publication failpoint 'during-stage-write' interrupted '$Leaf'.")
}

function Invoke-AgentEnvironmentSetupBarrier {
    param([Parameter(Mandatory=$true)][string]$Name)
    $directory=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_BARRIER_DIRECTORY')
    $selected=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_SETUP_BARRIER')
    if([string]::IsNullOrEmpty($directory) -or $selected -cne $Name){return}
    $directory=[IO.Path]::GetFullPath($directory)
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'ready'),$PID.ToString([Globalization.CultureInfo]::InvariantCulture))
    $deadline=[DateTimeOffset]::UtcNow.AddMinutes(2)
    while(-not [IO.File]::Exists((Join-Path $directory 'release'))){
        if([DateTimeOffset]::UtcNow -ge $deadline){throw (New-AgentEnvironmentSetupRefusal internal-error "Setup test barrier '$Name' timed out.")}
        [Threading.Thread]::Sleep(10)
    }
}

function Resolve-AgentEnvironmentSetupTransaction {
    param(
        [Parameter(Mandatory=$true)]$Transaction,
        [Parameter(Mandatory=$true)][string]$TransactionPath,
        [Parameter(Mandatory=$true)]$Parent,
        [Parameter(Mandatory=$true)][string]$ParentPath,
        [Parameter(Mandatory=$true)]$Journal
    )
    $target=Get-AgentEnvironmentSetupLeafState $Parent $ParentPath ([string]$Journal.leaf)
    $stage=Get-AgentEnvironmentSetupLeafState $Transaction $TransactionPath 'stage'
    $displaced=Get-AgentEnvironmentSetupLeafState $Transaction $TransactionPath 'displaced'
    $targetDesired=Test-AgentEnvironmentSetupStateEqual $target $Journal.desiredState
    $targetExpected=Test-AgentEnvironmentSetupStateEqual $target $Journal.expectedState
    $stageDesired=Test-AgentEnvironmentSetupStateEqual $stage $Journal.desiredState
    $displacedExpected=Test-AgentEnvironmentSetupStateEqual $displaced $Journal.expectedState
    if($targetExpected){
        if($null -eq $stage){
            if($null -ne $displaced){throw (New-AgentEnvironmentSetupRefusal interrupted-install 'A pre-publication setup transaction has an unexpected displaced file.')}
            return [pscustomobject]@{decision='rollback';target=$target;stage=$stage;displaced=$displaced}
        }
        if($null -ne $displaced){throw (New-AgentEnvironmentSetupRefusal interrupted-install 'A pre-publication setup transaction has an unexpected displaced file.')}
        if(-not $stageDesired){return [pscustomobject]@{decision='rollback';target=$target;stage=$stage;displaced=$displaced}}
        return [pscustomobject]@{decision='publish';target=$target;stage=$stage;displaced=$displaced}
    }
    if($targetDesired){
        if($null -ne $stage){throw (New-AgentEnvironmentSetupRefusal interrupted-install 'A completed setup publication still has an ambiguous stage file.')}
        if($null -ne $displaced -and -not $displacedExpected){throw (New-AgentEnvironmentSetupRefusal interrupted-install 'A completed setup publication has an unexpected displaced file.')}
        return [pscustomobject]@{decision='complete';target=$target;stage=$stage;displaced=$displaced}
    }
    if($null -eq $target -and [bool]$Journal.expectedState.exists -and $stageDesired -and $displacedExpected){
        return [pscustomobject]@{decision='publish-after-displace';target=$target;stage=$stage;displaced=$displaced}
    }
    throw (New-AgentEnvironmentSetupRefusal interrupted-install 'The setup publication state has no unique recovery decision.')
}

# F5/G1/G2: recover setup-owned strict write-ahead logs while setup.lock is held.
# Resolve-AgentEnvironmentSetupTransaction is the single state resolver. Empty or
# legacy stage-only pre-WAL directories are safe rollback; every journaled state
# has exactly one complete/rollback/cleanup decision.
function Repair-AgentEnvironmentSetupTransactions {
    param([Parameter(Mandatory = $true)][string] $SetupRoot)
    $storePath = Join-Path $SetupRoot '.ai-instructions-txn'
    $storeEntry = Get-AgentEnvironmentSetupEntry $SetupRoot '.ai-instructions-txn'
    if ($null -eq $storeEntry) { return }
    if ($storeEntry.Kind -cne 'directory') { throw (New-AgentEnvironmentSetupRefusal interrupted-install 'The setup transaction store is not a directory.') }
    $store = Open-PlatformDirectory -Root $SetupRoot -RelativePath '.ai-instructions-txn'
    try {
        foreach ($transactionPath in @([IO.Directory]::EnumerateFileSystemEntries($storePath) | Sort-Object)) {
            $transactionId = [IO.Path]::GetFileName($transactionPath)
            $entry = Get-AgentEnvironmentSetupEntry $storePath $transactionId
            if ($transactionId -cnotmatch '^[0-9a-f]{32}$' -or $null -eq $entry -or $entry.Kind -cne 'directory') { throw (New-AgentEnvironmentSetupRefusal interrupted-install 'The setup transaction store contains an unrecognized entry.') }
            $members = @([IO.Directory]::EnumerateFileSystemEntries($transactionPath) | ForEach-Object { [IO.Path]::GetFileName($_) })
            if (@($members | Where-Object { $_ -cnotin @('journal.json','journal.stage','stage','displaced') }).Count -ne 0) { throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction '$transactionId' has an unknown journal closure.") }
            $transaction = Open-PlatformDirectory -Root $SetupRoot -RelativePath ".ai-instructions-txn/$transactionId"
            $parent = $null; $stage = $null
            try {
                Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $SetupRoot -RelativePath ".ai-instructions-txn/$transactionId"
                $hasJournal='journal.json' -cin $members
                if(-not $hasJournal){
                    if(@($members | Where-Object {$_ -cnotin @('journal.stage','stage')}).Count -ne 0){throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction '$transactionId' lacks its write-ahead journal.")}
                    Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'journal.stage'
                    Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'stage'
                }
                else {
                if('journal.stage' -cin $members){throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction '$transactionId' has both a committed journal and its staging file.")}
                $journalLease = Open-PlatformFile -ParentLease $transaction -Leaf 'journal.json' -Access Read -CreateMode OpenExisting
                try { $journalBytes = (Get-AgentEnvironmentSetupFileState $journalLease).Bytes } finally { $journalLease.Dispose() }
                try { $journal = [Text.UTF8Encoding]::new($false,$true).GetString($journalBytes) | ConvertFrom-Json -ErrorAction Stop }
                catch { throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction '$transactionId' has an invalid journal.") }
                $journalDirectory=[string]$journal.directory;$journalLeaf=[string]$journal.leaf
                $validJournalLeaf=if($journalDirectory -ceq 'receipts'){$journalLeaf -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.json$'}else{
                    $journalDirectory -ceq 'cache' -and $journalLeaf -cmatch '^(?:PowerShell|powershell)-[0-9]+\.[0-9]+\.[0-9]+-(?:win|linux|osx)-(?:x64|arm64)\.(?:zip|tar\.gz)$'
                }
                if ([int]$journal.schemaVersion -ne 1 -or [string]$journal.kind -cne 'agent-environment-setup-publication' -or
                    [string]$journal.transactionId -cne $transactionId -or [string]$journal.phase -cne 'intent' -or
                    -not $validJournalLeaf) {
                    throw (New-AgentEnvironmentSetupRefusal interrupted-install "Setup transaction '$transactionId' journal identity or phase is invalid.")
                }
                $parentPath = Join-Path $SetupRoot ([string]$journal.directory)
                $parent = Open-PlatformDirectory -Root $SetupRoot -RelativePath ([string]$journal.directory) -CreatePrivate
                Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $SetupRoot -RelativePath ([string]$journal.directory)
                $resolution=Resolve-AgentEnvironmentSetupTransaction $transaction $transactionPath $parent $parentPath $journal
                if($resolution.decision -in @('publish','publish-after-displace')){
                    $stage = Open-PlatformFile -ParentLease $transaction -Leaf 'stage' -Access ReadWrite -CreateMode OpenExisting
                    $resumeExpected=if($resolution.decision -ceq 'publish-after-displace'){[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}}else{$journal.expectedState}
                    Publish-PlatformFile -ParentLease $parent -Leaf ([string]$journal.leaf) -TransactionLease $transaction -StageLease $stage -ExpectedState $resumeExpected `
                        -DisplacedLeaf $(if ($resolution.decision -ceq 'publish' -and [bool]$journal.expectedState.exists) { 'displaced' } else { $null }) -ExpectedStage $journal.desiredState -NoReplace:(-not [bool]$resumeExpected.exists) | Out-Null
                    $stage.Dispose(); $stage = $null
                }
                Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'displaced'
                Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'stage'
                # Strict WAL: journal deletion is the final file mutation after the
                # target and all transaction data have been verified/cleaned.
                Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'journal.json'
                }
            } finally {
                if ($null -ne $stage) { $stage.Dispose() }
                if ($null -ne $parent) { $parent.Dispose() }
                $transaction.Dispose()
            }
            if([IO.Directory]::Exists($transactionPath)){[IO.Directory]::Delete($transactionPath,$false)}
        }
    } finally { $store.Dispose() }
    if([IO.Directory]::Exists($storePath)){[IO.Directory]::Delete($storePath,$false)}
}

# M4/F5/G1/G2: strict WAL publication. The immutable intent journal is written
# and flushed before stage or target mutation, and removed only after the target
# and transaction closure have been verified.
function Publish-AgentEnvironmentSetupFile {
    param(
        [Parameter(Mandatory = $true)][string] $SetupRoot,
        [Parameter(Mandatory = $true)][ValidateSet('receipts','cache')][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [switch] $NoReplace
    )
    $validLeaf=if($Directory -ceq 'receipts'){$Leaf -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.json$'}else{
        $Leaf -cmatch '^(?:PowerShell|powershell)-[0-9]+\.[0-9]+\.[0-9]+-(?:win|linux|osx)-(?:x64|arm64)\.(?:zip|tar\.gz)$'
    }
    if(-not $validLeaf){throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup publication leaf '$Directory/$Leaf' is invalid.")}
    $transactionId = [guid]::NewGuid().ToString('N')
    $transactionStore = Open-PlatformDirectory -Root $SetupRoot -RelativePath '.ai-instructions-txn' -CreatePrivate
    $transaction = $null; $parent = $null; $stage = $null; $journalStage = $null; $displaced = $null
    $transactionPath = Join-Path (Join-Path $SetupRoot '.ai-instructions-txn') $transactionId
    $completed = $false;$journalCreated = $false
    try {
        $transaction = Open-PlatformDirectory -Root $SetupRoot -RelativePath ".ai-instructions-txn/$transactionId" -CreatePrivate
        Invoke-AgentEnvironmentSetupFailpoint 'after-transaction-directory' $Leaf
        Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $SetupRoot -RelativePath ".ai-instructions-txn/$transactionId"
        Invoke-AgentEnvironmentSetupFailpoint 'after-transaction-directory-durable' $Leaf
        $current = $null
        $directoryEntry = Get-AgentEnvironmentSetupEntry $SetupRoot $Directory
        if ($null -ne $directoryEntry) {
            if ($directoryEntry.Kind -cne 'directory') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup directory '$Directory' is not a directory.") }
            $parent = Open-PlatformDirectory -Root $SetupRoot -RelativePath $Directory
            $existing = Get-AgentEnvironmentSetupEntry (Join-Path $SetupRoot $Directory) $Leaf
            if ($null -ne $existing) {
                if ($NoReplace) { throw (New-AgentEnvironmentSetupRefusal runtime-incomplete "Setup file '$Directory/$Leaf' already exists.") }
                if ($existing.Kind -cne 'file') { throw (New-AgentEnvironmentSetupRefusal unsafe-path "Setup file '$Directory/$Leaf' is not a regular file.") }
                $targetLease = Open-PlatformFile -ParentLease $parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
                try { $current = (Get-AgentEnvironmentSetupFileState $targetLease).State } finally { $targetLease.Dispose() }
            }
        }
        $expected = if ($null -eq $current) { [pscustomobject][ordered]@{ exists = $false; sha256 = $null; length = $null; identity = $null } } else { $current }
        $desired=[pscustomobject][ordered]@{exists=$true;sha256=(Get-AgentEnvironmentSetupSha256Bytes $Bytes);length=[int64]$Bytes.Length;identity=$null}
        $journal = [pscustomobject][ordered]@{
            schemaVersion = 1; kind = 'agent-environment-setup-publication'; transactionId = $transactionId; phase = 'intent'
            directory = $Directory; leaf = $Leaf; expectedState = $expected; desiredState = $desired
        }
        $journalBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-AgentEnvironmentSetupJsonLine $journal) + "`n")
        $journalStage = Open-PlatformFile -ParentLease $transaction -Leaf 'journal.stage' -Access ReadWrite -CreateMode CreateNew
        $journalStage.WriteNewBytes($journalBytes)
        $journalStageState = (Get-AgentEnvironmentSetupFileState $journalStage).State
        Invoke-AgentEnvironmentSetupFailpoint 'after-journal-stage' $Leaf
        $missing=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        Publish-PlatformFile -ParentLease $transaction -Leaf 'journal.json' -TransactionLease $transaction -StageLease $journalStage `
            -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $journalStageState -NoReplace | Out-Null
        $journalStage.Dispose(); $journalStage = $null
        $journalCreated = $true
        Invoke-AgentEnvironmentSetupFailpoint 'after-journal' $Leaf
        if ($null -eq $parent) { $parent = Open-PlatformDirectory -Root $SetupRoot -RelativePath $Directory -CreatePrivate }
        Invoke-AgentEnvironmentSetupFailpoint 'after-parent-directory' $Leaf
        Confirm-AgentEnvironmentSetupDirectoryPathDurability -Root $SetupRoot -RelativePath $Directory
        Invoke-AgentEnvironmentSetupFailpoint 'after-parent-directory-durable' $Leaf
        $stage = Open-PlatformFile -ParentLease $transaction -Leaf 'stage' -Access ReadWrite -CreateMode CreateNew
        Invoke-AgentEnvironmentSetupTornStageFailpoint $stage $Bytes $Leaf
        $stage.WriteNewBytes($Bytes)
        $stageState = Get-AgentEnvironmentSetupFileState $stage
        if (-not (Test-AgentEnvironmentSetupStateEqual $stageState.State $desired)) { throw 'The staged setup file differs from its write-ahead journal.' }
        Invoke-AgentEnvironmentSetupFailpoint 'after-stage' $Leaf
        Publish-PlatformFile -ParentLease $parent -Leaf $Leaf -TransactionLease $transaction -StageLease $stage -ExpectedState $expected `
            -DisplacedLeaf $(if ($null -eq $current) { $null } else { 'displaced' }) -ExpectedStage $desired -NoReplace:($null -eq $current) | Out-Null
        $stage.Dispose(); $stage = $null
        Invoke-AgentEnvironmentSetupFailpoint 'after-rename' $Leaf
        if ($null -ne $current) { Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'displaced' }
        Invoke-AgentEnvironmentSetupFailpoint 'after-displaced-cleanup' $Leaf
        Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'journal.json'
        $completed = $true
        Invoke-AgentEnvironmentSetupFailpoint 'after-journal-cleanup' $Leaf
    }
    finally {
        if (-not $journalCreated -and $null -ne (Get-AgentEnvironmentSetupEntry $transactionPath 'journal.json')) {
            # Journal publication is atomic. A durability error after the rename
            # must retain the committed intent for the next lock holder.
            $journalCreated = $true
        }
        if (-not $journalCreated -and $null -ne $transaction) {
            if ($null -ne $stage) { $stage.Dispose(); $stage = $null }
            if ($null -ne $journalStage) { $journalStage.Dispose(); $journalStage = $null }
            Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'journal.stage'
            Remove-AgentEnvironmentSetupTransactionFile $transaction $transactionPath 'stage'
        }
        if ($null -ne $journalStage) { $journalStage.Dispose() }
        if ($null -ne $displaced) { $displaced.Dispose() }
        if ($null -ne $stage) { $stage.Dispose() }
        if ($null -ne $parent) { $parent.Dispose() }
        if ($null -ne $transaction) { $transaction.Dispose() }
        $transactionStore.Dispose()
        if (-not $journalCreated) {
            if ([IO.Directory]::Exists($transactionPath)) { [IO.Directory]::Delete($transactionPath,$false) }
            $storePath = Join-Path $SetupRoot '.ai-instructions-txn'
            if ([IO.Directory]::Exists($storePath)) { [IO.Directory]::Delete($storePath,$false) }
        }
    }
    if ($completed) {
        [IO.Directory]::Delete($transactionPath,$false)
        Invoke-AgentEnvironmentSetupFailpoint 'after-transaction-cleanup' $Leaf
        [IO.Directory]::Delete((Join-Path $SetupRoot '.ai-instructions-txn'),$false)
    }
}

# H1/J2: publish a fully verified, unique runtime directory with the existing
# create-only platform primitive. That primitive durably flushes both rename
# parents and reads the result back before this function can publish a pointer.
# No runtime directory is ever deleted or reused; the receipt is the only pointer.
function Publish-AgentEnvironmentSetupRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)] $Layout,
        [Parameter(Mandatory = $true)] $Attempt,
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)] $Policy
    )
    if ([string]$Attempt.StageLeaf -cnotmatch '^\.stage-[0-9a-f]{32}$' -or
        -not ([string]$Attempt.RuntimeLeaf).StartsWith([string]$Layout.RuntimeLeafPrefix,[StringComparison]::Ordinal) -or
        ([string]$Attempt.RuntimeLeaf).Substring(([string]$Layout.RuntimeLeafPrefix).Length) -cnotmatch '^[0-9a-f]{32}$') {
        throw (New-AgentEnvironmentSetupRefusal unsafe-path 'The runtime attempt identity is invalid.')
    }
    $stage = Get-AgentEnvironmentSetupEntry $Layout.RuntimeParentDirectory ([string]$Attempt.StageLeaf)
    $target = Get-AgentEnvironmentSetupEntry $Layout.RuntimeParentDirectory ([string]$Attempt.RuntimeLeaf)
    if ($null -eq $stage -or $stage.Kind -cne 'directory' -or $null -ne $target) {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The private runtime stage is missing, linked, or its unique destination is occupied.')
    }
    [void](Assert-PlatformPowerShellRuntime -Policy $Policy -Receipt $Receipt)
    $parentLease = $null
    $transactionLease = $null
    try {
        $parentLease = Open-PlatformDirectory -Root $Layout.SetupRoot -RelativePath $Layout.RuntimeParentRelativePath
        $transactionLease = Open-PlatformDirectory -Root $Layout.SetupRoot -RelativePath ([string]$Attempt.TransactionRelativePath)
        $stageState = Get-PlatformDirectoryState -ParentLease $parentLease -Leaf ([string]$Attempt.StageLeaf)
        if (-not [bool]$stageState.exists) { throw 'The verified runtime stage disappeared before publication.' }
        # Relocate the verified private stage into its unique transaction first.
        # The following FromTransaction rename is the only externally visible
        # runtime publication and durably flushes the pwsh parent before return.
        [void](Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf ([string]$Attempt.StageLeaf) -TransactionLease $transactionLease -DestinationLeaf ([string]$Attempt.StageLeaf) -ExpectedIdentity $stageState.identity -Direction ToTransaction -ExpectedState $stageState)
        [void](Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf ([string]$Attempt.StageLeaf) -TransactionLease $transactionLease -DestinationLeaf ([string]$Attempt.RuntimeLeaf) -ExpectedIdentity $stageState.identity -Direction FromTransaction -ExpectedState $stageState)
    }
    catch {
        throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed ('The verified runtime directory was not durably published: ' + $_.Exception.Message))
    }
    finally {
        if ($null -ne $transactionLease) { $transactionLease.Dispose() }
        if ($null -ne $parentLease) { $parentLease.Dispose() }
    }
    if ([IO.Directory]::Exists([string]$Attempt.StageDirectory) -or -not [IO.Directory]::Exists([string]$Attempt.RuntimeDirectory)) { throw (New-AgentEnvironmentSetupRefusal runtime-verification-failed 'The durable runtime publication readback did not confirm the unique location.') }
    $Receipt.executablePath = [string]$Attempt.RuntimeExecutable
    $Receipt.runtimeClosure.rootPath = [string]$Attempt.RuntimeDirectory
    [void](Assert-AgentEnvironmentSetupRuntimeReceiptLayout $Receipt $Layout)
    [void](Assert-PlatformPowerShellRuntime -Policy $Policy -Receipt $Receipt)
    return $Receipt
}

function Publish-AgentEnvironmentSetupArchiveCache {
    param(
        [Parameter(Mandatory = $true)][string] $SetupRoot,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )
    $cacheGuard = $null
    try {
        $cacheGuard = Open-AgentEnvironmentSetupPrivateDirectoryGuard -SetupRoot $SetupRoot -Directory 'cache' -AllowMissing
        $existing = Read-AgentEnvironmentSetupFile $SetupRoot 'cache' $Leaf
        if ($null -ne $existing -and (Get-AgentEnvironmentSetupSha256Bytes $existing.Bytes) -ceq $ExpectedSha256) { return 'current' }
        $bytes = [IO.File]::ReadAllBytes($ArchivePath)
        if ((Get-AgentEnvironmentSetupSha256Bytes $bytes) -cne $ExpectedSha256) { throw (New-AgentEnvironmentSetupRefusal archive-hash-mismatch 'The private archive snapshot changed before cache publication.') }
        Publish-AgentEnvironmentSetupFile -SetupRoot $SetupRoot -Directory 'cache' -Leaf $Leaf -Bytes $bytes -NoReplace:($null -eq $existing)
        if ($null -eq $cacheGuard) { $cacheGuard = Open-AgentEnvironmentSetupPrivateDirectoryGuard -SetupRoot $SetupRoot -Directory 'cache' }
        return 'published'
    }
    finally { if ($null -ne $cacheGuard) { $cacheGuard.Dispose() } }
}

function New-AgentEnvironmentSetupReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('prepare','offline')][string] $Mode,
        [Parameter(Mandatory = $true)][ValidateSet('prepared-runtime-only','verified-runtime-only','completed','refused')][string] $Result,
        [AllowNull()] $Code,
        [AllowNull()] $Rid,
        [AllowNull()] $SetupCommit,
        [AllowNull()] $PolicySha256,
        [AllowNull()] $PowerShell,
        [AllowNull()] $DotNetVersion,
        [AllowNull()] $Capabilities,
        [AllowNull()] $RecoverCommand,
        [AllowNull()] $RuntimeAction,
        [AllowNull()] $RuntimeCommit,
        [AllowNull()] $InstallAction,
        [AllowNull()] $ProjectionAction
    )
    # Null-or-empty optional strings are rendered as JSON null, never "".
    $optional = { param($Value) if ([string]::IsNullOrEmpty([string]$Value)) { $null } else { [string]$Value } }
    $Code = & $optional $Code; $Rid = & $optional $Rid; $SetupCommit = & $optional $SetupCommit; $PolicySha256 = & $optional $PolicySha256
    $DotNetVersion = & $optional $DotNetVersion; $RecoverCommand = & $optional $RecoverCommand; $RuntimeAction = & $optional $RuntimeAction
    $RuntimeCommit = & $optional $RuntimeCommit; $InstallAction = & $optional $InstallAction; $ProjectionAction = & $optional $ProjectionAction
    $exitCode = if ($Result -ceq 'refused') { Get-AgentEnvironmentSetupExitCode $(if ([string]::IsNullOrEmpty($Code)) { 'internal-error' } else { $Code }) } else { 0 }
    $parts = if ($null -eq $Rid) { @($null,$null) } else { $Rid.Split('-',2) }
    $osName = switch ($parts[0]) { 'win' { 'windows' } 'linux' { 'linux' } 'osx' { 'macos' } default { $null } }
    $steps = [Collections.Generic.List[object]]::new()
    if ($Result -cne 'refused') {
        $steps.Add([pscustomobject][ordered]@{ step = 'S5'; status = 'completed'; detail = $(if ([string]::IsNullOrEmpty($RuntimeAction)) { $null } else { $RuntimeAction }) })
        $steps.Add([pscustomobject][ordered]@{ step = 'S6'; status = 'completed'; detail = 'process-scope' })
    }
    if ($Result -ceq 'completed') {
        $steps.Add([pscustomobject][ordered]@{ step = 'S7'; status = 'completed'; detail = $InstallAction })
        $steps.Add([pscustomobject][ordered]@{ step = 'S8'; status = 'completed'; detail = $ProjectionAction })
        $steps.Add([pscustomobject][ordered]@{ step = 'S9'; status = 'completed'; detail = 'verified' })
    }
    else {
        foreach ($step in $script:AgentEnvironmentSetupDeferredSteps) { $steps.Add([pscustomobject][ordered]@{ step = $step; status = 'not-implemented-until-p10b'; detail = $null }) }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'agent-environment-setup-receipt'
        phase = $(if ($Result -ceq 'completed') { 'p9d' } else { 'p10a' })
        mode = $Mode
        result = $Result
        code = $(if ($Result -ceq 'refused') { $Code } else { $null })
        exitCode = $exitCode
        os = $osName
        architecture = $parts[1]
        rid = $Rid
        setupCommit = $SetupCommit
        runtimeCommit = $RuntimeCommit
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
    'Get-AgentEnvironmentSetupCloudPlan','Resolve-AgentEnvironmentSetupProjectionResult',
    'New-AgentEnvironmentSetupRefusal','Get-AgentEnvironmentSetupRefusalCode','Get-AgentEnvironmentSetupSha256Text',
    'Assert-AgentEnvironmentSetupPolicy','Read-AgentEnvironmentSetupPolicy','ConvertTo-AgentEnvironmentSetupPolicyTsv',
    'Assert-AgentEnvironmentSetupPolicyTsv','Get-AgentEnvironmentSetupRid','Get-AgentEnvironmentSetupPolicyAsset',
    'Get-AgentEnvironmentSetupLayout','ConvertTo-AgentEnvironmentSetupHomePath','ConvertFrom-AgentEnvironmentSetupHomePath',
    'New-AgentEnvironmentSetupRuntimeAttemptLayout',
    'ConvertTo-AgentEnvironmentSetupSanitizedText','ConvertTo-AgentEnvironmentSetupStoredRuntimeReceipt',
    'ConvertFrom-AgentEnvironmentSetupStoredRuntimeReceipt','Assert-AgentEnvironmentSetupRuntimeReceiptLayout','Get-AgentEnvironmentSetupPlan',
    'Assert-AgentEnvironmentSetupPhysicalPath','Get-AgentEnvironmentSetupUserHome','Assert-AgentEnvironmentSetupCodexHome',
    'Assert-AgentEnvironmentSetupCommit','Test-AgentEnvironmentSetupSameFile','Get-AgentEnvironmentSetupChildEnvironment','Read-AgentEnvironmentSetupFile',
    'Confirm-AgentEnvironmentSetupDirectoryPathDurability','Confirm-AgentEnvironmentSetupRuntimeTreeDurability',
    'Repair-AgentEnvironmentSetupTransactions','Resolve-AgentEnvironmentSetupTransaction','Publish-AgentEnvironmentSetupFile',
    'Publish-AgentEnvironmentSetupRuntimeDirectory','Publish-AgentEnvironmentSetupArchiveCache','Invoke-AgentEnvironmentSetupFailpoint','Invoke-AgentEnvironmentSetupBarrier',
    'New-AgentEnvironmentSetupReceipt','ConvertTo-AgentEnvironmentSetupJsonLine'
)
