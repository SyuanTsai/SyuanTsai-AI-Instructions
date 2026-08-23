$script:BootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions.ps1'
$script:ManifestPath = '.codex\ai-instructions.manifest.json'
$script:TestRepositoryUrl = 'git@example.com:team/bootstrap-test.git'

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function New-TestSource {
    param([Parameter(Mandatory = $true)][string] $Path)

    New-Item -ItemType Directory -Force -Path (Join-Path $Path '.codex\AI-Rules') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path '.github\AI-Rules') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path '.agents\skills') | Out-Null

    Set-TestText -Path (Join-Path $Path '.codex\AGENTS.en.md') -Value '# Codex English Base'
    Set-TestText -Path (Join-Path $Path '.codex\AI-Rules\Testing.en.md') -Value '# Codex English Testing'
    Set-TestText -Path (Join-Path $Path '.github\copilot-instructions.en.md') -Value '# Copilot English Base'
    Set-TestText -Path (Join-Path $Path '.github\AI-Rules\Testing.en.md') -Value '# Copilot English Testing'
    Set-TestText -Path (Join-Path $Path '.agents\skills\.gitkeep') -Value '# Keep the shared skills directory'
}

function Set-TestText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, "$Value`n", $utf8WithoutBom)
}

function Compress-TestSource {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceRoot,

        [Parameter(Mandatory = $true)]
        [string] $ArchivePath
    )

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

function New-TestProvenance {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $skillIds = @(
            $archive.Entries |
                ForEach-Object {
                    if ($_.FullName -cmatch '^[^/]+/\.agents/skills/([^/]+)/SKILL\.md$') { $Matches[1] }
                } |
                Sort-Object -Unique
        )
    }
    finally { $archive.Dispose() }

    $skillSources = @(
        foreach ($skillId in $skillIds) {
            [ordered]@{
                id = $skillId
                sourceId = 'test-skills'
                sourceRepository = 'https://example.com/test-skills.git'
                sourceRef = 'main'
                sourceCommit = ('b' * 40)
                sourceVersion = 'test@bbbbbbbb'
            }
        }
    )
    $provenance = [ordered]@{
        schemaVersion = 1
        catalogId = 'test-catalog'
        lockSha256 = ('a' * 64)
        instruction = [ordered]@{
            sourceId = 'ai-instructions'
            sourceRepository = 'https://example.com/ai-instructions.git'
            sourceRef = ('c' * 40)
            sourceCommit = ('c' * 40)
            sourceVersion = 'test@cccccccc'
        }
        skills = $skillSources
    }
    $json = ($provenance | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string[]] $ExcludedRepositoryUrls = @(),

        [string[]] $ExcludedRepositoryPaths = @()
    )

    $configuration = [ordered]@{
        schemaVersion = 3
        excludedRepositoryUrls = @($ExcludedRepositoryUrls)
        excludedRepositoryPaths = @($ExcludedRepositoryPaths)
    }
    $configurationJson = ($configuration | ConvertTo-Json -Depth 3).Replace("`r`n", "`n") + "`n"
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $configurationJson, $utf8WithoutBom)
}

function New-TestRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $OriginUrl = $script:TestRepositoryUrl
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('init', '--quiet') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.name', 'Bootstrap Test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.email', 'bootstrap@example.test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'core.autocrlf', 'true') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('remote', 'add', 'origin', $OriginUrl) | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value '# Test Repository'
    Invoke-TestGit -Repository $Path -Arguments @('add', '--', 'README.md') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('commit', '--quiet', '-m', 'initial commit') | Out-Null
}

