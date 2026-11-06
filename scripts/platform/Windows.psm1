# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:RuntimePreparationModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:RuntimePreparationModulePath)) { throw [IO.InvalidDataException]::new('The verified runtime preparation dependency did not load from its bound path.') }
$script:RuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Invoke-WindowsRuntimePreparationCommand {
    param([string]$Name,[Collections.IDictionary]$Arguments)
    $command = $script:RuntimePreparationModule.ExportedCommands[$Name]
    if ($null -eq $command) { throw [IO.InvalidDataException]::new("The verified runtime preparation dependency does not export '$Name'.") }
    return & $command @Arguments
}

function New-WindowsPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'windows',$Step)
}

function Open-WindowsPlatformDirectory {
    param([Parameter(Mandatory = $true)][string] $Root, [string] $RelativePath, [switch] $CreatePrivate, [switch] $RootOnly)
    $parts = if ($RootOnly) { @() } else { [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath) }
    # Restrict anchors to absolute local drive roots. UNC/device paths need a separate probe.
    if ($Root -notmatch '^[A-Za-z]:[\\/]') {
        throw [ArgumentException]::new('An absolute local drive root is required.')
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $driveRoot = [IO.Path]::GetPathRoot($rootPath)
    $rawTail = $Root.Substring(3).TrimEnd('\','/')
    if ($rawTail.Length -gt 0) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($rawTail) }
    $tail = $rootPath.Substring($driveRoot.Length).TrimEnd('\','/')
    $guards = [Collections.Generic.List[IDisposable]]::new()
    $transferred = $false
    try {
        # The legacy helper trims a drive root's final slash. Keep the actual drive
        # root with a native guard; delegate every ordinary component to the verified module.
        $guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::WrapDirectory($driveRoot,[IDisposable[]]@()))
        $current = $driveRoot
        if ($tail.Length -gt 0) {
            foreach ($part in [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($tail)) {
                if ($current -eq $driveRoot) {
                    $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard((Join-Path $current $part),''))
                } else {
                    $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($current,$part))
                }
                $current = Join-Path $current $part
            }
        }
        foreach ($part in $parts) {
            $next = Join-Path $current $part
            if ($CreatePrivate) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                try { $sddl = 'D:P(A;OICI;FA;;;' + $identity.User.Value + ')' } finally { $identity.Dispose() }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePrivateDirectory($next,$sddl)
            }
            if ($current -eq $driveRoot) {
                $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($next,''))
            } else {
                $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($current,$part))
            }
            $current = $next
        }
        $lease = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::WrapDirectory($current,$guards.ToArray())
        $transferred = $true
        return $lease
    }
    finally { if (-not $transferred) { for ($i = $guards.Count - 1; $i -ge 0; $i--) { $guards[$i].Dispose() } } }
}

function Assert-WindowsPlatformFileIdentity {
    param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink, [switch] $VerifyPath)
    $observed = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink)
    if ($VerifyPath) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease) }
    return $observed
}

function Open-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Enter-WindowsPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function New-WindowsPlatformVerificationError {
    param([string]$Capability,[string]$Message)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new($Capability,'windows',$Message)
}

