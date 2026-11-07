#Requires -Version 7
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallFailpointPatterns = @(
    'after-journal-prepared',
    'after-journal-stage-flush',
    'after-journal-publish-before-parent-flush',
    'after-recovery-before-install',
    'before-operation-<sequence>',
    'after-original-to-backup-<sequence>',
    'after-operation-<sequence>-before-journal',
    'after-operation-<sequence>',
    'after-committed-before-cleanup',
    'before-cleanup-<artifact-leaf>',
    'during-cleanup-<artifact-leaf>',
    'after-cleanup-<artifact-leaf>',
    'after-rollback-operation-<sequence>'
)

function Get-AiInstructionsInstallFailpointPatterns {
    return [string[]]@($script:InstallFailpointPatterns)
}

function Assert-AiInstructionsInstallerCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Receipt)
    $required = @('directory-lease','file-lease','file-identity','lock','publication','owned-file-removal','permissions','directory-publication')
    $missing = @($required | Where-Object {
        $name = $_
        @($Receipt.capabilities | Where-Object { [string]$_.name -ceq $name -and [string]$_.status -ceq 'available' }).Count -ne 1
    })
    if ($missing.Count -gt 0) {
        $evidence = @($Receipt.capabilities | Where-Object { [string]$_.name -cin $missing } | ForEach-Object {
            "$($_.name)=$($_.status): $([string]::Join('; ',[string[]]@($_.evidence)))"
        })
        throw (New-AiInstructionsRefusalException -Code capability-unavailable -Message (
            'Required installer platform capabilities are unavailable: ' + ($missing -join ', ') + '. Evidence: ' + ($evidence -join ' | ')))
    }
    return $Receipt
}

function Test-AiInstructionsInstallFailpointName {
    param([Parameter(Mandatory = $true)][string] $Name)
    if ($Name -cin @('after-journal-prepared','after-journal-stage-flush','after-journal-publish-before-parent-flush','after-recovery-before-install','after-committed-before-cleanup')) { return $true }
    if ($Name -cmatch '^(?:before-operation-[1-9][0-9]*|after-original-to-backup-[1-9][0-9]*|after-operation-[1-9][0-9]*-before-journal|after-operation-[1-9][0-9]*|after-rollback-operation-[1-9][0-9]*)$') { return $true }
    return $Name -cmatch '^(?:before-cleanup|during-cleanup|after-cleanup)-[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Invoke-AiInstructionsInstallFailpoint {
    param([Parameter(Mandatory = $true)][string] $Name)
    $requested = [Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','Process')
    if ([string]::IsNullOrEmpty($requested) -or -not [string]::Equals($requested,$Name,[StringComparison]::Ordinal)) { return }
    if (-not (Test-AiInstructionsInstallFailpointName -Name $Name)) { return }
    [Environment]::FailFast("AI instructions installer failpoint: $Name")
}

function Get-InstallTransactionSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-InstallTransactionIdentity {
    param([Parameter(Mandatory = $true)] $Observation,[Parameter(Mandatory = $true)][ValidateSet('windows','linux','macos')][string] $PlatformOs)
    $kind = if ($PlatformOs -ceq 'windows') { 'windows-file-id' } else { 'unix-device-inode' }
    $device = if ($PlatformOs -ceq 'windows') { '0x{0:x}' -f [uint64]$Observation.Device } else { [string][uint64]$Observation.Device }
    $fileId = if ($PlatformOs -ceq 'windows') { '0x{0:x}' -f [uint64]$Observation.Inode } else { [string][uint64]$Observation.Inode }
    return [pscustomobject][ordered]@{ kind=$kind; device=$device; fileId=$fileId }
}

function Test-InstallTransactionIdentityEqual {
    param([AllowNull()] $First,[AllowNull()] $Second)
    if ($null -eq $First -or $null -eq $Second) { return $null -eq $First -and $null -eq $Second }
    return [string]$First.kind -ceq [string]$Second.kind -and
        [string]::Equals([string]$First.device,[string]$Second.device,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$First.fileId,[string]$Second.fileId,[StringComparison]::OrdinalIgnoreCase)
}

function Test-InstallTransactionFileStateEqual {
    param([Parameter(Mandatory = $true)] $Actual,[Parameter(Mandatory = $true)] $Expected)
    if ([bool]$Actual.exists -ne [bool]$Expected.exists) { return $false }
    if (-not [bool]$Expected.exists) { return $true }
    return [string]$Actual.sha256 -ceq [string]$Expected.sha256 -and
        [int64]$Actual.length -eq [int64]$Expected.length -and
        (Test-InstallTransactionIdentityEqual $Actual.identity $Expected.identity)
}

function Test-InstallTransactionDirectoryStateEqual {
    param([Parameter(Mandatory = $true)] $Actual,[Parameter(Mandatory = $true)] $Expected)
    if ([bool]$Actual.exists -ne [bool]$Expected.exists) { return $false }
    if (-not [bool]$Expected.exists) { return $true }
    return [string]$Actual.inventorySha256 -ceq [string]$Expected.inventorySha256 -and
        [int64]$Actual.entryCount -eq [int64]$Expected.entryCount -and
        (Test-InstallTransactionIdentityEqual $Actual.identity $Expected.identity)
}

function Get-InstallTransactionEntryKind {
    param([Parameter(Mandatory = $true)][string] $LiteralPath)
    try { $attributes = [IO.File]::GetAttributes([IO.Path]::GetFullPath($LiteralPath)) }
    catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) { return 'missing' }
        throw
    }
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 'reparse' }
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return 'directory' }
    return 'file'
}

