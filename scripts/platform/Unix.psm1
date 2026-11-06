# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function Assert-UnixPlatformHost {
    param([Parameter(Mandatory=$true)][string] $Capability)
    $platform = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    if ($platform -cnotin @('linux','macos')) {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($Capability,$platform)
    }
    return $platform
}

function Get-UnixContractValue {
    param([AllowNull()] $Object,[Parameter(Mandatory=$true)][string] $Name,[switch] $Required)
    if ($null -eq $Object) {
        if ($Required) { throw [ArgumentException]::new("Contract object is missing '$Name'.") }
        return $null
    }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    if ($Required) { throw [ArgumentException]::new("Contract object is missing '$Name'.") }
    return $null
}

function ConvertFrom-UnixIdentityNumber {
    param([Parameter(Mandatory=$true)] $Value,[Parameter(Mandatory=$true)][string] $Name)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw [ArgumentException]::new("$Name must be a journal identity string.") }
    $text = [string]$Value
    try {
        if ($text.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)) { return [Convert]::ToUInt64($text.Substring(2),16) }
        return [Convert]::ToUInt64($text,[Globalization.CultureInfo]::InvariantCulture)
    }
    catch { throw [ArgumentException]::new("$Name is outside the unsigned 64-bit identity range.",$_.Exception) }
}

function ConvertTo-UnixPlatformIdentity {
    param([AllowNull()] $Observation)
    if ($null -eq $Observation) { return $null }
    [pscustomobject][ordered]@{
        kind = 'unix-device-inode'
        device = ([uint64]$Observation.Device).ToString([Globalization.CultureInfo]::InvariantCulture)
        fileId = ([uint64]$Observation.Inode).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
}

function ConvertTo-UnixPermissionReceipt {
    param([Parameter(Mandatory=$true)] $Snapshot)
    [pscustomobject][ordered]@{ kind='unix-mode'; mode=[string]$Snapshot.Mode; uid=[uint64]$Snapshot.Uid; gid=[uint64]$Snapshot.Gid }
}

function ConvertTo-UnixFlushReceipt {
    param([Parameter(Mandatory=$true)] $Flush)
    [pscustomobject][ordered]@{
        file=[string]$Flush.File
        parentDirectory=[string]$Flush.ParentDirectory
        transactionDirectory=[string]$Flush.TransactionDirectory
        durability=[string]$Flush.Durability
    }
}

function Assert-UnixExpectedState {
    param([Parameter(Mandatory=$true)] $State,[Parameter(Mandatory=$true)][string] $Context,[switch] $AllowAbsent)
    $exists = Get-UnixContractValue $State exists -Required
    if ($exists -isnot [bool]) { throw [ArgumentException]::new("$Context.exists must be boolean.") }
    if (-not $exists) {
        if (-not $AllowAbsent) { throw [ArgumentException]::new("$Context must describe an existing file.") }
        foreach ($name in @('sha256','length','identity')) {
            if ($null -ne (Get-UnixContractValue $State $name)) { throw [ArgumentException]::new("$Context.$name must be null when exists is false.") }
        }
        return [pscustomobject]@{ exists=$false; sha256=$null; length=[long]0; device=[uint64]0; inode=[uint64]0 }
    }
    $sha256 = Get-UnixContractValue $State sha256 -Required
    $length = Get-UnixContractValue $State length -Required
    $identity = Get-UnixContractValue $State identity -Required
    if ($sha256 -isnot [string] -or [string]$sha256 -cnotmatch '^[0-9a-f]{64}$') { throw [ArgumentException]::new("$Context.sha256 must be lowercase SHA-256.") }
    if ($length -is [bool] -or $null -eq $length -or [decimal]$length -ne [Math]::Truncate([decimal]$length) -or [decimal]$length -lt 0 -or [decimal]$length -gt [long]::MaxValue) { throw [ArgumentException]::new("$Context.length is invalid.") }
    if ((Get-UnixContractValue $identity kind -Required) -cne 'unix-device-inode') { throw [ArgumentException]::new("$Context.identity.kind must be unix-device-inode.") }
    [pscustomobject]@{
        exists=$true
        sha256=[string]$sha256
        length=[long]$length
        device=ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity device -Required) "$Context.identity.device"
        inode=ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity fileId -Required) "$Context.identity.fileId"
    }
}