function Get-WindowsPlatformLeasePath { param($Lease) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease) }
function Get-WindowsPlatformIdentity {
    param($Observation)
    [pscustomobject][ordered]@{ kind='windows-file-id'; device=('0x{0:x}' -f [uint64]$Observation.Device); fileId=('0x{0:x}' -f [uint64]$Observation.Inode) }
}
function ConvertTo-WindowsPlatformIdentityNumber {
    param([string]$Value)
    if ($Value -notmatch '^(?:0x)?[0-9a-fA-F]+$') { throw [ArgumentException]::new('Windows file identity values must be hexadecimal strings.') }
    return [Convert]::ToUInt64(($Value -replace '^0x',''),16)
}
function Assert-WindowsPlatformExpectedState {
    param($Lease,$Expected,[string]$Capability)
    if ($Expected -isnot [object] -or $Expected.exists -isnot [bool]) { throw (New-WindowsPlatformVerificationError $Capability 'ExpectedState is invalid.') }
    if (-not [bool]$Expected.exists) { if ($null -ne $Lease) { throw (New-WindowsPlatformVerificationError $Capability 'The target exists but ExpectedState.exists is false.') }; return }
    if ($null -eq $Lease -or [string]$Expected.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [int64]$Expected.length -lt 0 -or
        $null -eq $Expected.identity -or [string]$Expected.identity.kind -cne 'windows-file-id') { throw (New-WindowsPlatformVerificationError $Capability 'ExpectedState does not describe an existing Windows file.') }
    $observation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Lease.Observation,$true)
    if ([uint64]$observation.Device -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$Expected.identity.device)) -or
        [uint64]$observation.Inode -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$Expected.identity.fileId)) -or
        [int64]$observation.Size -ne [int64]$Expected.length -or
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ComputeSha256($Lease) -cne [string]$Expected.sha256) {
        throw (New-WindowsPlatformVerificationError $Capability 'The target identity, hash, or length differs from ExpectedState.')
    }
}
function Assert-WindowsPlatformTransactionLease {
    param($ParentLease,$TransactionLease,[string]$Capability)
    $parentPath=Get-WindowsPlatformLeasePath $ParentLease
    $transactionPath=Get-WindowsPlatformLeasePath $TransactionLease
    $transactionId=[IO.Path]::GetFileName($transactionPath)
    if ($transactionId -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($transactionPath)) -cne '.ai-instructions-txn' -or
        [uint64]$ParentLease.Observation.Device -ne [uint64]$TransactionLease.Observation.Device -or
        $parentPath.StartsWith($transactionPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw (New-WindowsPlatformVerificationError $Capability 'TransactionLease must be .ai-instructions-txn/<32 lowercase hex> on the target volume, and the target must be outside it.')
    }
    return $transactionPath
}
function Assert-WindowsPlatformJournalOperation {
    param($Journal,[string]$Leaf,[string]$StageLeaf,[AllowNull()][string]$BackupLeaf,$ExpectedState,$ExpectedStage,[string]$Method)
    if ($null -eq $Journal) { return }
    if ($Journal -is [array] -or $null -eq $Journal.PSObject.Properties['targetRelativePath']) { throw [ArgumentException]::new('Journal must be one validated journal v1 operation.') }
    $journalLeaf=([string]$Journal.targetRelativePath -split '/')[-1]
    if ($journalLeaf -cne $Leaf -or [string]$Journal.method -cne $Method -or
        (($null -eq $StageLeaf) -ne ($null -eq $Journal.stageLeaf)) -or ($null -ne $StageLeaf -and [string]$Journal.stageLeaf -cne $StageLeaf) -or
        (($null -eq $BackupLeaf) -ne ($null -eq $Journal.backupLeaf)) -or ($null -ne $BackupLeaf -and [string]$Journal.backupLeaf -cne $BackupLeaf) -or
        [bool]$Journal.original.exists -ne [bool]$ExpectedState.exists -or [string]$Journal.original.sha256 -cne [string]$ExpectedState.sha256 -or
        [string]$Journal.original.length -cne [string]$ExpectedState.length) { throw [ArgumentException]::new('Journal operation does not match publication parameters.') }
    if ([bool]$ExpectedState.exists -and ([string]$Journal.original.identity.kind -cne [string]$ExpectedState.identity.kind -or
        (ConvertTo-WindowsPlatformIdentityNumber ([string]$Journal.original.identity.device)) -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$ExpectedState.identity.device)) -or
        (ConvertTo-WindowsPlatformIdentityNumber ([string]$Journal.original.identity.fileId)) -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$ExpectedState.identity.fileId)))) {
        throw [ArgumentException]::new('Journal original identity does not match ExpectedState.')
    }
    if ($null -ne $ExpectedStage -and ([string]$Journal.applied.sha256 -cne [string]$ExpectedStage.sha256 -or [string]$Journal.applied.length -cne [string]$ExpectedStage.length)) {
        throw [ArgumentException]::new('Journal applied state does not match ExpectedStage.')
    }
}

