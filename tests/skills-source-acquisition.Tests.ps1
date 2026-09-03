$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:AcquisitionModule = Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1'
$script:IsWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

Import-Module $script:AcquisitionModule -Force

function Assert-ThrowsMessage {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Pattern
    )

    $thrown = $false
    $message = $null
    try {
        & $Action
    }
    catch {
        $thrown = $true
        $message = $_.Exception.Message
    }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

function Get-TestFileSha256 {
    param([string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Compress-TestDirectory {
    param([string] $SourceRoot, [string] $ArchivePath)

    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression
    $resolvedSource = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($ArchivePath), [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $rootName = Split-Path -Leaf $resolvedSource
            foreach ($file in @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -Force -File | Sort-Object FullName)) {
                $relativePath = $file.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry = $archive.CreateEntry("$rootName/$relativePath", [System.IO.Compression.CompressionLevel]::Optimal)
                $input = [System.IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-TestSkillText {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [string] $Description = 'Test skill description.'
    )

    return "---`nname: $SkillId`ndescription: $Description`n---`n`n# $SkillId`n"
}

function New-TestSkillSourceArchive {
    param(
        [string] $Name,
        [string] $SkillId,
        [string] $SkillText
    )

    $sourceRoot = Join-Path $TestDrive "$Name-root"
    $archivePath = Join-Path $TestDrive "$Name.zip"
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

    $repositoryRoot = Join-Path $sourceRoot "$Name-repository"
    $skillRoot = Join-Path $repositoryRoot ".agents\skills\$SkillId"
    New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), $SkillText, (New-Object System.Text.UTF8Encoding($false)))
    $contentHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $archivePath
    return [pscustomobject]@{
        ArchivePath = $archivePath
        ContentHash = $contentHash
    }
}

function New-TestAcquisitionPlan {
    param(
        [string] $AlphaArchiveHash,
        [string] $BetaArchiveHash,
        [string] $AlphaContentHash,
        [string] $BetaContentHash
    )

    return [pscustomobject]@{
        Sources = @(
            [pscustomobject]@{ id='source-a'; archiveSha256=$AlphaArchiveHash; resolvedCommit=('a' * 40) },
            [pscustomobject]@{ id='source-b'; archiveSha256=$BetaArchiveHash; resolvedCommit=('b' * 40) }
        )
        Skills = @(
            [pscustomobject]@{ id='skill-a'; sourceId='source-a'; sourcePath='.agents/skills/skill-a'; contentSha256=$AlphaContentHash },
            [pscustomobject]@{ id='skill-b'; sourceId='source-b'; sourcePath='.agents/skills/skill-b'; contentSha256=$BetaContentHash }
        )
    }
}

Describe 'Skills source archive acquisition' {
    # Scenario: A case-sensitive source repository contains two distinct paths that differ only by letter casing.
    # Purpose: Keep deterministic Skill content hashes bound to each exact repository path on Linux and macOS.
    It 'UnitT05_tracks_inventory_paths_with_ordinal_case_sensitivity' {
        InModuleScope skills-source-acquisition {
            # Given
            $paths = New-SkillInventoryPathMap

            # When
            $paths.Add('.agents/skills/example/A.md', 'upper')
            $paths.Add('.agents/skills/example/a.md', 'lower')

            # Then
            $paths.Count | Should Be 2
            $paths['.agents/skills/example/A.md'] | Should Be 'upper'
            $paths['.agents/skills/example/a.md'] | Should Be 'lower'
        }
    }

    # Scenario: A selected Skill contains a hidden resource whose bytes change while all visible files remain unchanged.
    # Purpose: Bind hidden and dot-prefixed resources to contentSha256 so copied Skill content cannot bypass its lock.
    It 'UnitT07_includes_hidden_resources_in_the_skill_content_hash' {
        # Given
        $repositoryRoot = Join-Path $TestDrive 'hidden-resource-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents\skills\hidden-resource-skill'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Value 'skill definition' -Encoding UTF8
        $hiddenPath = Join-Path $skillRoot '.hidden-resource'
        Set-Content -LiteralPath $hiddenPath -Value 'first value' -Encoding UTF8
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $hiddenItem = Get-Item -LiteralPath $hiddenPath
            $hiddenItem.Attributes = $hiddenItem.Attributes -bor [System.IO.FileAttributes]::Hidden
        }

        # When
        $firstHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot
        Set-Content -LiteralPath $hiddenPath -Value 'second value' -Encoding UTF8 -Force
        $secondHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

        # Then
        $secondHash | Should Not Be $firstHash
    }

    # Scenario: Inventory path framing is fed a control character, colon, dot segment, or alternate casing.
    # Purpose: Reject non-portable and case-colliding paths before they can become ambiguous hash input.
    It 'UnitT08_rejects_nonportable_and_case_colliding_inventory_paths' {
        InModuleScope skills-source-acquisition {
            foreach ($invalidPath in @(
                '.agents/skills/example/a:b.txt',
                ".agents/skills/example/tab`tname.txt",
                ".agents/skills/example/line`nbreak.txt",
                '.agents/skills/./file.txt',
                '.agents/skills//file.txt'
            )) {
                $nfcPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
                $asciiFoldPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
                $targetCasings = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                { Assert-PortableSkillInventoryPath -RelativePath $invalidPath -NfcPaths $nfcPaths -AsciiFoldPaths $asciiFoldPaths -TargetPathCasings $targetCasings } | Should Throw
            }

            $nfcPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
            $asciiFoldPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
            $targetCasings = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Assert-PortableSkillInventoryPath -RelativePath '.agents/skills/example/A.txt' -NfcPaths $nfcPaths -AsciiFoldPaths $asciiFoldPaths -TargetPathCasings $targetCasings
            { Assert-PortableSkillInventoryPath -RelativePath '.agents/skills/example/a.txt' -NfcPaths $nfcPaths -AsciiFoldPaths $asciiFoldPaths -TargetPathCasings $targetCasings } | Should Throw
        }
    }

    # Scenario: A case-sensitive source tree contains two otherwise valid files whose paths collide on Windows.
    # Purpose: Make the exported inventory hasher enforce the same portable identity on every host.
    It 'UnitT09_rejects_case_insensitive_file_collisions_before_hashing' -Skip:$script:IsWindowsPlatform {
        $repositoryRoot = Join-Path $TestDrive 'case-collision-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents/skills/example'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillRoot 'A.txt'),'upper')
        [System.IO.File]::WriteAllText((Join-Path $skillRoot 'a.txt'),'lower')

        { Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot } | Should Throw
    }

    # Scenario: Linux can store canonically equivalent composed and decomposed Unicode names as distinct source paths.
    # Purpose: Enforce the Standard's NFC ordinal identity before hashing either ambiguous inventory.
    It 'UnitT09d_rejects_Unicode_NFC_path_collisions_before_hashing' -Skip:$script:IsWindowsPlatform {
        $repositoryRoot = Join-Path $TestDrive 'nfc-collision-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents/skills/example'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        $composed = [string]([char]0x00E9) + '.txt'
        $decomposed = 'e' + [string]([char]0x0301) + '.txt'
        [System.IO.File]::WriteAllText((Join-Path $skillRoot $composed),'composed')
        [System.IO.File]::WriteAllText((Join-Path $skillRoot $decomposed),'decomposed')

        { Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot } | Should Throw
    }

    # Scenario: Two distinct Unix directories differ only by root-path casing.
    # Purpose: Keep repository containment ordinal on case-sensitive hosts instead of hashing a sibling tree.
    It 'UnitT09e_rejects_a_case_variant_sibling_as_the_repository_skill_root' -Skip:$script:IsWindowsPlatform {
        $repositoryRoot = Join-Path $TestDrive 'repository-root'
        $outsideSkillRoot = Join-Path $TestDrive 'REPOSITORY-ROOT/skills/example'
        New-Item -ItemType Directory -Force -Path $repositoryRoot,$outsideSkillRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outsideSkillRoot 'SKILL.md'),'outside')

        { Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $outsideSkillRoot } | Should Throw
    }

    # Scenario: A selected Skill contains a symbolic link to content outside its repository snapshot.
    # Purpose: Refuse root or descendant reparse traversal before any inventory bytes are hashed.
    It 'UnitT09a_rejects_descendant_reparse_points_before_hashing' -Skip:$script:IsWindowsPlatform {
        $repositoryRoot = Join-Path $TestDrive 'reparse-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents/skills/example'
        $outside = Join-Path $TestDrive 'outside.txt'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),'regular')
        [System.IO.File]::WriteAllText($outside,'outside')
        New-Item -ItemType SymbolicLink -Path (Join-Path $skillRoot 'linked.txt') -Target $outside | Out-Null

        { Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot } | Should Throw
    }

    # Scenario: A Unix FIFO is placed where a selected Skill resource file is expected.
    # Purpose: Avoid blocking on or hashing non-regular filesystem objects.
    It 'UnitT09b_rejects_non_regular_files_before_hashing' -Skip:$script:IsWindowsPlatform {
        $mkfifo = Get-Command mkfifo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $mkfifo) { Set-TestInconclusive 'mkfifo is unavailable on this host.'; return }
        $repositoryRoot = Join-Path $TestDrive 'fifo-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents/skills/example'
        $fifoPath = Join-Path $skillRoot 'resource.pipe'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),'regular')
        & $mkfifo.Source $fifoPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not create FIFO test fixture.' }

        { Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot } | Should Throw
    }

    # Scenario: A valid Skill resource is intentionally read-only.
    # Purpose: Special-file detection must not require write access to regular source content.
    It 'UnitT09c_hashes_read_only_regular_files' {
        $repositoryRoot = Join-Path $TestDrive 'read-only-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents/skills/example'
        $readOnlyPath = Join-Path $skillRoot 'resource.txt'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),'regular')
        [System.IO.File]::WriteAllText($readOnlyPath,'read only')
        $readOnlyItem = Get-Item -Force -LiteralPath $readOnlyPath
        $readOnlyItem.Attributes = $readOnlyItem.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        try {
            (Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot) | Should Match '^[0-9a-f]{64}$'
        }
        finally {
            $readOnlyItem = Get-Item -Force -LiteralPath $readOnlyPath
            $readOnlyItem.Attributes = $readOnlyItem.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
    }

    # Scenario: Two required source archives and their selected Skills match every archive and content lock.
    # Purpose: Prove the normal multi-source staging path preserves independent provenance for each Skill.
    It 'UnitT10_stages_two_independent_selected_sources_and_validates_skill_content_locks' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash

        $result = Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging')

        @($result.Sources).Count | Should Be 2
        @($result.Skills).Count | Should Be 2
        @($result.Skills)[0].contentSha256 | Should Be $alpha.ContentHash
        @($result.Skills)[1].contentSha256 | Should Be $beta.ContentHash
    }

    # Scenario: A required source archive's bytes do not match its locked archiveSha256.
    # Purpose: Stop before extraction so unpinned source content cannot reach composition.
    It 'UnitT20_rejects_an_archive_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash ('0' * 64) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'archive SHA-256 mismatch'
    }

    # Scenario: The archive path could be replaced after verification but before a second path-based extraction open.
    # Purpose: Bind extraction to the exact same exclusively opened bytes that produced archiveSha256.
    It 'UnitT21_hashes_rewinds_and_extracts_each_source_archive_through_one_stream' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AcquisitionModule,[ref]$tokens,[ref]$errors)
        @($errors).Count | Should Be 0
        $function = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Expand-ValidatedSkillsSourceArchives'
        },$true))[0]
        $source = $function.Extent.Text

        $source | Should Match '\[System\.IO\.FileShare\]::None'
        $source | Should Match 'Get-ArchiveSha256\s+-Stream\s+\$archiveStream'
        $source | Should Match '\$archiveStream\.Position\s*=\s*0'
        $source | Should Match 'Expand-SafeZipRepository\s+-ArchiveStream\s+\$archiveStream'
        $source | Should Not Match 'Expand-SafeZipRepository\s+-ArchivePath\s+\$archivePath'
    }

    # Scenario: A ZIP entry uses a lowercase Windows reserved device name with a file extension.
    # Purpose: Reject device aliases in every casing before extraction on Windows or another operating system.
    It 'UnitT24_rejects_lowercase_Windows_device_names' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'lowercase-device-name.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entry = $archive.CreateEntry('repository/nul.txt')
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write('must not extract') } finally { $writer.Dispose() }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'device-staging')
        } 'Windows device name'
    }

    # Scenario: A hash-pinned source archive contains an entry that traverses above its assigned staging directory.
    # Purpose: Verify archive extraction fails closed without writing attacker-controlled content outside the source boundary.
    It 'UnitT25_rejects_archive_path_traversal_without_staging_escape' {
        # Given
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'traversal.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new(
                $archiveStream,
                [System.IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                $entry = $archive.CreateEntry('../escaped.txt')
                $writer = [System.IO.StreamWriter]::new($entry.Open())
                try {
                    $writer.Write('must not escape')
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $archiveStream.Dispose()
        }
        $workingRoot = Join-Path $TestDrive 'traversal-staging'
        $escapedPath = Join-Path $workingRoot 'escaped.txt'
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{
                id = 'source-a'
                archiveSha256 = Get-TestFileSha256 -Path $archivePath
                resolvedCommit = ('a' * 40)
            })
            Skills = @()
        }

        # When / Then
        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a' = $archivePath } `
                -WorkingRoot $workingRoot
        } '.'
        Test-Path -LiteralPath $escapedPath | Should Be $false
    }

    # Scenario: A ZIP contains two names that collide on a case-insensitive target filesystem.
    # Purpose: Reject ambiguous archives before extraction on every supported operating system.
    It 'UnitT26_rejects_case_insensitive_archive_path_collisions' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'case-collision.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('repository/File.txt','repository/file.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'case-staging')
        } 'case-insensitive path collision'
    }

    # Scenario: ZIP file paths differ only in the casing of an implicit parent directory.
    # Purpose: Prevent two logical trees from merging on a case-insensitive target filesystem.
    It 'UnitT27_rejects_case_insensitive_parent_directory_collisions' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'parent-case-collision.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('repository/Folder/first.txt','repository/folder/second.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'parent-case-staging')
        } 'case-insensitive path collision'
    }

    # Scenario: A valid ZIP lists a file before the explicit directory entries for its parent paths.
    # Purpose: Distinguish a directory implied by descendants from a duplicate explicit archive entry.
    It 'UnitT27_accepts_explicit_directory_entries_after_their_files' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'file-before-directory.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $fileEntry = $archive.CreateEntry('repository/content/child.txt')
                $writer = New-Object System.IO.StreamWriter($fileEntry.Open())
                try { $writer.Write('valid content') } finally { $writer.Dispose() }
                $null = $archive.CreateEntry('repository/content/')
                $null = $archive.CreateEntry('repository/')
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        $result = Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{'source-a'=$archivePath} `
            -WorkingRoot (Join-Path $TestDrive 'file-before-directory-staging')

        $extractedSource = @($result.Sources)[0]
        Test-Path -LiteralPath (Join-Path ([string]$extractedSource.rootPath) 'content/child.txt') -PathType Leaf | Should Be $true
    }

    # Scenario: A ZIP first implies a directory through a child and later declares that same path as a file.
    # Purpose: Keep file/directory collisions rejected while allowing a later explicit directory entry.
    It 'UnitT27_rejects_a_file_that_reuses_an_implied_directory_path' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'file-directory-collision.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('repository/content/child.txt','repository/content')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{'source-a'=$archivePath} `
                -WorkingRoot (Join-Path $TestDrive 'file-directory-collision-staging')
        } 'file/directory path collision'
    }

    # Scenario: A ZIP contains a symbolic-link entry under its repository root.
    # Purpose: Prevent link traversal and reparse-point behavior from escaping staged source boundaries.
    It 'UnitT28_rejects_symbolic_link_archive_entries' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'symbolic-link.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entry = $archive.CreateEntry('repository/link')
                $entry.ExternalAttributes = -1610612736
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write('../outside') } finally { $writer.Dispose() }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'link-staging')
        } 'symbolic link'
    }

    # Scenario: A ZIP contains more than one top-level repository root.
    # Purpose: Make archive root selection deterministic instead of silently choosing one tree.
    It 'UnitT29_rejects_archives_with_multiple_repository_roots' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'multiple-roots.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('first/a.txt','second/b.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'roots-staging')
        } 'exactly one repository root'
    }

    # Scenario: The routing plan requires two sources but only one archive input is available.
    # Purpose: Reject incomplete acquisition instead of composing a partial desired set.
    It 'UnitT30_rejects_a_missing_selected_source_archive' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'has no archive input'
    }

    # Scenario: A caller bypasses routing validation and supplies a selected Skill path containing parent traversal.
    # Purpose: Preserve defense in depth at the archive-to-filesystem boundary.
    It 'UnitT35_rejects_an_unsafe_selected_skill_path_during_acquisition' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        $plan.Skills[0].sourcePath = '../skill-a'

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } `
                -WorkingRoot (Join-Path $TestDrive 'unsafe-path-staging')
        } 'Unsafe source path'
    }

    # Scenario: A validated source archive does not contain the selected Skill directory at its locked path.
    # Purpose: Prevent a source routing mismatch from being treated as a successful acquisition.
    It 'UnitT40_rejects_a_missing_skill_in_a_selected_source' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'different-skill' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'is missing from source'
    }

    # Scenario: The selected Skill directory exists in its source archive but does not contain SKILL.md.
    # Purpose: Reject an incomplete Skill definition before calculating content provenance or composing output.
    It 'UnitT45_rejects_a_selected_skill_directory_without_SKILL_md' {
        $sourceRoot = Join-Path $TestDrive 'missing-definition-root'
        $repositoryRoot = Join-Path $sourceRoot 'missing-definition-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents\skills\skill-a'
        $archivePath = Join-Path $TestDrive 'missing-definition.zip'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $skillRoot 'README.md') -Value 'No SKILL.md is present.' -Encoding UTF8
        Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{
                id = 'source-a'
                archiveSha256 = Get-TestFileSha256 -Path $archivePath
                resolvedCommit = ('a' * 40)
            })
            Skills = @([pscustomobject]@{
                id = 'skill-a'
                sourceId = 'source-a'
                sourcePath = '.agents/skills/skill-a'
                contentSha256 = ('0' * 64)
            })
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a' = $archivePath } `
                -WorkingRoot (Join-Path $TestDrive 'missing-definition-staging')
        } 'is missing SKILL.md'
    }

    # Scenario: A selected Skill exists but its deterministic inventory differs from contentSha256.
    # Purpose: Bind every copied Skill file to the immutable Lock before composition.
    It 'UnitT50_rejects_a_skill_content_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'content SHA-256 mismatch'
    }

    # Scenario: A selected Skill definition contains Markdown without YAML frontmatter.
    # Purpose: Reject structurally invalid Agent Skills before they enter the composed source.
    It 'UnitT60_rejects_SKILL_md_without_frontmatter' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'must start with YAML frontmatter'
    }

    # Scenario: SKILL.md declares a valid name that differs from the selected stable Skill ID.
    # Purpose: Keep the directory, Catalog, Lock, and Skill definition identity aligned.
    It 'UnitT70_rejects_SKILL_md_name_that_does_not_match_stable_id' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'does not match its stable Skill ID'
    }

    # Scenario: SKILL.md frontmatter declares a name but omits its required description.
    # Purpose: Enforce the minimum cross-platform Agent Skill discovery contract.
    It 'UnitT80_rejects_SKILL_md_without_description' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`n---`n`n# skill-a`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing description'
    }

    # Scenario: SKILL.md frontmatter declares a description but omits its required name.
    # Purpose: Reject a Skill whose stable identity cannot be verified.
    It 'UnitT90_rejects_SKILL_md_without_name' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`ndescription: Test skill.`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing name'
    }

    # Scenario: A required frontmatter scalar starts an unterminated YAML flow collection.
    # Purpose: Fail closed on malformed YAML instead of accepting a misleading description value.
    It 'UnitT95_rejects_a_malformed_YAML_scalar' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`ndescription: [unterminated`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'malformed YAML flow-sequence syntax'
    }

    # Scenario: Required or optional string fields use plain scalars that a YAML parser resolves to non-string types.
    # Purpose: Prevent lexical extraction from coercing booleans, nulls, numbers, or timestamps into accepted strings.
    It 'UnitT95a_rejects_implicitly_typed_YAML_scalars_for_name_description_and_metadata' {
        $cases = @(
            [pscustomobject]@{ Expected='123'; Text="---`nname: 123`ndescription: Test skill.`n---`n# 123`n" },
            [pscustomobject]@{ Expected='skill-a'; Text="---`nname: skill-a`ndescription: true`n---`n# skill-a`n" },
            [pscustomobject]@{ Expected='skill-a'; Text="---`nname: skill-a`ndescription: 2026-09-02`n---`n# skill-a`n" },
            [pscustomobject]@{ Expected='skill-a'; Text="---`nname: skill-a`ndescription: Test skill.`nmetadata: {owner: null}`n---`n# skill-a`n" },
            [pscustomobject]@{ Expected='skill-a'; Text="---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: 42`n---`n# skill-a`n" }
        )
        $index = 0
        foreach ($case in $cases) {
            $definition = Join-Path $TestDrive "implicit-scalar-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,[string]$case.Text)
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId ([string]$case.Expected) } | Should Throw
            $index++
        }
    }

    # Scenario: Values resembling implicit YAML types are explicitly quoted strings.
    # Purpose: Preserve valid string metadata while rejecting only the ambiguous plain-scalar form.
    It 'UnitT95b_accepts_quoted_strings_that_resemble_YAML_implicit_types' {
        $definition = Join-Path $TestDrive 'quoted-implicit-scalar-SKILL.md'
        [System.IO.File]::WriteAllText($definition,"---`nname: '123'`ndescription: 'true'`nmetadata: {owner: '2026-09-02', priority: '42'}`n---`n# 123`n")

        { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId '123' } | Should Not Throw
    }

    # Scenario: Required string fields attempt to use YAML aliases, anchors, or custom tags.
    # Purpose: Keep active YAML composition features outside the acquisition adapter's lexical subset.
    It 'UnitT95c_rejects_YAML_aliases_anchors_and_tags_in_required_fields' {
        $definitions = @(
            "---`nname: *shared`ndescription: Test skill.`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: &shared Test skill.`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: !custom Test skill.`n---`n# skill-a`n"
        )
        $index = 0
        foreach ($text in $definitions) {
            $definition = Join-Path $TestDrive "active-required-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,$text)
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
            $index++
        }
    }

    # Scenario: Quoted frontmatter contains malformed inner quotes or escapes that the lexical adapter cannot decode.
    # Purpose: Accept only a fully validated JSON-compatible double-quoted subset and YAML-doubled single quotes.
    It 'UnitT95d_rejects_invalid_quoted_scalar_syntax_and_decodes_the_supported_subset' {
        $invalidDefinitions = @(
            "---`nname: skill-a`ndescription: `"a`"b`"`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: 'a'b'`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: `"\x41`"`n---`n# skill-a`n"
        )
        $index = 0
        foreach ($text in $invalidDefinitions) {
            $definition = Join-Path $TestDrive "invalid-quoted-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,$text)
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
            $index++
        }

        $validDefinition = Join-Path $TestDrive 'valid-quoted-subset-SKILL.md'
        [System.IO.File]::WriteAllText($validDefinition,"---`nname: `"skill\u002da`"`ndescription: 'It''s valid'`n---`n# skill-a`n")
        { Assert-SkillDefinition -SkillDefinitionPath $validDefinition -ExpectedSkillId 'skill-a' } | Should Not Throw
    }

    # Scenario: A plain scalar begins with YAML flow, directive, reserved, or block-indicator syntax.
    # Purpose: Fail closed on malformed YAML while continuing to accept ordinary textual plain strings.
    It 'UnitT95e_rejects_reserved_plain_scalar_indicators_without_rejecting_normal_text' {
        $invalidValues = @('%bad','@bad',([string][char]0x60 + 'bad'),',bad','? bad','- bad',']bad','}bad')
        $index = 0
        foreach ($value in $invalidValues) {
            $definition = Join-Path $TestDrive "reserved-indicator-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,"---`nname: skill-a`ndescription: $value`n---`n# skill-a`n")
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
            $index++
        }

        $validDefinition = Join-Path $TestDrive 'normal-plain-text-SKILL.md'
        [System.IO.File]::WriteAllText($validDefinition,"---`nname: skill-a`ndescription: Text with @mention, comma, ?question, and -dash.`n---`n# skill-a`n")
        { Assert-SkillDefinition -SkillDefinitionPath $validDefinition -ExpectedSkillId 'skill-a' } | Should Not Throw
    }

    # Scenario: A Skill adds an unrecognized top-level frontmatter property.
    # Purpose: Keep the acquisition adapter fail closed instead of silently accepting schema expansion.
    It 'UnitT96_rejects_an_unknown_frontmatter_key' {
        $alphaText = "---`nname: skill-a`ndescription: Test skill.`nunknown: value`n---`n# skill-a`n"
        $alpha = New-TestSkillSourceArchive -Name 'unknown-key' -SkillId 'skill-a' -SkillText $alphaText
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'unknown-key-staging') } 'unsupported top-level key'
    }

    # Scenario: A conformant Skill supplies a bounded string-to-string metadata flow mapping.
    # Purpose: Preserve interoperable optional metadata while validating its complete shape.
    It 'UnitT97_accepts_supported_metadata_mapping' {
        $alphaText = "---`nname: skill-a`ndescription: Test skill.`nmetadata: {owner: example}`n---`n# skill-a`n"
        $alpha = New-TestSkillSourceArchive -Name 'metadata' -SkillId 'skill-a' -SkillText $alphaText
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        $result = Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'metadata-staging')
        @($result.Skills).Count | Should Be 2
    }

    # Scenario: Metadata attempts to introduce a nested structure outside the bounded adapter.
    # Purpose: Fail closed on mapping semantics the acquisition layer cannot validate safely.
    It 'UnitT97a_rejects_nested_metadata' {
        $definition = Join-Path $TestDrive 'nested-metadata-SKILL.md'
        [System.IO.File]::WriteAllText($definition,"---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner:`n    nested: value`n---`n# skill-a`n")

        { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
    }

    # Scenario: Metadata uses duplicate keys or YAML composition features that can change the apparent mapping.
    # Purpose: Keep the bounded metadata adapter deterministic and independent of aliases, tags, and merges.
    It 'UnitT97b_rejects_duplicate_keys_aliases_tags_and_merge_keys' {
        $definitions = @(
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: first`n  owner: second`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: *shared`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: &shared team`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: !custom team`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  <<: *shared`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata: {owner: first, owner: second}`n---`n# skill-a`n"
        )
        $index = 0
        foreach ($text in $definitions) {
            $definition = Join-Path $TestDrive "active-metadata-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,$text)
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
            $index++
        }
    }

    # Scenario: Metadata contains a raw control character in a scalar value.
    # Purpose: Reject non-portable strings that can corrupt line-oriented manifests or diagnostics.
    It 'UnitT97c_rejects_metadata_control_characters' {
        $definitions = @(
            "---`nname: skill-a`ndescription: Test skill.`nmetadata:`n  owner: team$([char]0)`n---`n# skill-a`n",
            "---`nname: skill-a`ndescription: Test skill.`nmetadata: {owner: `"\u0000`"}`n---`n# skill-a`n"
        )
        $index = 0
        foreach ($text in $definitions) {
            $definition = Join-Path $TestDrive "control-metadata-$index-SKILL.md"
            [System.IO.File]::WriteAllText($definition,$text)
            { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
            $index++
        }
    }

    # Scenario: Quoted metadata values contain flow delimiters that must remain inside one scalar.
    # Purpose: Prove commas and colons inside quotes cannot be reinterpreted as injected mapping entries.
    It 'UnitT97d_parses_quoted_flow_delimiters_without_mapping_injection' {
        $definition = Join-Path $TestDrive 'quoted-flow-metadata-SKILL.md'
        [System.IO.File]::WriteAllText($definition,"---`nname: skill-a`ndescription: Test skill.`nmetadata: {owner: 'team,example:primary', tier: stable}`n---`n# skill-a`n")

        { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Not Throw

        foreach ($invalidFlow in @('{owner: value}}','{owner: value], tier: stable}')) {
            $invalidDefinition = Join-Path $TestDrive (([Guid]::NewGuid().ToString('N')) + '-invalid-flow-SKILL.md')
            [System.IO.File]::WriteAllText($invalidDefinition,"---`nname: skill-a`ndescription: Test skill.`nmetadata: $invalidFlow`n---`n# skill-a`n")
            { Assert-SkillDefinition -SkillDefinitionPath $invalidDefinition -ExpectedSkillId 'skill-a' } | Should Throw
        }
    }

    # Scenario: A Skill description exceeds the portable Agent Skills limit.
    # Purpose: Reject oversized routing metadata before composition.
    It 'UnitT98_rejects_a_description_longer_than_1024_characters' {
        $alphaText = "---`nname: skill-a`ndescription: $('x' * 1025)`n---`n# skill-a`n"
        $alpha = New-TestSkillSourceArchive -Name 'long-description' -SkillId 'skill-a' -SkillText $alphaText
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'long-description-staging') } 'must not exceed 1024'
    }

    # Scenario: A description includes angle-bracket placeholder syntax rejected by the frozen provider baseline.
    # Purpose: Keep runtime acquisition aligned with the portable routing metadata contract.
    It 'UnitT98a_rejects_angle_brackets_in_description' {
        $definition = Join-Path $TestDrive 'angle-description-SKILL.md'
        [System.IO.File]::WriteAllText($definition,"---`nname: skill-a`ndescription: Configure <target>.`n---`n# skill-a`n")

        { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Throw
    }

    # Scenario: A syntactically valid frontmatter block has no instruction body.
    # Purpose: Prevent metadata-only packages from being installed as usable Agent Skills.
    It 'UnitT99_rejects_an_empty_skill_body' {
        $alphaText = "---`nname: skill-a`ndescription: Test skill.`n---`n"
        $alpha = New-TestSkillSourceArchive -Name 'empty-body' -SkillId 'skill-a' -SkillText $alphaText
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'empty-body-staging') } 'body must not be empty'
    }

    # Scenario: Optional scalar fields from the explicit allowlist accompany valid required metadata and body.
    # Purpose: Prove frontmatter hardening does not reject supported license or allowed-tools fields.
    It 'UnitT99a_accepts_supported_optional_scalar_frontmatter_fields' {
        $definition = Join-Path $TestDrive 'supported-frontmatter-SKILL.md'
        [System.IO.File]::WriteAllText($definition,"---`nname: skill-a`ndescription: Test skill.`nlicense: MIT`nallowed-tools: Read Bash`n---`n# skill-a`n")

        { Assert-SkillDefinition -SkillDefinitionPath $definition -ExpectedSkillId 'skill-a' } | Should Not Throw
    }
}
