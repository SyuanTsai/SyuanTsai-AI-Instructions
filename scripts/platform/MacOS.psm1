# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Unix.psm1') -Scope Local -ErrorAction Stop
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:RuntimePreparationModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [StringComparer]::Ordinal.Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:RuntimePreparationModulePath)) { throw [IO.InvalidDataException]::new('The verified runtime preparation dependency did not load from its bound path.') }
$script:RuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Invoke-MacOSRuntimePreparationCommand { param([string]$Name,[Collections.IDictionary]$Arguments) $command=$script:RuntimePreparationModule.ExportedCommands[$Name]; if($null -eq $command){throw [IO.InvalidDataException]::new("The verified runtime preparation dependency does not export '$Name'.")}; & $command @Arguments }

function New-MacOSPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'macos',$Step)
}

function Open-MacOSPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [string] $RelativePath, [switch] $CreatePrivate, [switch] $RootOnly) if ($RootOnly) { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectoryRoot($Root) } else { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectory($Root,$RelativePath,[bool]$CreatePrivate) } }
function Open-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Assert-MacOSPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink, [switch] $VerifyPath) $observed = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink); if ($VerifyPath) { [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($Lease) }; return $observed }
function Enter-MacOSPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function Publish-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-MacOSPlatformNotImplementedError 'publication' 'P7') }
function Remove-MacOSPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-MacOSPlatformNotImplementedError 'owned-file-removal' 'P7') }
function Get-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissions($Lease) }
function Set-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Set-UnixPlatformPermissions @PSBoundParameters }
function Resolve-MacOSPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-MacOSRuntimePreparationCommand 'Resolve-VerifiedPlatformPowerShell' @{ Policy=$Policy; DestinationLease=$DestinationLease; OfflineCache=$OfflineCache; ReleaseMetadata=$ReleaseMetadata; Platform='macos' } }
function Initialize-MacOSPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-MacOSRuntimePreparationCommand 'Initialize-VerifiedPlatformPester' @{ Policy=$Policy; RuntimeReceipt=$RuntimeReceipt; DestinationLease=$DestinationLease; Platform='macos'; ResolverPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Resolve-StandardValidationTool.ps1') } }

Export-ModuleMember -Function *-MacOSPlatform*
