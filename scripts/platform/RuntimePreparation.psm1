# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Capture the bundle binding once; validator loading later hashes and parses the
# SAME private snapshot, rather than trusting an earlier pathname inventory check.
$bundle = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'platform-runtime.psd1')
$script:PesterResolverSha256 = [string](@($bundle.PrivateData.PlatformRuntime.Inventory | Where-Object Path -CEQ 'Resolve-StandardValidationTool.ps1')[0].Sha256)

function New-PlatformPreparationSession {
    return [pscustomobject]@{ Guards=[Collections.Generic.List[IDisposable]]::new(); Files=[Collections.Generic.List[object]]::new() }
}

function Close-PlatformPreparationSession {
    param($Session)
    if ($null -ne $Session) { for ($i=$Session.Guards.Count-1; $i -ge 0; $i--) { $Session.Guards[$i].Dispose() }; $Session.Guards.Clear() }
}

function Get-PlatformProtectionBoundary {
    param([string]$Platform)
    if ($Platform -ceq 'windows') { return 'deny-write-delete guards held through verification and process exit; reacquire and revalidate on reuse' }
    return 'A1: archive/payload snapshot hashes and pre-execution revalidation; same-account uncooperative writers cannot be excluded between verification and use'
}

function New-PlatformExpectedClosure {
    param([string]$Root,$Files)
    $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Files) { $ordered.Add([string]$file.path,[pscustomobject]@{path=[string]$file.path;sha256=[string]$file.sha256}) }
    if ($ordered.Count -eq 0) { throw [IO.InvalidDataException]::new('Expected closure is empty.') }
    $canonical=($ordered.Values | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar);sha256=$digest;files=@($ordered.Values)}
}

function Open-PlatformClosureGuards {
    param($Closure,[string]$Platform)
    $session=New-PlatformPreparationSession
    try {
        if ($null -eq $Closure) { throw 'Runtime closure receipt is required.' }
        if ($Platform -ceq 'windows') {
            $root=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot([string]$Closure.rootPath)
            $session.Guards.Add($root)
            foreach ($file in $Closure.files) {
                $relative=Assert-SafePlatformArchivePath ([string]$file.path) $Platform
                $parts=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($relative)
                $parent=$root
                for ($i=0; $i -lt $parts.Length-1; $i++) {
                    $parent=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationDirectory($parent,$parts[$i])
                    $session.Guards.Add($parent)
                }
                $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($parent,$parts[$parts.Length-1],'Read','OpenExisting'))
            }
        }
        return $session
    } catch {
        Close-PlatformPreparationSession $session
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform ('Runtime closure protection failed: '+$_.Exception.Message))
    }
}

function Get-PlatformPreparationProperty {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $matches = @($Value.Keys | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals([string]$_,$Name) })
        if ($matches.Count -gt 1) { throw [IO.InvalidDataException]::new("Property '$Name' is ambiguous by case.") }
        if ($matches.Count -eq 1) { return $Value[$matches[0]] }
        return $null
    }
    $properties = @($Value.PSObject.Properties | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name,$Name) })
    if ($properties.Count -gt 1) { throw [IO.InvalidDataException]::new("Property '$Name' is ambiguous by case.") }
    if ($properties.Count -eq 0) { return $null }
    return $properties[0].Value
}

function New-PlatformPreparationFailure {
    param([string] $Capability, [string] $Platform, [string] $Message)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new($Capability,$Platform,$Message)
}

function Get-VerifiedPlatformLeasePath {
    param($Lease,[string]$Platform)
    try {
        $path = if ($Platform -ceq 'windows') {
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease)
        } else {
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($Lease)
        }
        if ($Lease.Observation.Kind -cne 'directory') { throw [ArgumentException]::new('A live directory lease is required.') }
        return [IO.Path]::GetFullPath($path)
    }
    catch { throw (New-PlatformPreparationFailure 'destination-lease' $Platform $_.Exception.Message) }
}

function Get-PlatformSha256 {
    param([string]$LiteralPath)
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -cne 'windows') {
        $snapshot = New-PlatformArchiveSnapshot $LiteralPath
        try { return Get-PlatformArchiveSha256 $snapshot } finally { $snapshot.Dispose() }
    }
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function New-PlatformArchiveSnapshot {
    param([string]$ArchivePath)
    # Copy once into a private buffer, then expose only a read-only, non-publicly
    # visible stream. Even Unix writers/renames cannot alter the bytes subsequently
    # hashed and extracted. A concurrent change during the copy must still pass
    # the approved hash of this exact snapshot. No disk staging or cache reopen.
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -cne 'windows') {
        return [IO.MemoryStream]::new([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ReadPreparationFileBytes($ArchivePath),$false)
    }
    return [IO.MemoryStream]::new([IO.File]::ReadAllBytes($ArchivePath),$false)
}

