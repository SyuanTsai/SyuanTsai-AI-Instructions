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

    It 'creates both English instruction families as local ignored artifacts without changing HEAD or status' {
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

    It 'preserves project ignore rules and unrelated ignored files while adding exact local exclusions' {
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

    It 'recursively syncs shared Agent Skill files and removes managed resources deleted from the source' {
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

    It 'preserves an existing unmanaged Agent Skill while syncing other instructions' {
        # Given
        $sourceSkillPath = Join-Path $sourceRoot '.agents\skills\existing-skill'
        New-Item -ItemType Directory -Force -Path $sourceSkillPath | Out-Null
        Set-TestText -Path (Join-Path $sourceSkillPath 'SKILL.md') -Value '# Shared skill'
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
        ($output -join [Environment]::NewLine) | Should Match 'customized or unmanaged.*\.agents/skills/existing-skill/SKILL.md'
    }

    It 'never commits based on a matching local folder name' {
        $namedTargetRoot = Join-Path $TestDrive 'OwnedProject'
        New-TestRepository -Path $namedTargetRoot -OriginUrl 'git@example.com:someone-else/owned-project.git'
        $commitBefore = Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $namedTargetRoot

        (Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        @(Invoke-TestGit -Repository $namedTargetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    It 'skips synchronization when the repository is excluded' {
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

    It 'skips synchronization when the startup directory is excluded' {
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

    It 'does not overwrite an existing Codex family and still creates a missing GitHub family' {
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

    It 'preserves unrelated staged and unstaged changes' {
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

    It 'updates managed instructions when the source Agent changes' {
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

    It 'keeps one branch-independent local artifact set across branch switches' {
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

    It 'creates the same local ignored artifact model in a new linked worktree' {
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
    It 'InterT72_preserves_linked_worktree_exclusions_when_managed_sets_differ' {
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

    It 'self-heals a missing manifest, managed file, and local exclude marker' {
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

    It 'does not create another commit when managed instructions are current' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
    }

    It 'preserves customized managed files while updating other managed files' {
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

    It 'fails closed when manifest-proven personal runtime artifacts are Git tracked' {
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

    It 'removes an unchanged managed rule when the source removes it' {
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

    It 'syncs branch-independent files without staging or committing' {
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

    It 'stores exact managed files as recovery evidence when instruction paths are ignored' {
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
    It 'InterT75_preserves an unrelated stash when creating a PersonalAgent stash' {
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

    It 'continues refreshing managed files while prior sync changes remain uncommitted' {
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

    It 'keeps and reapplies the existing PersonalAgent stash when no source update is needed' {
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