function Publish-WindowsPlatformFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $TransactionLease,[Parameter(Mandatory = $true)] $StageLease,[Parameter(Mandatory = $true)] $ExpectedState,[AllowNull()] $DisplacedLeaf,[Parameter(Mandatory = $true)] $ExpectedStage,[switch] $NoReplace,$Journal)
    if ([string]::IsNullOrEmpty($DisplacedLeaf)) { $DisplacedLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    if ($null -ne $DisplacedLeaf) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DisplacedLeaf) }
    $transactionPath=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'publication'
    $stagePath=Get-WindowsPlatformLeasePath $StageLease
    $stageLeaf=[IO.Path]::GetFileName($stagePath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($stagePath),$transactionPath)) { throw (New-WindowsPlatformVerificationError 'publication' 'StageLease is not an immediate child of TransactionLease.') }
    $stageObservation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($StageLease,$StageLease.Observation,$true)
    if ([string]$ExpectedStage.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [int64]$stageObservation.Size -ne [int64]$ExpectedStage.length -or
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ComputeSha256($StageLease) -cne [string]$ExpectedStage.sha256) { throw (New-WindowsPlatformVerificationError 'publication' 'Stage hash or length differs from ExpectedStage.') }
    if ([bool]$ExpectedState.exists -ne ($null -ne $DisplacedLeaf)) { throw (New-WindowsPlatformVerificationError 'publication' 'DisplacedLeaf must be supplied exactly when ExpectedState.exists is true.') }
    Assert-WindowsPlatformJournalOperation $Journal $Leaf $stageLeaf $DisplacedLeaf $ExpectedState $ExpectedStage 'stage-rename'
    $target=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenOwnedFile($ParentLease,$Leaf)
    $displaced=$false
    $applied=$false
    $stagePermissions=Get-WindowsPlatformPermissions $StageLease
    $permissionsApplied=$false
    $targetReadOnlyCleared=$false
    try {
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'publication'
        if ($NoReplace -and $null -ne $target) { throw (New-WindowsPlatformVerificationError 'publication' 'NoReplace rejected an existing target.') }
        $permissions=$null
        if ($null -ne $target) { $permissions=Get-WindowsPlatformPermissions $target }
        else {
            $probeLeaf='.ai-instructions-permission-probe-'+[Guid]::NewGuid().ToString('N')
            $probe=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($ParentLease,$probeLeaf,'ReadWrite','CreateNew')
            try {
                $permissions=Get-WindowsPlatformPermissions $probe
                $probe.Dispose()
                $probe=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenOwnedFile($ParentLease,$probeLeaf)
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOnClose($probe)
            } finally { if($null -ne $probe){$probe.Dispose()} }
        }
        [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($StageLease,[string]$permissions.sddl,$false)
        $permissionsApplied=$true
        if ($null -ne $target) {
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$targetReadOnlyCleared=$true }
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$DisplacedLeaf)
            $displaced=$true
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
        }
        try { [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($StageLease,$ParentLease,$Leaf) }
        catch {
            if ($displaced) {
                try { if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }; [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf); if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }; $targetReadOnlyCleared=$false;$displaced=$false }
                catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rename rollback also failed; inspect target '$Leaf', stage '$stageLeaf', and displaced '$DisplacedLeaf'.") }
            }
            throw
        }
        $applied=$true
        [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($StageLease,$null,[bool]$permissions.readOnly)
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::Flush($StageLease)
        $directoryFlushed=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryFlushDirectory($ParentLease)
        $published=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenValidationFile($ParentLease,$Leaf)
        try {
            Assert-WindowsPlatformExpectedState $published ([pscustomobject]@{exists=$true;sha256=[string]$ExpectedStage.sha256;length=[int64]$ExpectedStage.length;identity=(Get-WindowsPlatformIdentity $StageLease.Observation)}) 'publication'
            $actualPermissions=Get-WindowsPlatformPermissions $published
            if ([string]$actualPermissions.sddl -cne [string]$permissions.sddl -or [bool]$actualPermissions.readOnly -ne [bool]$permissions.readOnly) { throw (New-WindowsPlatformVerificationError 'publication' "Published permissions do not match the expected snapshot (expected '$($permissions.sddl)'/$($permissions.readOnly), observed '$($actualPermissions.sddl)'/$($actualPermissions.readOnly)).") }
        } finally { if($null -ne $published){$published.Dispose()} }
        return [pscustomobject][ordered]@{ appliedIdentity=(Get-WindowsPlatformIdentity $StageLease.Observation); displacedIdentity=$(if($null -eq $target){$null}else{Get-WindowsPlatformIdentity $target.Observation}); permissions=$permissions; displacedLeaf=$DisplacedLeaf; flush=[pscustomobject][ordered]@{file=$true;directory=$directoryFlushed;directoryUnsupported=(-not $directoryFlushed)} }
    }
    catch {
        $publicationFailure=$_
        try {
            if ($applied) {
                [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($StageLease,$null,$false)
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($StageLease,$TransactionLease,$stageLeaf)
                $applied=$false
            }
            if ($displaced) {
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf)
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
                $displaced=$false
            }
            elseif ($targetReadOnlyCleared) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
            if ($permissionsApplied) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($StageLease,[string]$stagePermissions.sddl,[bool]$stagePermissions.readOnly) }
        }
        catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rollback could not restore every rename; target='$Leaf', stage='$stageLeaf', displaced='$DisplacedLeaf'.") }
        throw $publicationFailure
    }
    finally { if ($null -ne $target) { $target.Dispose() } }
}

function Remove-WindowsPlatformOwnedFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $ExpectedState,$TransactionLease,[AllowNull()] $TombstoneLeaf,$Journal)
    if ([string]::IsNullOrEmpty($TombstoneLeaf)) { $TombstoneLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    $tombstone=($null -ne $TransactionLease -and $null -ne $TombstoneLeaf)
    if (($null -ne $TransactionLease) -ne ($null -ne $TombstoneLeaf)) { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'TransactionLease and TombstoneLeaf must be supplied together.') }
    if ($tombstone) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($TombstoneLeaf); [void](Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'owned-file-removal') }
    else {
        $path=Get-WindowsPlatformLeasePath $ParentLease
        if ([IO.Path]::GetFileName($path) -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path)) -cne '.ai-instructions-txn') { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Cleanup is restricted to a transaction-private directory.') }
    }
    Assert-WindowsPlatformJournalOperation $Journal $Leaf $null $(if($tombstone){$TombstoneLeaf}else{$null}) $ExpectedState $null $(if($null -eq $Journal){'tombstone-rename'}else{'tombstone-rename'})
    if ($null -ne $Journal -and [string]$Journal.method -cne 'tombstone-rename') { throw [ArgumentException]::new('Remove journal method must be tombstone-rename.') }
    $target=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenOwnedFile($ParentLease,$Leaf)
    try {
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'owned-file-removal'
        $permissions=Get-WindowsPlatformPermissions $target
        $identity=Get-WindowsPlatformIdentity $target.Observation
        if ($tombstone) {
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
            try { [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$TombstoneLeaf) }
            catch { if($permissions.readOnly){[void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true)};throw }
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
            return [pscustomobject][ordered]@{backupIdentity=$identity;permissions=$permissions;tombstoneLeaf=$TombstoneLeaf}
        }
        if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOnClose($target)
        return [pscustomobject][ordered]@{backupIdentity=$identity;permissions=$permissions;deleted=$true}
    } finally { if($null -ne $target){$target.Dispose()} }
}
function Get-WindowsPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease)
    $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetPermissions($Lease)
    [pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}
}
function Set-WindowsPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    if ($null -ne $Snapshot) {
        if ($null -ne $Policy -or [string]$Snapshot.kind -cne 'windows-sddl' -or [string]$Snapshot.sddl -notmatch '^D:' -or [string]$Snapshot.sddl -match '[OGS]:' -or $Snapshot.readOnly -isnot [bool]) {
            throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-snapshot: a DACL-only windows-sddl snapshot is required','windows')
        }
        $Policy=@{Sddl=[string]$Snapshot.sddl;ReadOnly=[bool]$Snapshot.readOnly}
    }
    if ($Policy -isnot [Collections.IDictionary] -or $Policy.Count -eq 0 -or @($Policy.Keys | Where-Object { $_ -cnotin @('Sddl','ReadOnly') }).Count -gt 0) {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-policy: only DACL Sddl and ReadOnly are supported','windows')
    }
    $sddl = $null
    $readOnly = $null
    if ($Policy.Contains('Sddl')) {
        $sddl = [string]$Policy.Sddl
        if ($sddl -notmatch '^D:' -or $sddl -match '[OGS]:') { throw [ArgumentException]::new('Only a DACL SDDL policy is supported.') }
    }
    if ($Policy.Contains('ReadOnly')) {
        if ($Policy.ReadOnly -isnot [bool]) { throw [ArgumentException]::new('ReadOnly must be Boolean.') }
        $readOnly = $Policy.ReadOnly
    }
    $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($Lease,$sddl,$readOnly)
    [pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}
}
function Resolve-WindowsPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-WindowsRuntimePreparationCommand 'Resolve-VerifiedPlatformPowerShell' @{ Policy=$Policy; DestinationLease=$DestinationLease; OfflineCache=$OfflineCache; ReleaseMetadata=$ReleaseMetadata; Platform='windows' } }
function Initialize-WindowsPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-WindowsRuntimePreparationCommand 'Initialize-VerifiedPlatformPester' @{ Policy=$Policy; RuntimeReceipt=$RuntimeReceipt; DestinationLease=$DestinationLease; Platform='windows'; ResolverPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Resolve-StandardValidationTool.ps1') } }

Export-ModuleMember -Function *-WindowsPlatform*
