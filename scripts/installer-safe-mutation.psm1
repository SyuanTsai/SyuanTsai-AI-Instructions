Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('CodexAiInstructions.InstallerNativeMutation' -as [type])) {
    $platformDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'platform'))
    $nativeSource = [IO.Path]::GetFullPath((Join-Path $platformDirectory 'WindowsInstallerMutation.cs'))
    if ([IO.Path]::GetDirectoryName($nativeSource) -cne $platformDirectory -or
        -not [IO.File]::Exists($nativeSource) -or
        (([IO.File]::GetAttributes([IO.Path]::GetFullPath($PSScriptRoot)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
        (([IO.File]::GetAttributes($platformDirectory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
        (([IO.File]::GetAttributes($nativeSource) -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0)) {
        throw [IO.InvalidDataException]::new('The installer mutation native source must be the physical scripts/platform/WindowsInstallerMutation.cs file in this repository.')
    }
    Add-Type -LiteralPath $nativeSource -ErrorAction Stop
}

function Open-InstallerMutationDirectoryGuard {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativeDirectory
    )

    return [CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($TargetRoot,$RelativeDirectory)
}

function Assert-InstallerMutationFileOwnership {
    param([Parameter(Mandatory = $true)][string] $Path)

    [CodexAiInstructions.InstallerNativeMutation]::AssertSingleLinkFile($Path)
}

function Test-InstallerSafeBytesEqual {
    param(
        [AllowNull()][byte[]] $Left,
        [AllowNull()][byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Read-InstallerSafeStreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileStream] $Stream)

    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.Position = 0
        $Stream.CopyTo($memory)
        return ,([byte[]]$memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function Write-InstallerSafeStreamBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $Stream.Position = 0
    $Stream.SetLength(0)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes,0,$Bytes.Length) }
    $Stream.Flush($true)
}

function Set-InstallerSafeFileBytes {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [switch] $ExpectMissing
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "Installer safe mutation requires Windows: $RelativePath"
    }
    $hasExpectedBytes = $PSBoundParameters.ContainsKey('ExpectedBytes')
    if ($ExpectMissing -and $hasExpectedBytes) {
        throw "Installer safe mutation cannot require both missing state and expected bytes: $RelativePath"
    }
    $targetPath = Join-Path ([System.IO.Path]::GetFullPath($TargetRoot)) $RelativePath.Replace('/','\')
    $context = $null
    $handle = $null
    $stream = $null
    try {
        $context = [CodexAiInstructions.InstallerNativeMutation]::OpenForAtomicWriteOrCreate(
            $TargetRoot,$targetPath,$RelativePath)
        $handle = $context.TakeFileHandle()
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::ReadWrite)
        $handle = $null
        [byte[]]$originalBytes = Read-InstallerSafeStreamBytes -Stream $stream
        if ($ExpectMissing -and -not [bool]$context.Created) {
            throw "Installer destination changed concurrently; an unexpected file was preserved: $RelativePath"
        }
        if ($hasExpectedBytes -and [bool]$context.Created) {
            [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
            throw "Installer destination changed concurrently; the expected file is missing: $RelativePath"
        }
        if ($hasExpectedBytes -and -not (Test-InstallerSafeBytesEqual -Left $originalBytes -Right $ExpectedBytes)) {
            throw "Installer destination changed concurrently; current bytes were preserved: $RelativePath"
        }
        try {
            Write-InstallerSafeStreamBytes -Stream $stream -Bytes $Bytes
            [byte[]]$writtenBytes = Read-InstallerSafeStreamBytes -Stream $stream
            if (-not (Test-InstallerSafeBytesEqual -Left $writtenBytes -Right $Bytes)) {
                throw "Installer destination did not retain the exact requested bytes: $RelativePath"
            }
        }
        catch {
            $writeError = $_
            try {
                if ([bool]$context.Created) {
                    [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
                }
                else {
                    Write-InstallerSafeStreamBytes -Stream $stream -Bytes $originalBytes
                    [byte[]]$restoredBytes = Read-InstallerSafeStreamBytes -Stream $stream
                    if (-not (Test-InstallerSafeBytesEqual -Left $restoredBytes -Right $originalBytes)) {
                        throw 'The original installer destination bytes were not restored exactly.'
                    }
                }
            }
            catch {
                throw "Installer destination write failed and its single-file rollback also failed: $RelativePath. Original: $($writeError.Exception.Message). Rollback: $($_.Exception.Message)"
            }
            throw $writeError
        }
    }
    finally {
        if ($null -ne $stream) {
            try {
                if ($null -ne $context -and $context.RestoreReadOnly) {
                    [CodexAiInstructions.InstallerNativeMutation]::RestoreReadOnly($stream.SafeFileHandle)
                }
            }
            finally { $stream.Dispose() }
        }
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $context) { $context.Dispose() }
    }
}

function Set-InstallerSafeFileFromSource {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Source,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [switch] $ExpectMissing
    )

    $arguments = @{
        TargetRoot = $TargetRoot
        RelativePath = $RelativePath
        Bytes = [System.IO.File]::ReadAllBytes($Source)
    }
    if ($PSBoundParameters.ContainsKey('ExpectedBytes')) { $arguments.ExpectedBytes = $ExpectedBytes }
    if ($ExpectMissing) { $arguments.ExpectMissing = $true }
    Set-InstallerSafeFileBytes @arguments
}

function Remove-InstallerSafeFile {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes
    )

    $targetPath = Join-Path ([System.IO.Path]::GetFullPath($TargetRoot)) $RelativePath.Replace('/','\')
    $handle = $null
    $stream = $null
    try {
        $handle = [CodexAiInstructions.InstallerNativeMutation]::OpenForAtomicDelete(
            $TargetRoot,$targetPath,$RelativePath)
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::Read)
        $handle = $null
        if ($PSBoundParameters.ContainsKey('ExpectedBytes')) {
            [byte[]]$currentBytes = Read-InstallerSafeStreamBytes -Stream $stream
            if (-not (Test-InstallerSafeBytesEqual -Left $currentBytes -Right $ExpectedBytes)) {
                throw "Installer rollback detected concurrent destination bytes; the current file was preserved: $RelativePath"
            }
        }
        [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Open-InstallerMutationDirectoryGuard',
    'Assert-InstallerMutationFileOwnership',
    'Set-InstallerSafeFileBytes',
    'Set-InstallerSafeFileFromSource',
    'Remove-InstallerSafeFile'
)
