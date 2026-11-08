$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:CleanupScript = Join-Path $script:RepositoryRoot 'scripts\cleanup-ai-instructions-pollution.ps1'
$script:ManifestRelativePath = '.codex/ai-instructions.manifest.json'
$script:TestPowerShellExecutable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' } })

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
    param([Parameter(Mandatory = $true)][string] $TargetRoot,[switch] $Authorize,[string] $GitExecutable)
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:CleanupScript,'-TargetRoot',$TargetRoot)
    if ($Authorize) { $arguments += '-Authorize' }
    if (-not [string]::IsNullOrWhiteSpace($GitExecutable)) { $arguments += @('-GitExecutable',$GitExecutable) }
    $output = & $script:TestPowerShellExecutable @arguments 2>&1
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

    # Scenario: A manifest owns a tracked CRLF license copy beside a product-owned root LICENSE.
    # Purpose: Use byte hashes for license cleanup and retain product files and local delivery bytes.
    It 'InterT15_cleans_tracked_license_delivery_using_raw_hashes' {
        $targetRoot = Join-Path $TestDrive 'licensed-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('config','core.autocrlf','false') | Out-Null
        $relative = '.codex/ai-instructions-licenses/source/LICENSE'
        $path = Join-Path $targetRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [IO.File]::WriteAllText($path,"source license`r`n")
        Set-CleanupTestText -Path (Join-Path $targetRoot 'LICENSE') -Value 'Product license'
        $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $entry = $manifest.files[0] | ConvertTo-Json | ConvertFrom-Json
        $entry.artifactId='codex-licensing'; $entry.sourcePath='LICENSE'; $entry.targetPath=$relative
        $entry.sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        $manifest.files=@($manifest.files)+@($entry)
        Set-CleanupTestText -Path $manifestPath -Value ($manifest | ConvertTo-Json -Depth 10)
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--',$relative,$script:ManifestRelativePath,'LICENSE') | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','license fixture') | Out-Null
        $result=Invoke-CleanupScript -TargetRoot $targetRoot -Authorize
        $result.ExitCode | Should Be 0
        (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() | Should Be $entry.sha256
        $deleted=@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only','--diff-filter=D'))
        ($deleted -contains $relative) | Should Be $true
        ($deleted -contains 'LICENSE') | Should Be $false
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

    # Scenario: The caller exports an alternate Git index before authorizing cleanup.
    # Purpose: Fail before reading ownership or mutating either index, shared excludes, or local materialization.
    It 'InterT25_rejects_an_ambient_alternate_Git_index_before_mutation' {
        $targetRoot = Join-Path $TestDrive 'alternate-index'
        New-PollutedTestRepository -Path $targetRoot
        $productIndexPath = ((Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index')) | Select-Object -First 1).Trim()
        if (-not [System.IO.Path]::IsPathRooted($productIndexPath)) { $productIndexPath = Join-Path $targetRoot $productIndexPath }
        $productIndexPath = [System.IO.Path]::GetFullPath($productIndexPath)
        $alternateIndexPath = Join-Path $targetRoot 'alternate.index'
        [System.IO.File]::Copy($productIndexPath,$alternateIndexPath,$false)
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        $productIndexBefore = (Get-FileHash -LiteralPath $productIndexPath -Algorithm SHA256).Hash
        $alternateIndexBefore = (Get-FileHash -LiteralPath $alternateIndexPath -Algorithm SHA256).Hash
        $excludeBefore = [System.IO.File]::ReadAllBytes($excludePath)
        $agentBefore = [System.IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'))
        $manifestBefore = [System.IO.File]::ReadAllBytes((Join-Path $targetRoot $script:ManifestRelativePath))
        $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
        $priorAlternateIndex = $env:GIT_INDEX_FILE
        try {
            $env:GIT_INDEX_FILE = $alternateIndexPath
            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize
        }
        finally {
            if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
            else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        }

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'unset GIT_INDEX_FILE'
        (Get-FileHash -LiteralPath $productIndexPath -Algorithm SHA256).Hash | Should Be $productIndexBefore
        (Get-FileHash -LiteralPath $alternateIndexPath -Algorithm SHA256).Hash | Should Be $alternateIndexBefore
        [System.IO.File]::ReadAllBytes($excludePath) | Should Be $excludeBefore
        [System.IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')) | Should Be $agentBefore
        [System.IO.File]::ReadAllBytes((Join-Path $targetRoot $script:ManifestRelativePath)) | Should Be $manifestBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
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

    # Scenario: Manifest-proven pollution includes a Unicode-named file in a recursively managed Skill.
    # Purpose: Keep tracked Skill payload and index entries intact while staging only Instructions pollution deletions.
    It 'InterT62_protects_a_tracked_manifest_owned_Unicode_Skill_resource' {
        $targetRoot = Join-Path $TestDrive 'unicode-skill-pollution'
        New-PollutedTestRepository -Path $targetRoot
        $skillRoot = Join-Path $targetRoot '.agents\skills\unicode-skill'
        $unicodeFileName = ([string][char]0x8AAA) + ([string][char]0x660E) + '.md'
        $unicodeRelativePath = '.agents/skills/unicode-skill/' + $unicodeFileName
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        $skillFiles = @(
            [pscustomobject]@{ RelativePath='.agents/skills/unicode-skill/SKILL.md'; FullPath=(Join-Path $skillRoot 'SKILL.md'); Content='# Unicode Skill' },
            [pscustomobject]@{ RelativePath=$unicodeRelativePath; FullPath=(Join-Path $skillRoot $unicodeFileName); Content='# Unicode path content' }
        )
        foreach ($skillFile in $skillFiles) { Set-CleanupTestText -Path $skillFile.FullPath -Value $skillFile.Content }
        $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        $skillEntries = @(
            foreach ($skillFile in $skillFiles) {
                [ordered]@{
                    artifactType='skill'; artifactId='unicode-skill'; sourceId='test-skills';
                    sourceRepository='https://example.com/test-skills.git'; sourceRef=('b' * 40);
                    sourceCommit=('b' * 40); sourceVersion='commit@bbbbbbbb'; sourcePath=$skillFile.RelativePath;
                    targetPath=$skillFile.RelativePath; sha256=(Get-FileHash -LiteralPath $skillFile.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
        $manifest.files = @($manifest.files) + $skillEntries
        Set-CleanupTestText -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments (@('add','--',$script:ManifestRelativePath) + @($skillFiles.RelativePath)) | Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','add unicode skill pollution') | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Be 0
        $skillDeletion = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('-c','core.quotePath=false','diff','--cached','--name-status','--','.agents/skills/unicode-skill/SKILL.md'))
        $unicodeDeletion = @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('-c','core.quotePath=false','diff','--cached','--name-status','--',$unicodeRelativePath))
        $skillDeletion.Count | Should Be 0
        $unicodeDeletion.Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $skillRoot $unicodeFileName) -PathType Leaf | Should Be $true
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

    # Scenario: An external process already has the shared exclude file open for writing when cleanup reaches its exclude update.
    # Purpose: Stop before index mutation instead of using an unlocked read-modify-write sequence that can lose user rules.
    It 'InterT79_fails_closed_when_the_shared_exclude_write_handle_is_unavailable' {
        $targetRoot = Join-Path $TestDrive 'locked-exclude'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        $excludeBefore = [System.IO.File]::ReadAllBytes($excludePath)
        $excludeLock = [System.IO.File]::Open($excludePath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
        try {
            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize
        }
        finally {
            $excludeLock.Dispose()
        }

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'exclusive shared Git exclude mutation handle'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($excludePath)) | Should Be ([Convert]::ToBase64String($excludeBefore))
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md') -PathType Leaf | Should Be $true
    }

    # Scenario: The shared Git info directory is a junction to a location outside the repository metadata.
    # Purpose: Stop before cleanup writes shared exclusions through a reparse-backed parent.
    It 'InterT71_rejects_a_reparse_backed_shared_Git_info_directory' {
        $targetRoot = Join-Path $TestDrive 'reparse-git-info'
        New-PollutedTestRepository -Path $targetRoot
        $gitInfoPath = Join-Path $targetRoot '.git\info'
        $outsideInfoPath = Join-Path $TestDrive 'outside-cleanup-git-info'
        Move-Item -LiteralPath $gitInfoPath -Destination $outsideInfoPath
        $outsideExcludePath = Join-Path $outsideInfoPath 'exclude'
        $outsideBytesBefore = [System.IO.File]::ReadAllBytes($outsideExcludePath)
        New-Item -ItemType Junction -Path $gitInfoPath -Target $outsideInfoPath | Out-Null

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match '(?is)unsafe shared Git exclude mutation path.*non-reparse'
        [System.IO.File]::ReadAllBytes($outsideExcludePath) | Should Be $outsideBytesBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
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

    # Scenario: Git retains a prunable linked worktree record whose local manifest is schema-v4.
    # Purpose: Ignore stale records consistently during optimistic, locked, and shared-exclude cleanup scans.
    It 'InterT69f_ignores_a_prunable_linked_worktree_v4_manifest_in_all_cleanup_scans' {
        $targetRoot = Join-Path $TestDrive 'prunable-v4-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $linkedRoot = Join-Path $TestDrive 'prunable-v4-cleanup-worktree'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','prunable-v4-cleanup-fixture',$linkedRoot) | Out-Null
        try {
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestRelativePath
            $linkedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $linkedManifestPath | ConvertFrom-Json
            $linkedManifest.schemaVersion = 4
            $linkedManifest.files[0].targetPath = 'stale-prunable-cleanup-only.md'
            Set-CleanupTestText -Path $linkedManifestPath -Value (($linkedManifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
            Remove-Item -LiteralPath (Join-Path $linkedRoot '.git') -Force

            (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','list','--porcelain')) -join "`n") | Should Match 'prunable'
            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

            $result.ExitCode | Should Be 0
            $excludePath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
            (Get-Content -Raw -LiteralPath $excludePath) | Should Not Match ([regex]::Escape('stale-prunable-cleanup-only.md'))
        }
        finally {
            Remove-Item -LiteralPath $linkedRoot -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','prune') | Out-Null
        }
    }

    # Scenario: The optimistic worktree inventory succeeds, but the strict inventory under the cleanup lock fails.
    # Purpose: Fail closed before cleanup changes the index, shared exclusions, or managed bytes.
    It 'InterT69a_fails_closed_when_the_locked_worktree_inventory_fails' {
        $targetRoot = Join-Path $TestDrive 'locked-worktree-list-failure'
        New-PollutedTestRepository -Path $targetRoot
        $wrapperRoot = Join-Path $TestDrive 'cleanup-locked-worktree-list-failure-wrapper'
        New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $firstListMarker = Join-Path $wrapperRoot 'first-list.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"worktree list --porcelain" >nul
if errorlevel 1 goto forward
if exist "$firstListMarker" exit /b 91
type nul > "$firstListMarker"
:forward
"$realGit" %*
"@
        Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper
        $indexPath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index') | Select-Object -First 1).Trim()
        if (-not [IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $targetRoot $indexPath }
        $excludePath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
        if (-not [IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
        $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
        $indexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
        $excludeBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
        $manifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))
        $agentBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')))

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Cannot determine linked worktree manifests before mutation\.'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) | Should Be $indexBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should Be $excludeBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath)) | Should Be $manifestBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'))) | Should Be $agentBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
    }

    # Scenario: A linked worktree publishes v4 after cleanup's optimistic scan and before its locked scan.
    # Purpose: Recheck projection ownership under the repository lock before staging remediation.
    It 'InterT69b_detects_linked_v4_published_before_the_locked_scan' {
        $targetRoot = Join-Path $TestDrive 'linked-v4-race-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-v4-race-cleanup-worktree'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','cleanup-linked-v4-race-fixture',$linkedRoot) | Out-Null
        try {
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestRelativePath
            $v4ManifestPath = Join-Path $TestDrive 'cleanup-linked-v4-race.json'
            $v4Manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $linkedManifestPath | ConvertFrom-Json
            $v4Manifest.schemaVersion = 4
            Set-CleanupTestText -Path $v4ManifestPath -Value (($v4Manifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
            $wrapperRoot = Join-Path $TestDrive 'cleanup-locked-v4-publication-wrapper'
            New-Item -ItemType Directory -Force -Path $wrapperRoot | Out-Null
            $realGit = (Get-Command git.exe).Source
            $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
            $firstListMarker = Join-Path $wrapperRoot 'first-list.marker'
            $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
            $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"worktree list --porcelain" >nul
if errorlevel 1 goto forward
if not exist "$firstListMarker" (
  type nul > "$firstListMarker"
  goto forward
)
copy /y "$v4ManifestPath" "$linkedManifestPath" >nul
if errorlevel 1 exit /b 92
:forward
"$realGit" %*
"@
            Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper
            $indexPath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $targetRoot $indexPath }
            $excludePath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
            $indexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
            $excludeBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
            $agentBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')))
            $headBefore = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()

            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match '(?s)managed manifest.*(?:missing|unsupported)'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) | Should Be $indexBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should Be $excludeBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'))) | Should Be $agentBefore
            (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim() | Should Be $headBefore
            @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        }
        finally {
            Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: A linked worktree has a syntactically invalid manifest during authorized cleanup.
    # Purpose: Fail under the cleanup lock before the index, shared excludes, or managed bytes can change.
    It 'InterT69c_fails_closed_when_a_linked_worktree_manifest_is_not_valid_json' {
        $targetRoot = Join-Path $TestDrive 'linked-malformed-manifest-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $linkedRoot = Join-Path $TestDrive 'linked-malformed-manifest-cleanup-worktree'
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','cleanup-linked-malformed-manifest-fixture',$linkedRoot) | Out-Null
        try {
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestRelativePath
            Set-CleanupTestText -Path $linkedManifestPath -Value '{ malformed json'
            $indexPath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $targetRoot $indexPath }
            $excludePath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
            $indexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
            $excludeBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
            $manifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot $script:ManifestRelativePath)))
            $agentBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')))
            $linkedManifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedManifestPath))
            $headBefore = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()

            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'Cannot inspect linked worktree manifest before mutation'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) | Should Be $indexBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should Be $excludeBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot $script:ManifestRelativePath))) | Should Be $manifestBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'))) | Should Be $agentBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedManifestPath)) | Should Be $linkedManifestBefore
            (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim() | Should Be $headBefore
            @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        }
        finally {
            Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: Git reports a linked worktree whose path contains non-ASCII characters without C quoting under -z.
    # Purpose: Inspect the real linked path and reject its v4 manifest before cleanup mutates bytes or the index.
    It 'InterT69d_rejects_v4_in_a_non_ascii_linked_worktree_path_before_mutation' {
        $targetRoot = Join-Path $TestDrive 'unicode-linked-v4-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $unicodeWorktreeName = ([string][char]0x5DE5) + ([string][char]0x4F5C) + ([string][char]0x6A39) + '-' + ([string][char]0x00FC) + '-cleanup'
        $linkedRoot = Join-Path $TestDrive $unicodeWorktreeName
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','add','--quiet','-b','cleanup-linked-unicode-v4-fixture',$linkedRoot) | Out-Null
        try {
            $linkedManifestPath = Join-Path $linkedRoot $script:ManifestRelativePath
            $linkedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $linkedManifestPath | ConvertFrom-Json
            $linkedManifest.schemaVersion = 4
            Set-CleanupTestText -Path $linkedManifestPath -Value (($linkedManifest | ConvertTo-Json -Depth 10).Replace("`r`n","`n").TrimEnd())
            $indexPath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $targetRoot $indexPath }
            $excludePath = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
            if (-not [IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $targetRoot $excludePath }
            $manifestPath = Join-Path $targetRoot $script:ManifestRelativePath
            $indexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
            $excludeBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
            $manifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))
            $linkedManifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedManifestPath))
            $headBefore = (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()

            $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match '(?s)managed manifest.*(?:missing|unsupported)'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) | Should Be $indexBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should Be $excludeBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath)) | Should Be $manifestBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedManifestPath)) | Should Be $linkedManifestBefore
            (Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim() | Should Be $headBefore
            @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        }
        finally {
            Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('worktree','remove','--force',$linkedRoot) | Out-Null
        }
    }

    # Scenario: Strict cleanup inspection reaches an existing manifest but its path safety check fails with I/O.
    # Purpose: Propagate non-reparse inspection errors instead of treating the manifest as absent.
    It 'InterT69e_fails_closed_when_strict_manifest_path_safety_throws_io' {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:CleanupScript,[ref]$tokens,[ref]$parseErrors)
        foreach ($functionName in @('Get-CleanupWorktreeRoots','Assert-CleanupManagedFilePath','Assert-NoRepoManagedManifestV4')) {
            $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName },$true))[0]
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:manifestRelativePath = $script:ManifestRelativePath
        $fixtureRoot = Join-Path $TestDrive 'strict-cleanup-io'
        New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot '.codex') | Out-Null
        Set-CleanupTestText -Path (Join-Path $fixtureRoot $script:ManifestRelativePath) -Value '{}'
        Mock Get-CleanupWorktreeRoots { @($fixtureRoot) }
        Mock Assert-CleanupManagedFilePath { throw [System.IO.IOException]::new('Injected manifest inspection I/O failure.') }
        $message = $null

        try { Assert-NoRepoManagedManifestV4 -Repository $fixtureRoot -Strict }
        catch { $message = $_.Exception.Message }

        if ([string]::IsNullOrWhiteSpace($message)) { throw 'Expected strict linked-manifest inspection to fail.' }
        $message.Contains('Cannot inspect linked worktree manifest before mutation') | Should Be $true
        $message.Contains('Injected manifest inspection I/O failure.') | Should Be $true
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
    It 'InterT72_rejects_a_malformed_managed_exclude_block' {
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
    It 'InterT74_rejects_a_reparse_backed_managed_manifest_path' {
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

    # Scenario: Another Git process stages user bytes for a managed path after cleanup removes its original index entry and a later check fails.
    # Purpose: Restore only entries still absent because of this transaction and never reset a concurrent user's staged blob to HEAD.
    It 'InterT76_preserves_concurrent_staged_bytes_when_cleanup_rolls_back' {
        $targetRoot = Join-Path $TestDrive 'concurrent-index-rollback'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        $excludeBefore = [System.IO.File]::ReadAllBytes($excludePath)
        $wrapperRoot = Join-Path $TestDrive 'cleanup-git-wrapper'
        New-Item -ItemType Directory -Path $wrapperRoot | Out-Null
        $userBlobFile = Join-Path $wrapperRoot 'user-agent.txt'
        Set-CleanupTestText -Path $userBlobFile -Value '# Concurrent user staged Agent'
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $markerPath = Join-Path $wrapperRoot 'injected.marker'
        $hashPath = Join-Path $wrapperRoot 'blob.txt'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"diff --cached --name-status -- AGENTS.md" >nul
if errorlevel 1 goto forward
if exist "$markerPath" goto forward
type nul > "$markerPath"
"$realGit" -C "$targetRoot" hash-object -w "$userBlobFile" > "$hashPath"
if errorlevel 1 exit /b 86
set /p userblob=<"$hashPath"
"$realGit" -C "$targetRoot" update-index --add --cacheinfo 100644,%userblob%,AGENTS.md
if errorlevel 1 exit /b 87
exit /b 88
:forward
"$realGit" %*
"@
        Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper
        $expectedBlob = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('hash-object',$userBlobFile)) -join '').Trim()

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

        $result.ExitCode | Should Not Be 0
        Test-Path -LiteralPath $markerPath | Should Be $true
        ((@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--verify',':AGENTS.md')) -join '').Trim()) |
            Should Be $expectedBlob
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only','--',$script:ManifestRelativePath)).Count |
            Should Be 0
        [System.IO.File]::ReadAllBytes($excludePath) | Should Be $excludeBefore
    }

    # Scenario: Another Git process attempts to stage a managed blob after rollback has read the current index but before it restores entries.
    # Purpose: Hold the real index lock across rollback comparison and replacement so no successful concurrent stage can be overwritten.
    It 'InterT78_holds_the_index_lock_across_rollback_compare_and_restore' {
        $targetRoot = Join-Path $TestDrive 'atomic-index-rollback'
        New-PollutedTestRepository -Path $targetRoot
        $originalBlob = ((@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--verify',':AGENTS.md')) -join '').Trim())
        $wrapperRoot = Join-Path $TestDrive 'cleanup-atomic-rollback-wrapper'
        New-Item -ItemType Directory -Path $wrapperRoot | Out-Null
        $userBlobFile = Join-Path $wrapperRoot 'user-agent.txt'
        Set-CleanupTestText -Path $userBlobFile -Value '# Rollback race user blob'
        $userBlob = ((@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('hash-object','-w',$userBlobFile)) -join '').Trim())
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $rollbackMarker = Join-Path $wrapperRoot 'rollback.marker'
        $attemptedMarker = Join-Path $wrapperRoot 'attempted.marker'
        $blockedMarker = Join-Path $wrapperRoot 'blocked.marker'
        $succeededMarker = Join-Path $wrapperRoot 'succeeded.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
if not exist "$rollbackMarker" goto inspect_failure
echo %* | "$findString" /C:"ls-files --stage" >nul
if errorlevel 1 goto forward
if exist "$attemptedMarker" goto forward
"$realGit" %*
set forwardcode=%errorlevel%
type nul > "$attemptedMarker"
"$realGit" -C "$targetRoot" update-index --add --cacheinfo 100644,$userBlob,AGENTS.md >nul 2>&1
if errorlevel 1 (type nul > "$blockedMarker") else (type nul > "$succeededMarker")
exit /b %forwardcode%
:inspect_failure
echo %* | "$findString" /C:"diff --cached --name-status -- AGENTS.md" >nul
if errorlevel 1 goto forward
type nul > "$rollbackMarker"
exit /b 88
:forward
"$realGit" %*
exit /b %errorlevel%
"@
        Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

        $result.ExitCode | Should Not Be 0
        Test-Path -LiteralPath $attemptedMarker | Should Be $true
        Test-Path -LiteralPath $blockedMarker | Should Be $true
        Test-Path -LiteralPath $succeededMarker | Should Be $false
        ((@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--verify',':AGENTS.md')) -join '').Trim()) |
            Should Be $originalBlob
    }

    # Scenario: Another Git process stages user bytes immediately after cleanup's final managed-entry snapshot but before index mutation.
    # Purpose: Acquire the real Git index lock and recheck expected entries so cleanup cannot replace a last-moment staged blob with deletion.
    It 'InterT77_rejects_last_moment_index_drift_before_atomic_cleanup_mutation' {
        $targetRoot = Join-Path $TestDrive 'last-moment-index-drift'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        $excludeBefore = [System.IO.File]::ReadAllBytes($excludePath)
        $wrapperRoot = Join-Path $TestDrive 'cleanup-last-moment-wrapper'
        New-Item -ItemType Directory -Path $wrapperRoot | Out-Null
        $userBlobFile = Join-Path $wrapperRoot 'user-agent.txt'
        Set-CleanupTestText -Path $userBlobFile -Value '# Last-moment concurrent staged Agent'
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $injectedMarker = Join-Path $wrapperRoot 'injected.marker'
        $hashPath = Join-Path $wrapperRoot 'blob.txt'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"rev-parse --git-path index" >nul
if not errorlevel 1 goto inject_after_forward
echo %* | "$findString" /C:"rm --cached" >nul
if errorlevel 1 goto forward
if exist "$injectedMarker" goto forward
goto inject_before_forward
:inject_after_forward
"$realGit" %*
if errorlevel 1 exit /b %errorlevel%
if exist "$injectedMarker" exit /b 0
:inject_before_forward
"$realGit" -C "$targetRoot" hash-object -w "$userBlobFile" > "$hashPath"
if errorlevel 1 exit /b 86
set /p userblob=<"$hashPath"
"$realGit" -C "$targetRoot" update-index --add --cacheinfo 100644,%userblob%,AGENTS.md
if errorlevel 1 exit /b 87
copy /Y "$userBlobFile" "$targetRoot\AGENTS.md" >nul
if errorlevel 1 exit /b 88
type nul > "$injectedMarker"
echo %* | "$findString" /C:"rev-parse --git-path index" >nul
if not errorlevel 1 exit /b 0
:forward
"$realGit" %*
exit /b %errorlevel%
"@
        Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper
        $expectedBlob = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('hash-object',$userBlobFile)) -join '').Trim()

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

        $result.ExitCode | Should Not Be 0
        Test-Path -LiteralPath $injectedMarker | Should Be $true
        ((@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--verify',':AGENTS.md')) -join '').Trim()) |
            Should Be $expectedBlob
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Last-moment concurrent staged Agent'
        [System.IO.File]::ReadAllBytes($excludePath) | Should Be $excludeBefore
    }

    # Scenario: An external process appends a user rule after cleanup writes its managed block and a later index step fails.
    # Purpose: Roll back the index but preserve externally changed exclude bytes instead of overwriting them with the old snapshot.
    It 'InterT80_preserves_concurrent_shared_exclude_bytes_when_cleanup_rolls_back' {
        $targetRoot = Join-Path $TestDrive 'concurrent-exclude-rollback'
        New-PollutedTestRepository -Path $targetRoot
        $excludePath = Join-Path $targetRoot '.git\info\exclude'
        $excludeTextBefore = [System.IO.File]::ReadAllText($excludePath)
        $indexPath = (@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('rev-parse','--git-path','index')) -join '').Trim()
        if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $targetRoot $indexPath }
        $indexHashBefore = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        $wrapperRoot = Join-Path $TestDrive 'cleanup-concurrent-exclude-wrapper'
        New-Item -ItemType Directory -Path $wrapperRoot | Out-Null
        $realGit = (Get-Command git.exe).Source
        $findString = Join-Path $env:SystemRoot 'System32\findstr.exe'
        $injectedMarker = Join-Path $wrapperRoot 'injected.marker'
        $gitWrapperPath = Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper = @"
@echo off
echo %* | "$findString" /C:"rev-parse --git-path index" >nul
if errorlevel 1 goto forward
if exist "$injectedMarker" goto forward
type nul > "$injectedMarker"
echo /concurrent-user-rule>>"$excludePath"
exit /b 86
:forward
"$realGit" %*
exit /b %errorlevel%
"@
        Set-CleanupTestText -Path $gitWrapperPath -Value $gitWrapper

        $result = Invoke-CleanupScript -TargetRoot $targetRoot -Authorize -GitExecutable $gitWrapperPath

        $result.ExitCode | Should Not Be 0
        Test-Path -LiteralPath $injectedMarker | Should Be $true
        $result.Output | Should Match '(?is)rollback also failed.*shared Git exclude changed concurrently'
        (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash | Should Be $indexHashBefore
        @(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only')).Count | Should Be 0
        $excludeAfter = [System.IO.File]::ReadAllText($excludePath)
        $excludeAfter | Should Match '/concurrent-user-rule'
        $excludeAfter | Should Match '# BEGIN Codex AI Instructions managed paths'
        $excludeAfter | Should Match ([regex]::Escape(($excludeTextBefore -split "`r?`n")[0]))
    }

    # Scenario: A valid v4 manifest owns tracked Codex base plus Claude Rule and license artifacts.
    # Purpose: Revalidate v4 ownership, clean every precise tracked target, preserve local bytes, and avoid treating Claude Skills as cleanup scope.
    It 'InterT81_cleans_valid_v4_Claude_rule_and_license_ownership' {
        $targetRoot=Join-Path $TestDrive 'v4-claude-cleanup'
        New-PollutedTestRepository -Path $targetRoot
        $ruleRelative='.claude/AI-Rules/Testing.en.md'
        $licenseRelative='.claude/ai-instructions-licenses/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/delivery.json'
        $rulePath=Join-Path $targetRoot $ruleRelative
        $licensePath=Join-Path $targetRoot $licenseRelative
        Set-CleanupTestText -Path $rulePath -Value '# Managed Claude rule'
        Set-CleanupTestText -Path $licensePath -Value '{"schemaVersion":1}'
        $manifestPath=Join-Path $targetRoot $script:ManifestRelativePath
        $legacy=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $renderer='e'*64
        $codex=$legacy.files[0]
        $codex|Add-Member -NotePropertyName host -NotePropertyValue codex
        $codex|Add-Member -NotePropertyName rendererId -NotePropertyValue build-ai-instructions
        $codex|Add-Member -NotePropertyName rendererSha256 -NotePropertyValue $renderer
        $claudeRule=($codex|ConvertTo-Json -Depth 10|ConvertFrom-Json)
        $claudeRule.artifactId='claude-rule-testing';$claudeRule.host='claude';$claudeRule.sourcePath='.claude/AI-Rules/Testing.en.md';$claudeRule.targetPath=$ruleRelative
        $claudeRule.sha256=(Get-FileHash -LiteralPath $rulePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $claudeLicense=($codex|ConvertTo-Json -Depth 10|ConvertFrom-Json)
        $claudeLicense.artifactId='claude-licensing';$claudeLicense.host='claude';$claudeLicense.sourcePath='.ai-instructions-generated/delivery.json';$claudeLicense.targetPath=$licenseRelative
        $claudeLicense.sha256=(Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[ordered]@{
            schemaVersion=4;catalogId=[string]$legacy.catalogId;lockSha256=[string]$legacy.lockSha256
            projectionContractSha256=('f'*64);generation=1;projections=@();files=@($codex,$claudeRule,$claudeLicense)
        }
        Set-CleanupTestText -Path $manifestPath -Value (($manifest|ConvertTo-Json -Depth 20).Replace("`r`n","`n").TrimEnd())
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('add','--',$ruleRelative,$licenseRelative,$script:ManifestRelativePath)|Out-Null
        Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','v4 Claude pollution fixture')|Out-Null
        $ruleBefore=[IO.File]::ReadAllBytes($rulePath);$licenseBefore=[IO.File]::ReadAllBytes($licensePath)

        $result=Invoke-CleanupScript -TargetRoot $targetRoot -Authorize
        $result.ExitCode|Should Be 0
        $deleted=@(Invoke-CleanupTestGit -Repository $targetRoot -Arguments @('diff','--cached','--name-only','--diff-filter=D'))
        foreach($relative in @('AGENTS.md',$script:ManifestRelativePath,$ruleRelative,$licenseRelative)){($deleted-contains$relative)|Should Be $true}
        [IO.File]::ReadAllBytes($rulePath)|Should Be $ruleBefore
        [IO.File]::ReadAllBytes($licensePath)|Should Be $licenseBefore
        ($deleted|Where-Object{$_-like'.claude/skills/*'}).Count|Should Be 0
    }
}
