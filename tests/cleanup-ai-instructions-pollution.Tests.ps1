$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:CleanupScript = Join-Path $script:RepositoryRoot 'scripts\cleanup-ai-instructions-pollution.ps1'
$script:ManifestRelativePath = '.codex/ai-instructions.manifest.json'

function Invoke-CleanupTestGit {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Set-CleanupTestText {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, "$Value`n", (New-Object System.Text.UTF8Encoding($false)))
}

function New-PollutedTestRepository {
    param([Parameter(Mandatory = $true)][string] $Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-CleanupTestGit -Repository $Path -Arguments @('init','--quiet') | Out-Null
    Invoke-CleanupTestGit -Repository $Path -Arguments @('config','user.name','Cleanup Test') | Out-Null
    Invoke-CleanupTestGit -Repository $Path -Arguments @('config','user.email','cleanup@example.test') | Out-Null
    Invoke-CleanupTestGit -Repository $Path -Arguments @('remote','add','origin','https://example.com/team/product.git') | Out-Null
    Set-CleanupTestText -Path (Join-Path $Path 'README.md') -Value '# Product'
    Set-CleanupTestText -Path (Join-Path $Path 'AGENTS.md') -Value '# Managed Agent'
    $agentHash = (Get-FileHash -LiteralPath (Join-Path $Path 'AGENTS.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schemaVersion = 2
        catalogId = 'test-catalog'
        lockSha256 = ('a' * 64)
        files = @([ordered]@{
            artifactType='instruction'; artifactId='codex-base'; sourceId='ai-instructions';
            sourceRepository='https://github.com/example/ai-instructions.git'; sourceRef=('b' * 40);
            sourceCommit=('b' * 40); sourceVersion='commit@bbbbbbbb'; sourcePath='.codex/AGENTS.en.md';
            targetPath='AGENTS.md'; sha256=$agentHash
        })
    }
    Set-CleanupTestText -Path (Join-Path $Path $script:ManifestRelativePath) -Value (($manifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
    Invoke-CleanupTestGit -Repository $Path -Arguments @('add','--','README.md','AGENTS.md',$script:ManifestRelativePath.Replace('\','/')) | Out-Null
    Invoke-CleanupTestGit -Repository $Path -Arguments @('commit','--quiet','-m','polluted repository') | Out-Null
}

function Invoke-CleanupScript {
    param([Parameter(Mandatory = $true)][string] $TargetRoot,[switch] $Authorize)
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:CleanupScript,'-TargetRoot',$TargetRoot)
    if ($Authorize) { $arguments += '-Authorize' }
    $output = & powershell.exe @arguments 2>&1
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($output -join [Environment]::NewLine) }
}

Describe 'tracked AI instructions pollution cleanup' {
    # Scenario: Pollution is inspected without explicit cleanup authorization.
    # Purpose: Keep bootstrap and inspection read-only until the user authorizes index mutation.
    It 'InterT10_requires_explicit_authorization_before_git_index_changes' {
        $targetRoot = Join-Path $TestDrive 'unauthorized'
        New-PollutedTestRepository -Path $targetRoot
        $headBefore = Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')

        $result = Invoke-CleanupScript -TargetRoot $targetRoot

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'explicit authorization'
        (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Should Be $headBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: The user explicitly authorizes cleanup of manifest-proven tracked files.
    # Purpose: Stage only index deletions, preserve local bytes, add local ignores, and never commit or push.
    It 'InterT20_stages_precise_deletions_and_preserves_local_materialization' {
        $targetRoot = Join-Path $TestDrive 'authorized'
        New-PollutedTestRepository -Path $targetRoot
        $headBefore = Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')
        $agentBefore = [System.IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'))

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Should Be $headBefore
        $stagedChanges = @((Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-status')) | Sort-Object)
        $stagedChanges.Count | Should Be 2
        ($stagedChanges -contains "D`t.codex/ai-instructions.manifest.json") | Should Be $true
        ($stagedChanges -contains "D`tAGENTS.md") | Should Be $true
        [System.IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')) | Should Be $agentBefore
        Test-Path -LiteralPath (Join-Path $targetRoot $script:ManifestRelativePath) | Should Be $true
        $excludePath = ((Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
        if (-not [System.IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
        $exclude = Get-Content -Raw -LiteralPath $excludePath
        $exclude | Should Match '(?m)^/AGENTS\.md$'
        $exclude | Should Match '(?m)^/\.codex/ai-instructions\.manifest\.json$'
    }

    # Scenario: A managed pollution path already has an intentional staged change.
    # Purpose: Avoid replacing or masking user work in the Git index.
    It 'InterT30_refuses_cleanup_when_a_managed_path_is_already_staged' {
        $targetRoot = Join-Path $TestDrive 'staged'
        New-PollutedTestRepository -Path $targetRoot
        Set-CleanupTestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# User staged change'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--','AGENTS.md') | Out-Null
        $statusBefore = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join "`n"

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'staged'
        (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('status','--porcelain')) -join "`n") | Should Be $statusBefore
    }

    # Scenario: A tracked file no longer matches the manifest ownership hash.
    # Purpose: Preserve customized or ownership-ambiguous content and fail closed.
    It 'InterT40_refuses_cleanup_for_customized_or_unowned_content' {
        $targetRoot = Join-Path $TestDrive 'customized'
        New-PollutedTestRepository -Path $targetRoot
        Set-CleanupTestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Customized local content'

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'ownership|customized|hash'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: The cleanup command is run against the canonical Instructions source repository shape.
    # Purpose: Ensure product-repository cleanup can never remove the source repository's own tracked contract files.
    It 'InterT50_refuses_the_canonical_instructions_source_repository' {
        $targetRoot = Join-Path $TestDrive 'source-repository'
        New-PollutedTestRepository -Path $targetRoot
        Set-CleanupTestText -Path (Join-Path $targetRoot '.codex\AGENTS.en.md') -Value '# Source Codex'
        Set-CleanupTestText -Path (Join-Path $targetRoot '.github\copilot-instructions.en.md') -Value '# Source Copilot'

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'source repository'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: The product repository tracks its own Agent Skill outside the personal manifest.
    # Purpose: Remove only manifest-proven pollution and never treat a syntactically similar project asset as owned.
    It 'InterT60_preserves_a_repository_owned_tracked_agent_skill' {
        $targetRoot = Join-Path $TestDrive 'project-skill'
        New-PollutedTestRepository -Path $targetRoot
        Set-CleanupTestText -Path (Join-Path $targetRoot '.agents\skills\project-skill\SKILL.md') -Value '# Project-owned Skill'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--','.agents/skills/project-skill/SKILL.md') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','add project skill') | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('ls-files','--','.agents/skills/project-skill/SKILL.md')).Count | Should Be 1
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.agents\skills\project-skill\SKILL.md')).Trim() | Should Be '# Project-owned Skill'
        (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')) -contains '.agents/skills/project-skill/SKILL.md') | Should Be $false
    }
}
