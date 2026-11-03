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
    Add-Type -LiteralPath @($nativeSourcePath, (Join-Path $PSScriptRoot 'platform/UnixNative.cs'), (Join-Path $PSScriptRoot 'platform/WindowsNative.cs'), (Join-Path $PSScriptRoot 'platform/OwnedProcess.cs'), (Join-Path $PSScriptRoot 'platform/UnixProcess.cs'), (Join-Path $PSScriptRoot 'platform/WindowsProcess.cs')) -ErrorAction Stop
}
elseif ($null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.UnixNative' -as [type]) -or
        $null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative' -as [type]) -or
        $null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease' -as [type])) {
    throw [IO.InvalidDataException]::new('A pre-P3 native assembly is already loaded. Import this verified runtime in a fresh PowerShell process.')
}

Import-Module (Join-Path $PSScriptRoot 'platform/Windows.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/Linux.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/MacOS.psm1') -Scope Local -ErrorAction Stop
$script:PlatformRuntimePreparationPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'platform/RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:PlatformRuntimePreparationPath -PassThru -Scope Local -ErrorAction Stop)
$runtimePreparationPathComparison = if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:PlatformRuntimePreparationPath,$runtimePreparationPathComparison)) {
    throw [IO.InvalidDataException]::new('The allowlisted process-launch dependency did not load from its inventory-bound path.')
}
$script:PlatformRuntimePreparationModule = $loadedRuntimePreparationModules[0]

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
    $processProbe = Test-PlatformOwnedProcess
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
    $powerShellExecutable = Join-Path $PSHOME $(if ($platform -ceq 'windows') { 'pwsh.exe' } else { 'pwsh' })
    $powerShellStatus = 'unavailable'
    $powerShellEvidence = 'The current PowerShell executable was not verified.'
    try {
        $powerShellItem = Get-Item -Force -LiteralPath $powerShellExecutable -ErrorAction Stop
        if ($powerShellItem.PSIsContainer -or ($powerShellItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $powerShellItem.LinkType) { throw 'The current pwsh is not a physical regular file.' }
        $identityCommand = $script:PlatformRuntimePreparationModule.ExportedCommands['Test-PlatformPowerShellIdentity']
        if ($null -eq $identityCommand) { throw 'The verified runtime identity dependency is incomplete.' }
        $runtimeClosure = & $script:PlatformRuntimePreparationModule {
            param([string]$Root,[string]$Platform)
            Get-PlatformRuntimeClosure $Root $Platform
        } $PSHOME $platform
        $expectedArchitecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        $identity = & $identityCommand $powerShellExecutable $PSVersionTable.PSVersion.ToString() $platform $expectedArchitecture $runtimeClosure
        if ([string]$identity.version -cne $PSVersionTable.PSVersion.ToString()) { throw 'The current pwsh version probe disagrees with this process.' }
        $powerShellStatus = 'available'
        $powerShellEvidence = "Physical pwsh identity and version probe passed: $([IO.Path]::GetFullPath($powerShellExecutable))"
    } catch { $powerShellEvidence = $_.Exception.Message }
    $pesterStatus = 'unavailable'
    $pesterEvidence = 'No physical Pester module manifest was verified.'
    try {
        $verifiedPester = New-Object Collections.Generic.List[string]
        foreach ($candidate in @(Get-Module -ListAvailable -Name Pester)) {
            $item = Get-Item -Force -LiteralPath ([string]$candidate.Path) -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { continue }
            $manifest = Import-PowerShellDataFile -Path $item.FullName -ErrorAction Stop
            if ([string]$manifest.ModuleVersion -ceq $candidate.Version.ToString()) { $verifiedPester.Add("$($candidate.Version):$($item.FullName)") }
        }
        if ($verifiedPester.Count -gt 0) { $pesterStatus = 'available'; $pesterEvidence = [string]::Join('; ',$verifiedPester.ToArray()) }
    } catch { $pesterEvidence = $_.Exception.Message }
    $capabilityDefinitions = [ordered]@{
        'directory-lease' = @('unverified','P2 probe pending.')
        'file-lease' = @('unverified','P2 probe pending.')
        'file-identity' = @('unverified','P2 probe pending.')
        'lock' = @('unverified','P2 probe pending.')
        'publication' = @('unverified','P7 publication primitive is not implemented or probed.')
        'owned-file-removal' = @('unverified','P7 owned-file removal is not implemented or probed.')
        'permissions' = @('unverified','P2 probe pending.')
        'process-isolation' = @('unverified','P3 probe pending.')
        'owned-process' = @('unverified','P3 probe pending.')
        'process-cleanup' = @('unverified','P3 probe pending.')
        'powershell-resolution' = @('unverified','P4 PowerShell resolution is not implemented or probed.')
        'pester-initialization' = @('unverified','P4 Pester initialization is not implemented or probed.')
        'powershell-runtime' = @($powerShellStatus,$powerShellEvidence)
        'pester-module' = @($pesterStatus,$pesterEvidence)
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
        if ($capability.name -cin @('owned-process','process-cleanup','process-isolation')) {
            $capability.status = $processProbe.status
            $capability.evidence = [object[]]@($processProbe.evidence)
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
function Start-PlatformOwnedProcess {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory=$true,ParameterSetName='Lease')] $ExecutableLease,
        [Parameter(Mandatory=$true,ParameterSetName='Path')][ValidateNotNullOrEmpty()][string] $ExecutablePath,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.IDictionary] $Environment,
        [Parameter(Mandatory=$true)] $WorkingDirectoryLease,
        [Parameter(Mandatory=$true)][DateTimeOffset] $Deadline,
        [ValidateSet('cooperative','strong')][string] $IsolationRequirement = 'cooperative',
        [Parameter(Mandatory=$true)][string] $StdoutPath,
        [Parameter(Mandatory=$true)][string] $StderrPath,
        # Legacy spelling remains an alias; quotas are UTF-8 decoded characters per stream.
        [Alias('OutputLimitBytes')][ValidateRange(1,1048576)][long] $OutputLimitCharacters = 1048576,
        # Unix invocation name only; Windows validates it but keeps its launch semantics.
        [string] $ArgumentZero
    )
    $platform = Get-CurrentPlatformName
    $argumentZeroValue = $null
    if ($PSBoundParameters.ContainsKey('ArgumentZero')) {
        if ($ArgumentZero.IndexOf([char]0) -ge 0 -or -not [IO.Path]::IsPathFullyQualified($ArgumentZero)) {
            throw [ArgumentException]::new('ArgumentZero must be an absolute path without NUL.')
        }
        $argumentZeroValue = $ArgumentZero
    }
    if ($IsolationRequirement -eq 'strong' -and $platform -ne 'windows') {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('strong-process-isolation: external sandbox required',$platform)
    }
    if ($Deadline -le [DateTimeOffset]::UtcNow) { throw [ArgumentException]::new('Deadline must be in the future.') }
    # Output files are create-only P2 leases, including validation of every ancestor.
    # Linux executable leases execute through /proc/self/fd. Darwin uses F_GETPATH
    # with identity checks before/after suspended spawn (cooperative, not atomic fd
    # execution). Neither mode supplies a hostile-UID sandbox.
    $outLease = $null; $errLease = $null
    try {
        foreach ($path in @($StdoutPath,$StderrPath)) {
            if (-not [IO.Path]::IsPathRooted($path)) { throw [ArgumentException]::new('Capture paths must be absolute.') }
            $anchor = [IO.Path]::GetPathRoot($path)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($path.Substring($anchor.Length))
        }
        foreach ($pair in @(@('out',$StdoutPath),@('err',$StderrPath))) {
            $parentPath = [IO.Path]::GetDirectoryName($pair[1])
            $anchor = [IO.Path]::GetPathRoot($parentPath)
            $relative = $parentPath.Substring($anchor.Length)
            if ([string]::IsNullOrEmpty($relative)) { throw [ArgumentException]::new('Capture files require a directory below the filesystem root.') }
            $parent = Open-PlatformDirectory -Root $anchor -RelativePath $relative
            try {
                $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($pair[1])) -Access Write -CreateMode CreateNew
                if ($pair[0] -eq 'out') { $outLease = $file } else { $errLease = $file }
            } finally { $parent.Dispose() }
        }
        $startParameters = @{
            ExecutablePath = $ExecutablePath; ExecutableLease = $ExecutableLease; ArgumentList = $ArgumentList
            Environment = $Environment; WorkingDirectoryLease = $WorkingDirectoryLease; Deadline = $Deadline
            IsolationRequirement = $IsolationRequirement; StdoutLease = $outLease; StderrLease = $errLease
            OutputLimitBytes = $OutputLimitCharacters
        }
        if ($PSBoundParameters.ContainsKey('ArgumentZero')) { $startParameters.ArgumentZero = $argumentZeroValue }
        $lease = Start-PlatformCapturedProcess @startParameters
        $outLease = $null; $errLease = $null
        return $lease
    } finally {
        if ($null -ne $outLease) { $outLease.Dispose() }
        if ($null -ne $errLease) { $errLease.Dispose() }
    }
}
function Start-PlatformCapturedProcess {
    # Internal boundary shared by caller-owned capture files and temporary probes.
    param($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes,$ArgumentZero=$null)
    if ($PSBoundParameters.ContainsKey('ArgumentZero') -and $null -ne $ArgumentZero) {
        return [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes,[string]$ArgumentZero)
    }
    [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes)
}