function Assert-UnixExpectedStage {
    param([Parameter(Mandatory=$true)] $State)
    $sha256 = Get-UnixContractValue $State sha256 -Required
    $length = Get-UnixContractValue $State length -Required
    if ($sha256 -isnot [string] -or [string]$sha256 -cnotmatch '^[0-9a-f]{64}$') { throw [ArgumentException]::new('ExpectedStage.sha256 must be lowercase SHA-256.') }
    if ($length -is [bool] -or $null -eq $length -or [decimal]$length -ne [Math]::Truncate([decimal]$length) -or [decimal]$length -lt 0 -or [decimal]$length -gt [long]::MaxValue) { throw [ArgumentException]::new('ExpectedStage.length is invalid.') }
    [pscustomobject]@{ sha256=[string]$sha256; length=[long]$length }
}

function Assert-UnixJournalBinding {
    param($Journal,$TransactionLease,[string]$Leaf,$StageLease,[string]$DisplacedLeaf,$ExpectedState,$ExpectedStage,[switch]$Remove)
    if ($null -eq $Journal) { return }
    if ((Get-UnixContractValue $Journal schemaVersion -Required) -ne 1) { throw [ArgumentException]::new('Journal must use schemaVersion 1.') }
    $transactionId = [string](Get-UnixContractValue $Journal transactionId -Required)
    if ($transactionId -cnotmatch '^[0-9a-f]{32}$') { throw [ArgumentException]::new('Journal transactionId is invalid.') }
    $verified = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($TransactionLease)
    if ([IO.Path]::GetFileName($verified.TrimEnd([IO.Path]::DirectorySeparatorChar)) -cne $transactionId) { throw [ArgumentException]::new('Journal transactionId does not identify TransactionLease.') }
    $platform = Get-UnixContractValue $Journal platform -Required
    if ((Get-UnixContractValue $platform os -Required) -cne [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()) { throw [ArgumentException]::new('Journal platform does not match the active host.') }
    $matches = @()
    foreach ($operation in @(Get-UnixContractValue $Journal operations -Required)) {
        $relative = [string](Get-UnixContractValue $operation targetRelativePath -Required)
        if (($relative.Replace('\','/').Split('/')[-1]) -ceq $Leaf) { $matches += $operation }
    }
    if ($matches.Count -ne 1) { throw [ArgumentException]::new('Journal must contain exactly one operation for the requested target leaf.') }
    $bound = $matches[0]
    $journalOriginal = Get-UnixContractValue $bound original -Required
    if ([bool](Get-UnixContractValue $journalOriginal exists -Required) -ne [bool](Get-UnixContractValue $ExpectedState exists -Required) -or
        (Get-UnixContractValue $journalOriginal sha256) -cne (Get-UnixContractValue $ExpectedState sha256) -or
        (Get-UnixContractValue $journalOriginal length) -ne (Get-UnixContractValue $ExpectedState length)) { throw [ArgumentException]::new('Journal original state does not match ExpectedState.') }
    if ([bool](Get-UnixContractValue $ExpectedState exists -Required)) {
        $journalIdentity = Get-UnixContractValue $journalOriginal identity -Required
        $expectedIdentity = Get-UnixContractValue $ExpectedState identity -Required
        foreach ($name in @('kind','device','fileId')) {
            if ((Get-UnixContractValue $journalIdentity $name -Required) -cne (Get-UnixContractValue $expectedIdentity $name -Required)) { throw [ArgumentException]::new('Journal original identity does not match ExpectedState.') }
        }
    }
    if ($Remove) {
        if ((Get-UnixContractValue $bound method -Required) -cne 'tombstone-rename' -or
            (Get-UnixContractValue $bound backupLeaf -Required) -cne $DisplacedLeaf) { throw [ArgumentException]::new('Journal removal operation does not match TombstoneLeaf.') }
    }
    else {
        if ((Get-UnixContractValue $bound method -Required) -cne 'stage-rename' -or
            (Get-UnixContractValue $bound stageLeaf -Required) -cne [string]$StageLease.Name) { throw [ArgumentException]::new('Journal publication operation does not match StageLease.') }
        $originalExists = [bool](Get-UnixContractValue $ExpectedState exists -Required)
        $journalBackup = Get-UnixContractValue $bound backupLeaf
        if (($originalExists -and $journalBackup -cne $DisplacedLeaf) -or (-not $originalExists -and $null -ne $journalBackup)) { throw [ArgumentException]::new('Journal publication operation does not match DisplacedLeaf.') }
        $journalApplied = Get-UnixContractValue $bound applied -Required
        if ((Get-UnixContractValue $journalApplied sha256 -Required) -cne (Get-UnixContractValue $ExpectedStage sha256 -Required) -or
            [long](Get-UnixContractValue $journalApplied length -Required) -ne [long](Get-UnixContractValue $ExpectedStage length -Required)) { throw [ArgumentException]::new('Journal applied state does not match ExpectedStage.') }
    }
}

function Get-UnixPlatformPermissionSnapshot {
    param([Parameter(Mandatory=$true)] $Lease)
    Assert-UnixPlatformHost permissions | Out-Null
    ConvertTo-UnixPermissionReceipt ([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissionSnapshot($Lease))
}

function Set-UnixPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    Assert-UnixPlatformHost permissions | Out-Null
    if (($null -eq $Policy) -eq ($null -eq $Snapshot)) { throw [ArgumentException]::new('Specify exactly one of Policy or Snapshot.') }
    if ($null -ne $Snapshot) {
        if ((Get-UnixContractValue $Snapshot kind -Required) -cne 'unix-mode') { throw [ArgumentException]::new('Snapshot.kind must be unix-mode.') }
        $mode = [string](Get-UnixContractValue $Snapshot mode -Required)
        $uid = Get-UnixContractValue $Snapshot uid -Required
        $gid = Get-UnixContractValue $Snapshot gid -Required
    }
    else {
        if ($Policy -isnot [Collections.IDictionary] -or $Policy.Count -ne 1 -or -not $Policy.Contains('Mode')) {
            throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-policy: only Mode is supported',[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem())
        }
        if ($Policy.Mode -is [string] -or $Policy.Mode -is [bool] -or $null -eq $Policy.Mode -or [decimal]$Policy.Mode -ne [Math]::Truncate([decimal]$Policy.Mode) -or [decimal]$Policy.Mode -lt 0 -or [decimal]$Policy.Mode -gt 4095) { throw [ArgumentException]::new('Mode must be an integer from 0 through 4095.') }
        $current = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissionSnapshot($Lease)
        $mode = [Convert]::ToString([int]$Policy.Mode,8).PadLeft($(if ([int]$Policy.Mode -gt 511) { 4 } else { 3 }),'0')
        $uid = $current.Uid; $gid = $current.Gid
    }
    if ($mode -cnotmatch '^[0-7]{3,4}$') { throw [ArgumentException]::new('Snapshot.mode must contain three or four octal digits.') }
    foreach ($value in @($uid,$gid)) { if ($value -is [bool] -or $null -eq $value -or [decimal]$value -ne [Math]::Truncate([decimal]$value) -or [decimal]$value -lt 0 -or [decimal]$value -gt [uint32]::MaxValue) { throw [ArgumentException]::new('Snapshot uid/gid is invalid.') } }
    ConvertTo-UnixPermissionReceipt ([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::SetPermissionSnapshot($Lease,$mode,[uint64]$uid,[uint64]$gid))
}

function Publish-UnixPlatformFile {
    param(
        [Parameter(Mandatory=$true)] $ParentLease,[Parameter(Mandatory=$true)][string] $Leaf,
        [Parameter(Mandatory=$true)] $TransactionLease,[Parameter(Mandatory=$true)] $StageLease,
        [Parameter(Mandatory=$true)] $ExpectedState,[Parameter(Mandatory=$true)][string] $DisplacedLeaf,
        [Parameter(Mandatory=$true)] $ExpectedStage,[switch] $NoReplace,
        [ValidateRange(0,4095)][uint32] $CreateMode = 384,$Journal
    )
    Assert-UnixPlatformHost publication | Out-Null
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DisplacedLeaf)
    $expected = Assert-UnixExpectedState $ExpectedState ExpectedState -AllowAbsent
    $stage = Assert-UnixExpectedStage $ExpectedStage
    Assert-UnixJournalBinding $Journal $TransactionLease $Leaf $StageLease $DisplacedLeaf $ExpectedState $ExpectedStage
    try {
        $result = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::Publish(
            $ParentLease,$Leaf,$TransactionLease,$StageLease,$expected.exists,$expected.device,$expected.inode,$expected.sha256,$expected.length,
            $DisplacedLeaf,$stage.sha256,$stage.length,[bool]$NoReplace,$CreateMode)
        [pscustomobject][ordered]@{
            appliedIdentity=ConvertTo-UnixPlatformIdentity $result.AppliedIdentity
            displacedIdentity=ConvertTo-UnixPlatformIdentity $result.DisplacedIdentity
            permissions=ConvertTo-UnixPermissionReceipt $result.Permissions
            displacedLeaf=$result.DisplacedLeaf
            flush=ConvertTo-UnixFlushReceipt $result.Flush
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException] {
        $native = $_.Exception
        $translated = if ($null -eq $native.Receipt) { $null } else { [pscustomobject][ordered]@{
            appliedIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.AppliedIdentity
            displacedIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.DisplacedIdentity
            permissions=if($null -eq $native.Receipt.Permissions){$null}else{ConvertTo-UnixPermissionReceipt $native.Receipt.Permissions}
            displacedLeaf=$native.Receipt.DisplacedLeaf
            flush=ConvertTo-UnixFlushReceipt $native.Receipt.Flush
        } }
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException]::new($native.Capability,$native.Platform,$native.CurrentState,$native.Message,$translated)
    }
}

function Remove-UnixPlatformOwnedFile {
    param(
        [Parameter(Mandatory=$true)] $ParentLease,[Parameter(Mandatory=$true)][string] $Leaf,
        [Parameter(Mandatory=$true)] $ExpectedState,[Parameter(Mandatory=$true)] $TransactionLease,
        [Parameter(Mandatory=$true)][string] $TombstoneLeaf,$Journal
    )
    Assert-UnixPlatformHost owned-file-removal | Out-Null
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($TombstoneLeaf)
    $expected = Assert-UnixExpectedState $ExpectedState ExpectedState
    Assert-UnixJournalBinding $Journal $TransactionLease $Leaf $null $TombstoneLeaf $ExpectedState $null -Remove
    try {
        $result = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::Remove($ParentLease,$Leaf,$TransactionLease,$TombstoneLeaf,$expected.device,$expected.inode,$expected.sha256,$expected.length)
        [pscustomobject][ordered]@{
            backupIdentity=ConvertTo-UnixPlatformIdentity $result.BackupIdentity
            permissions=ConvertTo-UnixPermissionReceipt $result.Permissions
            tombstoneLeaf=[string]$result.TombstoneLeaf
            method=[string]$result.Method
            flush=ConvertTo-UnixFlushReceipt $result.Flush
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException] {
        $native = $_.Exception
        $translated = if ($null -eq $native.Receipt) { $null } else { [pscustomobject][ordered]@{
            backupIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.BackupIdentity
            permissions=if($null -eq $native.Receipt.Permissions){$null}else{ConvertTo-UnixPermissionReceipt $native.Receipt.Permissions}
            tombstoneLeaf=$native.Receipt.TombstoneLeaf
            method=$native.Receipt.Method
            flush=ConvertTo-UnixFlushReceipt $native.Receipt.Flush
        } }
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException]::new($native.Capability,$native.Platform,$native.CurrentState,$native.Message,$translated)
    }
}

Export-ModuleMember -Function Set-UnixPlatformPermissions,Get-UnixPlatformPermissionSnapshot,Publish-UnixPlatformFile,Remove-UnixPlatformOwnedFile
