$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapScript = Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-multisource.ps1'

function Set-TestUtf8Text {
    param([string] $Path, [string] $Value)
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TestSha256 {
    param([string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-TestCatalogSkill {
    param([string] $Id, [string] $SourceId)
    return [ordered]@{
        id = $Id
        group = 'fixture'
        source = [ordered]@{ sourceId = $SourceId; path = ".agents/skills/$Id" }
        profiles = @('optional')
        compatibility = [ordered]@{
            platforms = @('any')
            shells = @()
            requiredCapabilities = @()
            anyOfCapabilities = @()
        }
        dependencies = @()
        lifecycle = [ordered]@{ status = 'active'; aliases = @() }
    }
}

function Write-LockArrayFixture {
    param(
        [string] $Root,
        [int] $SourceCount,
        [switch] $EmptyLockArrays
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $catalogPath = Join-Path $Root 'catalog.json'
    $lockPath = Join-Path $Root 'catalog.lock.json'
    $configurationPath = Join-Path $Root 'sync.json'

    $sources = @()
    $skills = @()
    for ($i = 1; $i -le $SourceCount; $i++) {
        $sourceId = "source-$i"
        $skillId = "skill-$i"
        $sources += [ordered]@{ id = $sourceId; repository = "https://github.com/example/$sourceId.git" }
        $skills += New-TestCatalogSkill -Id $skillId -SourceId $sourceId
    }

    $catalog = [ordered]@{
        schemaVersion = 1
        catalogId = 'lock-array-regression'
        sources = $sources
        profiles = @([ordered]@{
            id = 'optional'
            description = 'Optional fixture profile.'
            default = $false
            includes = @($skills | ForEach-Object { $_.id })
            excludes = @()
        })
        skills = $skills
    }
    Set-TestUtf8Text -Path $catalogPath -Value (($catalog | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n")

    $lockSources = @()
    $lockSkills = @()
    if (-not $EmptyLockArrays) {
        for ($i = 1; $i -le $SourceCount; $i++) {
            $sourceId = "source-$i"
            $skillId = "skill-$i"
            $lockSources += [ordered]@{
                id = $sourceId
                repository = "https://github.com/example/$sourceId.git"
                requestedRef = 'main'
                requestedRefType = 'branch'
                resolvedCommit = ('a' * 40)
                resolvedVersion = 'test'
                archiveSha256 = ('b' * 64)
            }
            $lockSkills += [ordered]@{
                id = $skillId
                sourceId = $sourceId
                sourcePath = ".agents/skills/$skillId"
                contentSha256 = ('c' * 64)
            }
        }
    }

    $lock = [ordered]@{
        schemaVersion = 1
        catalogId = 'lock-array-regression'
        catalogSha256 = Get-TestSha256 -Path $catalogPath
        sources = $lockSources
        skills = $lockSkills
    }
    Set-TestUtf8Text -Path $lockPath -Value (($lock | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n")

    $configuration = [ordered]@{
        schemaVersion = 3
        autoCommitRepositoryUrls = @()
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

    return [pscustomobject]@{
        CatalogPath = $catalogPath
        LockPath = $lockPath
        ConfigurationPath = $configurationPath
    }
}

function Invoke-LockFixtureBootstrap {
    param([object] $Fixture)
    $missingInstructionArchive = Join-Path $TestDrive 'missing-instruction.zip'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BootstrapScript `
        -CatalogPath $Fixture.CatalogPath `
        -LockPath $Fixture.LockPath `
        -ConfigurationPath $Fixture.ConfigurationPath `
        -InstructionSourceArchivePath $missingInstructionArchive 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
}

Describe 'bootstrap-ai-instructions-multisource lock array enumeration' {
    It 'LockArrayT10_enumerates_a_single_source_and_skill_lock_entry' {
        $fixture = Write-LockArrayFixture -Root (Join-Path $TestDrive 'single') -SourceCount 1
        $result = Invoke-LockFixtureBootstrap -Fixture $fixture

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Instruction source archive does not exist'
        $result.Output | Should Not Match "missing required property 'id'"
    }

    It 'LockArrayT20_enumerates_multiple_source_and_skill_lock_entries' {
        $fixture = Write-LockArrayFixture -Root (Join-Path $TestDrive 'multiple') -SourceCount 2
        $result = Invoke-LockFixtureBootstrap -Fixture $fixture

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Instruction source archive does not exist'
        $result.Output | Should Not Match "missing required property 'id'"
    }

    It 'LockArrayT30_handles_empty_lock_arrays_without_treating_the_array_as_a_lock_entry' {
        $fixture = Write-LockArrayFixture -Root (Join-Path $TestDrive 'empty') -SourceCount 1 -EmptyLockArrays
        $result = Invoke-LockFixtureBootstrap -Fixture $fixture

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match "source 'source-1' has no resolved lock entry"
        $result.Output | Should Not Match "missing required property 'id'"
    }
}
