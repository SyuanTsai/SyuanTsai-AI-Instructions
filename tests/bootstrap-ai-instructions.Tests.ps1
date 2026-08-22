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

function New-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string[]] $AutoCommitRepositoryUrls = @(),

        [string[]] $ExcludedRepositoryUrls = @(),

        [string[]] $ExcludedRepositoryPaths = @()
    )

    $configuration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($AutoCommitRepositoryUrls)
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

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:BootstrapScript,
        '-SourceArchivePath', $SourceArchivePath,
        '-ConfigurationPath', $ConfigurationPath
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
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $archiveRoot, $sourceArchive, $targetRoot, $configurationPath
        New-TestSource -Path $sourceRoot
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $configurationPath -AutoCommitRepositoryUrls @($script:TestRepositoryUrl)
        $script:TestConfigurationPath = $configurationPath
    }

    It 'creates both English instruction families and commits only those files' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing'
        (Get-Content -Raw (Join-Path $targetRoot '.github\copilot-instructions.md')).Trim() | Should Be '# Copilot English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.github\AI-Rules\Testing.en.md')).Trim() | Should Be '# Copilot English Testing'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true

        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $manifest.schemaVersion | Should Be 1
        $manifest.sourceRepository | Should Be 'SyuanTsai/SyuanTsai-AI-Instructions'
        $manifest.sourceRef | Should Be 'main'
        $manifest.files.Count | Should Be 4

        $commitMessage = Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')
        $commitMessage | Should Be 'chore: add shared AI instructions'

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        $committedFiles.Count | Should Be 5
        ($committedFiles -contains 'AGENTS.md') | Should Be $true
        ($committedFiles -contains '.codex/AI-Rules/Testing.en.md') | Should Be $true
        ($committedFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
        ($committedFiles -contains '.github/copilot-instructions.md') | Should Be $true
        ($committedFiles -contains '.github/AI-Rules/Testing.en.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot '.agents\skills\.gitkeep') | Should Be $false
    }

    It 'commits exact managed files when instruction paths are ignored' {
        Set-TestText -Path (Join-Path $targetRoot '.gitignore') -Value ".agents/`n.codex/`n.github/`n/AGENTS.md"
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot '.codex\personal-settings.json') -Value '{ "personal": true }'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.gitignore') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'ignore personal agent files') | Out-Null

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        $committedFiles.Count | Should Be 5
        ($committedFiles -contains 'AGENTS.md') | Should Be $true
        ($committedFiles -contains '.codex/AI-Rules/Testing.en.md') | Should Be $true
        ($committedFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
        ($committedFiles -contains '.github/copilot-instructions.md') | Should Be $true
        ($committedFiles -contains '.github/AI-Rules/Testing.en.md') | Should Be $true
        ($committedFiles -contains '.codex/personal-settings.json') | Should Be $false
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

    It 'matches the actual repository location across SSH and HTTPS origin URL formats' {
        New-TestConfiguration -Path $configurationPath `
            -AutoCommitRepositoryUrls @('https://example.com/team/bootstrap-test.git')

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')) |
            Should Be 'chore: add shared AI instructions'
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 0
    }

    It 'does not allow auto commit based on a matching local folder name' {
        $namedTargetRoot = Join-Path $TestDrive 'OwnedProject'
        New-TestRepository -Path $namedTargetRoot -OriginUrl 'git@example.com:someone-else/owned-project.git'
        New-TestConfiguration -Path $configurationPath `
            -AutoCommitRepositoryUrls @('git@example.com:team/owned-project.git')
        $commitBefore = Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $namedTargetRoot

        (Invoke-TestGit -Repository $namedTargetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        @(Invoke-TestGit -Repository $namedTargetRoot -Arguments @('stash', 'list', '--format=%gs') |
            Where-Object { $_ -match 'PersonalAgent$' }).Count | Should Be 1
    }

    It 'skips synchronization when the repository is excluded' {
        New-TestConfiguration -Path $configurationPath `
            -AutoCommitRepositoryUrls @($script:TestRepositoryUrl) `
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
            -AutoCommitRepositoryUrls @($script:TestRepositoryUrl) `
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

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        $committedFiles.Count | Should Be 3
        ($committedFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
        ($committedFiles -contains '.github/copilot-instructions.md') | Should Be $true
        ($committedFiles -contains '.github/AI-Rules/Testing.en.md') | Should Be $true
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
        (Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')) | Should Be 'chore: sync shared AI instructions'

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        ($committedFiles -contains 'AGENTS.md') | Should Be $true
        ($committedFiles -contains '.codex/AI-Rules/Testing.en.md') | Should Be $true
        ($committedFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
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
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'AGENTS.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'customize project agent') | Out-Null

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AI-Rules\Testing.en.md') -Value '# Codex English Testing v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Project-specific Agent'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing v2'
        ($output -join [Environment]::NewLine) | Should Match 'customized.*AGENTS.md'
    }

    It 'adopts unchanged files created by the previous bootstrap and updates them' {
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex\AI-Rules') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.github\AI-Rules') | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Destination (Join-Path $targetRoot 'AGENTS.md')
        Copy-Item -LiteralPath (Join-Path $sourceRoot '.codex\AI-Rules\Testing.en.md') -Destination (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')
        Copy-Item -LiteralPath (Join-Path $sourceRoot '.github\copilot-instructions.en.md') -Destination (Join-Path $targetRoot '.github\copilot-instructions.md')
        Copy-Item -LiteralPath (Join-Path $sourceRoot '.github\AI-Rules\Testing.en.md') -Destination (Join-Path $targetRoot '.github\AI-Rules\Testing.en.md')
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'AGENTS.md', '.codex/AI-Rules/Testing.en.md', '.github/copilot-instructions.md', '.github/AI-Rules/Testing.en.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'chore: add shared AI instructions') | Out-Null

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v2'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true
        (Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')) | Should Be 'chore: sync shared AI instructions'
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
        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        ($committedFiles -contains '.codex/AI-Rules/CodeReview.en.md') | Should Be $true
        ($committedFiles -contains '.codex/ai-instructions.manifest.json') | Should Be $true
    }

    It 'syncs files without staging or committing when the repository is not allowlisted' {
        $noCommitConfigurationPath = Join-Path $TestDrive 'missing-config-defaults-to-no-commit.json'
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $commitBefore
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $true
        @(Invoke-TestGit -Repository $targetRoot -Arguments @('diff', '--cached', '--name-only')).Count | Should Be 0
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
        ($output -join [Environment]::NewLine) | Should Match 'without commit'
        ($output -join [Environment]::NewLine) | Should Match 'PersonalAgent stash'
    }

    It 'stashes exact managed files when instruction paths are ignored in a non-allowlisted repository' {
        Set-TestText -Path (Join-Path $targetRoot '.gitignore') -Value ".agents/`n.codex/`n.github/`n/AGENTS.md"
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex') | Out-Null
        Set-TestText -Path (Join-Path $targetRoot '.codex\personal-settings.json') -Value '{ "personal": true }'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', '.gitignore') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'ignore personal agent files') | Out-Null
        $commitBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $noCommitConfigurationPath = Join-Path $TestDrive 'missing-config-defaults-to-no-commit.json'

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

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

    # Scenario: A non-PersonalAgent stash exists before a non-allowlisted repository is synchronized.
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
        $noCommitConfigurationPath = Join-Path $TestDrive 'missing-config-defaults-to-no-commit.json'

        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

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
        $noCommitConfigurationPath = Join-Path $TestDrive 'no-auto-commit.json'
        New-TestConfiguration -Path $noCommitConfigurationPath

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        Set-TestText -Path (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md') -Value '# Project customized Testing'
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v3'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $committedHead
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v3'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Project customized Testing'
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
        $stashPaths = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'show', '--name-only', '--include-untracked', 'stash@{0}'))
        ($stashPaths -contains '.codex/AI-Rules/Testing.en.md') | Should Be $false
        (Invoke-TestGit -Repository $targetRoot -Arguments @('show', 'stash@{0}:AGENTS.md')) -join "`n" | Should Match '# Codex English Base v3'
        ($output -join [Environment]::NewLine) | Should Match 'without commit'
    }

    It 'keeps and reapplies the existing PersonalAgent stash when no source update is needed' {
        $noCommitConfigurationPath = Join-Path $TestDrive 'no-auto-commit.json'
        New-TestConfiguration -Path $noCommitConfigurationPath
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath
        $stashBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')) | Should Be $stashBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
        ($output -join [Environment]::NewLine) | Should Match 'up to date'
    }

    # Scenario: Git is configured to rewrite text files to CRLF in a non-allowlisted repository.
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
        $noCommitConfigurationPath = Join-Path $TestDrive 'no-auto-commit-eol.json'
        New-TestConfiguration -Path $noCommitConfigurationPath

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot -ConfigurationPath $noCommitConfigurationPath

        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $entry = @($manifest.files | Where-Object { $_.targetPath -eq '.agents/skills/raw-byte-skill/references/data.txt' })[0]
        $targetSkillFile = Join-Path $targetRoot '.agents\skills\raw-byte-skill\references\data.txt'
        (Get-FileHash -LiteralPath $targetSkillFile -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$entry.sha256)
        $stashBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'stash@{0}')

        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot -ConfigurationPath $noCommitConfigurationPath

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
        ($output -join [Environment]::NewLine) | Should Match 'synchronized without commit'
        $invocations = Get-Content -Raw -LiteralPath $gitInvocationLog
        $invocations | Should Match 'rev-parse --show-toplevel'
        $invocations | Should Match 'rev-parse --verify HEAD'
        $invocations | Should Match 'stash apply'
    }

    # Scenario: An allowlisted repository rejects the generated commit through a pre-commit hook.
    # Purpose: Restore managed files, manifest, and index when Git finalization fails after target mutation.
    It 'InterT91_rolls_back_target_and_index_when_auto_commit_fails' {
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
            '-TargetRoot', $targetRoot
        )
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE

        # Then
        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'git commit'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | Should Be $false
    }

    # Scenario: A non-allowlisted repository cannot reapply the newly created PersonalAgent stash.
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

    # Scenario: A caller has staged an intentional managed-manifest edit before synchronization.
    # Purpose: Stop before target mutation so the manifest and managed files cannot diverge.
    It 'InterT93_skips_before_mutation_when_the_managed_manifest_is_staged' {
        # Given
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $manifestPath = Join-Path $targetRoot $script:ManifestPath
        [System.IO.File]::AppendAllText($manifestPath, "`n")
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', $script:ManifestPath) | Out-Null
        $headBefore = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $statusBefore = @(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n"
        $managedContentBefore = Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')
        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive

        # When
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        # Then
        ($output -join [Environment]::NewLine) | Should Match 'sync skipped.*manifest has staged changes'
        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $headBefore
        (@(Invoke-TestGit -Repository $targetRoot -Arguments @('status', '--porcelain')) -join "`n") | Should Be $statusBefore
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) | Should Be $managedContentBefore
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