function Invoke-BootstrapScript {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceArchivePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetRoot,

        [string] $ConfigurationPath = $script:TestConfigurationPath,

        [string] $WorkingDirectory,

        [switch] $UseCurrentRepositoryRoot
    )

    New-TestProvenance -ArchivePath $SourceArchivePath -Path $script:TestProvenancePath
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:BootstrapScript,
        '-SourceArchivePath', $SourceArchivePath,
        '-ConfigurationPath', $ConfigurationPath,
        '-ProvenancePath', $script:TestProvenancePath
    )

    if (-not $UseCurrentRepositoryRoot) {
        $arguments += @('-TargetRoot', $TargetRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        Push-Location -LiteralPath $WorkingDirectory
    }
    try {
        $output = & powershell.exe @arguments 2>&1
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Pop-Location
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap script failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

Describe 'bootstrap-ai-instructions' {
    BeforeEach {
        $archiveRoot = Join-Path $TestDrive 'archive'
        $sourceRoot = Join-Path $archiveRoot 'SyuanTsai-AI-Instructions-main'
        $sourceArchive = Join-Path $TestDrive 'source.zip'
        $targetRoot = Join-Path $TestDrive 'target'
        $configurationPath = Join-Path $TestDrive 'sync-config.json'
        $provenancePath = Join-Path $TestDrive 'provenance.json'
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $archiveRoot, $sourceArchive, $targetRoot, $configurationPath, $provenancePath
        New-TestSource -Path $sourceRoot
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $configurationPath
        $script:TestConfigurationPath = $configurationPath
        $script:TestProvenancePath = $provenancePath
        New-TestProvenance -ArchivePath $sourceArchive -Path $provenancePath
    }

    # Scenario: A clean product repository receives both instruction families for the first time.
    # Purpose: Materialize the complete local ignored model without changing product history or status.
    It 'InterT05_creates_both_English_instruction_families_without_changing_HEAD_or_status' {
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing'
        (Get-Content -Raw (Join-Path $targetRoot '.github\copilot-instructions.md')).Trim() | Should Be '# Copilot English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.github\AI-Rules\Testing.en.md')).Trim() | Should Be '# Copilot English Testing'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true

        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $manifest.schemaVersion | Should Be 2
        $manifest.catalogId | Should Be 'test-catalog'
        $manifest.lockSha256 | Should Be ('a' * 64)
        $manifest.files.Count | Should Be 4

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join '') | Should BeNullOrEmpty
        $exclude = Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.git\info\exclude')
        $exclude | Should Match '# BEGIN Codex AI Instructions managed paths'
        $exclude | Should Match '(?m)^/AGENTS\.md$'
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash','list','--format=%gs') | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
        Test-Path -LiteralPath (Join-Path $targetRoot '.agents\skills\.gitkeep') | Should Be $false
    }

    # Scenario: A repository already ignores broad personal Agent directories and contains an unrelated ignored file.
    # Purpose: Add only exact managed exclusions while preserving project ignore policy and personal content.
    It 'InterT10_preserves_project_ignore_rules_and_unrelated_ignored_files' {
        Set-TestText -Path (Join-Path $targetRoot '.gitignore') -Value ".agents/`n.codex/`n.github/`n/AGENTS.md"
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot '.codex\personal-settings.json') -Value '{ "personal": true }'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.gitignore') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'ignore personal agent files') | Out-Null

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('log','-1','--pretty=%s')) | Should Be 'ignore personal agent files'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.gitignore')) | Should Match '(?m)^\.agents/$'
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\personal-settings.json') | Should Be $true
    }

    # Scenario: The shared Git exclude file contains an incomplete managed marker block.
    # Purpose: Fail closed and roll back target materialization instead of appending a second ambiguous block.
    It 'InterT12_rejects_a_malformed_managed_exclude_block' {
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        Set-TestText -Path $excludePath -Value "# user rule`n# BEGIN Codex AI Instructions managed paths`n/old-agent.md"
        $excludeBefore = Get-Content -Raw -LiteralPath $excludePath

        try { Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot | Out-Null; $errorMessage = $null }
        catch { $errorMessage = $_.Exception.Message }

        $errorMessage | Should Match 'managed exclude block.*malformed'
        (Get-Content -Raw -LiteralPath $excludePath) | Should Be $excludeBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: The canonical Instructions origin is incomplete and therefore no longer has both source-shape marker files.
    # Purpose: Refuse source-repository fan-out by canonical identity before any personal artifact is materialized.
    It 'InterT13_skips_the_canonical_source_origin_even_when_its_file_shape_is_incomplete' {
        Invoke-TestGit -Repository $targetRoot -Arguments @('remote','set-url','origin','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git') | Out-Null

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        ($output -join [Environment]::NewLine) | Should Match 'shared instruction source'
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: A selected shared Skill contains nested text and binary resources, then removes one managed resource in a later source version.
    # Purpose: Preserve recursive byte-safe synchronization and safely remove only unchanged manifest-owned files.
    It 'InterT15_recursively_syncs_shared_Skill_files_and_removes_deleted_managed_resources' {
        # Given
        $sourceSkillPath = Join-Path $sourceRoot '.agents\skills\write-project-prompt'
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkillPath 'references') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkillPath 'assets') | Out-Null
        Set-TestText -Path (Join-Path $sourceSkillPath 'SKILL.md') -Value "---`nname: write-project-prompt`ndescription: Write a project prompt.`n---`n`n# Write project prompt"
        Set-TestText -Path (Join-Path $sourceSkillPath 'references\format.md') -Value '# Prompt format'
        [System.IO.File]::WriteAllBytes((Join-Path $sourceSkillPath 'assets\preview.bin'), [byte[]]@(0x80))
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        # Then
        $targetSkillPath = Join-Path $targetRoot '.agents\skills\write-project-prompt'
        (Get-Content -Raw (Join-Path $targetSkillPath 'SKILL.md')).Trim() | Should Match '# Write project prompt$'
        (Get-Content -Raw (Join-Path $targetSkillPath 'references\format.md')).Trim() | Should Be '# Prompt format'
        [System.IO.File]::ReadAllBytes((Join-Path $targetSkillPath 'assets\preview.bin'))[0] | Should Be 0x80
        Test-Path -LiteralPath (Join-Path $targetRoot '.agents\skills\.gitkeep') | Should Be $false
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object { $_.targetPath -eq '.agents/skills/write-project-prompt/SKILL.md' }).Count | Should Be 1
        @($manifest.files | Where-Object { $_.targetPath -eq '.agents/skills/write-project-prompt/references/format.md' }).Count | Should Be 1

        # Given a changed skill and a removed managed reference
        Set-TestText -Path (Join-Path $sourceSkillPath 'SKILL.md') -Value "---`nname: write-project-prompt`ndescription: Write a project prompt.`n---`n`n# Write project prompt v2"
        [System.IO.File]::WriteAllBytes((Join-Path $sourceSkillPath 'assets\preview.bin'), [byte[]]@(0x81))
        Remove-Item -LiteralPath (Join-Path $sourceSkillPath 'references\format.md')
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        # Then
        (Get-Content -Raw (Join-Path $targetSkillPath 'SKILL.md')).Trim() | Should Match '# Write project prompt v2$'
        [System.IO.File]::ReadAllBytes((Join-Path $targetSkillPath 'assets\preview.bin'))[0] | Should Be 0x81
        Test-Path -LiteralPath (Join-Path $targetSkillPath 'references\format.md') | Should Be $false
    }

    # Scenario: A product Repository already tracks its own Skill at a path also present in the selected shared source.
    # Purpose: Preserve repository-owned content and report the ownership conflict while syncing unrelated artifacts.
    It 'InterT20_preserves_an_existing_unmanaged_Skill_while_syncing_other_instructions' {
        # Given
        $sourceSkillPath = Join-Path $sourceRoot '.agents\skills\existing-skill'
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkillPath 'references') | Out-Null
        Set-TestText -Path (Join-Path $sourceSkillPath 'SKILL.md') -Value '# Shared skill'
        Set-TestText -Path (Join-Path $sourceSkillPath 'references\shared.md') -Value '# Shared nested resource'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        $targetSkillPath = Join-Path $targetRoot '.agents\skills\existing-skill'
        New-Item -ItemType Directory -Force -Path $targetSkillPath | Out-Null
        Set-TestText -Path (Join-Path $targetSkillPath 'SKILL.md') -Value '# Project skill'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.agents/skills/existing-skill/SKILL.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add project skill') | Out-Null

        # When
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        # Then
        (Get-Content -Raw (Join-Path $targetSkillPath 'SKILL.md')).Trim() | Should Be '# Project skill'
        Test-Path -LiteralPath (Join-Path $targetSkillPath 'references\shared.md') | Should Be $false
        ($output -join [Environment]::NewLine) | Should Match 'customized or unmanaged.*\.agents/skills/existing-skill/SKILL.md'
    }

    # Scenario: A Repository-owned AGENTS.md is tracked but currently has an intentional unstaged deletion.
    # Purpose: Preserve the deletion and never recreate an ownership-unknown tracked path from personal runtime content.
    It 'InterT21_preserves_a_missing_but_tracked_unmanaged_path' {
        Set-TestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Product-owned Agent'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add','--','AGENTS.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','add product Agent') | Out-Null
        Remove-Item -LiteralPath (Join-Path $targetRoot 'AGENTS.md')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain','--','AGENTS.md')) -join "`n") | Should Match '^ D AGENTS\.md$'
        ($output -join [Environment]::NewLine) | Should Match 'customized or unmanaged.*AGENTS\.md'
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object { $_.targetPath -eq 'AGENTS.md' }).Count | Should Be 0
    }

    # Scenario: A target folder name resembles a formerly allowlisted local path.
    # Purpose: Prove local path identity can no longer grant stage or commit authority.
    It 'InterT30_never_commits_based_on_a_matching_local_folder_name' {
        $namedTargetRoot = Join-Path $TestDrive 'OwnedProject'
        New-TestRepository -Path $namedTargetRoot -OriginUrl 'git@example.com:someone-else/owned-project.git'
        $commitBefore = Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $namedTargetRoot

        (Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        @(Invoke-TestGit -Repository $namedTargetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    # Scenario: The current Repository origin is listed in the personal exclusion configuration.
    # Purpose: Leave history, working-tree artifacts, manifest, and recovery evidence untouched.
    It 'InterT35_skips_synchronization_when_the_repository_is_excluded' {
        New-TestConfiguration -Path $configurationPath `
            -ExcludedRepositoryUrls @('https://example.com/team/bootstrap-test.git')
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match 'repository is excluded'
    }

    # Scenario: Production planning starts below a configured excluded Repository-relative directory.
    # Purpose: Apply path exclusions before materialization or recovery evidence creation.
    It 'InterT40_skips_synchronization_when_the_startup_directory_is_excluded' {
        $planningDirectory = Join-Path $targetRoot 'docs\architecture-planning'
        New-Item -ItemType Directory -Force -Path $planningDirectory | Out-Null
        New-TestConfiguration -Path $configurationPath `
            -ExcludedRepositoryPaths @('docs/architecture-planning')
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -WorkingDirectory $planningDirectory -UseCurrentRepositoryRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match 'directory is excluded'
    }

    # Scenario: A Repository tracks its own Codex family while the GitHub Copilot family is absent.
    # Purpose: Preserve repository-owned instructions without preventing safe materialization of an independent family.
    It 'InterT45_preserves_an_existing_Codex_family_and_creates_the_missing_GitHub_family' {
        Set-Content -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -Value '# Existing Agent'
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex\AI-Rules') | Out-Null
        Set-Content -LiteralPath (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md') -Value '# Existing Testing'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'AGENTS.md', '.codex/AI-Rules/Testing.en.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'Chore: add shared AI instructions') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AI-Rules\CodeReview.en.md') -Value '# Codex English Code Review'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Existing Agent'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Existing Testing'
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\AI-Rules\CodeReview.en.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot '.github\copilot-instructions.md') | Should Be $true

        (Invoke-TestGit -Repository $targetRoot -Arguments @('log','-1','--pretty=%s')) | Should Be 'Chore: add shared AI instructions'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: The target Repository contains unrelated staged and unstaged product work before bootstrap.
    # Purpose: Keep user index and working-tree changes intact while materializing ignored personal artifacts.
    It 'InterT50_preserves_unrelated_staged_and_unstaged_changes' {
        Set-Content -LiteralPath (Join-Path $targetRoot 'staged.txt') -Value 'staged change'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'staged.txt') | Out-Null
        Set-Content -LiteralPath (Join-Path $targetRoot 'README.md') -Value '# Unstaged change'

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        $stagedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff', '--cached', '--name-only')
        $stagedFiles.Count | Should Be 1
        ($stagedFiles -contains 'staged.txt') | Should Be $true

        $unstagedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff', '--name-only')
        ($unstagedFiles -contains 'README.md') | Should Be $true

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        ($committedFiles -contains 'staged.txt') | Should Be $false
        ($committedFiles -contains 'README.md') | Should Be $false
    }

    # Scenario: Immutable source instructions advance while existing target bytes still match their manifest hashes.
    # Purpose: Refresh managed bytes without producing a product Repository commit.
    It 'InterT55_updates_unchanged_managed_instructions_when_the_source_advances' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AI-Rules\Testing.en.md') -Value '# Codex English Testing v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v2'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing v2'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')) | Should Be 'initial commit'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: Managed local artifacts exist while the product repository switches between branches.
    # Purpose: Keep one ignored working-tree materialization without branch-specific stash operations.
    It 'InterT60_keeps_one_branch_independent_artifact_set_across_branch_switches' {
        $startingBranch = (@(Invoke-TestGit -Repository $targetRoot -Arguments @('branch','--show-current')) -join '').Trim()
        $headBefore = (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) -join '').Trim()
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Invoke-TestGit -Repository $targetRoot -Arguments @('switch','--quiet','-c','fixture-branch') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base branch-independent'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base branch-independent'

        Invoke-TestGit -Repository $targetRoot -Arguments @('switch','--quiet',$startingBranch) | Out-Null
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base branch-independent'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) -join '').Trim() | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
    }

    # Scenario: A linked worktree starts without its own local artifact materialization.
    # Purpose: Create the same ignored model without changing either worktree's branch history.
    It 'InterT65_creates_the_same_local_ignored_model_in_a_linked_worktree' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-worktree'
        Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','linked-fixture',$linkedRoot) | Out-Null
        try {
            Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $linkedRoot

            (Get-Content -Raw -LiteralPath (Join-Path $linkedRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
            Test-Path -LiteralPath (Join-Path $linkedRoot $script:ManifestPath) | Should Be $true
            (@(Invoke-TestGit -Repository $linkedRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
            (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
            @(Invoke-TestGit -Repository $linkedRoot -Arguments @('stash','list','--format=%gs') | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
        }
        finally {
            Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: One linked worktree has an unmanaged Codex base while another materializes the managed base.
    # Purpose: Keep the shared info/exclude state valid for every live worktree after either worktree bootstraps.
    It 'InterT67_preserves_linked_worktree_exclusions_when_managed_sets_differ' {
        Set-TestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Unmanaged project Agent'
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-divergent-worktree'
        Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','linked-divergent-fixture',$linkedRoot) | Out-Null
        try {
            Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $linkedRoot

            Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

            (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Unmanaged project Agent'
            (Get-Content -Raw -LiteralPath (Join-Path $linkedRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
            (@(Invoke-TestGit -Repository $linkedRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
        }
        finally {
            Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: A live linked worktree carries a schema-v2 manifest with an unsupported top-level property.
    # Purpose: Refuse schema-invalid ownership evidence before it can influence the shared Git exclude block.
    It 'InterT68_rejects_a_schema_invalid_linked_worktree_manifest' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-invalid-manifest-worktree'
        Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','linked-invalid-manifest-fixture',$linkedRoot) | Out-Null
        try {
            Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $linkedRoot
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestPath
            $linkedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $linkedManifestPath | ConvertFrom-Json
            $linkedManifest | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
            Set-TestText -Path $linkedManifestPath -Value (($linkedManifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())

            $arguments = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,
                '-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,
                '-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot
            )
            $output = & powershell.exe @arguments 2>&1

            $LASTEXITCODE | Should Not Be 0
            ($output -join [Environment]::NewLine) | Should Match '(?s)linked worktree manifest.*unsupported property.*unexpected'
            (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
        }
        finally {
            Invoke-TestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: A prior local artifact set loses its manifest, one managed file, and the managed exclude block.
    # Purpose: Reconstruct only state that immutable bytes can prove without dirtying the repository.
    It 'InterT70_self_heals_a_missing_manifest_file_and_exclude_marker' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        Remove-Item -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -Force
        Remove-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath) -Force
        Set-TestText -Path (Join-Path $targetRoot '.git\info\exclude') -Value '# keep personal exclude'

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files).Count | Should Be 4
        $exclude = Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.git\info\exclude')
        $exclude | Should Match '# keep personal exclude'
        $exclude | Should Match '# BEGIN Codex AI Instructions managed paths'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: The shared Git exclude path is occupied by an unrelated directory before bootstrap starts.
    # Purpose: Fail before target mutation and preserve the pre-existing filesystem entry instead of deleting it during rollback.
    It 'InterT71_rejects_an_unsafe_shared_Git_exclude_mutation_path' {
        $excludePath = (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude')) -join '').Trim()
        if (-not [System.IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
        Remove-Item -LiteralPath $excludePath -Force
        New-Item -ItemType Directory -Path $excludePath | Out-Null

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'unsafe shared Git exclude mutation path'
        Test-Path -LiteralPath $excludePath -PathType Container | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: A second bootstrap sees the same immutable source and complete valid materialization.
    # Purpose: Make the current-state path a zero-mutation operation with no Git commit.
    It 'InterT69_keeps_current_managed_instructions_as_a_no_op' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
    }

    # Scenario: One manifest-owned file is customized while another unchanged file has a newer immutable source version.
    # Purpose: Preserve customized bytes and continue updating independently provable managed files.
    It 'InterT77_preserves_customized_files_while_updating_other_managed_files' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        Set-TestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Project-specific Agent'

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AI-Rules\Testing.en.md') -Value '# Codex English Testing v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Project-specific Agent'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing v2'
        ($output -join [Environment]::NewLine) | Should Match 'customized.*AGENTS.md'
    }

    # Scenario: Manifest-owned personal runtime artifacts have been committed into product history.
    # Purpose: Stop without index mutation and direct the user to explicit pollution cleanup.
    It 'InterT72_fails_closed_when_manifest_proven_artifacts_are_Git_tracked' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        Invoke-TestGit -Repository $targetRoot -Arguments @('add','--force','--','AGENTS.md','.codex/AI-Rules/Testing.en.md','.github/copilot-instructions.md','.github/AI-Rules/Testing.en.md','.codex/ai-instructions.manifest.json') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','polluted fixture') | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')
        $contentBefore = Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'Repository pollution detected.*manifest-proven'
        ($output -join [Environment]::NewLine) | Should Match 'cleanup-ai-instructions-pollution\.ps1'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Should Be $headBefore
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) | Should Be $contentBefore
    }

    # Scenario: Git tracks a case variant of a manifest-proven managed path on an ignore-case repository.
    # Purpose: Prevent Windows path aliases from bypassing tracked pollution detection and managed ownership checks.
    It 'InterT73_fails_closed_for_a_case_variant_tracked_managed_path' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        Invoke-TestGit -Repository $targetRoot -Arguments @('config','core.ignorecase','true') | Out-Null
        $agentPath = Join-Path $targetRoot 'AGENTS.md'
        $temporaryPath = Join-Path $targetRoot 'agent-case-temporary.md'
        $caseVariantPath = Join-Path $targetRoot 'agents.md'
        Move-Item -LiteralPath $agentPath -Destination $temporaryPath
        Move-Item -LiteralPath $temporaryPath -Destination $caseVariantPath
        Invoke-TestGit -Repository $targetRoot -Arguments @('add','--force','--','agents.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','case-variant pollution fixture') | Out-Null

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'Repository pollution detected.*AGENTS\.md'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('ls-files','--','agents.md')) -join '') | Should Be 'agents.md'
    }

    # Scenario: A schema-v2 manifest labels the Codex base as a Skill without a matching flat Skill path.
    # Purpose: Reject malformed ownership evidence instead of silently adopting or rewriting it during bootstrap.
    It 'InterT74_rejects_a_schema_invalid_managed_manifest_before_mutation' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $manifestPath = Join-Path $targetRoot $script:ManifestPath
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        $manifest.files[0].artifactType = 'skill'
        $manifestJson = ($manifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n") + "`n"
        [System.IO.File]::WriteAllText($manifestPath,$manifestJson,(New-Object System.Text.UTF8Encoding($false)))
        $agentBefore = Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'Managed Skill.*must preserve the flat'
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) | Should Be $agentBefore
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json).files[0].artifactType | Should Be 'skill'
    }

    # Scenario: A previously materialized rule remains byte-identical when the immutable source removes it.
    # Purpose: Remove obsolete manifest-owned content without touching customized or unmanaged files.
    It 'InterT79_removes_an_unchanged_managed_rule_deleted_from_the_source' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        $sourceRulePath = Join-Path $sourceRoot '.codex\AI-Rules\CodeReview.en.md'
        Set-TestText -Path $sourceRulePath -Value '# Codex English Code Review'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        $targetRulePath = Join-Path $targetRoot '.codex\AI-Rules\CodeReview.en.md'
        Test-Path -LiteralPath $targetRulePath | Should Be $true

        Remove-Item -LiteralPath $sourceRulePath
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Test-Path -LiteralPath $targetRulePath | Should Be $false
        (Invoke-TestGit -Repository $targetRoot -Arguments @('log','-1','--pretty=%s')) | Should Be 'initial commit'
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
    }

    # Scenario: A formerly managed rule is customized locally before the immutable source removes that rule.
    # Purpose: Preserve both the customized bytes and historical ownership evidence until the user resolves the customization.
    It 'InterT83_preserves_manifest_ownership_for_a_customized_rule_removed_from_source' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $sourceRulePath = Join-Path $sourceRoot '.codex\AI-Rules\CodeReview.en.md'
        Set-TestText -Path $sourceRulePath -Value '# Codex English Code Review'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $targetRulePath = Join-Path $targetRoot '.codex\AI-Rules\CodeReview.en.md'
        Set-TestText -Path $targetRulePath -Value '# Project customized Code Review'

        Remove-Item -LiteralPath $sourceRulePath
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw -LiteralPath $targetRulePath).Trim() | Should Be '# Project customized Code Review'
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object { $_.targetPath -ceq '.codex/AI-Rules/CodeReview.en.md' }).Count | Should Be 1
        ($output -join [Environment]::NewLine) | Should Match 'customized or unmanaged'
    }

    # Scenario: A broad Git cleanup removes every ignored managed artifact from an already bootstrapped repository.
    # Purpose: Re-materialize the complete immutable file set and recovery evidence after git clean -fdx.
    It 'InterT84_self_heals_the_complete_materialization_after_git_clean_fdx' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $headBefore = (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) -join '').Trim()

        Invoke-TestGit -Repository $targetRoot -Arguments @('clean','-fdx') | Out-Null
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files).Count | Should Be 4
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join '') | Should BeNullOrEmpty
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) -join '').Trim() | Should Be $headBefore
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash','list','--format=%gs') | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    # Scenario: Bootstrap runs with no legacy routing configuration present.
    # Purpose: Still materialize branch-independent files and recovery evidence without staging or committing.
    It 'InterT75_syncs_branch_independent_files_without_staging_or_committing' {
        $runtimeConfigurationPath = Join-Path $TestDrive 'missing-config-defaults.json'
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('diff', '--cached', '--name-only')).Count | Should Be 0
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
        ($output -join [Environment]::NewLine) | Should Match 'without Git commit'
        ($output -join [Environment]::NewLine) | Should Match 'PersonalAgent recovery evidence'
    }

    # Scenario: Broad project ignore rules cover instructions, Skills, and the managed manifest.
    # Purpose: Store only exact manifest-owned paths as byte-safe recovery evidence.
    It 'InterT76_stores_exact_managed_files_as_recovery_evidence' {
        Set-TestText -Path (Join-Path $targetRoot '.gitignore') -Value ".agents/`n.codex/`n.github/`n/AGENTS.md"
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot '.codex\personal-settings.json') -Value '{ "personal": true }'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.gitignore') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'ignore personal agent files') | Out-Null
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $runtimeConfigurationPath = Join-Path $TestDrive 'missing-config-defaults.json'

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('diff', '--cached', '--name-only')).Count | Should Be 0
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
        $stashFiles = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'show', '--name-only', '--include-untracked', 'stash@{0}'))
        ($stashFiles -contains 'AGENTS.md') | Should Be $true
        ($stashFiles -contains '.codex/AI-Rules/Testing.en.md') | Should Be $true
        ($stashFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
        ($stashFiles -contains '.github/copilot-instructions.md') | Should Be $true
        ($stashFiles -contains '.github/AI-Rules/Testing.en.md') | Should Be $true
        ($stashFiles -contains '.codex/personal-settings.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\personal-settings.json') | Should Be $true
    }

    # Scenario: A non-PersonalAgent stash exists before branch-independent artifacts are synchronized.
    # Purpose: Ensure refreshing PersonalAgent state never deletes unrelated user stashes.
    It 'InterT78_preserves_an_unrelated_stash_when_creating_a_PersonalAgent_stash' {
        # Given
        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'committed notes'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'notes.txt') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add notes') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'personal work in progress'
        Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'push', '--quiet', '-m', 'ProjectWork', '--', 'notes.txt') | Out-Null
        $unrelatedStashHash = (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}') |
            Select-Object -First 1).Trim()
        $runtimeConfigurationPath = Join-Path $TestDrive 'missing-config-defaults.json'

        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        # Then
        $stashLines = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs'))
        @($stashLines | Where-Object {
            $_ -match "^$([regex]::Escape($unrelatedStashHash))`t.*ProjectWork$"
        }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    # Scenario: Another Git process inserts a stash after obsolete PersonalAgent references are enumerated.
    # Purpose: Re-resolve recovery evidence by immutable hash so index drift cannot delete unrelated user work.
    It 'InterT88_preserves_unrelated_stashes_when_cleanup_references_shift' {
        # Given
        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'committed notes'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'notes.txt') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add notes') | Out-Null
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'personal work in progress'
        Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'push', '--quiet', '-m', 'ProjectWork', '--', 'notes.txt') | Out-Null
        $unrelatedStashHash = (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}') |
            Select-Object -First 1).Trim()

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath

        $wrapperRoot = Join-Path $TestDrive 'stash-index-shift-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $firstListMarker = Join-Path $wrapperRoot 'first-list.marker'
        $secondListMarker = Join-Path $wrapperRoot 'second-list.marker'
        $insertionMarker = Join-Path $wrapperRoot 'inserted.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"stash list" >nul
if errorlevel 1 goto forward
if not exist "$firstListMarker" (
  type nul > "$firstListMarker"
  goto forward
)
if not exist "$secondListMarker" (
  type nul > "$secondListMarker"
  goto forward
)
if not exist "$insertionMarker" (
  type nul > "$insertionMarker"
  "$realGit" %*
  if errorlevel 1 exit /b 86
  "$realGit" -C "$targetRoot" stash store -m ConcurrentUser "$unrelatedStashHash"
  if errorlevel 1 exit /b 87
  exit /b 0
)
:forward
"$realGit" %*
"@
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot,
            '-GitExecutable', $gitWrapperPath
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Be 0
        Test-Path -LiteralPath $insertionMarker | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v2'
        $stashLines = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs'))
        @($stashLines | Where-Object {
            $_ -match "^$([regex]::Escape($unrelatedStashHash))`t.*ProjectWork$"
        }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'ConcurrentUser$' }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
        ($output -join [Environment]::NewLine) | Should Not Match 'cleanup failed'
    }

    # Scenario: Another Git process inserts a stash after the new PersonalAgent stash is created but before it is reapplied.
    # Purpose: Apply the newly identified immutable hash instead of whichever stash later occupies index zero.
    It 'InterT96_applies_new_recovery_evidence_by_hash_when_the_latest_stash_shifts' {
        # Given
        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'committed notes'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'notes.txt') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add notes') | Out-Null
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'personal work in progress'
        Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'push', '--quiet', '-m', 'ProjectWork', '--', 'notes.txt') | Out-Null
        $unrelatedStashHash = (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}') |
            Select-Object -First 1).Trim()

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath

        $wrapperRoot = Join-Path $TestDrive 'stash-apply-shift-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $pushMarker = Join-Path $wrapperRoot 'push.marker'
        $insertionMarker = Join-Path $wrapperRoot 'inserted.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"stash push" >nul
if errorlevel 1 goto maybe_insert
"$realGit" %*
if errorlevel 1 exit /b 86
type nul > "$pushMarker"
exit /b 0
:maybe_insert
echo %* | "$findString" /C:"stash list" >nul
if errorlevel 1 goto forward
if not exist "$pushMarker" goto forward
if exist "$insertionMarker" goto forward
type nul > "$insertionMarker"
"$realGit" -C "$targetRoot" stash store -m ConcurrentUser "$unrelatedStashHash"
if errorlevel 1 exit /b 87
:forward
"$realGit" %*
"@
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot,
            '-GitExecutable', $gitWrapperPath
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Be 0
        Test-Path -LiteralPath $insertionMarker | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v2'
        $stashLines = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs'))
        @($stashLines | Where-Object { $_ -match 'ProjectWork$' }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'ConcurrentUser$' }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
        ($output -join [Environment]::NewLine) | Should Not Match 'stash apply changed'
    }

    # Scenario: A stash index changes after cleanup identity verification but before Git executes the drop.
    # Purpose: Restore any unexpectedly dropped immutable commit and retain old recovery evidence rather than lose user work.
    It 'InterT97_restores_an_unexpected_stash_dropped_during_last_moment_index_drift' {
        # Given
        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'committed notes'
        Set-TestText -Path (Join-Path $targetRoot 'concurrent.txt') -Value 'committed concurrent notes'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'notes.txt', 'concurrent.txt') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add notes') | Out-Null
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        Set-TestText -Path (Join-Path $targetRoot 'notes.txt') -Value 'personal work in progress'
        Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'push', '--quiet', '-m', 'ProjectWork', '--', 'notes.txt') | Out-Null
        $unrelatedStashHash = (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}') |
            Select-Object -First 1).Trim()
        Set-TestText -Path (Join-Path $targetRoot 'concurrent.txt') -Value 'concurrent work in progress'
        $concurrentStashHash = [string](@(
            Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'create', 'ConcurrentUser') |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -match '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$' } |
                Select-Object -First 1
        )[0])
        $concurrentStashHash = $concurrentStashHash.Trim()
        [string]::IsNullOrWhiteSpace($concurrentStashHash) | Should Be $false
        Invoke-TestGit -Repository $targetRoot -Arguments @('restore', '--worktree', '--', 'concurrent.txt') | Out-Null

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath

        $wrapperRoot = Join-Path $TestDrive 'stash-last-moment-shift-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $insertionMarker = Join-Path $wrapperRoot 'inserted.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"stash drop" >nul
