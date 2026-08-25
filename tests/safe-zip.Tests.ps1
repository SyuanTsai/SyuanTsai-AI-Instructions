$script:SafeZipModule = Join-Path $PSScriptRoot '..\scripts\safe-zip.psm1'

function New-SafeZipFixture {
    param([Parameter(Mandatory = $true)][string] $ArchivePath)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream = [System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            $entry = $archive.CreateEntry('candidate-root/scripts/bootstrap.ps1')
            $writer = New-Object System.IO.StreamWriter($entry.Open(),(New-Object System.Text.UTF8Encoding($false)))
            try { $writer.Write("Write-Output 'verified'`n") }
            finally { $writer.Dispose() }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
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
}
