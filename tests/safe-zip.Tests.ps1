$script:SafeZipModule = Join-Path $PSScriptRoot '..\scripts\safe-zip.psm1'

function New-SafeZipFixture {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [string] $EntryName = 'candidate-root/scripts/bootstrap.ps1',
        [int] $ExternalAttributes
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream = [System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            $entry = $archive.CreateEntry($EntryName)
            $writer = New-Object System.IO.StreamWriter($entry.Open(),(New-Object System.Text.UTF8Encoding($false)))
            try { $writer.Write("Write-Output 'verified'`n") }
            finally { $writer.Dispose() }
            if ($PSBoundParameters.ContainsKey('ExternalAttributes')) { $entry.ExternalAttributes = $ExternalAttributes }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Set-SafeZipEntryNameByte {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $EntryName,
        [Parameter(Mandatory = $true)][char] $Marker,
        [Parameter(Mandatory = $true)][byte] $Replacement
    )

    $markerIndex = $EntryName.IndexOf($Marker)
    if ($markerIndex -lt 0 -or $EntryName.LastIndexOf($Marker) -ne $markerIndex) {
        throw 'Safe ZIP test entry must contain exactly one marker.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($ArchivePath)
    $needle = [System.Text.Encoding]::UTF8.GetBytes($EntryName)
    $markerBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Marker)
    if ($markerBytes.Length -ne 1) {
        throw 'Safe ZIP test marker must encode as exactly one UTF-8 byte.'
    }
    $markerByteIndex = [System.Text.Encoding]::UTF8.GetByteCount($EntryName.Substring(0, $markerIndex))
    $replacementCount = 0
    for ($offset = 0; $offset -le ($bytes.Length - $needle.Length); $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $needle.Length; $index++) {
            if ($bytes[$offset + $index] -ne $needle[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            $bytes[$offset + $markerByteIndex] = $Replacement
            $replacementCount++
            $offset += $needle.Length - 1
        }
    }
    if ($replacementCount -ne 2) {
        throw "Safe ZIP test expected two entry-name records; found $replacementCount."
    }
    [System.IO.File]::WriteAllBytes($ArchivePath, $bytes)
}

Describe 'safe ZIP extraction' {
    BeforeEach { Import-Module $script:SafeZipModule -Force }

    # Scenario: A caller opens an immutable archive snapshot, hashes it, rewinds it, and extracts from the same handle.
    # Purpose: Prevent a path replacement between archive verification and extraction from changing the executed bytes.
    It 'UnitT10_extracts_from_the_same_exclusively_open_stream_that_was_verified' {
        $archivePath = Join-Path $TestDrive 'candidate.zip'
        $destinationRoot = Join-Path $TestDrive 'expanded'
        New-SafeZipFixture -ArchivePath $archivePath
        New-Item -ItemType Directory -Path $destinationRoot | Out-Null
        $stream = [System.IO.File]::Open($archivePath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $verifiedHash = ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $stream.Position = 0

            $repositoryRoot = Expand-SafeZipRepository -ArchiveStream $stream -DestinationRoot $destinationRoot

            $verifiedHash | Should Match '^[0-9a-f]{64}$'
            (Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'scripts\bootstrap.ps1')).Trim() | Should Be "Write-Output 'verified'"
            $stream.CanRead | Should Be $true
        }
        finally { $stream.Dispose() }
    }

    # Scenario: An archive member uses a control byte inside an otherwise normal-looking path.
    # Purpose: Keep archive extraction paths compatible with the unambiguous content-inventory grammar.
    It 'UnitT11_rejects_control_characters_in_archive_paths' {
        foreach ($control in @([char]9, [char]10, [char]0x7f)) {
            $archivePath = Join-Path $TestDrive ("control-{0}.zip" -f [int]$control)
            $entryName = 'candidate-root/scripts/file~name.ps1'
            New-SafeZipFixture -ArchivePath $archivePath -EntryName $entryName
            Set-SafeZipEntryNameByte -ArchivePath $archivePath -EntryName $entryName -Marker '~' -Replacement ([byte][int]$control)
            $errorMessage = $null
            try {
                Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot (Join-Path $TestDrive ("expanded-{0}" -f [int]$control)) | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            $errorMessage | Should Match 'Unsafe ZIP entry path'
        }
    }

    # Scenario: ZIP metadata marks a non-directory member as a Unix FIFO.
    # Purpose: Only regular files and directories may enter a verified source inventory.
    It 'UnitT12_rejects_special_file_archive_entries' {
        $archivePath = Join-Path $TestDrive 'special-file.zip'
        New-SafeZipFixture -ArchivePath $archivePath -ExternalAttributes ([int](0x1000 -shl 16))
        $errorMessage = $null
        try {
            Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot (Join-Path $TestDrive 'special-expanded') | Out-Null
        }
        catch { $errorMessage = $_.Exception.Message }
        $errorMessage | Should Match 'special file entry'
    }
}
