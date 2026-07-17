$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:BootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions.ps1'

function Invoke-InstallScript {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $CodexHome,

        [string[]] $AutoCommitRepositoryUrls = @(),

        [string[]] $ExcludedRepositoryUrls = @(),

        [string[]] $ExcludedRepositoryPaths = @()
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:InstallScript,
        '-RepositoryRoot', $RepositoryRoot,
        '-CodexHome', $CodexHome
    )

    if ($AutoCommitRepositoryUrls.Count -gt 0) {
        $arguments += '-AutoCommitRepositoryUrls'
        foreach ($repositoryUrl in $AutoCommitRepositoryUrls) {
            $arguments += $repositoryUrl
        }
    }

    if ($ExcludedRepositoryUrls.Count -gt 0) {
        $arguments += '-ExcludedRepositoryUrls'
        foreach ($repositoryUrl in $ExcludedRepositoryUrls) {
            $arguments += $repositoryUrl
        }
    }

    if ($ExcludedRepositoryPaths.Count -gt 0) {
        $arguments += '-ExcludedRepositoryPaths'
        foreach ($repositoryPath in $ExcludedRepositoryPaths) {
            $arguments += $repositoryPath
        }
    }

    $output = & powershell.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Install script failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Set-TestText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8WithoutBom)
}

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive '.codex'
    }

    It 'installs the bootstrap script and creates local Codex configuration files' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Test-Path -LiteralPath $installedHookScript | Should Be $true
        (Get-Content -Raw -LiteralPath $installedHookScript) |
            Should Be (Get-Content -Raw -LiteralPath $script:BootstrapScript)

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 2
        @($configuration.autoCommitRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryPaths).Count | Should Be 0

        $agents = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        $hooks.hooks.SessionStart[0].matcher | Should Be 'startup'
        $hooks.hooks.SessionStart[0].hooks[0].commandWindows | Should Match 'bootstrap-ai-instructions\.ps1'
    }

    It 'preserves existing personal content and does not duplicate bootstrap entries' {
        Set-TestText -Path (Join-Path $codexHome 'AGENTS.md') -Value @'
# Personal Codex Rules

Keep this personal note.

## Repository Instructions Bootstrap

old bootstrap text

## Other Rules

Keep this section too.
'@

        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""
          }
        ]
      },
      {
        "matcher": "other",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -File \"C:\\keep\\other.ps1\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "keep-stop",
        "hooks": []
      }
    ]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $agents = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Keep this personal note'
        $agents | Should Match 'Keep this section too'
        $agents | Should Not Match 'old bootstrap text'
        ([regex]::Matches($agents, 'Repository Instructions Bootstrap')).Count | Should Be 1

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 2
        @($hooks.hooks.SessionStart | Where-Object {
            @($_.hooks | Where-Object { $_.command -match 'bootstrap-ai-instructions\.ps1' }).Count -gt 0
        }).Count | Should Be 1
        @($hooks.hooks.SessionStart | Where-Object { $_.matcher -eq 'other' }).Count | Should Be 1
        @($hooks.hooks.Stop).Count | Should Be 1
    }

    It 'migrates sync configuration to schema version 2 and keeps repository URLs and paths' {
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 1,
  "autoCommitRepositoryUrls": [
    "git@example.com:team/old-project.git"
  ],
  "autoCommitRepositoryPaths": [
    "C:\\Local\\Project"
  ],
  "repositoryUrls": [
    "https://example.com/team/second-project.git"
  ],
  "excludedRepositoryUrls": [
    "git@example.com:team/planning-only.git"
  ],
  "excludedRepositoryPaths": [
    "docs/architecture-planning"
  ]
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome `
            -AutoCommitRepositoryUrls @('ssh://git@example.com/team/new-project.git') `
            -ExcludedRepositoryUrls @('https://example.com/team/architecture-only.git') `
            -ExcludedRepositoryPaths @('design/planning-only')

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 2
        @($configuration.autoCommitRepositoryUrls).Count | Should Be 3
        ($configuration.autoCommitRepositoryUrls -contains 'git@example.com:team/old-project.git') | Should Be $true
        ($configuration.autoCommitRepositoryUrls -contains 'https://example.com/team/second-project.git') | Should Be $true
        ($configuration.autoCommitRepositoryUrls -contains 'ssh://git@example.com/team/new-project.git') | Should Be $true
        @($configuration.excludedRepositoryUrls).Count | Should Be 2
        ($configuration.excludedRepositoryUrls -contains 'git@example.com:team/planning-only.git') | Should Be $true
        ($configuration.excludedRepositoryUrls -contains 'https://example.com/team/architecture-only.git') | Should Be $true
        @($configuration.excludedRepositoryPaths).Count | Should Be 2
        ($configuration.excludedRepositoryPaths -contains 'docs/architecture-planning') | Should Be $true
        ($configuration.excludedRepositoryPaths -contains 'design/planning-only') | Should Be $true
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryPaths') | Should Be $false
    }
}
