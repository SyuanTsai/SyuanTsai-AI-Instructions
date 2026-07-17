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

    Set-TestText -Path (Join-Path $Path '.codex\AGENTS.en.md') -Value '# Codex English Base'
    Set-TestText -Path (Join-Path $Path '.codex\AI-Rules\Testing.en.md') -Value '# Codex English Testing'
    Set-TestText -Path (Join-Path $Path '.github\copilot-instructions.en.md') -Value '# Copilot English Base'
    Set-TestText -Path (Join-Path $Path '.github\AI-Rules\Testing.en.md') -Value '# Copilot English Testing'
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
    Compress-Archive -Path $SourceRoot -DestinationPath $ArchivePath
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
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'existing instructions') | Out-Null
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

    It 'continues refreshing managed files while prior sync changes remain uncommitted' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        $committedHead = Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')
        $noCommitConfigurationPath = Join-Path $TestDrive 'no-auto-commit.json'
        New-TestConfiguration -Path $noCommitConfigurationPath

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v2'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        Set-TestText -Path (Join-Path $sourceRoot '.codex\AGENTS.en.md') -Value '# Codex English Base v3'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot `
            -ConfigurationPath $noCommitConfigurationPath

        (Invoke-TestGit -Repository $targetRoot -Arguments @('rev-parse', 'HEAD')) | Should Be $committedHead
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base v3'
        $personalAgentStashes = @(Invoke-TestGit -Repository $targetRoot -Arguments @('stash', 'list', '--format=%H%x09%gs') | Where-Object { $_ -match 'PersonalAgent$' })
        $personalAgentStashes.Count | Should Be 1
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
}