function Get-AiInstructionsInstallFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][string] $LiteralPath,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux','macos')][string] $PlatformOs,
        [switch] $IncludePermissions
    )
    $entryKind = Get-InstallTransactionEntryKind -LiteralPath $LiteralPath
    if ($entryKind -ceq 'missing') {
        return [pscustomobject][ordered]@{ exists=$false; sha256=$null; length=$null; identity=$null; permissions=$null }
    }
    if ($entryKind -cne 'file') { throw "Install recovery observed an external change: '$LiteralPath' is $entryKind instead of a regular file." }
    $lease = Open-PlatformFile -ParentLease $ParentLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try {
        $observation = Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink -VerifyPath
        [byte[]]$bytes = $lease.ReadAllBytes(268435456)
        $permissions = if ($IncludePermissions) { Get-PlatformPermissions -Lease $lease } else { $null }
        return [pscustomobject][ordered]@{
            exists=$true
            sha256=Get-InstallTransactionSha256 -Bytes $bytes
            length=[int64]$bytes.Length
            identity=ConvertTo-InstallTransactionIdentity -Observation $observation -PlatformOs $PlatformOs
            permissions=$permissions
        }
    }
    finally { $lease.Dispose() }
}

function Get-AiInstructionsInstallDirectoryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][string] $LiteralPath,
        [switch] $IncludePermissions
    )
    $entryKind = Get-InstallTransactionEntryKind -LiteralPath $LiteralPath
    if ($entryKind -ceq 'missing') {
        return [pscustomobject][ordered]@{ exists=$false; identity=$null; inventorySha256=$null; entryCount=$null; permissions=$null }
    }
    if ($entryKind -cne 'directory') { throw "Install recovery observed an external change: '$LiteralPath' is $entryKind instead of a physical directory." }
    $state = Get-PlatformDirectoryState -ParentLease $ParentLease -Leaf $Leaf
    if (-not $IncludePermissions) {
        return [pscustomobject][ordered]@{ exists=[bool]$state.exists; identity=$state.identity; inventorySha256=$state.inventorySha256; entryCount=$state.entryCount; permissions=$null }
    }
    $directoryLease = Open-PlatformDirectory -Root (Split-Path -Parent $LiteralPath) -RelativePath $Leaf
    try { $permissions = Get-PlatformPermissions -Lease $directoryLease }
    finally { $directoryLease.Dispose() }
    return [pscustomobject][ordered]@{ exists=[bool]$state.exists; identity=$state.identity; inventorySha256=$state.inventorySha256; entryCount=$state.entryCount; permissions=$permissions }
}

function New-AiInstructionsInstallStageFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux','macos')][string] $PlatformOs
    )
    $lease = Open-PlatformFile -ParentLease $TransactionLease -Leaf $Leaf -Access ReadWrite -CreateMode CreateNew
    try {
        $lease.WriteNewBytes($Bytes)
        $observation = Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink -VerifyPath
        $readback = $lease.ReadAllBytes([Math]::Max(1,$Bytes.Length + 1))
        if ([Convert]::ToBase64String($readback) -cne [Convert]::ToBase64String($Bytes)) { throw "Stage file readback differs: $Leaf" }
        return [pscustomobject][ordered]@{
            exists=$true
            sha256=Get-InstallTransactionSha256 -Bytes $Bytes
            length=[int64]$Bytes.Length
            identity=ConvertTo-InstallTransactionIdentity -Observation $observation -PlatformOs $PlatformOs
        }
    }
    finally { $lease.Dispose() }
}

function ConvertTo-InstallJournalBytes {
    param([Parameter(Mandatory = $true)] $Journal)
    return [Text.UTF8Encoding]::new($false).GetBytes((($Journal | ConvertTo-Json -Depth 30).Replace("`r`n","`n")) + "`n")
}

function Test-InstallJournalSemanticEqual {
    param([Parameter(Mandatory = $true)]$First,[Parameter(Mandatory = $true)]$Second)
    return ($First|ConvertTo-Json -Depth 30 -Compress) -ceq ($Second|ConvertTo-Json -Depth 30 -Compress)
}

function Read-AiInstructionsInstallJournalLeaf {
    param([Parameter(Mandatory = $true)] $TransactionLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)][string] $TransactionId)
    $lease = Open-PlatformFile -ParentLease $TransactionLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try { return ConvertFrom-AiInstructionsInstallJournalV1Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($lease.ReadAllBytes(16777216))) -ExpectedTransactionId $TransactionId }
    finally { $lease.Dispose() }
}

