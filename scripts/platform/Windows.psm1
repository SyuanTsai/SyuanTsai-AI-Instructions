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

function New-WindowsPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'windows',$Step)
}

function Open-WindowsPlatformDirectory {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate)
    if ($CreatePrivate) { throw (New-WindowsPlatformNotImplementedError 'directory-private-create' 'P2') }
    return Invoke-WindowsInstallerMutationCommand -Name 'Open-InstallerMutationDirectoryGuard' -Arguments @{
        TargetRoot = $Root
        RelativeDirectory = $RelativePath
    }
}

function Assert-WindowsPlatformFileIdentity {
    param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink)
    if (-not $SingleLink -or $Lease -isnot [string]) { throw (New-WindowsPlatformNotImplementedError 'file-identity' 'P2') }
    Invoke-WindowsInstallerMutationCommand -Name 'Assert-InstallerMutationFileOwnership' -Arguments @{
        Path = [string]$Lease
    }
    throw (New-WindowsPlatformNotImplementedError 'file-identity' 'P2')
}

function Open-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) throw (New-WindowsPlatformNotImplementedError 'file-lease' 'P2') }
function Enter-WindowsPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) throw (New-WindowsPlatformNotImplementedError 'lock' 'P2') }
function Publish-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) throw (New-WindowsPlatformNotImplementedError 'publication' 'P2') }
function Remove-WindowsPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) throw (New-WindowsPlatformNotImplementedError 'owned-file-removal' 'P2') }
function Get-WindowsPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) throw (New-WindowsPlatformNotImplementedError 'permissions' 'P2') }
function Set-WindowsPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) throw (New-WindowsPlatformNotImplementedError 'permissions' 'P2') }
function Start-WindowsPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) throw (New-WindowsPlatformNotImplementedError 'process-isolation' 'P3') }
function Stop-WindowsPlatformOwnedProcess { param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) throw (New-WindowsPlatformNotImplementedError 'process-isolation' 'P3') }
function Resolve-WindowsPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) throw (New-WindowsPlatformNotImplementedError 'powershell-resolution' 'P4') }
function Initialize-WindowsPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) throw (New-WindowsPlatformNotImplementedError 'pester-initialization' 'P4') }

Export-ModuleMember -Function *-WindowsPlatform*
