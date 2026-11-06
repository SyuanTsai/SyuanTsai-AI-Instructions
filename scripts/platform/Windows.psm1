# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$script:WindowsPublicationPostRenameTestHook = $null
$script:WindowsPublicationDurabilityTestHook = $null
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
    $transactionContainer=[IO.Path]::GetDirectoryName($transactionPath)
    $rootPath=[IO.Path]::GetDirectoryName($transactionContainer)
    if ([string]::IsNullOrEmpty($rootPath) -or $transactionId -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName($transactionContainer) -cne '.ai-instructions-txn' -or
        [uint64]$ParentLease.Observation.Device -ne [uint64]$TransactionLease.Observation.Device -or
        $parentPath.StartsWith($transactionPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw (New-WindowsPlatformVerificationError $Capability 'TransactionLease must be .ai-instructions-txn/<32 lowercase hex> on the target volume, and the target must be outside it.')
    }
    return [pscustomobject][ordered]@{parentPath=$parentPath;transactionPath=$transactionPath;rootPath=$rootPath;transactionId=$transactionId}
}
function ConvertTo-WindowsPlatformPermissionSnapshot {
    param($Snapshot,[string]$Capability,[string]$Context)
    try {
        if ($null -eq $Snapshot -or [string]$Snapshot.kind -cne 'windows-sddl' -or $Snapshot.sddl -isnot [string] -or
            [string]$Snapshot.sddl -notmatch '^D:' -or [string]$Snapshot.sddl -match '[OGS]:' -or $Snapshot.readOnly -isnot [bool]) {
            throw [ArgumentException]::new('A DACL-only windows-sddl snapshot with Boolean readOnly is required.')
        }
        return [pscustomobject][ordered]@{
            kind='windows-sddl'
            sddl=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::NormalizeDaclSddl([string]$Snapshot.sddl)
            readOnly=[bool]$Snapshot.readOnly
        }
    }
    catch { throw (New-WindowsPlatformVerificationError $Capability "$Context permissions are invalid: $($_.Exception.Message)") }
}
function Test-WindowsPlatformIdentityMatch {
    param($First,$Second)
    if ($null -eq $First -or $null -eq $Second -or [string]$First.kind -cne 'windows-file-id' -or [string]$Second.kind -cne 'windows-file-id') { return $false }
    try {
        return (ConvertTo-WindowsPlatformIdentityNumber ([string]$First.device)) -eq (ConvertTo-WindowsPlatformIdentityNumber ([string]$Second.device)) -and
            (ConvertTo-WindowsPlatformIdentityNumber ([string]$First.fileId)) -eq (ConvertTo-WindowsPlatformIdentityNumber ([string]$Second.fileId))
    } catch { return $false }
}
function Test-WindowsPlatformStateMatch {
    param($First,$Second)
    $stateProperties=@('exists','sha256','length','identity')
    if ($null -eq $First -or $null -eq $Second -or @($First.PSObject.Properties).Count -ne 4 -or @($Second.PSObject.Properties).Count -ne 4) { return $false }
    foreach($name in $stateProperties){if($null -eq $First.PSObject.Properties[$name] -or $null -eq $Second.PSObject.Properties[$name]){return $false}}
    if ($First.exists -isnot [bool] -or $Second.exists -isnot [bool] -or [bool]$First.exists -ne [bool]$Second.exists) { return $false }
    if (-not [bool]$First.exists) {
        return $null -eq $First.sha256 -and $null -eq $Second.sha256 -and $null -eq $First.length -and $null -eq $Second.length -and $null -eq $First.identity -and $null -eq $Second.identity
    }
    if($First.sha256 -isnot [string] -or $Second.sha256 -isnot [string] -or [string]$First.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Second.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $null -eq $First.length -or $null -eq $Second.length){return $false}
    try {
        return [string]$First.sha256 -ceq [string]$Second.sha256 -and [int64]$First.length -eq [int64]$Second.length -and
            (Test-WindowsPlatformIdentityMatch $First.identity $Second.identity)
    } catch { return $false }
}
function Assert-WindowsPlatformLeasePaths {
    param($ParentLease,$TransactionLease,[string]$Capability)
    [void](Get-WindowsPlatformLeasePath $ParentLease)
    [void](Get-WindowsPlatformLeasePath $TransactionLease)
}
function New-WindowsPlatformRecoveryError {
    param([string]$Capability,[string]$Message,$Receipt)
    $error=New-WindowsPlatformVerificationError $Capability $Message
    $error.Data['Receipt']=$Receipt
    return $error
}
function Invoke-WindowsPlatformDurabilityHook {
    param([string]$Point,[string]$Operation,[string]$Role,$Lease)
    if ($null -ne $script:WindowsPublicationDurabilityTestHook) {
        & $script:WindowsPublicationDurabilityTestHook $Point $Operation $Role $Lease
    }
}
function Invoke-WindowsPlatformFileFlush {
    param($Lease,[string]$Operation,[string]$Point='file-flush')
    try {
        Invoke-WindowsPlatformDurabilityHook $Point $Operation 'file' $Lease
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::Flush($Lease)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and
            [string]$_.Exception.Capability -ceq 'publication-durability') { throw }
        throw (New-WindowsPlatformVerificationError 'publication-durability' "$Operation $Point failed before durability was confirmed: $($_.Exception.Message)")
    }
}
function Invoke-WindowsPlatformDirectoryFlush {
    param($Lease,[string]$Operation,[string]$Point,[string]$Role)
    try {
        Invoke-WindowsPlatformDurabilityHook $Point $Operation $Role $Lease
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::FlushDirectory($Lease)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and
            [string]$_.Exception.Capability -ceq 'publication-durability') { throw }
        throw (New-WindowsPlatformVerificationError 'publication-durability' "$Operation $Point flush failed for the $Role directory: $($_.Exception.Message)")
    }
}
function Get-WindowsPlatformInheritedPermissions {
    param($ParentLease,[string]$Capability)
    $probeLeaf='.ai-instructions-permission-probe-'+[Guid]::NewGuid().ToString('N')
    $probe=$null
    $probeIdentity=$null
    try {
        $probe=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePermissionProbe($ParentLease,$probeLeaf)
        $probeIdentity=Get-WindowsPlatformIdentity $probe.Observation
        $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetPermissionProbePermissions($probe)
        Invoke-WindowsPlatformDurabilityHook 'permission-probe' $Capability 'probe' $probe
        return ConvertTo-WindowsPlatformPermissionSnapshot ([pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}) $Capability 'Inherited target'
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability "Permission probe '$probeLeaf' failed: $($_.Exception.Message)")
    }
    finally {
        $cleanupFailure=$null
        if ($null -ne $probe) {
            try { $probe.Dispose() } catch { $cleanupFailure=$_.Exception.Message }
            $probe=$null
        }
        if ($null -ne $probeIdentity) {
            $residual=$null
            try {
                $residual=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$probeLeaf)
                if ($null -ne $residual) {
                    $residualIdentity=Get-WindowsPlatformIdentity $residual.Observation
                    if (Test-WindowsPlatformIdentityMatch $probeIdentity $residualIdentity) {
                        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOnClose($residual)
                        $residual.Dispose();$residual=$null
                        $remaining=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$probeLeaf)
                        if ($null -ne $remaining) {
                            $remainingIdentity=Get-WindowsPlatformIdentity $remaining.Observation
                            $remaining.Dispose()
                            if (Test-WindowsPlatformIdentityMatch $probeIdentity $remainingIdentity) {
                                throw [IO.IOException]::new('the probe identity still occupies its leaf')
                            }
                        }
                    }
                }
            }
            catch { $cleanupFailure=$_.Exception.Message }
            finally { if ($null -ne $residual) { $residual.Dispose() } }
        }
        if ($null -ne $cleanupFailure) {
            throw (New-WindowsPlatformVerificationError $Capability "Permission probe cleanup failed; residual probe leaf is '$probeLeaf': $cleanupFailure")
        }
    }
}
function Open-WindowsPlatformMutationFile {
    param($ParentLease,[string]$Leaf,$Identity,[string]$Capability,[switch]$AllowMissing,[switch]$Writable)
    try {
        if ($null -eq $Identity) {
            if (-not $AllowMissing) { throw [ArgumentException]::new('An expected file identity is required.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$Leaf)
        }
        $device=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.device)
        $fileId=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.fileId)
        if ($Writable) {
            if ($AllowMissing) { throw [ArgumentException]::new('A writable mutation file must exist.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenWritableMutationFile($ParentLease,$Leaf,$device,$fileId)
        }
        if ($AllowMissing) { return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$Leaf,$device,$fileId) }
        return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenMutationFile($ParentLease,$Leaf,$device,$fileId)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability "The DELETE-scoped file handle could not be opened and identity-verified: $($_.Exception.Message)")
    }
}
function Assert-WindowsPlatformJournalOperation {
    param($Journal,$ParentLease,$TransactionLease,$TransactionContext,[string]$Leaf,[AllowNull()][string]$StageLeaf,[AllowNull()][string]$BackupLeaf,$ExpectedState,$ExpectedStage,[string]$Method,[string]$Capability,[switch]$Removal)
    if ($null -eq $Journal) { return }
    try {
        $required=@('sequence','kind','method','targetRelativePath','stageLeaf','backupLeaf','original','backupIdentity','applied','permissions','state')
        if ($Journal -is [array] -or $null -eq $Journal -or @($Journal.PSObject.Properties).Count -ne $required.Count) { throw [ArgumentException]::new('must be one validated journal v1 operation') }
        foreach($name in $required){ if($null -eq $Journal.PSObject.Properties[$name]){ throw [ArgumentException]::new("is missing $name") } }
        if ([string]$Journal.method -cne $Method) { throw [ArgumentException]::new("method does not match $Method") }
        if ($Removal) {
            if ([string]$Journal.kind -cne 'remove-file') { throw [ArgumentException]::new('kind must be remove-file') }
        }
        elseif (([string]$Journal.kind -cne 'write-file' -and [string]$Journal.kind -cne 'create-file') -or
            ([string]$Journal.kind -ceq 'write-file' -and -not [bool]$ExpectedState.exists) -or
            ([string]$Journal.kind -ceq 'create-file' -and [bool]$ExpectedState.exists)) {
            throw [ArgumentException]::new('kind must be write-file for an existing target or create-file for a missing target')
        }
        $segments=@(([string]$Journal.targetRelativePath).Split('/'))
        if($segments.Count -lt 1 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0){ throw [ArgumentException]::new('targetRelativePath is invalid') }
        foreach($segment in $segments){ [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($segment) }
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals($segments[-1],$Leaf)){ throw [ArgumentException]::new('targetRelativePath leaf does not match Leaf') }
        $parentRelative=[IO.Path]::GetRelativePath([string]$TransactionContext.rootPath,[string]$TransactionContext.parentPath).Replace('\','/')
        if($parentRelative -eq '.'){ $parentRelative='' }
        if([IO.Path]::IsPathRooted($parentRelative) -or $parentRelative -eq '..' -or $parentRelative.StartsWith('../',[StringComparison]::Ordinal)){ throw [ArgumentException]::new('ParentLease is outside the transaction root') }
        $expectedTarget=if([string]::IsNullOrEmpty($parentRelative)){$Leaf}else{$parentRelative+'/'+$Leaf}
        $roundTrip=[IO.Path]::GetFullPath((Join-Path ([string]$TransactionContext.rootPath) ([string]$Journal.targetRelativePath).Replace('/','\')))
        $expectedFull=[IO.Path]::GetFullPath((Join-Path ([string]$TransactionContext.parentPath) $Leaf))
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.targetRelativePath,$expectedTarget) -or -not [StringComparer]::OrdinalIgnoreCase.Equals($roundTrip,$expectedFull)){ throw [ArgumentException]::new('targetRelativePath parent does not match ParentLease') }
        if((($null -eq $StageLeaf) -ne ($null -eq $Journal.stageLeaf)) -or ($null -ne $StageLeaf -and -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.stageLeaf,$StageLeaf))){ throw [ArgumentException]::new('stageLeaf does not match StageLease') }
        if((($null -eq $BackupLeaf) -ne ($null -eq $Journal.backupLeaf)) -or ($null -ne $BackupLeaf -and -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.backupLeaf,$BackupLeaf))){ throw [ArgumentException]::new('backupLeaf does not match the displaced leaf') }
        if(-not (Test-WindowsPlatformStateMatch $Journal.original $ExpectedState)){ throw [ArgumentException]::new('original does not match ExpectedState') }
        if(([bool]$ExpectedState.exists -and $null -eq $Journal.permissions) -or (-not [bool]$ExpectedState.exists -and $null -ne $Journal.permissions)){ throw [ArgumentException]::new('permissions do not match original existence') }
        if($Removal){
            if($Journal.applied.exists -isnot [bool] -or [bool]$Journal.applied.exists -or $null -ne $Journal.applied.sha256 -or $null -ne $Journal.applied.length -or $null -ne $Journal.applied.identity){ throw [ArgumentException]::new('applied must describe a missing target for removal') }
        }
        elseif($null -eq $ExpectedStage -or $Journal.applied.exists -isnot [bool] -or -not [bool]$Journal.applied.exists -or $Journal.applied.sha256 -isnot [string] -or
            [string]$Journal.applied.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $null -eq $Journal.applied.length -or $null -eq $ExpectedStage.length -or
            [string]$Journal.applied.sha256 -cne [string]$ExpectedStage.sha256 -or [int64]$Journal.applied.length -ne [int64]$ExpectedStage.length){ throw [ArgumentException]::new('applied does not match ExpectedStage') }
    }
    catch { throw (New-WindowsPlatformVerificationError $Capability "Journal operation mismatch: $($_.Exception.Message)") }
}