function Set-InstallJournalPublicationFailpointHook {
    param([Parameter(Mandatory = $true)][bool] $Enabled)
    $modules = @(Get-Module -All | Where-Object {
        -not [string]::IsNullOrEmpty([string]$_.Path) -and
        ([string]$_.Path).Replace('/','\').EndsWith('\platform\Windows.psm1',[StringComparison]::OrdinalIgnoreCase)
    })
    if ($modules.Count -ne 1) { throw 'The verified Windows platform adapter module is unavailable for the journal durability failpoint.' }
    $value = if ($Enabled) {
        {
            param($Point,$Operation,$Role,$Lease)
            if ($Point -ceq 'post-rename' -and $Operation -ceq 'publication' -and $Role -ceq 'parent') {
                [Environment]::FailFast('AI instructions installer failpoint: after-journal-publish-before-parent-flush')
            }
        }
    }
    else { $null }
    & $modules[0] { param($Hook) $script:WindowsPublicationDurabilityTestHook = $Hook } $value
}

function Write-AiInstructionsInstallJournalStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][object] $Journal,
        [AllowNull()][object] $PreviousJournal = $null,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux','macos')][string] $PlatformOs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $JournalStoreStates
    )
    $leaves = Get-AiInstructionsInstallJournalStoreLeaves
    if ($null -ne $PreviousJournal) {
        $storedPrevious = Read-AiInstructionsInstallJournalLeaf -TransactionLease $TransactionLease -Leaf (Get-AiInstructionsInstallJournalStoreLeaves).journal -TransactionId ([string]$Journal.transactionId)
        if (-not (Test-InstallJournalSemanticEqual -First $storedPrevious -Second $PreviousJournal)) { throw 'Published journal differs from the expected previous journal generation.' }
        Assert-AiInstructionsInstallJournalStoreTransition -Previous $storedPrevious -Next $Journal | Out-Null
    }
    [byte[]]$bytes = ConvertTo-InstallJournalBytes -Journal $Journal
    $stageState = New-AiInstructionsInstallStageFile -TransactionLease $TransactionLease -Leaf $leaves.stage -Bytes $bytes -PlatformOs $PlatformOs
    $JournalStoreStates[[string]$leaves.stage] = $stageState
    Invoke-AiInstructionsInstallFailpoint -Name 'after-journal-stage-flush'
    $validatedStage = Read-AiInstructionsInstallJournalLeaf -TransactionLease $TransactionLease -Leaf $leaves.stage -TransactionId ([string]$Journal.transactionId)
    if (-not (Test-InstallJournalSemanticEqual -First $validatedStage -Second $Journal)) { throw 'Journal stage readback differs from the requested journal.' }
    $journalPath = Join-Path $TransactionPath $leaves.journal
    $registerPublicationFailpoint = $PlatformOs -ceq 'windows' -and
        [string]::Equals([Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','Process'),'after-journal-publish-before-parent-flush',[StringComparison]::Ordinal)
    if ($registerPublicationFailpoint) { Set-InstallJournalPublicationFailpointHook -Enabled $true }
    try {
        if ($null -eq $PreviousJournal) {
            $expected = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $stageLease = Open-PlatformFile -ParentLease $TransactionLease -Leaf $leaves.stage -Access ReadWrite -CreateMode OpenExisting
            try { $receipt = Publish-PlatformFile -ParentLease $TransactionLease -Leaf $leaves.journal -TransactionLease $TransactionLease -StageLease $stageLease -ExpectedState $expected -ExpectedStage $stageState -NoReplace }
            finally { $stageLease.Dispose() }
        }
        else {
            $current = $JournalStoreStates[[string]$leaves.journal]
            if ($null -eq $current) { throw 'The journal store does not contain a classified journal state.' }
            $stageLease = Open-PlatformFile -ParentLease $TransactionLease -Leaf $leaves.stage -Access ReadWrite -CreateMode OpenExisting
            try { $receipt = Publish-PlatformFile -ParentLease $TransactionLease -Leaf $leaves.journal -TransactionLease $TransactionLease -StageLease $stageLease -ExpectedState $current -DisplacedLeaf $leaves.previous -ExpectedStage $stageState }
            finally { $stageLease.Dispose() }
        }
    }
    finally { if ($registerPublicationFailpoint) { Set-InstallJournalPublicationFailpointHook -Enabled $false } }
    $JournalStoreStates[[string]$leaves.journal] = [pscustomobject][ordered]@{
        exists=$true
        sha256=Get-InstallTransactionSha256 -Bytes $bytes
        length=[int64]$bytes.Length
        identity=$receipt.appliedIdentity
    }
    $JournalStoreStates[[string]$leaves.stage] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
    $validated = Read-AiInstructionsInstallJournalLeaf -TransactionLease $TransactionLease -Leaf $leaves.journal -TransactionId ([string]$Journal.transactionId)
    if (-not (Test-InstallJournalSemanticEqual -First $validated -Second $Journal)) { throw 'Published journal readback differs from the requested journal.' }
    if ($null -ne $PreviousJournal) {
        # Publication preserves the displaced journal identity and bytes.  Bind
        # cleanup to the state observed before publication instead of granting
        # a replacement journal.prev authority to delete itself.
        Remove-PlatformOwnedFile -ParentLease $TransactionLease -Leaf $leaves.previous -ExpectedState $current | Out-Null
        $JournalStoreStates[[string]$leaves.previous] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
    }
    return $validated
}

function Copy-InstallJournalWithChange {
    param([Parameter(Mandatory = $true)] $Journal,[string] $Phase,[Nullable[long]] $Sequence,[string] $State)
    $copy = ConvertFrom-AiInstructionsInstallJournalV1Json -Json (($Journal | ConvertTo-Json -Depth 30)) -ExpectedTransactionId ([string]$Journal.transactionId)
    if (-not [string]::IsNullOrEmpty($Phase)) { $copy.phase = $Phase }
    if ($null -ne $Sequence) {
        $sequenceValue = [int64]$Sequence
        $operation = @($copy.operations | Where-Object { [int64]$_.sequence -eq $sequenceValue })
        if ($operation.Count -ne 1) { throw "Journal operation sequence $sequenceValue was not found." }
        $operation[0].state = $State
    }
    return $copy
}

function Invoke-AiInstructionsInstallOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Operation,
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)] $TransactionLease
    )
    $sequence = [int64]$Operation.sequence
    Invoke-AiInstructionsInstallFailpoint -Name "before-operation-$sequence"
    if ([string]$Operation.kind -in @('write-file','create-file')) {
        $stageLease = Open-PlatformFile -ParentLease $TransactionLease -Leaf ([string]$Operation.stageLeaf) -Access ReadWrite -CreateMode OpenExisting
        try {
            $parameters = @{
                ParentLease=$ParentLease; Leaf=([string]$Operation.targetRelativePath).Split('/')[-1]
                TransactionLease=$TransactionLease; StageLease=$stageLease; ExpectedState=$Operation.original
                ExpectedStage=$Operation.applied; Journal=$Operation
            }
            if ([string]$Operation.kind -ceq 'write-file') { $parameters.DisplacedLeaf = [string]$Operation.backupLeaf }
            else { $parameters.NoReplace = $true }
            $receipt = Publish-PlatformFile @parameters
        }
        finally { $stageLease.Dispose() }
        if (-not (Test-InstallTransactionIdentityEqual $receipt.appliedIdentity $Operation.applied.identity)) { throw "Operation $sequence applied identity differs from the prepared journal." }
        if ([bool]$Operation.original.exists -and -not (Test-InstallTransactionIdentityEqual $receipt.displacedIdentity $Operation.backupIdentity)) { throw "Operation $sequence backup identity differs from the prepared journal." }
    }
    elseif ([string]$Operation.kind -in @('swap-directory','create-directory')) {
        if ([string]$Operation.kind -ceq 'swap-directory') {
            $backupReceipt = Move-PlatformOwnedDirectory -ParentLease $ParentLease -Leaf ([string]$Operation.targetRelativePath).Split('/')[-1] -TransactionLease $TransactionLease -DestinationLeaf ([string]$Operation.backupLeaf) -ExpectedIdentity $Operation.original.identity -Direction ToTransaction -ExpectedState $Operation.original -Journal $Operation
            if (-not (Test-InstallTransactionIdentityEqual $backupReceipt.identity $Operation.backupIdentity)) { throw "Operation $sequence directory backup identity differs from the prepared journal." }
            Invoke-AiInstructionsInstallFailpoint -Name "after-original-to-backup-$sequence"
        }
        $receipt = Move-PlatformOwnedDirectory -ParentLease $ParentLease -Leaf ([string]$Operation.stageLeaf) -TransactionLease $TransactionLease -DestinationLeaf ([string]$Operation.targetRelativePath).Split('/')[-1] -ExpectedIdentity $Operation.applied.identity -Direction FromTransaction -ExpectedState $Operation.applied -Journal $Operation
        if (-not (Test-InstallTransactionIdentityEqual $receipt.identity $Operation.applied.identity)) { throw "Operation $sequence directory applied identity differs from the prepared journal." }
    }
    else { throw "Unsupported installer operation kind '$($Operation.kind)'." }
    Invoke-AiInstructionsInstallFailpoint -Name "after-operation-$sequence-before-journal"
    return $receipt
}