function Get-PlatformRuntimeClosure {
    param([string]$Root,[string]$Platform)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootPath)
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
            throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Runtime closure requires physical directories.')
        }
        # Do not recurse through an unchecked directory or junction.
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $child.LinkType) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Runtime closure contains a link.')
            }
            if ($child.PSIsContainer) { $pending.Enqueue($child.FullName); continue }
            [void](Test-PhysicalPlatformFile $child.FullName $Platform 'powershell-runtime')
            $relative = $child.FullName.Substring($rootPath.Length+1).Replace([IO.Path]::DirectorySeparatorChar,'/')
            [void](Assert-SafePlatformArchivePath $relative $Platform)
            $files.Add($relative,[pscustomobject]@{path=$relative;sha256=(Get-PlatformSha256 $child.FullName)})
        }
    }
    if ($files.Count -eq 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Runtime closure is empty.') }
    $canonical = ($files.Values | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{rootPath=$rootPath;sha256=$digest;files=@($files.Values)}
}

function Assert-PlatformRuntimeClosure {
    param([string]$ExecutablePath,$Expected,[string]$Platform)
    try {
        if ($null -eq $Expected) { throw 'Runtime closure receipt is required.' }
        $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExecutablePath))
        $comparison = if ($Platform -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals($root,[string]$Expected.rootPath,$comparison) -or [string]$Expected.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Runtime closure root or digest is invalid.' }
        $actual = Get-PlatformRuntimeClosure $root $Platform
        $expectedFiles = @($Expected.files)
        if ($actual.sha256 -cne [string]$Expected.sha256 -or $actual.files.Count -ne $expectedFiles.Count) { throw 'Runtime closure content or file list changed.' }
        for ($i=0; $i -lt $actual.files.Count; $i++) {
            if ($actual.files[$i].path -cne [string]$expectedFiles[$i].path -or $actual.files[$i].sha256 -cne [string]$expectedFiles[$i].sha256) { throw 'Runtime closure inventory differs from its receipt.' }
        }
        $leaf = [IO.Path]::GetFileName($ExecutablePath)
        if (@($actual.files | Where-Object { $_.path -ceq $leaf }).Count -ne 1) { throw 'Runtime closure does not bind the executable.' }
    } catch { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform ("Runtime closure verification failed: " + $_.Exception.Message)) }
}

function Get-PlatformArchiveSha256 {
    param([IO.MemoryStream]$Snapshot)
    if (-not $Snapshot.CanRead -or -not $Snapshot.CanSeek -or $Snapshot.CanWrite) { throw [IO.InvalidDataException]::new('A read-only archive snapshot is required.') }
    $Snapshot.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Snapshot)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $Snapshot.Position = 0 }
}

function Assert-SafePlatformArchivePath {
    param([string]$Path,[string]$Platform)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.StartsWith('/',[StringComparison]::Ordinal) -or
        $Path -match '^[A-Za-z]:' -or @($Path.Split('/') | Where-Object { $_ -ceq '.' -or $_ -ceq '..' -or $_ -ceq '' }).Count -gt 0) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member has an unsafe path: '$Path'.")
    }
    return ($Path.Split('/') -join [IO.Path]::DirectorySeparatorChar)
}

