# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$script:InstallerMutationModulePath = [IO.Path]::GetFullPath(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'installer-safe-mutation.psm1')
)
$loadedInstallerMutationModules = @(
    Import-Module -Name $script:InstallerMutationModulePath -Force -PassThru -Scope Local -ErrorAction Stop
)
if ($loadedInstallerMutationModules.Count -ne 1 -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath([string]$loadedInstallerMutationModules[0].Path),
        $script:InstallerMutationModulePath)) {
    throw [IO.InvalidDataException]::new('The verified installer mutation dependency did not load from its bound path.')
}
$script:InstallerMutationModule = $loadedInstallerMutationModules[0]
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:RuntimePreparationModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:RuntimePreparationModulePath)) { throw [IO.InvalidDataException]::new('The verified runtime preparation dependency did not load from its bound path.') }
$script:RuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Invoke-WindowsInstallerMutationCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Arguments
    )

    $command = $script:InstallerMutationModule.ExportedCommands[$Name]
    if ($null -eq $command) {
        throw [IO.InvalidDataException]::new("The verified installer mutation dependency does not export '$Name'.")
    }
    return & $command @Arguments
}

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
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate)
    $parts = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath)
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
                    $guards.Add((& $script:InstallerMutationModule {
                        param($Anchor)
                        [CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($Anchor,'')
                    } (Join-Path $current $part)))
                } else {
                    $guards.Add((Invoke-WindowsInstallerMutationCommand 'Open-InstallerMutationDirectoryGuard' @{ TargetRoot=$current; RelativeDirectory=$part }))
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
                $guards.Add((& $script:InstallerMutationModule {
                    param($Anchor)
                    [CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($Anchor,'')
                } $next))
            } else {
                $guards.Add((Invoke-WindowsInstallerMutationCommand 'Open-InstallerMutationDirectoryGuard' @{ TargetRoot=$current; RelativeDirectory=$part }))
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
    param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink)
    [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink)
}

function Open-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Enter-WindowsPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function Publish-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-WindowsPlatformNotImplementedError 'publication' 'P7') }
function Remove-WindowsPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-WindowsPlatformNotImplementedError 'owned-file-removal' 'P7') }
function Get-WindowsPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetPermissions($Lease) }
function Set-WindowsPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    if ($null -ne $Snapshot -or $Policy -isnot [Collections.IDictionary] -or $Policy.Count -eq 0 -or
        @($Policy.Keys | Where-Object { $_ -cnotin @('Sddl','ReadOnly') }).Count -gt 0) {
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
    [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($Lease,$sddl,$readOnly)
}
function Resolve-WindowsPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-WindowsRuntimePreparationCommand 'Resolve-VerifiedPlatformPowerShell' @{ Policy=$Policy; DestinationLease=$DestinationLease; OfflineCache=$OfflineCache; ReleaseMetadata=$ReleaseMetadata; Platform='windows' } }
function Initialize-WindowsPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-WindowsRuntimePreparationCommand 'Initialize-VerifiedPlatformPester' @{ Policy=$Policy; RuntimeReceipt=$RuntimeReceipt; DestinationLease=$DestinationLease; Platform='windows'; ResolverPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Resolve-StandardValidationTool.ps1') } }

Export-ModuleMember -Function *-WindowsPlatform*