function Open-InstallTargetParentLease {
    param([Parameter(Mandatory = $true)][string] $CodexHome,[Parameter(Mandatory = $true)][string] $TargetRelativePath)
    $segments = @($TargetRelativePath.Split('/'))
    if ($segments.Count -eq 1) { return Open-PlatformDirectory -Root $CodexHome -RootOnly }
    return Open-PlatformDirectory -Root $CodexHome -RelativePath ([string]::Join('/',[string[]]$segments[0..($segments.Count - 2)]))
}

function Get-AiInstructionsInstallRecoveryObservations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Journal,[Parameter(Mandatory = $true)][string] $CodexHome,[Parameter(Mandatory = $true)] $TransactionLease,[Parameter(Mandatory = $true)][string] $TransactionPath)
    $observations = [ordered]@{}
    foreach ($operation in @($Journal.operations)) {
        $parentLease = Open-InstallTargetParentLease -CodexHome $CodexHome -TargetRelativePath ([string]$operation.targetRelativePath)
        try {
            $leaf = ([string]$operation.targetRelativePath).Split('/')[-1]
            $targetPath = Join-Path $CodexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $isDirectory = [string]$operation.kind -in @('swap-directory','create-directory')
            $target = if ($isDirectory) { Get-AiInstructionsInstallDirectoryState -ParentLease $parentLease -Leaf $leaf -LiteralPath $targetPath -IncludePermissions }
                else { Get-AiInstructionsInstallFileState -ParentLease $parentLease -Leaf $leaf -LiteralPath $targetPath -PlatformOs ([string]$Journal.platform.os) -IncludePermissions }
            $backup = $null
            if ($null -ne $operation.backupLeaf) {
                $backupPath = Join-Path $TransactionPath ([string]$operation.backupLeaf)
                $backupState = if ($isDirectory) { Get-AiInstructionsInstallDirectoryState -ParentLease $TransactionLease -Leaf ([string]$operation.backupLeaf) -LiteralPath $backupPath }
                    else { Get-AiInstructionsInstallFileState -ParentLease $TransactionLease -Leaf ([string]$operation.backupLeaf) -LiteralPath $backupPath -PlatformOs ([string]$Journal.platform.os) }
                if ([bool]$backupState.exists) {
                    if ($isDirectory) { $backup = [pscustomobject][ordered]@{exists=$true;identity=$backupState.identity;inventorySha256=$backupState.inventorySha256;entryCount=$backupState.entryCount} }
                    else { $backup = [pscustomobject][ordered]@{exists=$true;sha256=$backupState.sha256;length=$backupState.length;identity=$backupState.identity} }
                }
            }
            if ($isDirectory) {
                $observations[[string]$operation.sequence] = [pscustomobject][ordered]@{exists=[bool]$target.exists;identity=$target.identity;inventorySha256=$target.inventorySha256;entryCount=$target.entryCount;permissions=$target.permissions;backup=$backup}
            }
            else {
                $observations[[string]$operation.sequence] = [pscustomobject][ordered]@{exists=[bool]$target.exists;sha256=$target.sha256;length=$target.length;identity=$target.identity;permissions=$target.permissions;backup=$backup}
            }
        }
        finally { $parentLease.Dispose() }
    }
    return [pscustomobject]$observations
}

