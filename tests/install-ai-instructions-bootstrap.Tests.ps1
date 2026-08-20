$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:InstalledBootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-installed.ps1'

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

    # Scenario: A fresh Codex home installs the production multi-source bootstrap.
    # Purpose: Make the user-facing hook immutable, self-contained, and schema-v3 based.
    It 'InterT05_installs_the_multi_source_runtime_without_creating_a_SessionStart_hook' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Test-Path -LiteralPath $installedHookScript | Should Be $true
        (Get-Content -Raw -LiteralPath $installedHookScript) |
            Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)

        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        foreach ($relativePath in @(
            'bootstrap-ai-instructions-multisource.ps1',
            'bootstrap-ai-instructions.ps1',
            'safe-zip.psm1',
            'skills-catalog-contract.psm1',
            'skills-source-retrieval.psm1',
            'skills-source-acquisition.psm1',
            'skills-source-composition.psm1',
            'catalog\skills-catalog.json',
            'catalog\skills-catalog-lock.json'
        )) {
            Test-Path -LiteralPath (Join-Path $runtimeRoot $relativePath) | Should Be $true
        }

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 3
        @($configuration.autoCommitRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryPaths).Count | Should Be 0
        [string]$configuration.catalog.repository | Should Match '^https://github\.com/.+/.+\.git$'
        [string]$configuration.catalog.ref | Should Match '^[0-9a-f]{40}$'
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'production code'
        $agents | Should Match '問問題'
        $agents | Should Not Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'
        $agents | Should Match 'Agent Skills'
        $agents | Should Match 'customized or unmanaged Instructions or Agent Skills'
        $agents | Should Match 'Git ignore.*精確的受管理檔案與 manifest'

        Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json') | Should Be $false
    }

    # Scenario: CodexHome already contains a bootstrap hook that uses --include-untracked.
    # Purpose: Ensure every installation replaces stale hook logic with the repository version.
    It 'InterT15_overwrites a stale bootstrap hook with the installed launcher' {
        # Given
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestText -Path $installedHookScript -Value @'
git stash push --include-untracked --quiet -m PersonalAgent -- AGENTS.md
'@

        # When
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        # Then
        $installedHook = Get-Content -Raw -LiteralPath $installedHookScript
        $installedHook | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)
        $installedHook | Should Match 'bootstrap-ai-instructions-multisource\.ps1'
        $installedHook | Should Not Match "'stash', 'push', '--include-untracked'"
    }

    It 'preserves personal content and unrelated hooks while removing the bootstrap SessionStart entry' {
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

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Keep this personal note'
        $agents | Should Match 'Keep this section too'
        $agents | Should Not Match 'old bootstrap text'
        ([regex]::Matches($agents, 'Repository Instructions Bootstrap')).Count | Should Be 1

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart | Where-Object {
            @($_.hooks | Where-Object { $_.command -match 'bootstrap-ai-instructions\.ps1' }).Count -gt 0
        }).Count | Should Be 0
        @($hooks.hooks.SessionStart | Where-Object { $_.matcher -eq 'other' }).Count | Should Be 1
        @($hooks.hooks.Stop).Count | Should Be 1
    }

    It 'removes SessionStart when the legacy bootstrap is its only entry' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "commandWindows": "powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""
          }
        ]
      }
    ]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        ($hooks.hooks.PSObject.Properties.Name -contains 'SessionStart') | Should Be $false
    }

    # Scenario: A legacy schema-v1 configuration is upgraded by the production installer.
    # Purpose: Preserve repository routing while adding deterministic catalog selection defaults.
    It 'InterT30_migrates_legacy_configuration_to_schema_version_3' {
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
        $configuration.schemaVersion | Should Be 3
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
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0
    }

    # Scenario: A user already chose profiles and explicit Skill overrides in schema v3.
    # Purpose: Reinstallation must not silently reset or broaden the user's selected Skill set.
    It 'InterT35_preserves_existing_schema_v3_catalog_selections_exactly' {
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 3,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": [],
  "catalog": {
    "repository": "https://example.com/acme/catalog.git",
    "ref": "0123456789abcdef0123456789abcdef01234567",
    "profiles": ["data"],
    "includeSkills": ["work-with-jira"],
    "excludeSkills": ["search-with-felo"]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 3
        [string]$configuration.catalog.repository | Should Be 'https://example.com/acme/catalog.git'
        [string]$configuration.catalog.ref | Should Be '0123456789abcdef0123456789abcdef01234567'
        @($configuration.catalog.profiles) | Should Be @('data')
        @($configuration.catalog.includeSkills) | Should Be @('work-with-jira')
        @($configuration.catalog.excludeSkills) | Should Be @('search-with-felo')
    }

    # Scenario: An existing schema-v3 configuration still points at a mutable Catalog branch.
    # Purpose: Fail closed before replacing a working hook or runtime with an unpinned production entrypoint.
    It 'InterT37_rejects_a_mutable_schema_v3_catalog_ref_before_installation_changes' {
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $runtimeMarker = Join-Path $codexHome 'hooks\ai-instructions-runtime\keep.marker'
        Set-TestText -Path $installedHookScript -Value '# keep this hook'
        Set-TestText -Path $runtimeMarker -Value '# keep runtime'
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 3,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": [],
  "catalog": {
    "repository": "https://example.com/acme/catalog.git",
    "ref": "main",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  }
}
'@

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'catalog.ref must be a full lowercase 40-character commit SHA'
        (Get-Content -Raw -LiteralPath $installedHookScript) | Should Be '# keep this hook'
        (Get-Content -Raw -LiteralPath $runtimeMarker) | Should Be '# keep runtime'
    }

    # Scenario: The existing configuration declares a future unsupported schema.
    # Purpose: Fail closed before replacing a working hook or runtime with incompatible state.
    It 'InterT40_rejects_unknown_configuration_schema_before_installation_changes' {
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $runtimeMarker = Join-Path $codexHome 'hooks\ai-instructions-runtime\keep.marker'
        Set-TestText -Path $installedHookScript -Value '# keep this hook'
        Set-TestText -Path $runtimeMarker -Value '# keep runtime'
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 99,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": []
}
'@

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome)
        $output = & powershell.exe @arguments 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'Unsupported AI instruction sync configuration schemaVersion'
        (Get-Content -Raw -LiteralPath $installedHookScript) | Should Be '# keep this hook'
        (Get-Content -Raw -LiteralPath $runtimeMarker) | Should Be '# keep runtime'
    }
}