function Start-PlatformProbeProcess {
    param($Directory,[string]$StdoutLeaf,[string]$StderrLeaf,$Executable,$Arguments,$Environment,
        [Collections.Generic.List[object]]$Entries)
    $outLease = $null; $errLease = $null
    try {
        # Record each create-only lease before the next creation or native start
        # can fail. Never infer ownership later by reopening a known pathname.
        $outLease = Open-PlatformFile -ParentLease $Directory -Leaf $StdoutLeaf -Access Write -CreateMode CreateNew
        $Entries.Add(@($StdoutLeaf,$outLease.Observation))
        $errLease = Open-PlatformFile -ParentLease $Directory -Leaf $StderrLeaf -Access Write -CreateMode CreateNew
        $Entries.Add(@($StderrLeaf,$errLease.Observation))
        $lease = Start-PlatformCapturedProcess -ExecutablePath $Executable -ArgumentList $Arguments -Environment $Environment -WorkingDirectoryLease $Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -IsolationRequirement cooperative -StdoutLease $outLease -StderrLease $errLease -OutputLimitBytes 4096
        $outLease = $null; $errLease = $null
        return $lease
    } finally {
        if ($null -ne $outLease) { $outLease.Dispose() }
        if ($null -ne $errLease) { $errLease.Dispose() }
    }
}