function Remove-InstallTransactionArtifact {
    param(
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][bool] $Directory,
        [Parameter(Mandatory = $true)][string] $PlatformOs,
        [AllowNull()][object] $ExpectedFileState = $null,
        [AllowNull()][object] $ExpectedDirectoryState = $null,
        [switch] $TrashDirectory
    )
    $path = Join-Path $TransactionPath $Leaf
    if ($Directory) {
        $state = Get-AiInstructionsInstallDirectoryState -ParentLease $TransactionLease -Leaf $Leaf -LiteralPath $path
        if ([bool]$state.exists) {
            if ($null -eq $ExpectedDirectoryState -or -not (Test-InstallTransactionDirectoryStateEqual $state $ExpectedDirectoryState)) {
                throw "Transaction directory artifact differs from the journal state: $Leaf"
            }
            if ($TrashDirectory) {
                if ($PlatformOs -cne 'windows') { throw 'Transaction directory trash publication requires the Windows directory-publication capability.' }
                $trashLeaf = "$Leaf.trash"
                $trashPath = Join-Path $TransactionPath $trashLeaf
                if ((Get-InstallTransactionEntryKind -LiteralPath $trashPath) -cne 'missing') { throw "Transaction cleanup trash already exists: $trashLeaf" }
                if ([string]$state.identity.kind -cne 'windows-file-id' -or
                    [string]$state.identity.device -cnotmatch '^(?:0x)?[0-9a-fA-F]+$' -or
                    [string]$state.identity.fileId -cnotmatch '^(?:0x)?[0-9a-fA-F]+$') {
                    throw "Transaction directory artifact does not have a valid Windows identity: $Leaf"
                }
                $device = [Convert]::ToUInt64(([string]$state.identity.device -replace '^0x',''),16)
                $fileId = [Convert]::ToUInt64(([string]$state.identity.fileId -replace '^0x',''),16)
                $sourceLease = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenMutationDirectory($TransactionLease,$Leaf,$device,$fileId)
                try {
                    $observation = Assert-PlatformFileIdentity -Lease $sourceLease -Expected $sourceLease.Observation -VerifyPath
                    $sourceIdentity = ConvertTo-InstallTransactionIdentity -Observation $observation -PlatformOs $PlatformOs
                    if (-not (Test-InstallTransactionIdentityEqual $sourceIdentity $state.identity)) { throw "Transaction directory artifact changed concurrently: $Leaf" }
                    [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameDirectoryNoReplace($sourceLease,$TransactionLease,$trashLeaf)
                    [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::FlushDirectory($TransactionLease)
                }
                finally { $sourceLease.Dispose() }
                $trashState = Get-AiInstructionsInstallDirectoryState -ParentLease $TransactionLease -Leaf $trashLeaf -LiteralPath $trashPath
                if (-not [bool]$trashState.exists -or -not (Test-InstallTransactionIdentityEqual $trashState.identity $state.identity) -or
                    [string]$trashState.inventorySha256 -cne [string]$state.inventorySha256 -or [int64]$trashState.entryCount -ne [int64]$state.entryCount) {
                    throw "Transaction directory trash differs after identity-bound rename: $trashLeaf"
                }
                Invoke-AiInstructionsInstallFailpoint -Name ("during-cleanup-" + $Leaf)
                Remove-PlatformOwnedDirectoryTree -TransactionLease $TransactionLease -Leaf $trashLeaf -ExpectedIdentity $trashState.identity | Out-Null
            }
            else { Remove-PlatformOwnedDirectoryTree -TransactionLease $TransactionLease -Leaf $Leaf -ExpectedIdentity $ExpectedDirectoryState.identity | Out-Null }
        }
    }
    else {
        $state = Get-AiInstructionsInstallFileState -ParentLease $TransactionLease -Leaf $Leaf -LiteralPath $path -PlatformOs $PlatformOs
        if ([bool]$state.exists) {
            if ($null -eq $ExpectedFileState -or -not (Test-InstallTransactionFileStateEqual $state $ExpectedFileState)) {
                throw "Transaction file artifact differs from the journal state: $Leaf"
            }
            Remove-PlatformOwnedFile -ParentLease $TransactionLease -Leaf $Leaf -ExpectedState $ExpectedFileState | Out-Null
        }
    }
}

function Get-InstallJournalStoreFileState {
    param(
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][ValidateSet('journal','stage','previous')][string] $Role,
        [Parameter(Mandatory = $true)] $CurrentJournal,
        [Parameter(Mandatory = $true)][string] $PlatformOs
    )
    $path = Join-Path $TransactionPath $Leaf
    $state = Get-AiInstructionsInstallFileState -ParentLease $TransactionLease -Leaf $Leaf -LiteralPath $path -PlatformOs $PlatformOs
    if (-not [bool]$state.exists) { return $state }
    $stored = Read-AiInstructionsInstallJournalLeaf -TransactionLease $TransactionLease -Leaf $Leaf -TransactionId ([string]$CurrentJournal.transactionId)
    $valid = Test-InstallJournalSemanticEqual -First $stored -Second $CurrentJournal
    if (-not $valid -and $Role -ceq 'stage') {
        try { Assert-AiInstructionsInstallJournalStoreTransition -Previous $CurrentJournal -Next $stored | Out-Null; $valid = $true }
        catch { $valid = $false }
    }
    elseif (-not $valid -and $Role -ceq 'previous') {
        try { Assert-AiInstructionsInstallJournalStoreTransition -Previous $stored -Next $CurrentJournal | Out-Null; $valid = $true }
        catch { $valid = $false }
    }
    if (-not $valid) { throw "Transaction journal store artifact is not a known $Role generation: $Leaf" }
    return $state
}