function Expand-VerifiedPlatformZip {
    param([IO.MemoryStream]$Snapshot,$DestinationLease,[string]$Platform,$Session)
    [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $archive = [IO.Compression.ZipArchive]::new($Snapshot,[IO.Compression.ZipArchiveMode]::Read,$true)
    $entries = New-Object Collections.Generic.List[object]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        foreach ($entry in $archive.Entries) {
            $raw = [string]$entry.FullName
            $directory = $raw.EndsWith('/',[StringComparison]::Ordinal)
            $name = if ($directory) { $raw.TrimEnd('/') } else { $raw }
            $relative = Assert-SafePlatformArchivePath $name $Platform
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes),0)
            $unixType = ($attributes -shr 16) -band 0xf000
            if ($unixType -eq 0xa000 -or ($attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member is a link: '$raw'.")
            }
            if (($unixType -ne 0 -and $unixType -cnotin @(0x4000,0x8000)) -or ($unixType -eq 0x4000 -and -not $directory) -or ($unixType -eq 0x8000 -and $directory)) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member has an unsupported type: '$raw'.")
            }
            if (-not $seen.Add($relative)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive has a duplicate member: '$raw'.") }
            $entries.Add([pscustomobject]@{ Entry=$entry; Relative=$relative; Directory=$directory })
        }
        foreach ($item in @($entries | Sort-Object { $_.Relative.Split([IO.Path]::DirectorySeparatorChar).Count })) {
            if ($item.Directory) { New-PlatformPreparationDirectory $DestinationLease $item.Relative $Platform $Session; continue }
            $source = $item.Entry.Open()
            try {
                Write-PlatformPreparationFile $DestinationLease $item.Relative $source $Platform $Session
            } finally { $source.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Expand-VerifiedPlatformTarGz {
    param([IO.MemoryStream]$Snapshot,$DestinationLease,[string]$Platform,$Session)
    [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
    $tarReaderType = [Type]::GetType('System.Formats.Tar.TarReader, System.Formats.Tar',$false)
    if ($null -eq $tarReaderType) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The runtime does not provide System.Formats.Tar for verified extraction.') }
    $gzip = [IO.Compression.GZipStream]::new($Snapshot,[IO.Compression.CompressionMode]::Decompress,$true)
    $reader = $null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $reader = [Activator]::CreateInstance($tarReaderType,@($gzip,$false))
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            $kind = $entry.EntryType.ToString()
            if ($kind -cnotin @('RegularFile','V7RegularFile','Directory')) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member '$($entry.Name)' has forbidden type '$kind'.")
            }
            # tar -C <root> . emits ./ and ./name. Strip only leading ./;
            # interior dot segments, traversal, and absolute paths remain errors.
            $name = [string]$entry.Name
            if ($name.StartsWith('./',[StringComparison]::Ordinal)) { $name = $name.Substring(2) }
            if ($kind -ceq 'Directory' -and ([string]$entry.Name -ceq '.' -or ($name -ceq '' -and ([string]$entry.Name).StartsWith('./',[StringComparison]::Ordinal)))) { continue }
            if ($kind -ceq 'Directory') { $name = $name.TrimEnd('/') }
            $relative = Assert-SafePlatformArchivePath $name $Platform
            if (-not $seen.Add($relative)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive has a duplicate member: '$($entry.Name)'.") }
            if ($kind -ceq 'Directory') { New-PlatformPreparationDirectory $DestinationLease $relative $Platform $Session; continue }
            if ($null -eq $entry.DataStream) {
                if ($entry.Length -ne 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member '$($entry.Name)' has no content stream for its nonzero length.") }
                $empty = [IO.MemoryStream]::new([byte[]]@(),$false)
                try { Write-PlatformPreparationFile $DestinationLease $relative $empty $Platform $Session }
                finally { $empty.Dispose() }
            } else { Write-PlatformPreparationFile $DestinationLease $relative $entry.DataStream $Platform $Session }
        }
    }
    finally { if ($null -ne $reader) { $reader.Dispose() }; $gzip.Dispose() }
}

function Get-PlatformPowerShellAsset {
    param($Policy,[string]$Platform,[string]$Architecture,$ReleaseMetadata)
    $root = Get-PlatformPreparationProperty $Policy 'powerShell'
    if ($null -eq $root) { $root = $Policy }
    $version = [string](Get-PlatformPreparationProperty $root 'version')
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $Architecture -cnotin @('x64','arm64')) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Policy version or host architecture is unsupported.')
    }
    $token = if ($Platform -ceq 'windows') { "win-$Architecture" } elseif ($Platform -ceq 'linux') { "linux-$Architecture" } else { "osx-$Architecture" }
    $expectedName = if ($Platform -ceq 'windows') { "PowerShell-$version-$token.zip" } else { "powershell-$version-$token.tar.gz" }
    $assetsValue = Get-PlatformPreparationProperty $root 'assets'
    $assets = @($assetsValue)
    if ($assetsValue -is [Collections.IDictionary]) {
        $keyedAsset = Get-PlatformPreparationProperty $assetsValue $token
        if ($null -eq $keyedAsset) { $keyedAsset = Get-PlatformPreparationProperty $assetsValue "$Platform-$Architecture" }
        if ($null -ne $keyedAsset) { $assets = @($keyedAsset) }
    }
    $matches = @($assets | Where-Object { [string](Get-PlatformPreparationProperty $_ 'name') -ceq $expectedName })
    if ($matches.Count -ne 1) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Policy must bind exactly one official asset '$expectedName'.") }
    $policyHash = [string](Get-PlatformPreparationProperty $matches[0] 'sha256')
    $metadataHash = $null
    if ($null -ne $ReleaseMetadata) {
        $metadataAssets = @(Get-PlatformPreparationProperty $ReleaseMetadata 'assets')
        $metadataMatches = @($metadataAssets | Where-Object { [string](Get-PlatformPreparationProperty $_ 'name') -ceq $expectedName })
        if ($metadataMatches.Count -ne 1) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Release metadata does not bind the selected asset exactly once.') }
        $metadataHash = [string](Get-PlatformPreparationProperty $metadataMatches[0] 'sha256')
        if ([string]::IsNullOrWhiteSpace($metadataHash)) {
            $digest = [string](Get-PlatformPreparationProperty $metadataMatches[0] 'digest')
            if ($digest -cmatch '^sha256:([a-f0-9]{64})$') { $metadataHash = [string]$Matches[1] }
        }
    }
    if ($policyHash -match '^[a-f0-9]{64}$' -and $metadataHash -match '^[a-f0-9]{64}$' -and $policyHash -cne $metadataHash) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Policy and release metadata hashes disagree.')
    }
    $hash = if ($policyHash -match '^[a-f0-9]{64}$') { $policyHash } else { $metadataHash }
    if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'No approved lowercase SHA-256 binds the selected asset.') }
    return [pscustomobject]@{ Version=$version; Name=$expectedName; Sha256=$hash }
}

function Test-PhysicalPlatformFile {
    param([string]$Path,[string]$Platform,[string]$Capability)
    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
        throw (New-PlatformPreparationFailure $Capability $Platform "A physical regular file is required: '$Path'.")
    }
    if ($Platform -cne 'windows') { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertRegularSourceFile($Path) }
    return $item
}

