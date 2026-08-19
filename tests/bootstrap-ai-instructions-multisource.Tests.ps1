$script:BootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-multisource.ps1'
$script:TestRepositoryUrl = 'git@example.com:team/multisource-bootstrap-test.git'

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Set-TestUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Value
    )

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8WithoutBom)
}

function Get-TestFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

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

function New-TestInstructionArchive {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ArchivePath
    )

    $repositoryRoot = Join-Path $Root 'SyuanTsai-AI-Instructions-main'
    New-Item -ItemType Directory -Force -Path (Join-Path $repositoryRoot '.codex\AI-Rules') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repositoryRoot '.github\AI-Rules') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repositoryRoot '.agents\skills\legacy-skill') | Out-Null
    Set-TestUtf8Text -Path (Join-Path $repositoryRoot '.codex\AGENTS.en.md') -Value "# Codex Base`n"
    Set-TestUtf8Text -Path (Join-Path $repositoryRoot '.codex\AI-Rules\core.en.md') -Value "# Codex Rule`n"
    Set-TestUtf8Text -Path (Join-Path $repositoryRoot '.github\copilot-instructions.en.md') -Value "# Copilot Base`n"
    Set-TestUtf8Text -Path (Join-Path $repositoryRoot '.github\AI-Rules\core.en.md') -Value "# Copilot Rule`n"
    Set-TestUtf8Text -Path (Join-Path $repositoryRoot '.agents\skills\legacy-skill\SKILL.md') -Value "---`nname: legacy-skill`ndescription: Legacy fixture skill.`n---`n"
    Compress-Archive -Path $repositoryRoot -DestinationPath $ArchivePath
}

function New-TestTargetRepository {
    param([Parameter(Mandatory = $true)][string] $Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('init', '--quiet') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.name', 'Multisource Bootstrap Test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('config', 'user.email', 'multisource@example.test') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('remote', 'add', 'origin', $script:TestRepositoryUrl) | Out-Null
    Set-TestUtf8Text -Path (Join-Path $Path 'README.md') -Value "# Test Repository`n"
    Invoke-TestGit -Repository $Path -Arguments @('add', '--', 'README.md') | Out-Null
    Invoke-TestGit -Repository $Path -Arguments @('commit', '--quiet', '-m', 'initial commit') | Out-Null
}

Describe 'bootstrap-ai-instructions-multisource' {
    It 'SmokeT10_executes_the_local_instruction_only_path_end_to_end' {
        $catalogPath = Join-Path $TestDrive 'catalog.json'
        $lockPath = Join-Path $TestDrive 'catalog.lock.json'
        $configurationPath = Join-Path $TestDrive 'sync-config.json'
        $instructionRoot = Join-Path $TestDrive 'instruction-archive-root'
        $instructionArchive = Join-Path $TestDrive 'instruction-source.zip'
        $targetRoot = Join-Path $TestDrive 'target'

        $catalog = [ordered]@{
            schemaVersion = 1
            catalogId = 'multisource-smoke'
            sources = @(
                [ordered]@{
                    id = 'unused-source'
                    repository = 'https://github.com/example/unused-source.git'
                }
            )
            profiles = @(
                [ordered]@{
                    id = 'optional'
                    description = 'Optional fixture profile.'
                    default = $false
                    includes = @('unused-skill')
                    excludes = @()
                }
            )
            skills = @(
                [ordered]@{
                    id = 'unused-skill'
                    group = 'fixture'
                    source = [ordered]@{
                        sourceId = 'unused-source'
                        path = '.agents/skills/unused-skill'
                    }
                    profiles = @('optional')
                    compatibility = [ordered]@{
                        platforms = @('any')
                        shells = @()
                        requiredCapabilities = @()
                        anyOfCapabilities = @()
                    }
                    dependencies = @()
                    lifecycle = [ordered]@{
                        status = 'active'
                        aliases = @()
                    }
                }
            )
        }
        $catalogJson = ($catalog | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n"
        Set-TestUtf8Text -Path $catalogPath -Value $catalogJson

        $lock = [ordered]@{
            schemaVersion = 1
            catalogId = 'multisource-smoke'
            catalogSha256 = Get-TestFileSha256 -Path $catalogPath
            sources = @()
            skills = @()
        }
        Set-TestUtf8Text -Path $lockPath -Value (($lock | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n")

        $configuration = [ordered]@{
            schemaVersion = 3
            autoCommitRepositoryUrls = @($script:TestRepositoryUrl)
            excludedRepositoryUrls = @()
            excludedRepositoryPaths = @()
            catalog = [ordered]@{
                repository = 'https://github.com/example/catalog.git'
                ref = 'main'
                profiles = @()
                includeSkills = @()
                excludeSkills = @()
            }
        }
        Set-TestUtf8Text -Path $configurationPath -Value (($configuration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n")

        New-TestInstructionArchive -Root $instructionRoot -ArchivePath $instructionArchive
        New-TestTargetRepository -Path $targetRoot

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BootstrapScript `
            -CatalogPath $catalogPath `
            -LockPath $lockPath `
            -ConfigurationPath $configurationPath `
            -InstructionSourceArchivePath $instructionArchive `
            -TargetRoot $targetRoot 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Multi-source bootstrap failed: $($output -join [Environment]::NewLine)"
        }

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex Base'
        (Get-Content -Raw (Join-Path $targetRoot '.github\copilot-instructions.md')).Trim() | Should Be '# Copilot Base'
        Test-Path -LiteralPath (Join-Path $targetRoot '.agents\skills\legacy-skill') | Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\ai-instructions.manifest.json') | Should Be $true
    }

    It 'SmokeT20_fails_with_an_actionable_error_when_selection_arrays_are_missing' {
        $catalogPath = Join-Path $TestDrive 'catalog.json'
        $lockPath = Join-Path $TestDrive 'catalog.lock.json'
        $configurationPath = Join-Path $TestDrive 'bad-sync-config.json'

        $catalog = [ordered]@{
            schemaVersion = 1
            catalogId = 'config-validation'
            sources = @([ordered]@{ id='source-a'; repository='https://github.com/example/source-a.git' })
            profiles = @([ordered]@{ id='core'; description='Core'; default=$false; includes=@('skill-a'); excludes=@() })
            skills = @([ordered]@{
                id='skill-a'; group='fixture';
                source=[ordered]@{ sourceId='source-a'; path='.agents/skills/skill-a' };
                profiles=@('core');
                compatibility=[ordered]@{ platforms=@('any'); shells=@(); requiredCapabilities=@(); anyOfCapabilities=@() };
                dependencies=@(); lifecycle=[ordered]@{ status='active'; aliases=@() }
            })
        }
        Set-TestUtf8Text -Path $catalogPath -Value (($catalog | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n")
        $lock = [ordered]@{ schemaVersion=1; catalogId='config-validation'; catalogSha256=(Get-TestFileSha256 -Path $catalogPath); sources=@(); skills=@() }
        Set-TestUtf8Text -Path $lockPath -Value (($lock | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n")
        $configuration = [ordered]@{
            schemaVersion=3; autoCommitRepositoryUrls=@(); excludedRepositoryUrls=@(); excludedRepositoryPaths=@();
            catalog=[ordered]@{ repository='https://github.com/example/catalog.git'; ref='main'; profiles=@() }
        }
        Set-TestUtf8Text -Path $configurationPath -Value (($configuration | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n")

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BootstrapScript `
            -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match "missing required property 'includeSkills'"
    }
}