function Assert-InstallRecoveryPermissionTarget {
    param(
        [Parameter(Mandatory = $true)] $Lease,
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)] $Operation,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $PlatformOs,
        [Parameter(Mandatory = $true)][bool] $Directory
    )
    $observation = Assert-PlatformFileIdentity -Lease $Lease -Expected $Lease.Observation -SingleLink:(-not $Directory) -VerifyPath
    $identity = ConvertTo-InstallTransactionIdentity -Observation $observation -PlatformOs $PlatformOs
    if (-not (Test-InstallTransactionIdentityEqual $identity $Operation.original.identity)) {
        throw "Recovery permission target identity differs from the journal original: $($Operation.targetRelativePath)"
    }
    if ($Directory) {
        $state = Get-AiInstructionsInstallDirectoryState -ParentLease $ParentLease -Leaf (([string]$Operation.targetRelativePath).Split('/')[-1]) -LiteralPath $TargetPath
        if (-not (Test-InstallTransactionDirectoryStateEqual $state $Operation.original)) {
            throw "Recovery permission target content differs from the journal original: $($Operation.targetRelativePath)"
        }
    }
    else {
        [byte[]]$bytes = $Lease.ReadAllBytes(268435456)
        if ([int64]$bytes.Length -ne [int64]$Operation.original.length -or
            (Get-InstallTransactionSha256 -Bytes $bytes) -cne [string]$Operation.original.sha256) {
            throw "Recovery permission target content differs from the journal original: $($Operation.targetRelativePath)"
        }
    }
}

function Remove-InstallTerminalTransactionArtifacts {
    param(
        [Parameter(Mandatory = $true)] $Journal,
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $JournalStoreStates
    )
    if ([string]$Journal.phase -cnotin @('committed','rolled-back')) {
        throw "Transaction artifacts can be finalized only from a terminal journal phase: $($Journal.phase)"
    }
    $platformOs = [string]$Journal.platform.os
    foreach ($operation in @($Journal.operations)) {
        $directoryArtifact = [string]$operation.kind -in @('swap-directory','create-directory')
        foreach ($leafName in @('backupLeaf','stageLeaf','quarantineLeaf')) {
            $property = $operation.PSObject.Properties[$leafName]
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            $leaf = [string]$property.Value
            $expectedState = if ($leafName -ceq 'backupLeaf') {
                if ($directoryArtifact) {
                    [pscustomobject][ordered]@{ exists=$true; identity=$operation.backupIdentity; inventorySha256=$operation.original.inventorySha256; entryCount=$operation.original.entryCount }
                }
                else {
                    [pscustomobject][ordered]@{ exists=$true; sha256=$operation.original.sha256; length=$operation.original.length; identity=$operation.backupIdentity }
                }
            }
            else { $operation.applied }
            if ($directoryArtifact) {
                Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ($leaf + '.trash') -Directory:$true -PlatformOs $platformOs -ExpectedDirectoryState $expectedState
                Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf $leaf -Directory:$true -PlatformOs $platformOs -ExpectedDirectoryState $expectedState -TrashDirectory
            }
            else {
                Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf $leaf -Directory:$false -PlatformOs $platformOs -ExpectedFileState $expectedState
            }
        }
    }
    $storeLeaves = Get-AiInstructionsInstallJournalStoreLeaves
    foreach ($entry in @(
        [pscustomobject]@{leaf=[string]$storeLeaves.stage;role='stage'},
        [pscustomobject]@{leaf=[string]$storeLeaves.previous;role='previous'},
        [pscustomobject]@{leaf=[string]$storeLeaves.journal;role='journal'}
    )) {
        $expected = $JournalStoreStates[[string]$entry.leaf]
        if ($null -eq $expected) { throw "The journal store does not contain a classified state for $($entry.leaf)." }
        Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf $entry.leaf -Directory:$false -PlatformOs $platformOs -ExpectedFileState $expected
        $JournalStoreStates[[string]$entry.leaf] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
    }
}