function Test-PlatformPowerShellIdentity {
    param([string]$ExecutablePath,[string]$ExpectedVersion,[string]$ExpectedPlatform,[string]$ExpectedArchitecture,$RuntimeClosure)
    [void](Test-PhysicalPlatformFile $ExecutablePath $ExpectedPlatform 'powershell-runtime')
    $probe = '$o=[ordered]@{version=$PSVersionTable.PSVersion.ToString();architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant();os=if($IsWindows){"windows"}elseif($IsLinux){"linux"}elseif($IsMacOS){"macos"}else{"unknown"}};$o|ConvertTo-Json -Compress'
    $output = Invoke-PlatformVerifiedProcess $ExecutablePath $RuntimeClosure $ExpectedPlatform $probe
    try { $identity = ([string]$output | ConvertFrom-Json -ErrorAction Stop) } catch { throw (New-PlatformPreparationFailure 'powershell-runtime' $ExpectedPlatform 'The selected pwsh returned invalid identity evidence.') }
    if ([string]$identity.version -cne $ExpectedVersion -or [string]$identity.os -cne $ExpectedPlatform -or [string]$identity.architecture -cne $ExpectedArchitecture) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $ExpectedPlatform 'The selected pwsh version, OS, or architecture does not match policy.')
    }
    return $identity
}

function Resolve-VerifiedPlatformPowerShell {
    param($Policy,$DestinationLease,$OfflineCache,$ReleaseMetadata,[string]$Platform)
    $session=New-PlatformPreparationSession
    try {
        $architecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        $asset = Get-PlatformPowerShellAsset $Policy $Platform $architecture $ReleaseMetadata
        $cachePath = if ($OfflineCache -is [string]) { $OfflineCache } else {
            $candidate = Get-PlatformPreparationProperty $OfflineCache 'archivePath'
            if ($null -eq $candidate) { $candidate = Get-PlatformPreparationProperty $OfflineCache 'path' }
            [string]$candidate
        }
        if ([string]::IsNullOrWhiteSpace($cachePath)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'An already-downloaded archive or offline cache path is required.') }
        $cachePath = [IO.Path]::GetFullPath($cachePath)
        if (Test-Path -LiteralPath $cachePath -PathType Container) { $cachePath = Join-Path $cachePath $asset.Name }
        [void](Test-PhysicalPlatformFile $cachePath $Platform 'powershell-runtime')
        if ([IO.Path]::GetFileName($cachePath) -cne $asset.Name) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The cache file name does not match the selected official asset.') }
        $snapshot = New-PlatformArchiveSnapshot $cachePath
        try {
            $actualHash = Get-PlatformArchiveSha256 $snapshot
            if ($actualHash -cne $asset.Sha256) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The archive SHA-256 does not match policy.') }
            $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
            if ($Platform -ceq 'windows') {
                $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($destination))
                [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            }
            if (@(Get-ChildItem -Force -LiteralPath $destination).Count -ne 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The destination lease directory must be empty.') }
            if ($Platform -ceq 'windows') { Expand-VerifiedPlatformZip $snapshot $DestinationLease $Platform $session } else { Expand-VerifiedPlatformTarGz $snapshot $DestinationLease $Platform $session }
        } finally { $snapshot.Dispose() }
        $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
        $executable = Join-Path $destination $(if ($Platform -ceq 'windows') { 'pwsh.exe' } else { 'pwsh' })
        if ($Platform -cne 'windows') {
            $lease = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($DestinationLease,'pwsh','Read','OpenExisting')
            try { [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::SetPermissions($lease,448) } finally { $lease.Dispose() }
        }
        # The trust baseline consists exclusively of hashes computed from member
        # bytes in the approved archive snapshot, NEVER the post-extraction disk.
        $runtimeClosure = New-PlatformExpectedClosure $destination $session.Files
        Assert-PlatformRuntimeClosure $executable $runtimeClosure $Platform
        [void](Test-PlatformPowerShellIdentity $executable $asset.Version $Platform $architecture $runtimeClosure)
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        $executableHash=[string](@($runtimeClosure.files | Where-Object path -CEQ ([IO.Path]::GetFileName($executable)))[0].sha256)
        return [pscustomobject][ordered]@{ apiVersion='1.0'; version=$asset.Version; assetName=$asset.Name; archiveSha256=$actualHash; executablePath=[IO.Path]::GetFullPath($executable); executableSha256=$executableHash; runtimeClosure=$runtimeClosure; protectionBoundary=(Get-PlatformProtectionBoundary $Platform); os=$Platform; architecture=$architecture }
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform $_.Exception.Message)
    }
    finally { Close-PlatformPreparationSession $session }
}