function Stop-PlatformOwnedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease] $Lease,
        [TimeSpan] $GracePeriod = [TimeSpan]::FromMilliseconds(250),
        [DateTimeOffset] $Deadline = [DateTimeOffset]::UtcNow.AddSeconds(5),
        [ValidateNotNullOrEmpty()][string] $ExpectedStartIdentity
    )
    $expected = if ($PSBoundParameters.ContainsKey('ExpectedStartIdentity')) { $ExpectedStartIdentity } else { $null }
    $Lease.Stop($GracePeriod,$Deadline,$expected)
}

function Test-PlatformOwnedProcess {
    $platform = Get-CurrentPlatformName
    $root = if ($platform -eq 'windows') { [IO.Path]::GetTempPath().TrimEnd('\','/') } elseif ($platform -eq 'macos') { '/private/tmp' } else { '/tmp' }
    $name = 'process-probe-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $root $name
    $directory = $null; $lease = $null; $status = 'unavailable'
    $entries = [Collections.Generic.List[object]]::new()
    $evidence = [ordered]@{
        isolation = $(switch ($platform) { windows { 'windows-job-object' }; linux { 'linux-process-group-subreaper' }; macos { 'macos-process-group' } })
        scope = 'Measured cooperative child execution and cleanup on this host; no filesystem isolation.'
        strong = ($platform -eq 'windows')
        limitations = @(
            if ($platform -eq 'macos') { 'macos-process-group-cannot-detect-setsid-escape' }
            if ($platform -eq 'macos' -or $platform -eq 'linux') { 'group-signal-external-reaper-race' }
        )
        # This probe exercises pathname execution only. ExecutableLease binding
        # must not be advertised without a separate successful lease probe.
        boundary = 'Unix process groups allow setsid escape; polling cannot prove containment of hostile code. Strong Unix isolation requires an external sandbox. Subreaper remains enabled for the supervisor lifetime; Unix leases are serialized.'
    }
    try {
        $directory = Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        $environment = @{}
        if ($platform -eq 'windows') {
            $executable = (Get-Process -Id $PID).Path
            $environment['SystemRoot'] = [Environment]::GetEnvironmentVariable('SystemRoot')
            $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-Command','[Console]::Out.Write("probe-out"); [Console]::Error.Write("probe-err"); exit 7')
        } else { $executable = '/bin/sh'; $arguments = @('-c','printf probe-out; printf probe-err >&2; exit 7') }
        $lease = Start-PlatformProbeProcess -Directory $directory -StdoutLeaf out -StderrLeaf err -Executable $executable -Arguments $arguments -Environment $environment -Entries $entries
        if (-not $lease.WaitForExit([TimeSpan]::FromSeconds(10))) { throw [TimeoutException]::new('Process capability probe timed out.') }
        $receipt = Stop-PlatformOwnedProcess -Lease $lease
        $evidence['cleanup'] = $receipt
        if (-not $receipt.CleanedUp -or $lease.ExitCode -ne 7) { throw [IO.IOException]::new('Process capability probe did not exit and clean up as expected.') }
        foreach ($leaf in @('out','err')) {
            $file = Open-PlatformFile -ParentLease $directory -Leaf $leaf -Access Read -CreateMode OpenExisting
            try {
                $created = $entries | Where-Object { $_[0] -ceq $leaf }
                Assert-PlatformFileIdentity -Lease $file -Expected $created[1] -SingleLink | Out-Null
                if ([IO.File]::ReadAllText((Join-Path $path $leaf)) -cne ('probe-' + $leaf)) { throw [IO.IOException]::new('Process capture probe mismatch.') }
            } finally { $file.Dispose() }
        }
        $evidence['exitCode'] = $lease.ExitCode
        $lease.Dispose(); $lease = $null
        $arguments = if ($platform -eq 'windows') { @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep 30') } else { @('-c','exec /bin/sleep 30') }
        $lease = Start-PlatformProbeProcess -Directory $directory -StdoutLeaf stop-out -StderrLeaf stop-err -Executable $executable -Arguments $arguments -Environment $environment -Entries $entries
        $receipt = Stop-PlatformOwnedProcess -Lease $lease
        $evidence['terminationCleanup'] = $receipt
        if (-not $receipt.CleanedUp -or $receipt.SignalsSent -lt 1) { throw [IO.IOException]::new('Process termination probe did not confirm cleanup.') }
        $status = 'available'
    } catch {
        $evidence['failure'] = $_.Exception.Message
        if ($null -ne $lease) { $evidence['unixObservation'] = $lease.UnixObservation }
    }
    finally {
        try {
            if ($null -ne $lease) { $lease.Dispose() }
        } catch {
            $evidence['processDisposeFailure'] = $_.Exception.Message
            $status = 'unavailable'
        } finally {
            if ($null -ne $directory) { Clear-PlatformProbe -Directory $directory -Path $path -Entries $entries.ToArray() -Evidence $evidence }
        }
    }
    if ($evidence.Contains('cleanupFailure')) { $status = 'unavailable' }
    [pscustomobject]@{ status=$status; evidence=[pscustomobject]$evidence }
}
function Resolve-PlatformPowerShell { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-PlatformAdapter 'Resolve-PlatformPowerShell' $PSBoundParameters }
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
