# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PlatformRuntimeApiVersion = '1.0'
$script:PlatformRuntimeManifestPath = Join-Path $PSScriptRoot 'platform-runtime.psd1'

function Get-PlatformRuntimeCanonicalSha256 {
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw [IO.InvalidDataException]::new('Platform runtime inventory files must be UTF-8 without BOM.')
    }
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    $canonicalText = $utf8.GetString($bytes).Replace("`r`n","`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($utf8.GetBytes($canonicalText)))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Assert-PlatformRuntimeInventory {
    [CmdletBinding()]
    param(
        [Parameter()][string] $Root = $PSScriptRoot,
        [Parameter()][string] $ManifestPath = (Join-Path $Root 'platform-runtime.psd1')
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $resolvedManifest = [IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('Platform runtime manifest is missing.')
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $resolvedManifest
    if ($null -eq $manifest.PrivateData -or $null -eq $manifest.PrivateData.PlatformRuntime -or
        $manifest.PrivateData.PlatformRuntime.HashMode -cne 'sha256-utf8-lf' -or
        $null -eq $manifest.PrivateData.PlatformRuntime.Inventory) {
        throw [IO.InvalidDataException]::new('Platform runtime manifest has no bound inventory.')
    }

    $inventory = @($manifest.PrivateData.PlatformRuntime.Inventory)
    $declaredPaths = @($inventory | ForEach-Object { ([string]$_.Path).Replace('\','/') })
    $expectedFileList = @('platform-runtime.psd1') + $declaredPaths
    $manifestFileList = @($manifest.FileList | ForEach-Object { ([string]$_).Replace('\','/') })
    $expectedFileListText = (@($expectedFileList | Sort-Object) -join "`n")
    $manifestFileListText = (@($manifestFileList | Sort-Object) -join "`n")
    if ($expectedFileListText -cne $manifestFileListText -or
        @($expectedFileList | Select-Object -Unique).Count -ne $expectedFileList.Count) {
        throw [IO.InvalidDataException]::new('Platform runtime FileList differs from its bound inventory.')
    }

    $platformRoot = Join-Path $resolvedRoot 'platform'
    if (-not (Test-Path -LiteralPath $platformRoot -PathType Container)) {
        throw [IO.InvalidDataException]::new('Platform runtime implementation directory is missing.')
    }
    $actualPlatformPaths = @(
        Get-ChildItem -LiteralPath $platformRoot -File -Recurse | ForEach-Object {
            ('platform/' + $_.FullName.Substring($platformRoot.Length).TrimStart('\','/')).Replace('\','/')
        }
    )
    $declaredPlatformPaths = @($declaredPaths | Where-Object { $_.StartsWith('platform/',[StringComparison]::Ordinal) })
    $actualPlatformPathsText = (@($actualPlatformPaths | Sort-Object) -join "`n")
    $declaredPlatformPathsText = (@($declaredPlatformPaths | Sort-Object) -join "`n")
    if ($actualPlatformPathsText -cne $declaredPlatformPathsText) {
        throw [IO.InvalidDataException]::new('Platform runtime implementation directory contains missing or extra files.')
    }

    $verifiedFiles = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $inventory) {
        $relativePath = ([string]$entry.Path).Replace('\','/')
        $expectedHash = [string]$entry.Sha256
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            @($relativePath.Split('/') | Where-Object { $_ -ceq '..' }).Count -gt 0 -or
            $expectedHash -notmatch '^[a-f0-9]{64}$') {
            throw [IO.InvalidDataException]::new('Platform runtime inventory contains an invalid entry.')
        }
        $fullPath = Join-Path $resolvedRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw [IO.InvalidDataException]::new("Platform runtime inventory file is missing: $relativePath")
        }
        $actualHash = Get-PlatformRuntimeCanonicalSha256 -LiteralPath $fullPath
        if ($actualHash -cne $expectedHash) {
            throw [IO.InvalidDataException]::new("Platform runtime inventory hash mismatch: $relativePath")
        }
        $verifiedFiles.Add([pscustomobject][ordered]@{ path = $relativePath; sha256 = $actualHash })
    }

    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        hashMode = 'sha256-utf8-lf'
        files = [object[]]$verifiedFiles.ToArray()
    }
}

Assert-PlatformRuntimeInventory | Out-Null

$nativeSourcePath = Join-Path $PSScriptRoot 'platform/PlatformNative.cs'
if ($null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative' -as [type])) {
    Add-Type -LiteralPath @($nativeSourcePath, (Join-Path $PSScriptRoot 'platform/UnixNative.cs'), (Join-Path $PSScriptRoot 'platform/WindowsNative.cs')) -ErrorAction Stop
}
elseif ($null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.UnixNative' -as [type]) -or
        $null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative' -as [type])) {
    throw [IO.InvalidDataException]::new('A pre-P2 native assembly is already loaded. Import this verified runtime in a fresh PowerShell process.')
}

Import-Module (Join-Path $PSScriptRoot 'platform/Windows.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/Linux.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/MacOS.psm1') -Scope Local -ErrorAction Stop

function Get-CurrentPlatformName {
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
}

function Clear-PlatformProbe {
    param(
        [Parameter(Mandatory = $true)] $Directory,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Evidence
    )
    $verified = $false
    try {
        # Check the directory BEFORE using its pathname for file cleanup. A renamed
        # lease still owns the old inode, not a replacement at the original path.
        Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
        foreach ($entry in $Entries) {
            if ($null -ne $entry[1]) {
                $cleanup = Open-PlatformFile -ParentLease $Directory -Leaf $entry[0] -Access Read -CreateMode OpenExisting
                try { Assert-PlatformFileIdentity -Lease $cleanup -Expected $entry[1] -SingleLink | Out-Null } finally { $cleanup.Dispose() }
                Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
                [IO.File]::Delete((Join-Path $Path $entry[0]))
            }
        }
        Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
        $verified = $true
    } catch { $Evidence['cleanupFailure'] = $_.Exception.Message } finally { $Directory.Dispose() }
    # A1 still applies to the final check-to-delete interval on Unix. A detected
    # mismatch, however, must NEVER authorize deletion of the replacement.
    if ($verified) {
        try { [IO.Directory]::Delete($Path,$false) } catch { $Evidence['cleanupFailure'] = $_.Exception.Message }
    }
}

function Test-PlatformPrimitives {
    # Receipt describes this local probe filesystem, not every mounted filesystem.
    $platform = Get-CurrentPlatformName
    $root = if ($platform -eq 'windows') { [IO.Path]::GetTempPath().TrimEnd('\','/') } elseif ($platform -eq 'macos') { '/private/tmp' } else { '/tmp' }
    $name = 'platform-probe-' + [Guid]::NewGuid().ToString('N')
    $path = Join-Path $root $name
    $directory = $null; $file = $null; $first = $null; $second = $null
    $fileIdentity = $null; $lockIdentity = $null
    $status = 'unavailable'
    $evidence = [ordered]@{
        lockPrimitive = $(if ($platform -eq 'windows') { 'windows-fileshare' } else { 'flock' })
        scope = 'Fresh local temporary-directory probe; other filesystems require their own validation.'
        guarantee = $(if ($platform -eq 'windows') { 'Handle sharing denies conflicting open/write/delete.' } else { 'Cooperative advisory flock only; same-account nonparticipants can mutate names/content. Revalidation is not mandatory exclusion (A1).' })
        abi = 'Win32 handle information'
    }
    try {
        if ($platform -ne 'windows') { $evidence.abi = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ValidateAbi() }
        $directory = Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        $file = Open-PlatformFile -ParentLease $directory -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
        $fileIdentity = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink
        $permissions = Get-PlatformPermissions -Lease $file
        if ($platform -eq 'windows') {
            Set-PlatformPermissions -Lease $file -Policy @{ Sddl=$permissions.Sddl; ReadOnly=$permissions.ReadOnly } | Out-Null
        } else {
            Set-PlatformPermissions -Lease $file -Policy @{ Mode=384 } | Out-Null
        }
        $file.Dispose(); $file = $null
        $first = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
        $lockIdentity = $first.Observation
        $second = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
        $conflicted = $false
        try {
            $unexpected = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            $unexpected.Dispose()
        } catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [TimeoutException]) { throw }
            $conflicted = $true
        }
        if (-not $conflicted) { throw [IO.IOException]::new('Lock probe did not exclude an exclusive participant.') }
        $second.Dispose(); $second = $null; $first.Dispose(); $first = $null
        $first = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        Assert-PlatformFileIdentity -Lease $first -Expected $lockIdentity -SingleLink | Out-Null
        $status = 'available'
    }
    catch {
        $evidence['failure'] = $_.Exception.Message
    }
    finally {
        if ($null -ne $second) { $second.Dispose() }
        if ($null -ne $first) { $first.Dispose() }
        if ($null -ne $file) { $file.Dispose() }
        # Only our two known probe names are cleaned; no recursive deletion.
        if ($null -ne $directory) {
            Clear-PlatformProbe -Directory $directory -Path $path -Entries @(@('data',$fileIdentity),@('lock',$lockIdentity)) -Evidence $evidence
        }
    }
    # Construct the receipt AFTER finally so cleanup failures are not lost in a
    # PSCustomObject copy made before cleanup ran.
    return [pscustomobject]@{ status=$status; evidence=[pscustomobject]$evidence }
}

function Get-PlatformCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Required)

    $platform = Get-CurrentPlatformName
    $primitiveProbe = Test-PlatformPrimitives
    $processEnvironmentMethod = @(
        [Environment].GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object {
            $_.Name -ceq 'SetEnvironmentVariable' -and
            $_.GetParameters().Count -eq 3 -and
            $_.GetParameters()[2].ParameterType -eq [EnvironmentVariableTarget]
        }
    )
    $processEnvironmentStatus = if ($processEnvironmentMethod.Count -gt 0) { 'available' } else { 'unavailable' }
    $processEnvironmentEvidence = if ($processEnvironmentMethod.Count -gt 0) {
        'The current runtime exposes System.Environment process-scope assignment.'
    }
    else {
        'The current runtime does not expose System.Environment process-scope assignment.'
    }
    $capabilityDefinitions = [ordered]@{
        'directory-lease' = @('unverified','P2 probe pending.')
        'file-lease' = @('unverified','P2 probe pending.')
        'file-identity' = @('unverified','P2 probe pending.')
        'lock' = @('unverified','P2 probe pending.')
        'publication' = @('unverified','P7 publication primitive is not implemented or probed.')
        'owned-file-removal' = @('unverified','P7 owned-file removal is not implemented or probed.')
        'permissions' = @('unverified','P2 probe pending.')
        'process-isolation' = @('unverified','P3 process isolation is not implemented or probed.')
        'powershell-resolution' = @('unverified','P4 PowerShell resolution is not implemented or probed.')
        'pester-initialization' = @('unverified','P4 Pester initialization is not implemented or probed.')
        'process-environment' = @($processEnvironmentStatus,$processEnvironmentEvidence)
    }

    $capabilities = New-Object System.Collections.Generic.List[object]
    foreach ($name in $capabilityDefinitions.Keys) {
        $definition = $capabilityDefinitions[$name]
        $capabilities.Add([pscustomobject][ordered]@{
            name = $name
            status = [string]$definition[0]
            evidence = [object[]]@([string]$definition[1])
        })
    }
    foreach ($capability in $capabilities) {
        if ($capability.name -cin @('directory-lease','file-lease','file-identity','lock','permissions')) {
            $capability.status = $primitiveProbe.status
            $capability.evidence = [object[]]@($primitiveProbe.evidence)
        }
    }
    foreach ($name in @($Required)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw [ArgumentException]::new('Required capability names cannot be empty.','Required')
        }
        $matches = @($capabilities | Where-Object {
            [StringComparer]::Ordinal.Equals([string]$_.name,[string]$name)
        })
        if ($matches.Count -ne 1 -or $matches[0].status -cne 'available') {
            throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($name,$platform)
        }
    }

    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        os = $platform
        architecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        runtime = [pscustomobject][ordered]@{
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            dotNetVersion = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        }
        capabilities = [object[]]$capabilities.ToArray()
    }
}

function Invoke-PlatformAdapter {
    param([Parameter(Mandatory = $true)][string] $Operation, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Arguments)
    $platformToken = switch (Get-CurrentPlatformName) {
        'windows' { 'Windows' }
        'linux' { 'Linux' }
        'macos' { 'MacOS' }
        default { throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($Operation,'unknown') }
    }
    $operationParts = $Operation.Split('-',2)
    if ($operationParts.Count -ne 2) { throw [ArgumentException]::new('Platform adapter operation must contain a verb and noun.','Operation') }
    $commandName = "$($operationParts[0])-$platformToken$($operationParts[1])"
    return & $commandName @Arguments
}

function Open-PlatformDirectory { [CmdletBinding()] param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [switch] $CreatePrivate) Invoke-PlatformAdapter 'Open-PlatformDirectory' @{ Root=$Root; RelativePath=$RelativePath; CreatePrivate=$CreatePrivate } }
function Open-PlatformFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) Invoke-PlatformAdapter 'Open-PlatformFile' @{ ParentLease=$ParentLease; Leaf=$Leaf; Access=$Access; CreateMode=$CreateMode } }
function Assert-PlatformFileIdentity { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink) Invoke-PlatformAdapter 'Assert-PlatformFileIdentity' @{ Lease=$Lease; Expected=$Expected; SingleLink=$SingleLink } }
function Enter-PlatformLock { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][ValidateSet('Shared','Exclusive')][string] $Mode, [Parameter(Mandatory = $true)][TimeSpan] $Timeout) Invoke-PlatformAdapter 'Enter-PlatformLock' $PSBoundParameters }
function Publish-PlatformFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [switch] $NoReplace, $Journal) Invoke-PlatformAdapter 'Publish-PlatformFile' $PSBoundParameters }
function Remove-PlatformOwnedFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $Journal) Invoke-PlatformAdapter 'Remove-PlatformOwnedFile' $PSBoundParameters }
function Get-PlatformPermissions { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease) Invoke-PlatformAdapter 'Get-PlatformPermissions' $PSBoundParameters }
function Set-PlatformPermissions { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Invoke-PlatformAdapter 'Set-PlatformPermissions' $PSBoundParameters }
function Start-PlatformOwnedProcess { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ExecutableLease, [string[]] $ArgumentList, [hashtable] $Environment, [DateTimeOffset] $Deadline, [string] $IsolationRequirement) Invoke-PlatformAdapter 'Start-PlatformOwnedProcess' $PSBoundParameters }
function Stop-PlatformOwnedProcess { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease, [TimeSpan] $GracePeriod, [DateTimeOffset] $Deadline) Invoke-PlatformAdapter 'Stop-PlatformOwnedProcess' $PSBoundParameters }
function Resolve-PlatformPowerShell { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, $OfflineCache) Invoke-PlatformAdapter 'Resolve-PlatformPowerShell' $PSBoundParameters }
function Initialize-PlatformPester { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-PlatformAdapter 'Initialize-PlatformPester' $PSBoundParameters }

function Set-PlatformProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $Name, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
    [Environment]::SetEnvironmentVariable($Name,$Value,[EnvironmentVariableTarget]::Process)
    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        name = $Name
        scope = 'Process'
    }
}

Export-ModuleMember -Function @(
    'Assert-PlatformRuntimeInventory',
    'Get-PlatformCapabilities',
    'Open-PlatformDirectory',
    'Open-PlatformFile',
    'Assert-PlatformFileIdentity',
    'Enter-PlatformLock',
    'Publish-PlatformFile',
    'Remove-PlatformOwnedFile',
    'Get-PlatformPermissions',
    'Set-PlatformPermissions',
    'Start-PlatformOwnedProcess',
    'Stop-PlatformOwnedProcess',
    'Resolve-PlatformPowerShell',
    'Initialize-PlatformPester',
    'Set-PlatformProcessEnvironment'
)