if errorlevel 1 goto forward
if exist "$insertionMarker" goto forward
type nul > "$insertionMarker"
"$realGit" -C "$targetRoot" stash store -m ConcurrentUser "$concurrentStashHash"
if errorlevel 1 exit /b 87
:forward
"$realGit" %*
"@
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot,
            '-GitExecutable', $gitWrapperPath
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Be 0
        Test-Path -LiteralPath $insertionMarker | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v2'
        $stashLines = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs'))
        @($stashLines | Where-Object { $_ -match "^$([regex]::Escape($unrelatedStashHash))`t" }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match "^$([regex]::Escape($concurrentStashHash))`t" }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'ProjectWork$' }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'ConcurrentUser$' }).Count | Should Be 1
        @($stashLines | Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 2
        ($output -join [Environment]::NewLine) | Should Match 'concurrent stash index drift.*restored'
    }

    # Scenario: Prior branch-independent materialization exists locally and one managed file is subsequently customized.
    # Purpose: Refresh other provable files without relying on product commits or overwriting local customization.
    It 'InterT81_refreshes_provable_files_while_prior_materialization_remains_uncommitted' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $committedHead = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $runtimeConfigurationPath = Join-Path $TestDrive 'branch-independent-runtime.json'
        New-TestConfiguration -Path $runtimeConfigurationPath

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        Set-TestText -Path (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md') -Value '# Project customized Testing'
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v3'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $committedHead
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v3'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Project customized Testing'
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
        $stashPaths = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'show', '--name-only', '--include-untracked', 'stash@{0}'))
        ($stashPaths -contains '.codex/AI-Rules/Testing.en.md') | Should Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) | Should Match '# Codex English Base v3'
        ($output -join [Environment]::NewLine) | Should Match 'without Git commit'
    }

    # Scenario: Current materialization and its branch-neutral PersonalAgent recovery evidence are already complete.
    # Purpose: Reuse the same evidence and avoid rotating stash state on a no-op bootstrap.
    It 'InterT82_reuses_existing_PersonalAgent_evidence_when_no_update_is_needed' {
        $runtimeConfigurationPath = Join-Path $TestDrive 'branch-independent-runtime.json'
        New-TestConfiguration -Path $runtimeConfigurationPath
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath
        $stashBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $runtimeConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')) | Should Be $stashBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
    }

    # Scenario: Git is configured to rewrite text files to CRLF for local runtime artifacts.
    # Purpose: Preserve the exact locked bytes of Agent Skill files across PersonalAgent stash push/apply.
    It 'InterT80_preserves_raw_skill_bytes_with_core_autocrlf_enabled' {
        $sourceSkillPath = Join-Path $sourceRoot '.agents\skills\raw-byte-skill'
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkillPath 'references') | Out-Null
        Set-TestText -Path (Join-Path $sourceSkillPath 'SKILL.md') -Value @'