function Import-VerifiedPesterResolverModule {
    param([string]$ResolverPath,[string]$Platform)
    [void](Test-PhysicalPlatformFile $ResolverPath $Platform 'pester-module')
    # The resolver is already hash-bound by the bundle inventory. Take only the
    # validator definitions and their helpers, verbatim; never run its entrypoint
    # (even -ValidatePolicyOnly reads a repository-relative policy outside closure).
    $tokens = $null; $errors = $null
    $snapshot=New-PlatformArchiveSnapshot $ResolverPath
    try {
        $bytes=$snapshot.ToArray()
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Resolver has a forbidden UTF-8 BOM.' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).Replace("`r`n","`n")
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($hash -cne $script:PesterResolverSha256) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Resolver snapshot differs from its bundle inventory.') }
        $ast = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    } finally { $snapshot.Dispose() }
    if (@($errors).Count -ne 0) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The verified resolver could not be parsed.') }
    $required = @(
        'Get-FileSha256','Get-ResolverAsciiCaseFold','Assert-ResolverSafeRelativePath',
        'Get-ResolverSymlinkTarget','Get-ResolverSymlinkIdentitySha256','Get-ResolverSafeUnixSymlinkEntry',
        'Get-ResolverOrderedClosureEntries','Get-ResolverParallelFileHashes','Get-DirectoryClosureIdentity',
        'Get-ApprovedPesterPayloadSha256','Assert-ApprovedPesterManifest'
    )
    $definitions = foreach ($name in $required) {
        $matches = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw (New-PlatformPreparationFailure 'pester-module' $Platform "The verified resolver must define '$name' exactly once.") }
        $matches[0].Extent.Text
    }
    $body = "Set-StrictMode -Version Latest`n" + ($definitions -join "`n") + "`nExport-ModuleMember -Function Get-DirectoryClosureIdentity,Get-ApprovedPesterPayloadSha256,Assert-ApprovedPesterManifest"
    $module = New-Module -Name ('PlatformPesterResolver-' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($body))
    if ($null -eq $module -or @($module.ExportedCommands.Keys).Count -ne 3) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The verified resolver module did not expose the required Pester validators.') }
    return $module
}

function Open-WindowsPreparationDirectoryGuards {
    param($DestinationLease,[string]$RelativePath)
    $current = Get-VerifiedPlatformLeasePath $DestinationLease 'windows'
    $parts = if ($RelativePath.Length -eq 0) { @() } else { [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath) }
    $parentLease = $DestinationLease
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sddl = 'D:P(A;OICI;FA;;;' + $identity.User.Value + ')' } finally { $identity.Dispose() }
    $guards = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($part in $parts) {
            $next = Join-Path $current $part
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePrivateDirectory($next,$sddl)
            # Retain EVERY no-reparse, deny-write/delete guard. No descendant is
            # created or opened until its parent has been guarded. If an attacker
            # replaces the new directory before this open, validation rejects it.
            $parentLease = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationDirectory($parentLease,$part)
            $guards.Add($parentLease)
            $current = $next
        }
        return [pscustomobject]@{ Path=$current; Guards=$guards; Parent=$parentLease }
    } catch {
        for ($i=$guards.Count-1; $i -ge 0; $i--) { $guards[$i].Dispose() }
        throw
    }
}

