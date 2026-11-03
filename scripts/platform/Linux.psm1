# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Unix.psm1') -Scope Local -ErrorAction Stop

function New-LinuxPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'linux',$Step)
}

function Open-LinuxPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectory($Root,$RelativePath,[bool]$CreatePrivate) }
function Open-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Assert-LinuxPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink) }
function Enter-LinuxPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function Publish-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-LinuxPlatformNotImplementedError 'publication' 'P7') }
function Remove-LinuxPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-LinuxPlatformNotImplementedError 'owned-file-removal' 'P7') }
function Get-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissions($Lease) }
function Set-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Set-UnixPlatformPermissions @PSBoundParameters }
function Start-LinuxPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) throw (New-LinuxPlatformNotImplementedError 'process-isolation' 'P3') }
function Stop-LinuxPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) throw (New-LinuxPlatformNotImplementedError 'process-isolation' 'P3') }
function Resolve-LinuxPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) throw (New-LinuxPlatformNotImplementedError 'powershell-resolution' 'P4') }
function Initialize-LinuxPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) throw (New-LinuxPlatformNotImplementedError 'pester-initialization' 'P4') }

Export-ModuleMember -Function *-LinuxPlatform*
