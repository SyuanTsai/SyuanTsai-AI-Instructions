# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Unix.psm1') -Scope Local -ErrorAction Stop

function New-MacOSPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'macos',$Step)
}

function Open-MacOSPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectory($Root,$RelativePath,[bool]$CreatePrivate) }
function Open-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Assert-MacOSPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink) }
function Enter-MacOSPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function Publish-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-MacOSPlatformNotImplementedError 'publication' 'P7') }
function Remove-MacOSPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-MacOSPlatformNotImplementedError 'owned-file-removal' 'P7') }
function Get-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissions($Lease) }
function Set-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Set-UnixPlatformPermissions @PSBoundParameters }
function Start-MacOSPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) throw (New-MacOSPlatformNotImplementedError 'process-isolation' 'P3') }
function Stop-MacOSPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) throw (New-MacOSPlatformNotImplementedError 'process-isolation' 'P3') }
function Resolve-MacOSPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) throw (New-MacOSPlatformNotImplementedError 'powershell-resolution' 'P4') }
function Initialize-MacOSPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) throw (New-MacOSPlatformNotImplementedError 'pester-initialization' 'P4') }

Export-ModuleMember -Function *-MacOSPlatform*