function Publish-WindowsPlatformFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $TransactionLease,[Parameter(Mandatory = $true)] $StageLease,[Parameter(Mandatory = $true)] $ExpectedState,[AllowNull()] $DisplacedLeaf,[Parameter(Mandatory = $true)] $ExpectedStage,[switch] $NoReplace,$Journal)
    if ([string]::IsNullOrEmpty($DisplacedLeaf)) { $DisplacedLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    if ($null -ne $DisplacedLeaf) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DisplacedLeaf) }
    if ($NoReplace -and [bool]$ExpectedState.exists) { throw (New-WindowsPlatformVerificationError 'publication' 'NoReplace requires ExpectedState.exists=false and relies on the native rename to reject a raced destination.') }
    $transactionContext=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'publication'
    Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'publication'
    $stagePath=Get-WindowsPlatformLeasePath $StageLease
    $stageLeaf=[IO.Path]::GetFileName($stagePath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($stagePath),[string]$transactionContext.transactionPath)) { throw (New-WindowsPlatformVerificationError 'publication' 'StageLease is not an immediate child of TransactionLease.') }
    $stageObservation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($StageLease,$StageLease.Observation,$true)
    $stageIdentity=Get-WindowsPlatformIdentity $stageObservation
    if ([string]$ExpectedStage.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [int64]$stageObservation.Size -ne [int64]$ExpectedStage.length -or
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ComputeSha256($StageLease) -cne [string]$ExpectedStage.sha256) { throw (New-WindowsPlatformVerificationError 'publication' 'Stage hash or length differs from ExpectedStage.') }
    if ([bool]$ExpectedState.exists -ne ($null -ne $DisplacedLeaf)) { throw (New-WindowsPlatformVerificationError 'publication' 'DisplacedLeaf must be supplied exactly when ExpectedState.exists is true.') }
    Assert-WindowsPlatformJournalOperation $Journal $ParentLease $TransactionLease $transactionContext $Leaf $stageLeaf $DisplacedLeaf $ExpectedState $ExpectedStage 'stage-rename' 'publication'
    # In NoReplace mode do not probe the destination name. The handle-bound native
    # rename is the authority that rejects an existing or raced destination.
    $target=$null
    $mutationStage=$null
    $displaced=$false
    $applied=$false
    $stagePermissions=$null
    $permissionsApplied=$false
    $targetReadOnlyCleared=$false
    $preserveForRecovery=$false
    $permissions=$null
    $receipt=$null
    try {
        $target=if($NoReplace){$null}elseif([bool]$ExpectedState.exists){Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'publication' -AllowMissing}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'publication' -AllowMissing}
        $stagePermissions=Get-WindowsPlatformPermissions $StageLease
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'publication'
        if ($null -ne $target) {
            $permissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'publication' 'Live target'
            if ($null -ne $Journal) {
                $journalPermissions=ConvertTo-WindowsPlatformPermissionSnapshot $Journal.permissions 'publication' 'Journal original'
                if ([string]$permissions.sddl -cne [string]$journalPermissions.sddl -or [bool]$permissions.readOnly -ne [bool]$journalPermissions.readOnly) {
                    throw (New-WindowsPlatformVerificationError 'publication' 'Journal permissions do not match the live target.')
                }
            }
        }
        else {
            $permissions=Get-WindowsPlatformInheritedPermissions $ParentLease 'publication'
        }
        # OpenFile intentionally preserves origin/main's read-only share mode, which
        # blocks a second DELETE request.  Publication therefore consumes the caller's
        # validated stage lease, then reopens the same identity relative to TransactionLease.
        $StageLease.Dispose()
        $mutationStage=Open-WindowsPlatformMutationFile $TransactionLease $stageLeaf $stageIdentity 'publication' -Writable
        $appliedStagePermissions=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,[string]$permissions.sddl,[bool]$permissions.readOnly)
        $permissionsApplied=$true
        $canonicalStagePermissions=ConvertTo-WindowsPlatformPermissionSnapshot ([pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$appliedStagePermissions.Sddl;readOnly=[bool]$appliedStagePermissions.ReadOnly}) 'publication' 'Applied stage'
        if ([string]$canonicalStagePermissions.sddl -cne [string]$permissions.sddl -or [bool]$canonicalStagePermissions.readOnly -ne [bool]$permissions.readOnly) {
            throw (New-WindowsPlatformVerificationError 'publication' 'Applied stage permissions do not match the target snapshot.')
        }
        Invoke-WindowsPlatformFileFlush $mutationStage 'publication' 'stage-flush'
        Invoke-WindowsPlatformDirectoryFlush $ParentLease 'publication' 'preflight' 'parent'
        Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'publication' 'preflight' 'transaction'
        if ($null -ne $target) {
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$targetReadOnlyCleared=$true }
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$DisplacedLeaf)
            $displaced=$true
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
        }
        try { [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($mutationStage,$ParentLease,$Leaf) }
        catch {
            if ($displaced) {
                try { if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }; [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf); if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }; $targetReadOnlyCleared=$false;$displaced=$false }
                catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rename rollback also failed; inspect target '$Leaf', stage '$stageLeaf', and displaced '$DisplacedLeaf'.") }
            }
            throw
        }
        $applied=$true
        [string[]]$completedSteps=@($(if($null -ne $target){'displaced-rename'})) + @('applied-rename','file-flush')
        $receipt=[pscustomobject][ordered]@{
            completedSteps=$completedSteps
            appliedIdentity=(Get-WindowsPlatformIdentity $mutationStage.Observation)
            displacedIdentity=$(if($null -eq $target){$null}else{Get-WindowsPlatformIdentity $target.Observation})
            permissions=$permissions
            displacedLeaf=$DisplacedLeaf
            durability='unconfirmed'
            flush=[pscustomobject][ordered]@{file=$true;directory=$false;transactionDirectory=$false}
        }
        try {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'publication' 'post-rename' 'parent'
            $receipt.flush.directory=$true
            Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'publication' 'post-rename' 'transaction'
            $receipt.flush.transactionDirectory=$true
            $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
            $receipt.durability='confirmed'
        }
        catch {
            $preserveForRecovery=$true
            throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-rename directory flush failed; journal recovery is required. $($_.Exception.Message)" $receipt)
        }
        try {
            if ($null -ne $script:WindowsPublicationPostRenameTestHook) { & $script:WindowsPublicationPostRenameTestHook 'publication' $transactionContext.parentPath $transactionContext.transactionPath $ParentLease $TransactionLease $mutationStage $target }
            Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'publication'
            $published=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenValidationFile($ParentLease,$Leaf)
            try {
                Assert-WindowsPlatformExpectedState $published ([pscustomobject]@{exists=$true;sha256=[string]$ExpectedStage.sha256;length=[int64]$ExpectedStage.length;identity=(Get-WindowsPlatformIdentity $mutationStage.Observation)}) 'publication'
                $actualPermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $published) 'publication' 'Published target'
                if ([string]$actualPermissions.sddl -cne [string]$permissions.sddl -or [bool]$actualPermissions.readOnly -ne [bool]$permissions.readOnly) { throw (New-WindowsPlatformVerificationError 'publication' "Published permissions do not match the expected snapshot (expected '$($permissions.sddl)'/$($permissions.readOnly), observed '$($actualPermissions.sddl)'/$($actualPermissions.readOnly)).") }
            } finally { if($null -ne $published){$published.Dispose()} }
        }
        catch {
            $preserveForRecovery=$true
            throw (New-WindowsPlatformRecoveryError 'publication' "Post-publication path verification failed; journal recovery is required. $($_.Exception.Message)" $receipt)
        }
        return $receipt
    }
    catch {
        $publicationFailure=$_
        if ($preserveForRecovery) { throw $publicationFailure }
        try {
            if ($applied) {
                [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,$null,$false)
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($mutationStage,$TransactionLease,$stageLeaf)
                $applied=$false
            }
            if ($displaced) {
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf)
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
                $displaced=$false
            }
            elseif ($targetReadOnlyCleared) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
            if ($permissionsApplied) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,[string]$stagePermissions.sddl,[bool]$stagePermissions.readOnly) }
        }
        catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rollback could not restore every rename; target='$Leaf', stage='$stageLeaf', displaced='$DisplacedLeaf'.") }
        throw $publicationFailure
    }
    finally {
        if ($null -ne $mutationStage) { $mutationStage.Dispose() }
        if ($null -ne $target) { $target.Dispose() }
    }
}

function Remove-WindowsPlatformOwnedFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $ExpectedState,$TransactionLease,[AllowNull()] $TombstoneLeaf,$Journal)
    if ([string]::IsNullOrEmpty($TombstoneLeaf)) { $TombstoneLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    $tombstone=($null -ne $TransactionLease -and $null -ne $TombstoneLeaf)
    if (($null -ne $TransactionLease) -ne ($null -ne $TombstoneLeaf)) { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'TransactionLease and TombstoneLeaf must be supplied together.') }
    if (-not $tombstone -and $null -ne $Journal) { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Journal is forbidden in cleanup mode.') }
    $transactionContext=$null
    if ($tombstone) {
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($TombstoneLeaf)
        $transactionContext=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'owned-file-removal'
        Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'owned-file-removal'
        Assert-WindowsPlatformJournalOperation $Journal $ParentLease $TransactionLease $transactionContext $Leaf $null $TombstoneLeaf $ExpectedState $null 'tombstone-rename' 'owned-file-removal' -Removal
    }
    else {
        $path=Get-WindowsPlatformLeasePath $ParentLease
        if ([IO.Path]::GetFileName($path) -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path)) -cne '.ai-instructions-txn') { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Cleanup is restricted to a transaction-private directory.') }
    }
    $target=$null
    $renamed=$false
    $readOnlyCleared=$false
    $preserveForRecovery=$false
    $permissions=$null
    $receipt=$null
    try {
        $target=if([bool]$ExpectedState.exists){Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal'}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'owned-file-removal' -AllowMissing}
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'owned-file-removal'
        $permissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'owned-file-removal' 'Live target'
        if ($null -ne $Journal) {
            $journalPermissions=ConvertTo-WindowsPlatformPermissionSnapshot $Journal.permissions 'owned-file-removal' 'Journal original'
            if ([string]$permissions.sddl -cne [string]$journalPermissions.sddl -or [bool]$permissions.readOnly -ne [bool]$journalPermissions.readOnly) {
                throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Journal permissions do not match the live target.')
            }
        }
        $identity=Get-WindowsPlatformIdentity $target.Observation
        if ($tombstone) {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal' 'preflight' 'parent'
            Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'owned-file-removal' 'preflight' 'transaction'
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$readOnlyCleared=$true }
            $target.Dispose();$target=$null
            $target=Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal' -Writable
            Invoke-WindowsPlatformFileFlush $target 'owned-file-removal' 'file-flush'
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$TombstoneLeaf)
            $renamed=$true
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$readOnlyCleared=$false }
            $receipt=[pscustomobject][ordered]@{
                completedSteps=[string[]]@('tombstone-rename','file-flush')
                appliedIdentity=$null
                displacedIdentity=$identity
                backupIdentity=$identity
                permissions=$permissions
                tombstoneLeaf=$TombstoneLeaf
                durability='unconfirmed'
                flush=[pscustomobject][ordered]@{file=$true;directory=$false;transactionDirectory=$false}
            }
            try {
                Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal' 'post-rename' 'parent'
                $receipt.flush.directory=$true
                Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'owned-file-removal' 'post-rename' 'transaction'
                $receipt.flush.transactionDirectory=$true
                $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
                $receipt.durability='confirmed'
            }
            catch {
                $preserveForRecovery=$true
                throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-rename directory flush failed; journal recovery is required. $($_.Exception.Message)" $receipt)
            }
            try {
                if ($null -ne $script:WindowsPublicationPostRenameTestHook) { & $script:WindowsPublicationPostRenameTestHook 'removal' $transactionContext.parentPath $transactionContext.transactionPath $ParentLease $TransactionLease $null $target }
                Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'owned-file-removal'
                $remaining=Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'owned-file-removal' -AllowMissing
                if($null -ne $remaining){ try { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Removed target name still exists.') } finally { $remaining.Dispose() } }
                $tombstoneValidation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenValidationFile($TransactionLease,$TombstoneLeaf)
                try { Assert-WindowsPlatformExpectedState $tombstoneValidation $ExpectedState 'owned-file-removal' }
                finally { $tombstoneValidation.Dispose() }
            }
            catch {
                $preserveForRecovery=$true
                throw (New-WindowsPlatformRecoveryError 'owned-file-removal' "Post-removal path verification failed; journal recovery is required. $($_.Exception.Message)" $receipt)
            }
            return $receipt
        }
        Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal-cleanup' 'preflight' 'parent'
        if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOnClose($target)
        $receipt=[pscustomobject][ordered]@{
            completedSteps=[string[]]@('delete-on-close')
            appliedIdentity=$null
            displacedIdentity=$identity
            backupIdentity=$identity
            permissions=$permissions
            deleted=$true
            durability='unconfirmed'
            flush=[pscustomobject][ordered]@{file=$false;fileNotRequired=$true;directory=$false;transactionDirectory=$null}
        }
        $target.Dispose();$target=$null
        try {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal-cleanup' 'post-delete' 'parent'
            $receipt.flush.directory=$true
            $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
            $receipt.durability='confirmed'
        }
        catch {
            $preserveForRecovery=$true
            throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-delete directory flush failed; manual recovery verification is required. $($_.Exception.Message)" $receipt)
        }
        return $receipt
    }
    catch {
        $removalFailure=$_
        if ($preserveForRecovery) { throw $removalFailure }
        if ($renamed) {
            try {
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf)
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
                $renamed=$false;$readOnlyCleared=$false
            }
            catch { throw (New-WindowsPlatformVerificationError 'owned-file-removal' "Removal failed and rollback could not restore the tombstone rename; target='$Leaf', tombstone='$TombstoneLeaf'.") }
        }
        elseif ($readOnlyCleared) {
            $restoreTarget=$null
            try {
                $restoreTarget=if($null -ne $target){$target}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal'}
                [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($restoreTarget,$null,$true)
                $readOnlyCleared=$false
            }
            catch { throw (New-WindowsPlatformVerificationError 'owned-file-removal' "Removal failed before rename and the read-only attribute could not be restored for '$Leaf'.") }
            finally { if($null -eq $target -and $null -ne $restoreTarget){$restoreTarget.Dispose()} }
        }
        throw $removalFailure
    }
    finally { if($null -ne $target){$target.Dispose()} }
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
