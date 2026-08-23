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

    # Scenario: A committed schema-v2 manifest labels the Codex base as a Skill without a matching flat Skill path.
    # Purpose: Refuse cleanup when the manifest cannot satisfy the shared ownership contract.
    It 'InterT42_rejects_schema_invalid_manifest_ownership_evidence' {
        $targetRoot = Join-Path $TestDrive 'invalid-manifest'
        New-PollutedTestRepository -Path $targetRoot
        $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        $manifest.files[0].artifactType = 'skill'
        Set-CleanupTestText -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--',$script:ManifestRelativePath) | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','invalid manifest fixture') | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Managed Skill.*must preserve the flat'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('ls-files','--','AGENTS.md')).Count | Should Be 1
    }

    # Scenario: HEAD and the index contain product-owned bytes while the working tree is replaced with manifest-owned bytes.
    # Purpose: Prove ownership from the Git index itself before staging a deletion, not merely from the local materialization.
    It 'InterT45_refuses_cleanup_when_the_index_blob_is_not_manifest_owned' {
        $targetRoot = Join-Path $TestDrive 'unowned-index'
        New-PollutedTestRepository -Path $targetRoot
        Set-CleanupTestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Product-owned instructions'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--','AGENTS.md') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','product owns instructions') | Out-Null
        Set-CleanupTestText -Path (Join-Path $targetRoot 'AGENTS.md') -Value '# Managed Agent'

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'index|ownership|hash'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: The cleanup command is run against the canonical Instructions origin while one source marker is missing.
    # Purpose: Refuse by repository identity rather than relying only on a complete source-repository file shape.
    It 'InterT50_refuses_the_canonical_instructions_source_repository' {
        $targetRoot = Join-Path $TestDrive 'source-repository'
        New-PollutedTestRepository -Path $targetRoot
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('remote','set-url','origin','git@github.com:SyuanTsai/SyuanTsai-AI-Instructions.git') | Out-Null
        Set-CleanupTestText -Path (Join-Path $targetRoot '.codex\AGENTS.en.md') -Value '# Source Codex'

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'source repository'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: A legacy schema-v1 manifest and its managed bytes were committed by an older runtime.
    # Purpose: Provide the same explicit, hash-proven cleanup path for legacy pollution without first mutating the tracked manifest.
    It 'InterT52_cleans_manifest_proven_schema_v1_pollution' {
        $targetRoot = Join-Path $TestDrive 'legacy-v1-pollution'
        New-PollutedTestRepository -Path $targetRoot
        $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
        $manifestV2 = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        $manifestV1 = [ordered]@{
            schemaVersion = 1
            sourceRepository = 'https://github.com/example/catalog.git'
            sourceRef = 'main'
            files = @(
                foreach ($entry in @($manifestV2.files)) {
                    [ordered]@{ sourcePath=[string]$entry.sourcePath; targetPath=[string]$entry.targetPath; sha256=[string]$entry.sha256 }
                }
            )
        }
        Set-CleanupTestText -Path $manifestPath -Value (($manifestV1 | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--',$script:ManifestRelativePath) | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','legacy manifest pollution') | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        $stagedChanges = @((Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-status')) | Sort-Object)
        ($stagedChanges -contains "D`tAGENTS.md") | Should Be $true
        ($stagedChanges -contains "D`t.codex/ai-instructions.manifest.json") | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -PathType Leaf | Should Be $true
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

    # Scenario: The index spelling of a manifest-owned path differs only by case on an ignore-case repository.
    # Purpose: Stage the actual polluted index entry while preserving the canonical local materialization.
    It 'InterT65_cleans_the_actual_case_variant_index_path' {
        $targetRoot = Join-Path $TestDrive 'case-variant'
        New-PollutedTestRepository -Path $targetRoot
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('config','core.ignorecase','true') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('mv','-f','AGENTS.md','agent-case-temporary.md') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('mv','-f','agent-case-temporary.md','agents.md') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','case-variant pollution') | Out-Null
        $canonicalPath = Join-Path $targetRoot 'AGENTS.md'
        $caseVariantPath = Join-Path $targetRoot 'agents.md'
        if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
            Copy-Item -LiteralPath $caseVariantPath -Destination $canonicalPath
        }
        $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        $stagedChanges = @((Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-status')) | Sort-Object)
        ($stagedChanges -contains "D`tagents.md") | Should Be $true
        ($stagedChanges -contains "D`t.codex/ai-instructions.manifest.json") | Should Be $true
        [System.IO.File]::ReadAllBytes($canonicalPath) | Should Be $canonicalBytes
    }

    # Scenario: A repository imported from a case-sensitive system has both case aliases in the index.
    # Purpose: Remove every colliding pollution entry instead of collapsing them during cleanup path de-duplication.
    It 'InterT67_cleans_all_case_colliding_index_entries' {
        $targetRoot = Join-Path $TestDrive 'case-collision'
        New-PollutedTestRepository -Path $targetRoot
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('config','core.ignorecase','true') | Out-Null
        $blob = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('hash-object','AGENTS.md')) -join '').Trim()
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('update-index','--add','--cacheinfo',"100644,$blob,agents.md") | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','dual case pollution') | Out-Null
        $trackedBefore = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('ls-files'))
        ($trackedBefore -ccontains 'AGENTS.md') | Should Be $true
        ($trackedBefore -ccontains 'agents.md') | Should Be $true

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        $remaining = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('ls-files'))
        ($remaining -ccontains 'AGENTS.md') | Should Be $false
        ($remaining -ccontains 'agents.md') | Should Be $false
        $stagedChanges = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-status'))
        ($stagedChanges -ccontains "D`tAGENTS.md") | Should Be $true
        ($stagedChanges -ccontains "D`tagents.md") | Should Be $true
    }

    # Scenario: The shared Git exclude path is occupied by an unrelated directory when cleanup is authorized.
    # Purpose: Preserve that filesystem entry and stop before staging any pollution deletion.
    It 'InterT68_rejects_an_unsafe_shared_Git_exclude_mutation_path' {
        $targetRoot = Join-Path $TestDrive 'unsafe-exclude'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude')) -join '').Trim()
        if (-not [System.IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
        Remove-Item -LiteralPath $excludePath -Force
        New-Item -ItemType Directory -Path $excludePath | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'unsafe shared Git exclude mutation path'
        Test-Path -LiteralPath $excludePath -PathType Container | Should Be $true
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -PathType Leaf | Should Be $true
    }

    # Scenario: A linked worktree manifest contains an unsupported schema-v2 property during authorized cleanup.
    # Purpose: Stop before index mutation instead of letting invalid ownership evidence alter shared local ignores.
    It 'InterT69_rejects_a_schema_invalid_linked_worktree_manifest_before_cleanup' {
        $targetRoot = Join-Path $TestDrive 'linked-invalid-manifest'
        New-PollutedTestRepository -Path $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-invalid-manifest-worktree'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','cleanup-linked-invalid-fixture',$linkedRoot) | Out-Null
        try {
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestRelativePath
            $linkedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $linkedManifestPath | ConvertFrom-Json
            $linkedManifest | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
            Set-CleanupTestText -Path $linkedManifestPath -Value (($linkedManifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())

            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match '(?s)linked worktree manifest.*unsupported property.*unexpected'
            @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        }
        finally {
            Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: Bootstrap or another cleanup process holds the shared repository runtime lock.
    # Purpose: Prevent cleanup index changes from interleaving with stash, manifest, or exclude transactions.
    It 'InterT70_refuses_cleanup_while_the_repository_runtime_lock_is_held' {
        $targetRoot = Join-Path $TestDrive 'concurrent-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $commonGitDirectory = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-common-dir')) -join '').Trim()
        if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $targetRoot $commonGitDirectory }
        $runtimeLockPath = Join-Path ([System.IO.Path]::GetFullPath($commonGitDirectory)) 'codex-ai-instructions.lock'
        $lockStream = [System.IO.File]::Open($runtimeLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize
        }
        finally {
            $lockStream.Dispose()
        }

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'another AI instruction repository operation is already running'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: The shared exclude file contains a begin marker without its matching end marker.
    # Purpose: Stop before index mutation instead of creating duplicate or ambiguous managed ignore blocks.
    It 'InterT68b_rejects_a_malformed_managed_exclude_block' {
        $targetRoot = Join-Path $TestDrive 'malformed-exclude-block'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        Set-CleanupTestText -Path $excludePath -Value "# user rule`n# BEGIN Codex AI Instructions managed paths`n/old-agent.md"
        $excludeBefore = Get-Content -Raw -LiteralPath $excludePath

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'managed exclude block.*malformed'
        (Get-Content -Raw -LiteralPath $excludePath) | Should Be $excludeBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: A managed manifest is reached through a directory junction after the polluted commit was created.
    # Purpose: Treat reparse-backed ownership evidence as unsafe and stop before touching the Git index.
    It 'InterT68c_rejects_a_reparse_backed_managed_manifest_path' {
        $targetRoot = Join-Path $TestDrive 'reparse-manifest'
        New-PollutedTestRepository -Path $targetRoot
        $codexPath = Join-Path $targetRoot '.codex'
        $externalCodexPath = Join-Path $TestDrive 'reparse-manifest-content'
        Move-Item -LiteralPath $codexPath -Destination $externalCodexPath
        New-Item -ItemType Junction -Path $codexPath -Target $externalCodexPath | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'reparse point'
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $externalCodexPath 'ai-instructions.manifest.json') -PathType Leaf | Should Be $true
    }
}