function New-PlatformPreparationDirectory {
    param($DestinationLease,[string]$RelativePath,[string]$Platform,$Session)
    if ($Platform -cne 'windows') {
        [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::CreatePreparationDirectory($DestinationLease,$RelativePath)
    } else {
        $owned = Open-WindowsPreparationDirectoryGuards $DestinationLease $RelativePath
        try {
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            if ($null -ne $Session) { foreach($guard in $owned.Guards) { $Session.Guards.Add($guard) }; $owned.Guards.Clear() }
        }
        finally { for ($i=$owned.Guards.Count-1; $i -ge 0; $i--) { $owned.Guards[$i].Dispose() } }
    }
}

function Write-PlatformPreparationFile {
    param($DestinationLease,[string]$RelativePath,[IO.Stream]$Source,[string]$Platform,$Session)
    $owned=$null; $guard=$null; $buffer=[IO.MemoryStream]::new(); $snapshot=$null
    try {
        if ($Platform -ceq 'windows') {
            $parts = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath)
            $parent = if ($parts.Length -gt 1) { ($parts[0..($parts.Length-2)] -join [IO.Path]::DirectorySeparatorChar) } else { '' }
            $owned = Open-WindowsPreparationDirectoryGuards $DestinationLease $parent
        }
        # Hash input bytes in memory, before the destination can influence the
        # expected inventory. This also works for non-seekable tar entry streams.
        $Source.CopyTo($buffer)
        $snapshot=[IO.MemoryStream]::new($buffer.ToArray(),$false)
        $expected=Get-PlatformArchiveSha256 $snapshot
        if ($null -ne $Session) { $Session.Files.Add([pscustomobject]@{path=$RelativePath.Replace('\','/');sha256=$expected}) }
        if ($Platform -cne 'windows') {
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::WritePreparationFile($DestinationLease,$RelativePath,$snapshot)
        } else {
            $target = Join-Path $owned.Path $parts[$parts.Length-1]
            $output = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $snapshot.CopyTo($output) } finally { $output.Dispose() }
            # Read-only guards allow the loader's ordinary read sharing. The
            # writer-to-reader handoff is NOT trusted: acquire deny-write/delete,
            # then compare to the input hash. A racing writer either blocks the
            # guard or causes a mismatch. No disk bytes become a trust baseline.
            $guard=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($owned.Parent,$parts[$parts.Length-1],'Read','OpenExisting')
            if ((Get-PlatformSha256 $target) -cne $expected) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Written member differs from its source snapshot.') }
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            if ($null -ne $Session) {
                foreach($directoryGuard in $owned.Guards) { $Session.Guards.Add($directoryGuard) }; $owned.Guards.Clear()
                $Session.Guards.Add($guard); $guard=$null
            }
        }
    } finally {
        if ($null -ne $guard) { $guard.Dispose() }
        if ($null -ne $owned) { for ($i=$owned.Guards.Count-1; $i -ge 0; $i--) { $owned.Guards[$i].Dispose() } }
        if ($null -ne $snapshot) { $snapshot.Dispose() }; $buffer.Dispose()
    }
}

function New-PlatformPesterSnapshot {
    param([string]$SourceVersionRoot,[string]$VersionRelativePath,[string]$Destination,[string]$Platform)
    $sourceItem = Get-Item -Force -LiteralPath $SourceVersionRoot -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $sourceItem.LinkType) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester source must be a physical directory.') }
    $members=[Collections.Generic.List[object]]::new()
    $pending=[Collections.Generic.Queue[string]]::new(); $pending.Enqueue($sourceItem.FullName)
    try {
        while ($pending.Count -gt 0) {
            foreach ($item in @(Get-ChildItem -Force -LiteralPath $pending.Dequeue())) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { throw (New-PlatformPreparationFailure 'pester-module' $Platform "Pester payload contains a link: '$($item.FullName)'.") }
                if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
                [void](Test-PhysicalPlatformFile $item.FullName $Platform 'pester-module')
                $relative=($VersionRelativePath+'/'+$item.FullName.Substring($sourceItem.FullName.Length).TrimStart('\','/')).Replace('\','/')
                [void](Assert-SafePlatformArchivePath $relative $Platform)
                $stream=New-PlatformArchiveSnapshot $item.FullName
                try { $members.Add([pscustomobject]@{path=$relative;sha256=(Get-PlatformArchiveSha256 $stream);stream=$stream}) }
                catch { $stream.Dispose(); throw }
            }
        }
        return [pscustomobject]@{ Members=$members; Closure=(New-PlatformExpectedClosure $Destination $members) }
    } catch { foreach($member in $members) { $member.stream.Dispose() }; throw }
}

function Copy-PhysicalPesterPayload {
    param([string]$SourceVersionRoot,$DestinationLease,[string]$VersionRelativePath,[string]$Platform,$Snapshot,$Session)
    $destination=Get-VerifiedPlatformLeasePath $DestinationLease $Platform
    $ownsSnapshot=$null -eq $Snapshot
    if ($ownsSnapshot) { $Snapshot=New-PlatformPesterSnapshot $SourceVersionRoot $VersionRelativePath $destination $Platform }
    try {
        New-PlatformPreparationDirectory $DestinationLease $VersionRelativePath $Platform $Session
        foreach ($member in $Snapshot.Members) {
            $member.stream.Position=0
            Write-PlatformPreparationFile $DestinationLease $member.path $member.stream $Platform $Session
        }
    } finally { if ($ownsSnapshot) { foreach ($member in $Snapshot.Members) { $member.stream.Dispose() } } }
}

function Assert-PlatformPesterClosure {
    param([string]$Destination,$Expected,[string]$Platform)
    try {
        $actual=Get-PlatformRuntimeClosure $Destination $Platform
        if ($actual.sha256 -cne $Expected.sha256 -or $actual.files.Count -ne $Expected.files.Count) { throw 'Pester payload differs from its approved snapshot.' }
        for ($i=0; $i -lt $actual.files.Count; $i++) {
            if ($actual.files[$i].path -cne $Expected.files[$i].path -or $actual.files[$i].sha256 -cne $Expected.files[$i].sha256) { throw 'Pester payload inventory differs from its approved snapshot.' }
        }
    } catch { throw (New-PlatformPreparationFailure 'pester-module' $Platform ('Pester closure verification failed: '+$_.Exception.Message)) }
}

function Assert-PlatformPesterSnapshotInventory {
    param($Resolver,$Entries)
    # Apply the resolver's path and collision contract to in-memory entries.
    # Do not rescan a mutable tree to manufacture the approved baseline.
    & $Resolver {
        param($Entries)
        $nfcPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $casePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $Entries) {
            Assert-ResolverSafeRelativePath -Value ([string]$entry.path)
            $nfc=([string]$entry.path).Normalize([Text.NormalizationForm]::FormC)
            if (-not $nfcPaths.Add($nfc) -or -not $casePaths.Add((Get-ResolverAsciiCaseFold $nfc))) { throw 'Pester snapshot contains normalization/case-colliding paths.' }
        }
    } $Entries
}

# All launches use this boundary. Windows callers already hold preparation guards
# and this independently reacquires receipt guards for subsequent uses. On Unix,
# checking both closures immediately before launch detects changes, not a hostile
# same-UID writer in the final check-to-use interval (A1).
function Invoke-PlatformVerifiedProcess {
    param([string]$Executable,$RuntimeClosure,[string]$Platform,[string]$Probe,$PesterClosure)
    $guards=Open-PlatformClosureGuards $RuntimeClosure $Platform
    $moduleGuards=$null
    try {
        if ($null -ne $PesterClosure) {
            try { $moduleGuards=Open-PlatformClosureGuards $PesterClosure $Platform }
            catch { throw (New-PlatformPreparationFailure 'pester-module' $Platform ('Pester closure protection failed: '+$_.Exception.Message)) }
        }
        Assert-PlatformRuntimeClosure $Executable $RuntimeClosure $Platform
        if ($null -ne $PesterClosure) { Assert-PlatformPesterClosure $PesterClosure.rootPath $PesterClosure $Platform }
        $output=@(& $Executable -NoLogo -NoProfile -Command $Probe 2>&1)
        if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Verified runtime process failed.') }
        Assert-PlatformRuntimeClosure $Executable $RuntimeClosure $Platform
        if ($null -ne $PesterClosure) { Assert-PlatformPesterClosure $PesterClosure.rootPath $PesterClosure $Platform }
        return $output[0]
    } finally { Close-PlatformPreparationSession $moduleGuards; Close-PlatformPreparationSession $guards }
}

function Close-PlatformPesterSnapshot {
    param($Snapshot)
    if ($null -ne $Snapshot) {
        foreach ($member in $Snapshot.Members) { $member.stream.Dispose() }
    }
}

function Assert-RegressionPesterManifest {
    param([string]$Path)
    # The approved 4.10.1 payload uses ModuleToProcess (the legacy RootModule
    # alias). Keep this compatibility in P4; the formal resolver stays unchanged.
    $manifest = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $root = Get-PlatformPreparationProperty $manifest 'RootModule'
    $legacyRoot = Get-PlatformPreparationProperty $manifest 'ModuleToProcess'
    if ($null -ne $root -and $null -ne $legacyRoot -and [string]$root -cne [string]$legacyRoot) { throw 'Conflicting Pester root module declarations.' }
    if ($null -eq $root) { $root = $legacyRoot }
    if ([string](Get-PlatformPreparationProperty $manifest 'ModuleVersion') -cne '4.10.1' -or
        [string]$root -cne 'Pester.psm1' -or
        @((Get-PlatformPreparationProperty $manifest 'FunctionsToExport') | Where-Object { [string]$_ -ceq 'Invoke-Pester' }).Count -ne 1) {
        throw 'Regression Pester manifest does not bind Pester@4.10.1.'
    }
    foreach ($hook in @('ScriptsToProcess','NestedModules','RequiredModules','RequiredAssemblies')) {
        if ($manifest.Contains($hook) -and @($manifest[$hook]).Count -gt 0) { throw "Regression Pester manifest contains initialization hooks: $hook." }
    }
}

function Assert-PlatformPesterImportIdentity {
    param($Import,[string]$Version,[string]$ModuleBase,[string]$Platform)
    $comparison = if ($Platform -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $rootModule = Join-Path $ModuleBase 'Pester.psm1'
    if ([string]$Import.version -cne $Version -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Import.path),[IO.Path]::GetFullPath($rootModule),$comparison) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Import.moduleBase),[IO.Path]::GetFullPath($ModuleBase),$comparison)) {
        throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Imported Pester identity differs from the verified physical root module or module base.')
    }
}

