# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function New-LinuxPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'linux',$Step)
}

function Open-LinuxPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate) throw (New-LinuxPlatformNotImplementedError 'directory-lease' 'P2') }
function Open-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) throw (New-LinuxPlatformNotImplementedError 'file-lease' 'P2') }
function Assert-LinuxPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink) throw (New-LinuxPlatformNotImplementedError 'file-identity' 'P2') }
function Enter-LinuxPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) throw (New-LinuxPlatformNotImplementedError 'lock' 'P2') }
function Publish-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-LinuxPlatformNotImplementedError 'publication' 'P2') }
function Remove-LinuxPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-LinuxPlatformNotImplementedError 'owned-file-removal' 'P2') }
function Get-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) throw (New-LinuxPlatformNotImplementedError 'permissions' 'P2') }
function Set-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) throw (New-LinuxPlatformNotImplementedError 'permissions' 'P2') }
function Start-LinuxPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) throw (New-LinuxPlatformNotImplementedError 'process-isolation' 'P3') }
function Stop-LinuxPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) throw (New-LinuxPlatformNotImplementedError 'process-isolation' 'P3') }
function Resolve-LinuxPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) throw (New-LinuxPlatformNotImplementedError 'powershell-resolution' 'P4') }
function Initialize-LinuxPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) throw (New-LinuxPlatformNotImplementedError 'pester-initialization' 'P4') }

Export-ModuleMember -Function *-LinuxPlatform*
