$script:BootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions.ps1'

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

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Path '.codex\AGENTS.en.md'), "# Codex English Base`n", $utf8WithoutBom)
    [System.IO.File]::WriteAllText((Join-Path $Path '.codex\AI-Rules\Testing.en.md'), "# Codex English Testing`n", $utf8WithoutBom)
    [System.IO.File]::WriteAllText((Join-Path $Path '.github\copilot-instructions.en.md'), "# Copilot English Base`n", $utf8WithoutBom)
    [System.IO.File]::WriteAllText((Join-Path $Path '.github\AI-Rules\Testing.en.md'), "# Copilot English Testing`n", $utf8WithoutBom)
}

function New-TestRepository {
    param([Parameter(Mandatory = $true)][string] $Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('init', '--quiet') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.name', 'Bootstrap Test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.email', 'bootstrap@example.test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'core.autocrlf', 'true') | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value '# Test Repository'
    Invoke-TestGit -Repository $Path -Arguments @('add', '--', 'README.md') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('commit', '--quiet', '-m', 'initial commit') | Out-Null
}

function Invoke-BootstrapScript {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceArchivePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetRoot
    )

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BootstrapScript `
        -SourceArchivePath $SourceArchivePath -TargetRoot $TargetRoot 2>&1

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
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $archiveRoot, $sourceArchive, $targetRoot
        New-TestSource -Path $sourceRoot
        Compress-Archive -Path $sourceRoot -DestinationPath $sourceArchive
        New-TestRepository -Path $targetRoot
    }

    It 'creates both English instruction families and commits only those files' {
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Codex English Testing'
        (Get-Content -Raw (Join-Path $targetRoot '.github\copilot-instructions.md')).Trim() | Should Be '# Copilot English Base'
        (Get-Content -Raw (Join-Path $targetRoot '.github\AI-Rules\Testing.en.md')).Trim() | Should Be '# Copilot English Testing'

        $commitMessage = Invoke-TestGit -Repository $targetRoot -Arguments @('log', '-1', '--pretty=%s')
        $commitMessage | Should Be 'chore: add shared AI instructions'

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        $committedFiles.Count | Should Be 4
        ($committedFiles -contains 'AGENTS.md') | Should Be $true
        ($committedFiles -contains '.codex/AI-Rules/Testing.en.md') | Should Be $true
        ($committedFiles -contains '.github/copilot-instructions.md') | Should Be $true
        ($committedFiles -contains '.github/AI-Rules/Testing.en.md') | Should Be $true
    }

    It 'does not overwrite an existing Codex family and still creates a missing GitHub family' {
        Set-Content -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -Value '# Existing Agent'
        New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.codex\AI-Rules') | Out-Null
        Set-Content -LiteralPath (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md') -Value '# Existing Testing'
        Invoke-TestGit -Repository $targetRoot -Arguments @('add', '--', 'AGENTS.md', '.codex/AI-Rules/Testing.en.md') | Out-Null
        Invoke-TestGit -Repository $targetRoot -Arguments @('commit', '--quiet', '-m', 'existing instructions') | Out-Null

        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Existing Agent'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\AI-Rules\Testing.en.md')).Trim() | Should Be '# Existing Testing'
        Test-Path -LiteralPath (Join-Path $targetRoot '.github\copilot-instructions.md') | Should Be $true

        $committedFiles = Invoke-TestGit -Repository $targetRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')
        $committedFiles.Count | Should Be 2
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
}