function Invoke-AiInstructionsInstallRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Journal,
        [Parameter(Mandatory = $true)] $Plan,
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [Parameter(Mandatory = $true)] $TransactionRootLease,
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $JournalStoreStates
    )
    if ([string]$Plan.action -ceq 'refuse') { throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Interrupted install recovery refused mutation for '$TransactionPath'.") }
    $current = $Journal
    $storeLeaves = Get-AiInstructionsInstallJournalStoreLeaves
    # A killed writer may leave a fully flushed but unpublished stage, or the
    # validated previous generation beside the published journal.  Neither is
    # authoritative after the recovery decision has been made, and both would
    # collide with the next durable store transition.
    try {
        foreach ($storeLeaf in @([string]$storeLeaves.journal,[string]$storeLeaves.previous,[string]$storeLeaves.stage)) {
            $expectedStoreState = $JournalStoreStates[$storeLeaf]
            if ($null -eq $expectedStoreState) { throw "The journal store does not contain a classified state for $storeLeaf." }
            $liveStoreState = Get-AiInstructionsInstallFileState -ParentLease $TransactionLease -Leaf $storeLeaf -LiteralPath (Join-Path $TransactionPath $storeLeaf) -PlatformOs ([string]$Journal.platform.os)
            if (-not (Test-InstallTransactionFileStateEqual $liveStoreState $expectedStoreState)) {
                throw "Transaction journal store artifact changed after classification: $storeLeaf"
            }
        }
        $classifiedStageState = $JournalStoreStates[[string]$storeLeaves.stage]
        if ($null -eq $classifiedStageState) { throw 'The journal store does not contain a classified journal.stage state.' }
        $stageState = Get-InstallJournalStoreFileState -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ([string]$storeLeaves.stage) -Role stage -CurrentJournal $current -PlatformOs ([string]$Journal.platform.os)
        if (-not (Test-InstallTransactionFileStateEqual $stageState $classifiedStageState)) {
            throw "Transaction journal store artifact changed after classification: $($storeLeaves.stage)"
        }
        Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ([string]$storeLeaves.stage) -Directory:$false -PlatformOs ([string]$Journal.platform.os) -ExpectedFileState $stageState
        $JournalStoreStates[[string]$storeLeaves.stage] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        $journalPath = Join-Path $TransactionPath ([string]$storeLeaves.journal)
        $previousPath = Join-Path $TransactionPath ([string]$storeLeaves.previous)
        $journalExists = Test-Path -LiteralPath $journalPath -PathType Leaf
        $previousExists = Test-Path -LiteralPath $previousPath -PathType Leaf
        if (-not $journalExists -and $previousExists) {
            $current = Write-AiInstructionsInstallJournalStore -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Journal $current -PlatformOs ([string]$Journal.platform.os) -JournalStoreStates $JournalStoreStates
            $previousState = $JournalStoreStates[[string]$storeLeaves.previous]
            Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ([string]$storeLeaves.previous) -Directory:$false -PlatformOs ([string]$Journal.platform.os) -ExpectedFileState $previousState
            $JournalStoreStates[[string]$storeLeaves.previous] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        }
        elseif ($journalExists -and $previousExists) {
            $previousState = $JournalStoreStates[[string]$storeLeaves.previous]
            Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ([string]$storeLeaves.previous) -Directory:$false -PlatformOs ([string]$Journal.platform.os) -ExpectedFileState $previousState
            $JournalStoreStates[[string]$storeLeaves.previous] = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        }
    }
    catch {
        if ((Get-AiInstructionsRefusalCode $_) -ceq 'interrupted-install') { throw }
        throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Interrupted install recovery refused mutation and retained evidence at '$TransactionPath'." -InnerException $_.Exception)
    }
    $transactionIdentity = ConvertTo-InstallTransactionIdentity -Observation $TransactionLease.Observation -PlatformOs ([string]$Journal.platform.os)
    $transactionDisposed = $false
    try {
        foreach ($step in @($Plan.steps)) {
            switch ([string]$step.step) {
                'write-phase' {
                    $next = Copy-InstallJournalWithChange -Journal $current -Phase ([string]$step.phase)
                    $current = Write-AiInstructionsInstallJournalStore -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Journal $next -PreviousJournal $current -PlatformOs ([string]$Journal.platform.os) -JournalStoreStates $JournalStoreStates
                    if ([string]$step.phase -ceq 'committed') { Invoke-AiInstructionsInstallFailpoint -Name 'after-committed-before-cleanup' }
                }
                'write-operation-state' {
                    $next = Copy-InstallJournalWithChange -Journal $current -Sequence ([int64]$step.sequence) -State ([string]$step.state)
                    $current = Write-AiInstructionsInstallJournalStore -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Journal $next -PreviousJournal $current -PlatformOs ([string]$Journal.platform.os) -JournalStoreStates $JournalStoreStates
                }
                'cleanup-artifact' {
                    Invoke-AiInstructionsInstallFailpoint -Name ("before-cleanup-" + [string]$step.leaf)
                    $directoryArtifact = [string]$step.primitive -ceq 'Remove-PlatformOwnedDirectoryTree'
                    $cleanupOperation = @($current.operations | Where-Object { [int64]$_.sequence -eq [int64]$step.sequence })[0]
                    $isBackup = [string]$step.leaf -ceq [string]$cleanupOperation.backupLeaf
                    $expectedState = if ($isBackup) {
                        if ($directoryArtifact) { [pscustomobject][ordered]@{exists=$true;identity=$cleanupOperation.backupIdentity;inventorySha256=$cleanupOperation.original.inventorySha256;entryCount=$cleanupOperation.original.entryCount} }
                        else { [pscustomobject][ordered]@{exists=$true;sha256=$cleanupOperation.original.sha256;length=$cleanupOperation.original.length;identity=$cleanupOperation.backupIdentity} }
                    }
                    else { $cleanupOperation.applied }
                    Remove-InstallTransactionArtifact -TransactionLease $TransactionLease -TransactionPath $TransactionPath -Leaf ([string]$step.leaf) -Directory:$directoryArtifact -PlatformOs ([string]$Journal.platform.os) -ExpectedFileState $(if($directoryArtifact){$null}else{$expectedState}) -ExpectedDirectoryState $(if($directoryArtifact){$expectedState}else{$null}) -TrashDirectory:$directoryArtifact
                    Invoke-AiInstructionsInstallFailpoint -Name ("after-cleanup-" + [string]$step.leaf)
                }
                'operation' {
                    $operation = @($current.operations | Where-Object { [int64]$_.sequence -eq [int64]$step.sequence })[0]
                    $parentLease = Open-InstallTargetParentLease -CodexHome $CodexHome -TargetRelativePath ([string]$operation.targetRelativePath)
                    try {
                        $leaf = ([string]$operation.targetRelativePath).Split('/')[-1]
                        $targetPath = Join-Path $CodexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
                        if ([string]$step.action -ceq 'restore-permissions') {
                            $directoryTarget = [string]$operation.kind -in @('swap-directory','create-directory')
                            $lease = if ([string]$operation.kind -in @('swap-directory','create-directory')) { Open-PlatformDirectory -Root (Split-Path -Parent $targetPath) -RelativePath $leaf }
                                else { Open-PlatformFile -ParentLease $parentLease -Leaf $leaf -Access ReadWrite -CreateMode OpenExisting }
                            try {
                                Assert-InstallRecoveryPermissionTarget -Lease $lease -ParentLease $parentLease -Operation $operation -TargetPath $targetPath -PlatformOs ([string]$Journal.platform.os) -Directory $directoryTarget
                                Set-PlatformPermissions -Lease $lease -Snapshot $step.snapshot | Out-Null
                            }
                            finally { $lease.Dispose() }
                        }
                        elseif ([string]$operation.kind -ceq 'swap-directory') {
                            $targetState = Get-AiInstructionsInstallDirectoryState -ParentLease $parentLease -Leaf $leaf -LiteralPath $targetPath
                            if ([bool]$targetState.exists) {
                                Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf $leaf -TransactionLease $TransactionLease -DestinationLeaf ([string]$operation.quarantineLeaf) -ExpectedIdentity $operation.applied.identity -Direction ToTransaction -ExpectedState $operation.applied -Journal $operation | Out-Null
                            }
                            Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf ([string]$operation.backupLeaf) -TransactionLease $TransactionLease -DestinationLeaf $leaf -ExpectedIdentity $operation.backupIdentity -Direction FromTransaction -ExpectedState $operation.original -Journal $operation | Out-Null
                        }
                        elseif ([string]$operation.kind -ceq 'create-directory') {
                            Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf $leaf -TransactionLease $TransactionLease -DestinationLeaf ([string]$operation.quarantineLeaf) -ExpectedIdentity $operation.applied.identity -Direction ToTransaction -ExpectedState $operation.applied -Journal $operation | Out-Null
                        }
                        elseif ([string]$step.action -ceq 'restore-original') {
                            $targetMissing = (Get-InstallTransactionEntryKind -LiteralPath $targetPath) -ceq 'missing'
                            $backupLease = Open-PlatformFile -ParentLease $TransactionLease -Leaf ([string]$operation.backupLeaf) -Access ReadWrite -CreateMode OpenExisting
                            try {
                                $expectedTarget = if ($targetMissing) { [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null} } else { $operation.applied }
                                $parameters = @{ParentLease=$parentLease;Leaf=$leaf;TransactionLease=$TransactionLease;StageLease=$backupLease;ExpectedState=$expectedTarget;ExpectedStage=$operation.original}
                                if ($targetMissing) { $parameters.NoReplace=$true } else { $parameters.DisplacedLeaf=[string]$operation.stageLeaf }
                                Publish-PlatformFile @parameters | Out-Null
                            }
                            finally { $backupLease.Dispose() }
                        }
                        elseif ([string]$step.action -ceq 'remove-applied') {
                            Remove-PlatformOwnedFile -ParentLease $parentLease -Leaf $leaf -ExpectedState $operation.applied -TransactionLease $TransactionLease -TombstoneLeaf ([string]$operation.stageLeaf) | Out-Null
                        }
                    }
                    finally { $parentLease.Dispose() }
                    Invoke-AiInstructionsInstallFailpoint -Name ("after-rollback-operation-" + [string]$step.sequence)
                }
                'cleanup-transaction' {
                    foreach ($directoryOperation in @($current.operations | Where-Object { [string]$_.kind -in @('swap-directory','create-directory') -and $null -ne $_.quarantineLeaf })) {
                        $quarantinePath = Join-Path $TransactionPath ([string]$directoryOperation.quarantineLeaf)
                        $quarantineState = Get-AiInstructionsInstallDirectoryState -ParentLease $TransactionLease -Leaf ([string]$directoryOperation.quarantineLeaf) -LiteralPath $quarantinePath
                        if ([bool]$quarantineState.exists -and -not (Test-InstallTransactionIdentityEqual $quarantineState.identity $directoryOperation.applied.identity)) {
                            throw "Transaction quarantine identity differs from the applied journal identity for sequence $($directoryOperation.sequence)."
                        }
                    }
                    Remove-InstallTerminalTransactionArtifacts -Journal $current -TransactionLease $TransactionLease -TransactionPath $TransactionPath -JournalStoreStates $JournalStoreStates
                    $TransactionLease.Dispose(); $transactionDisposed=$true
                    Remove-PlatformOwnedDirectoryTree -TransactionRootLease $TransactionRootLease -Leaf ([string]$Journal.transactionId) -ExpectedIdentity $transactionIdentity | Out-Null
                }
                default { throw "Unsupported recovery plan step '$($step.step)'." }
            }
        }
    }
    catch {
        if ((Get-AiInstructionsRefusalCode $_) -ceq 'interrupted-install') { throw }
        throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Interrupted install recovery refused mutation and retained evidence at '$TransactionPath'." -InnerException $_.Exception)
    }
    finally { if (-not $transactionDisposed) { } }
    return $current
}

Export-ModuleMember -Function @(
    'Get-AiInstructionsInstallFailpointPatterns','Invoke-AiInstructionsInstallFailpoint','Assert-AiInstructionsInstallerCapabilities',
    'Get-AiInstructionsInstallFileState','Get-AiInstructionsInstallDirectoryState','New-AiInstructionsInstallStageFile',
    'Write-AiInstructionsInstallJournalStore','Invoke-AiInstructionsInstallOperation',
    'Get-AiInstructionsInstallRecoveryObservations','Invoke-AiInstructionsInstallRecoveryPlan'
)