function Initialize-VerifiedPlatformPester {
    param($Policy,$RuntimeReceipt,$DestinationLease,[string]$Platform,[string]$ResolverPath)
    $session=New-PlatformPreparationSession; $runtimeGuards=$null; $payloadSnapshot=$null
    try {
        if ([string]$RuntimeReceipt.os -cne $Platform -or [string]$RuntimeReceipt.architecture -cne [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime receipt does not match the current platform.') }
        if ([string]$RuntimeReceipt.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$RuntimeReceipt.executableSha256 -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime receipt lacks a verified version or executable identity.') }
        if ((Get-PlatformSha256 ([string]$RuntimeReceipt.executablePath)) -cne [string]$RuntimeReceipt.executableSha256) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime executable changed after its receipt was issued.') }
        $runtimeClosure = Get-PlatformPreparationProperty $RuntimeReceipt 'runtimeClosure'
        $runtimeGuards=Open-PlatformClosureGuards $runtimeClosure $Platform
        [void](Test-PlatformPowerShellIdentity ([string]$RuntimeReceipt.executablePath) ([string]$RuntimeReceipt.version) $Platform ([string]$RuntimeReceipt.architecture) $runtimeClosure)
        $purpose = [string](Get-PlatformPreparationProperty $Policy 'pesterPurpose')
        $modulePath = [string](Get-PlatformPreparationProperty $Policy 'pesterModulePath')
        if ($purpose -ceq 'formal-gate') {
            $tools = Get-PlatformPreparationProperty $Policy 'tools'; $pester = Get-PlatformPreparationProperty $tools 'pester'; $approved = Get-PlatformPreparationProperty $pester 'approvedPayload'
            if ([string](Get-PlatformPreparationProperty $pester 'source') -cne 'PowerShellGallery:Pester' -or [string](Get-PlatformPreparationProperty $pester 'channel') -cne 'latest-stable') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Formal-gate Pester must use the approved PowerShellGallery latest-stable policy lane.') }
        } elseif ($purpose -ceq 'regression') {
            $approved = Get-PlatformPreparationProperty $Policy 'approvedPayload'
        } else { throw (New-PlatformPreparationFailure 'pester-module' $Platform "Pester purpose must be exactly 'regression' or 'formal-gate'.") }
        $version = [string](Get-PlatformPreparationProperty $approved 'version'); $approvedHash = [string](Get-PlatformPreparationProperty $approved 'sha256')
        if ($purpose -ceq 'regression' -and $version -cne '4.10.1') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Regression Pester must be exactly 4.10.1.') }
        if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $approvedHash -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester policy lacks an approved immutable payload identity.') }
        $sourceManifest = [IO.Path]::GetFullPath($modulePath)
        [void](Test-PhysicalPlatformFile $sourceManifest $Platform 'pester-module')
        if ([IO.Path]::GetFileName($sourceManifest) -cne 'Pester.psd1' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($sourceManifest)) -cne $version) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester manifest path does not match the approved version layout.') }
        $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
        if ($Platform -ceq 'windows') {
            $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($destination))
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        }
        if (@(Get-ChildItem -Force -LiteralPath $destination).Count -ne 0) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The Pester destination lease directory must be empty.') }
        $targetVersionRoot = Join-Path (Join-Path $destination 'Pester') $version
        $targetManifest = Join-Path $targetVersionRoot 'Pester.psd1'
        $resolver = Import-VerifiedPesterResolverModule $ResolverPath $Platform
        try {
            $payloadCommand = $resolver.ExportedCommands['Get-ApprovedPesterPayloadSha256']; $manifestCommand = $resolver.ExportedCommands['Assert-ApprovedPesterManifest']
            $payloadSnapshot=New-PlatformPesterSnapshot ([IO.Path]::GetDirectoryName($sourceManifest)) "Pester/$version" $destination $Platform
            # Validate the captured member inventory against policy BEFORE copying.
            # Generated PSGetModuleInfo.xml remains excluded by the existing
            # resolver's approved-payload contract, but bound in the full receipt.
            $expectedPayload=$payloadSnapshot.Closure
            Assert-PlatformPesterSnapshotInventory $resolver $expectedPayload.files
            $closure=[pscustomobject]@{sha256=$expectedPayload.sha256;entries=$expectedPayload.files}
            $payloadHash = & $payloadCommand -Closure $closure -Version $version
            if ([string]$payloadHash -cne $approvedHash) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester payload identity is not approved for this lane.') }
            Copy-PhysicalPesterPayload ([IO.Path]::GetDirectoryName($sourceManifest)) $DestinationLease "Pester/$version" $Platform $payloadSnapshot $session
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            Assert-PlatformPesterClosure $destination $expectedPayload $Platform
            if ($purpose -ceq 'regression') { Assert-RegressionPesterManifest $targetManifest }
            else { & $manifestCommand -Path $targetManifest -Version $version }
            Assert-PlatformPesterClosure $destination $expectedPayload $Platform
        } finally { Remove-Module $resolver -Force -ErrorAction SilentlyContinue }
        $escaped = $targetManifest.Replace("'","''")
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        $probe = "`$WarningPreference='SilentlyContinue';`$ProgressPreference='SilentlyContinue';`$m=Import-Module -Name '$escaped' -Force -PassThru -ErrorAction Stop -WarningAction SilentlyContinue;if(@(`$m).Count-ne 1){throw 'count'};[pscustomobject]@{version=`$m.Version.ToString();path=[IO.Path]::GetFullPath(`$m.Path);moduleBase=[IO.Path]::GetFullPath(`$m.ModuleBase)}|ConvertTo-Json -Compress"
        $output = Invoke-PlatformVerifiedProcess ([string]$RuntimeReceipt.executablePath) $runtimeClosure $Platform $probe $expectedPayload
        $import = [string]$output | ConvertFrom-Json -ErrorAction Stop
        $targetRootModule = Join-Path $targetVersionRoot 'Pester.psm1'
        [void](Test-PhysicalPlatformFile $targetRootModule $Platform 'pester-module')
        Assert-PlatformPesterImportIdentity $import $version $targetVersionRoot $Platform
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        return [pscustomobject][ordered]@{ apiVersion='1.0'; purpose=$purpose; version=$version; modulePath=[IO.Path]::GetFullPath($targetManifest); approvedPayloadSha256=$payloadHash; dependencyClosureSha256=[string]$closure.sha256; moduleClosure=$expectedPayload; protectionBoundary=(Get-PlatformProtectionBoundary $Platform); runtimePath=[string]$RuntimeReceipt.executablePath; os=$Platform; architecture=[string]$RuntimeReceipt.architecture }
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-PlatformPreparationFailure 'pester-module' $Platform $_.Exception.Message)
    }
    finally { Close-PlatformPesterSnapshot $payloadSnapshot; Close-PlatformPreparationSession $session; Close-PlatformPreparationSession $runtimeGuards }
}

Export-ModuleMember -Function Resolve-VerifiedPlatformPowerShell,Initialize-VerifiedPlatformPester,Test-PlatformPowerShellIdentity
