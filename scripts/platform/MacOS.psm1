# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function New-MacOSPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'macos',$Step)
}

function Open-MacOSPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate) throw (New-MacOSPlatformNotImplementedError 'directory-lease' 'P2') }
function Open-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) throw (New-MacOSPlatformNotImplementedError 'file-lease' 'P2') }
function Assert-MacOSPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink) throw (New-MacOSPlatformNotImplementedError 'file-identity' 'P2') }
function Enter-MacOSPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) throw (New-MacOSPlatformNotImplementedError 'lock' 'P2') }
function Publish-MacOSPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-MacOSPlatformNotImplementedError 'publication' 'P2') }
function Remove-MacOSPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-MacOSPlatformNotImplementedError 'owned-file-removal' 'P2') }
function Get-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) throw (New-MacOSPlatformNotImplementedError 'permissions' 'P2') }
function Set-MacOSPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) throw (New-MacOSPlatformNotImplementedError 'permissions' 'P2') }
function Start-MacOSPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) throw (New-MacOSPlatformNotImplementedError 'process-isolation' 'P3') }
function Stop-MacOSPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) throw (New-MacOSPlatformNotImplementedError 'process-isolation' 'P3') }
function Resolve-MacOSPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) throw (New-MacOSPlatformNotImplementedError 'powershell-resolution' 'P4') }
function Initialize-MacOSPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) throw (New-MacOSPlatformNotImplementedError 'pester-initialization' 'P4') }

Export-ModuleMember -Function *-MacOSPlatform*