---
name: raw-byte-skill
description: Verify raw bytes.
---
'@
        Set-TestText -Path (Join-Path $sourceSkillPath 'references\data.txt') -Value ("first{0}second" -f [char]10)
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $runtimeConfigurationPath = Join-Path $TestDrive 'branch-independent-runtime-eol.json'
        New-TestConfiguration -Path $runtimeConfigurationPath

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot -ConfigurationPath $runtimeConfigurationPath

        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $entry = @($manifest.files | Where-Object { $_.targetPath -eq '.agents/skills/raw-byte-skill/references/data.txt' })[0]
        $targetSkillFile = Join-Path $targetRoot '.agents\skills\raw-byte-skill\references\data.txt'
        (Get-FileHash -LiteralPath $targetSkillFile -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$entry.sha256)
        $stashBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot -ConfigurationPath $runtimeConfigurationPath

        (Get-FileHash -LiteralPath $targetSkillFile -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$entry.sha256)
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')) | Should Be $stashBefore
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
        ($output -join [Environment]::NewLine) | Should Not Match 'customized or unmanaged'
    }

    # Scenario: A target path is blocked after an earlier managed file has already been copied.
    # Purpose: Roll back every live target mutation when fan-out fails before the manifest is committed.
    It 'InterT85_rolls_back_partial_target_writes_when_fan_out_fails' {
        # Given
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.github') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot '.github\AI-Rules') -Value '# Existing path blocker'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.github/AI-Rules') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add path blocker') | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match '\.github\\AI-Rules\\Testing\.en\.md'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.github\AI-Rules')).Trim() | Should Be '# Existing path blocker'
    }

    # Scenario: Git cannot enumerate existing PersonalAgent evidence after target files, manifest, and exclusions have been written.
    # Purpose: Keep stash discovery inside the target transaction so every live mutation is restored when finalization cannot begin.
    It 'InterT86_rolls_back_target_and_exclusions_when_stash_discovery_fails' {
        # Given
        $wrapperRoot = Join-Path $TestDrive 'stash-list-failure-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $gitWrapper = "@echo off`necho %* | `"$findString`" /C:`"stash list`" >nul`nif not errorlevel 1 exit /b 86`n`"$realGit`" %*"
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper
        $excludePath = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', '--git-path', 'info/exclude')
        if (-not [System.IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
        $excludeBytesBefore = [System.IO.File]::ReadAllBytes($excludePath)
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot,
            '-GitExecutable', $gitWrapperPath
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stash list'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($excludePath)) | Should Be ([Convert]::ToBase64String($excludeBytesBefore))
    }

    # Scenario: A managed file target is already occupied by a project-owned directory.
    # Purpose: Reject the collision before Copy-Item writes inside the directory or creates a partial commit.
    It 'InterT87_rejects_a_directory_at_an_exact_managed_file_path_before_mutation' {
        # Given
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot 'AGENTS.md') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot 'AGENTS.md\keep.txt') -Value '# Keep directory content'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'AGENTS.md/keep.txt') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'add managed path directory blocker') | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'AGENTS\.md'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md\keep.txt')).Trim() | Should Be '# Keep directory content'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
    }

    # Scenario: A managed target ancestor is a junction that resolves outside the target Repository.
    # Purpose: Prevent fan-out from following reparse points and mutating files outside the authorized target.
    It 'InterT89_rejects_target_reparse_points_before_mutation' {
        # Given
        $outsideRoot = Join-Path $TestDrive 'outside-target'
        New-Item -ItemType Directory -Force -Path $outsideRoot | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $targetRoot '.codex') -Target $outsideRoot | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'reparse point'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        @(Get-ChildItem -LiteralPath $outsideRoot -Force).Count | Should Be 0
    }

    # Scenario: A caller supplies an explicit Git executable while relying on automatic target discovery.
    # Purpose: Route target discovery, safety probes, mutation, and finalization through one consistent executable.
    It 'InterT90_routes_every_git_call_through_the_configured_executable' {
        # Given
        New-TestConfiguration -Path $configurationPath
        $wrapperRoot = Join-Path $TestDrive 'configured-git-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $gitInvocationLog = Join-Path $wrapperRoot 'invocations.log'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = "@echo off`necho %* >> `"$gitInvocationLog`"`n`"$realGit`" %*"
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper
        $powerShellExe = (Get-Command powershell.exe).Source
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-GitExecutable', $gitWrapperPath
        )

        # When
        Push-Location $targetRoot
        try {
            $output = & $powerShellExe @arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        # Then
        $exitCode | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match 'synchronized as local ignored runtime artifacts without Git commit'
        $invocations = Get-Content -Raw -LiteralPath $gitInvocationLog
        $invocations | Should Match 'rev-parse --show-toplevel'
        $invocations | Should Match 'rev-parse --verify HEAD'
        $invocations | Should Match 'stash apply'
    }

    # Scenario: A repository has a failing pre-commit hook and unrelated staged/unstaged work.
    # Purpose: Prove bootstrap never invokes commit and therefore never depends on repository commit policy.
    It 'InterT91_never_invokes_commit_or_the_repository_pre_commit_hook' {
        # Given
        $hookPath = Join-Path $targetRoot '.git\hooks\pre-commit'
        Set-TestText -Path $hookPath -Value "#!/bin/sh`nexit 1"
        Set-TestText -Path (Join-Path $targetRoot 'unrelated-staged.txt') -Value 'preserve staged content'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'unrelated-staged.txt') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot 'README.md') -Value '# Unrelated unstaged edit'
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match 'without Git commit'
        ($output -join [Environment]::NewLine) | Should Not Match 'git commit failed'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true
    }

    # Scenario: A target repository cannot reapply the newly created PersonalAgent recovery stash.
    # Purpose: Restore target and index state while retaining the new stash as recovery evidence.
    It 'InterT92_rolls_back_target_and_index_when_personal_agent_stash_apply_fails' {
        # Given
        New-TestConfiguration -Path $configurationPath
        $wrapperRoot = Join-Path $TestDrive 'git-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $powerShellExe = (Get-Command powershell.exe).Source
        $gitWrapper = "@echo off`necho %* | `"$findString`" /C:`"stash apply`" >nul`nif not errorlevel 1 exit /b 86`n`"$realGit`" %*"
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"

        # When
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BootstrapScript,
            '-SourceArchivePath', $sourceArchive,
            '-ConfigurationPath', $configurationPath,
            '-ProvenancePath', $script:TestProvenancePath,
            '-TargetRoot', $targetRoot,
            '-GitExecutable', $gitWrapperPath
        )
        $output = & $powerShellExe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stash apply'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    # Scenario: Git reports stash apply success but the managed manifest raw bytes are changed afterward.
    # Purpose: Verify every canonical recovery path byte-for-byte before obsolete PersonalAgent evidence can be removed.
    It 'InterT92_rolls_back_when_stash_apply_changes_only_manifest_bytes' {
        New-TestConfiguration -Path $configurationPath
        $wrapperRoot = Join-Path $TestDrive 'git-manifest-tamper-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $manifestPath = Join-Path $targetRoot $script:ManifestPath.Replace('/','\')
        $gitWrapper = "@echo off`n`"$realGit`" %*`nif errorlevel 1 exit /b %errorlevel%`necho %* | `"$findString`" /C:`"stash apply`" >nul`nif errorlevel 1 exit /b 0`necho.>>`"$manifestPath`"`nexit /b 0"
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        Set-TestText -Path $gitWrapperPath -Value $gitWrapper
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join "`n"

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,
            '-SourceArchivePath',$sourceArchive,
            '-ConfigurationPath',$configurationPath,
            '-ProvenancePath',$script:TestProvenancePath,
            '-TargetRoot',$targetRoot,
            '-GitExecutable',$gitWrapperPath
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'raw bytes.*ai-instructions\.manifest\.json'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath $manifestPath | Should Be $false
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash','list','--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    # Scenario: A caller force-stages the personal managed manifest into the product index.
    # Purpose: Treat the staged manifest as proven tracked pollution and fail before target mutation.
    It 'InterT93_fails_closed_when_the_managed_manifest_is_force_staged' {
        # Given
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $manifestPath = Join-Path $targetRoot $script:ManifestPath
        [System.IO.File]::AppendAllText($manifestPath, "`n")
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--force', '--', $script:ManifestPath) | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"
        $managedContentBefore = Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        # When
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
        $output = & powershell.exe @arguments 2>&1

        # Then
        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'Repository pollution detected'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) | Should Be $managedContentBefore
    }

    # Scenario: Another worktree holds the repository-wide personal runtime transaction lock.
    # Purpose: Serialize shared stash and info/exclude mutation before any target bytes are changed.
    It 'InterT94_fails_closed_when_the_repository_runtime_lock_is_held' {
        $commonGitDirectory = (@(Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse','--git-common-dir')) -join '').Trim()
        if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $targetRoot $commonGitDirectory }
        $runtimeLockPath = Join-Path ([System.IO.Path]::GetFullPath($commonGitDirectory)) 'codex-ai-instructions.lock'
        $lockStream = [System.IO.File]::Open($runtimeLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,'-ConfigurationPath',$configurationPath,'-ProvenancePath',$script:TestProvenancePath,'-TargetRoot',$targetRoot)
            $output = & powershell.exe @arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $lockStream.Dispose()
        }

        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'another AI instruction repository operation is already running'
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
    }

    # Scenario: The target is a Git work tree without an initial commit.
    # Purpose: Stop before mutation when Git cannot isolate or roll back a generated commit safely.
    It 'InterT95_skips_an_unborn_repository_before_target_mutation' {
        # Given
        $unbornRoot = Join-Path $TestDrive 'unborn-target'
        New-Item -ItemType Directory -Force -Path $unbornRoot | Out-Null
        Invoke-TestGit -Repository $unbornRoot -Arguments @('init', '--quiet') | Out-Null
        Invoke-TestGit -Repository $unbornRoot -Arguments @('remote', 'add', 'origin', $script:TestRepositoryUrl) | Out-Null

        # When
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $unbornRoot

        # Then
        ($output -join [Environment]::NewLine) | Should Match 'target repository has no commit'
        Test-Path -LiteralPath (Join-Path $unbornRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $unbornRoot $script:ManifestPath) | Should Be $false
        (@(Invoke-TestGit -Repository $unbornRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be ''
    }
}
