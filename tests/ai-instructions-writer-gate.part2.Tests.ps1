. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions writer and reader gate' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e'
        New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:V3Candidate=Join-Path $script:ExternalRoot 'src'
        New-P7eV3Candidate -Destination $script:V3Candidate
        $script:BaseV3Home=Join-Path $script:ExternalRoot 'v3'
        $install=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $script:BaseV3Home -WriterSchema V3V5
        if($install.ExitCode-ne0){throw "P7e v3 fixture install failed: $($install.Output)"}
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}


    # Scenario: The immutable source advances, removes one Claude Rule, and moves license payloads to a new sourceCommit namespace.
    # Purpose: Delete obsolete Claude Rule/license paths, update the v4 manifest, and remove only their exact exclude entries.
    It 'InterT118_reconciles_Claude_rule_license_and_exclude_cleanup' {
        $root=Join-Path $script:ExternalRoot 'p9b-claude-cleanup';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -OmitClaudeDatabase
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $oldRule=Join-Path $target '.claude/AI-Rules/Database.en.md'
        $oldLicenseRoot=Join-Path $target '.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc'
        Test-Path -LiteralPath $oldRule -PathType Leaf|Should Be $true
        Test-Path -LiteralPath $oldLicenseRoot -PathType Container|Should Be $true
        $context=New-P9bBootstrapContext -Root $root -InstructionCommit ('d'*40)

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        Test-Path -LiteralPath $oldRule|Should Be $false
        @(Get-ChildItem -LiteralPath $oldLicenseRoot -File -Recurse -ErrorAction SilentlyContinue).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target '.claude/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/delivery.json') -PathType Leaf|Should Be $true
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        @($manifest.files|Where-Object{[string]$_.targetPath-ceq'.claude/AI-Rules/Database.en.md'-or[string]$_.targetPath-like'.claude/ai-instructions-licenses/cccc*'}).Count|Should Be 0
        $exclude=[IO.File]::ReadAllText((Join-Path $target '.git/info/exclude'))
        $exclude|Should Not Match '(?m)^/\.claude/AI-Rules/Database\.en\.md$'
        $exclude|Should Not Match '(?m)^/\.claude/ai-instructions-licenses/cccc'
        $exclude|Should Match '(?m)^/\.claude/ai-instructions-licenses/dddd'
    }

    # Scenario: A manifest-owned CLAUDE.md becomes project-owned while its shared base exclude and older Claude Rule and license excludes still exist.
    # Purpose: Preserve obsolete Claude Rules and licenses while removing the base exclude so project-owned CLAUDE.md bytes remain visible.
    It 'InterT119_preserves_obsolete_Claude_entries_after_the_base_becomes_project_owned' {
        $root=Join-Path $script:ExternalRoot 'p9b-owned-obsolete';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -OmitClaudeDatabase
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $claudePath=Join-Path $target 'CLAUDE.md'
        [IO.File]::AppendAllText($claudePath,"project ownership`n",[Text.UTF8Encoding]::new($false))
        $claudeBytes=[IO.File]::ReadAllBytes($claudePath)
        $claudeFamily=Get-P7eTreeSnapshot (Join-Path $target '.claude')
        $excludePath=Join-Path $target '.git/info/exclude'
        $claudeExcludeBefore=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-eq'/CLAUDE.md'-or$_-like'/.claude/AI-Rules/*'-or$_-like'/.claude/ai-instructions-licenses/*'}|Sort-Object)
        $oldRule='.claude/AI-Rules/Database.en.md'
        $oldLicense='.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/delivery.json'
        $context=New-P9bBootstrapContext -Root $root -InstructionCommit ('d'*40)

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $result.Output|Should Match 'claude-base-skipped-project-owned'
        [IO.File]::ReadAllBytes($claudePath)|Should Be $claudeBytes
        (Get-P7eTreeSnapshot (Join-Path $target '.claude'))|Should Be $claudeFamily
        Test-Path -LiteralPath (Join-Path $target $oldRule) -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $target $oldLicense) -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $target '.claude/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/delivery.json')|Should Be $false
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        @($manifest.files|Where-Object{[string]$_.targetPath-in@($oldRule,$oldLicense)}).Count|Should Be 2
        $claudeExcludeAfter=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-eq'/CLAUDE.md'-or$_-like'/.claude/AI-Rules/*'-or$_-like'/.claude/ai-instructions-licenses/*'}|Sort-Object)
        $expectedClaudeExcludeAfter=@($claudeExcludeBefore|Where-Object{$_-ne'/CLAUDE.md'})
        $claudeExcludeAfter|Should Be $expectedClaudeExcludeAfter
        [IO.File]::ReadAllText($excludePath)|Should Not Match '(?m)^/CLAUDE\.md\r?$'
        [IO.File]::ReadAllText($excludePath)|Should Match '(?m)^/\.codex/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/'
        [IO.File]::ReadAllText($excludePath)|Should Not Match '(?m)^/\.codex/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/'
        ([IO.File]::ReadAllText((Join-Path $target 'AGENTS.md')))|Should Match '<!-- changed -->'
    }

    # Scenario: A customized retained instruction is carried from an existing v4 manifest while the source renderer changes.
    # Purpose: Preserve the retained entry's host, renderer ID, and renderer hash instead of attributing old bytes to the current renderer.
    It 'InterT120_preserves_renderer_provenance_for_a_retained_v4_instruction' {
        $root=Join-Path $script:ExternalRoot 'p9b-retained-renderer';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline -RendererMarker renderer-a
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -RendererMarker renderer-b
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retained=@($manifest.files|Where-Object targetPath -eq $retainedTarget)[0]
        $retained.rendererId='retained-renderer'
        $retained.rendererSha256='1'*64
        Set-P9bJson -Path $manifestPath -Document $manifest
        [IO.File]::AppendAllText((Join-Path $target $retainedTarget),"project customization`n",[Text.UTF8Encoding]::new($false))

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $updated=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $entry=@($updated.files|Where-Object targetPath -eq $retainedTarget)[0]
        [string]$entry.host|Should Be codex
        [string]$entry.rendererId|Should Be retained-renderer
        [string]$entry.rendererSha256|Should Be ('1'*64)
        @($updated.files|Where-Object{[string]$_.targetPath-ne$retainedTarget-and[string]$_.rendererSha256-eq$changed.RendererSha256}).Count|Should BeGreaterThan 0
    }

    # Scenario: A schema-v1 Skill entry remains after its REPO payload was already removed without staged or tracked residue.
    # Purpose: Treat the absent payload as a completed migration and let the projection-aware writer emit a complete v4 instruction manifest.
    It 'InterT121_advances_to_v4_after_a_legacy_Skill_payload_was_already_migrated' {
        $root=Join-Path $script:ExternalRoot 'p9b-v1-skill-migrated';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $skillRelative='.agents/skills/legacy-skill/SKILL.md'
        Set-P9bJson -Path (Join-Path $target '.codex/ai-instructions.manifest.json') -Document ([ordered]@{
            schemaVersion=1;sourceRepository='https://example.com/legacy-ai-instructions.git';sourceRef='legacy-pin'
            files=@([ordered]@{sourcePath=$skillRelative;targetPath=$skillRelative;sha256=('a'*64)})
        })

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        @($manifest.files|Where-Object{[string]$_.targetPath-like'.agents/skills/*'}).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target $skillRelative)|Should Be $false
        [IO.File]::ReadAllText((Join-Path $target '.git/info/exclude'))|Should Not Match '(?m)^/\.agents/skills/'
    }

    # Scenario: A schema-v1 Skill payload is still present, or its tracked payload is missing with a pending worktree deletion.
    # Purpose: Preserve both legacy ownership forms with a typed refusal before any REPO byte, index, HEAD, status, or exclude mutation.
    It 'InterT122_refuses_v4_while_legacy_Skill_ownership_must_be_retained_for_<Case>' -TestCases @(
        @{Case='untracked-present';TrackedMissing=$false},
        @{Case='tracked-missing';TrackedMissing=$true}
    ) {
        param($Case,$TrackedMissing)
        $root=Join-Path $script:ExternalRoot ("p9b-v1-skill-retained-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $skillRelative='.agents/skills/legacy-skill/SKILL.md'
        $skillPath=Join-Path $target $skillRelative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath)|Out-Null
        [IO.File]::WriteAllText($skillPath,"# Legacy Skill`n",[Text.UTF8Encoding]::new($false))
        $skillHash=(Get-FileHash -LiteralPath $skillPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($TrackedMissing){
            & git -C $target add -- $skillRelative
            & git -C $target commit --quiet -m 'track legacy Skill payload'
            Remove-Item -LiteralPath $skillPath -Force
        }
        Set-P9bJson -Path (Join-Path $target '.codex/ai-instructions.manifest.json') -Document ([ordered]@{
            schemaVersion=1;sourceRepository='https://example.com/legacy-ai-instructions.git';sourceRef='legacy-pin'
            files=@([ordered]@{sourcePath=$skillRelative;targetPath=$skillRelative;sha256=$skillHash})
        })
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'cannot replace retained legacy REPO Skill ownership'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A customized v2 entry or staged v3 entry is retained byte-for-byte during its one legacy-to-v4 conversion.
    # Purpose: Record an explicit legacy retention sentinel instead of attributing unrendered bytes to the current renderer.
    It 'InterT123_marks_retained_<Case>_legacy_instruction_with_unrendered_sentinel' -TestCases @(
        @{Case='customized-v2';SchemaVersion=2;TargetPath='.codex/AI-Rules/CodeReview.en.md';Staged=$false},
        @{Case='staged-v3';SchemaVersion=3;TargetPath='CLAUDE.md';Staged=$true}
    ) {
        param($Case,$SchemaVersion,$TargetPath,$Staged)
        $root=Join-Path $script:ExternalRoot ("p9b-legacy-retained-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip') -RendererMarker renderer-a
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion $SchemaVersion
        $targetFullPath=Join-Path $target $TargetPath
        [IO.File]::AppendAllText($targetFullPath,"retained $Case`n",[Text.UTF8Encoding]::new($false))
        $retainedBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetFullPath))
        if($Staged){& git -C $target add --force -- $TargetPath;if($LASTEXITCODE-ne0){throw "Could not stage $TargetPath."}}

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetFullPath))|Should Be $retainedBytes
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        $entry=@($manifest.files|Where-Object targetPath -eq $TargetPath)[0]
        [string]$entry.retention|Should Be legacy-preserved
        [string]$entry.rendererId|Should Be legacy-unrendered
        ($null-eq$entry.rendererSha256)|Should Be $true
        [string]$entry.host|Should Be $(if($TargetPath-ceq'CLAUDE.md'){'claude'}else{'codex'})
        if($Staged){(@(& git -C $target diff --cached --name-only -- $TargetPath)-join'')|Should Be $TargetPath}
    }

    # Scenario: A valid v4 sentinel entry remains customized while a later v4 run uses different renderer bytes.
    # Purpose: Preserve the original sentinel and never mint or replace retention provenance during v4-to-v4 reconciliation.
    It 'InterT124_preserves_an_existing_v4_unrendered_sentinel' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-sentinel-preserved';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -RendererMarker renderer-a
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -RendererMarker renderer-b
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 2
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retainedPath=Join-Path $target $retainedTarget
        [IO.File]::AppendAllText($retainedPath,"legacy customization`n",[Text.UTF8Encoding]::new($false))
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($retainedPath))

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($retainedPath))|Should Be $before
        $entry=@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object targetPath -eq $retainedTarget)[0]
        [string]$entry.retention|Should Be legacy-preserved
        [string]$entry.rendererId|Should Be legacy-unrendered
        ($null-eq$entry.rendererSha256)|Should Be $true
    }

    # Scenario: A sentinel entry's current bytes are restored to the desired render output before the next v4 run.
    # Purpose: Replace the legacy sentinel with verifiable renderer provenance as soon as normal reconciliation can own the bytes.
    It 'InterT125_replaces_sentinel_after_normal_rewrite_eligibility_returns' {
        $root=Join-Path $script:ExternalRoot 'p9b-sentinel-rewritten';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip') -RendererMarker renderer-a
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 3
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retainedPath=Join-Path $target $retainedTarget
        [IO.File]::AppendAllText($retainedPath,"legacy customization`n",[Text.UTF8Encoding]::new($false))
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        Copy-Item -LiteralPath (Join-Path $source.SourceRoot $retainedTarget) -Destination $retainedPath -Force

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        $entry=@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object targetPath -eq $retainedTarget)[0]
        @($entry.PSObject.Properties.Name)|Should Not Contain retention
        [string]$entry.rendererId|Should Be build-ai-instructions
        [string]$entry.rendererSha256|Should Be $source.RendererSha256
    }

    # Scenario: A retained legacy instruction uses a case-variant target that the legacy reader accepted but no exact v4 host owns.
    # Purpose: Return a typed refusal without mutation instead of guessing a host and manufacturing v4 ownership metadata.
    It 'InterT126_fails_closed_when_legacy_instruction_host_cannot_be_determined' {
        $root=Join-Path $script:ExternalRoot 'p9b-legacy-host-unknown';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 2
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $legacyBase=@($manifest.files|Where-Object targetPath -ceq 'AGENTS.md')[0]
        $legacyBase.targetPath='agents.md'
        Set-P9bJson -Path $manifestPath -Document $manifest
        [IO.File]::AppendAllText((Join-Path $target 'AGENTS.md'),"legacy customization`n",[Text.UTF8Encoding]::new($false))
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'Cannot determine exactly one instruction host'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A repository first writes v4 under one verified Catalog/Lock pair, then a newly installed v3/v5 runtime carries an updated valid Lock.
    # Purpose: Accept the old manifest as historical ownership, bind the next manifest to current verified context, increment once, and remain idempotent.
    It 'InterT127_advances_existing_v4_to_a_new_verified_Lock_idempotently' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-lock-advance';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $initialContext=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $initialContext -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 1

        $updatedCandidate=Join-Path $root 'updated-source';New-P7eV3Candidate -Destination $updatedCandidate
        $updatedLockPath=Join-Path $updatedCandidate 'catalog/skills-catalog-lock.json'
        $updatedLock=Get-Content -Raw -LiteralPath $updatedLockPath|ConvertFrom-Json
        $updatedLock.sources[0].requestedRef='v1.0.1'
        $updatedLock.sources[0].resolvedCommit='9'*40
        $updatedLock.sources[0].resolvedVersion='1.0.1'
        $updatedLock.sources[0].archiveSha256='8'*64
        foreach($skill in @($updatedLock.skills)){$skill.contentSha256='7'*64}
        Set-P9bJson -Path $updatedLockPath -Document $updatedLock
        $updatedHome=Join-Path $root 'updated-home'
        $install=Invoke-P7eInstaller -SourceRoot $updatedCandidate -CodexHome $updatedHome -WriterSchema V3V5
        $install.ExitCode|Should Be 0
        $updatedContext=New-P9bBootstrapContext -Root $root -CodexHome $updatedHome
        $updatedContext.LockSha256|Should Not Be $initialContext.LockSha256

        $advanced=Invoke-P9bRepoBootstrap -Context $updatedContext -ArchivePath $source.ArchivePath -TargetRoot $target
        $advanced.ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        [string]$manifest.lockSha256|Should Be $updatedContext.LockSha256
        [string]$manifest.projectionContractSha256|Should Be $updatedContext.ProjectionContractSha256
        $before=Get-P9bRepoSnapshot $target

        $repeat=Invoke-P9bRepoBootstrap -Context $updatedContext -ArchivePath $source.ArchivePath -TargetRoot $target
        $repeat.ExitCode|Should Be 0
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 2
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Worktree A synchronizes after worktree B acquires a tracked or untracked project-owned CLAUDE.md while A retains a tracked managed Claude Rule.
    # Purpose: Use A-only ownership for remediation and repository-wide ownership for shared exclusions without disabling A's fan-out or touching B's bytes and index.
    It 'InterT128_fans_out_A_while_linked_B_owns_<Ownership>_CLAUDE' -TestCases @(
        @{Ownership='tracked'},
        @{Ownership='untracked'}
    ) {
        param($Ownership)
        $root=Join-Path $script:ExternalRoot "p9b-linked-Claude-$Ownership";New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'worktree-a';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $linkedRoot=Join-Path $root 'worktree-b'
        & git -C $target worktree add --quiet -b "linked-Claude-$Ownership" $linkedRoot
        $LASTEXITCODE|Should Be 0
        try{
            $linkedClaude=Join-Path $linkedRoot 'CLAUDE.md'
            [IO.File]::WriteAllText($linkedClaude,"project-owned $Ownership Claude`n",[Text.UTF8Encoding]::new($false))
            if($Ownership-ceq'tracked'){
                & git -C $linkedRoot add -f -- CLAUDE.md
                & git -C $linkedRoot commit --quiet -m 'track project Claude base'
                $LASTEXITCODE|Should Be 0
            }
            $linkedBytes=[IO.File]::ReadAllBytes($linkedClaude)
            $managedRule='.claude/AI-Rules/Testing.en.md'
            & git -C $target add -f -- $managedRule
            & git -C $target commit --quiet -m 'tracked managed Claude rule fixture'
            $LASTEXITCODE|Should Be 0

            $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

            $result.ExitCode|Should Be 0
            $result.Output|Should Not Match 'Tracked reserved Agent artifacts remain after controlled remediation'
            Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md')|Should Be $true
            Test-Path -LiteralPath (Join-Path $target $managedRule)|Should Be $true
            $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
            @($manifest.files|Where-Object{[string]$_.targetPath-ceq'CLAUDE.md'}).Count|Should Be 1
            [IO.File]::ReadAllBytes($linkedClaude)|Should Be $linkedBytes
            (@(& git -C $linkedRoot diff --cached --name-only -- CLAUDE.md)-join'')|Should BeNullOrEmpty
            $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
            if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
            [IO.File]::ReadAllText($excludePath)|Should Not Match '(?m)^/CLAUDE\.md$'
            if($Ownership-ceq'untracked'){
                (@(& git -C $linkedRoot status --porcelain=v1 --untracked-files=all -- CLAUDE.md)-join"`n")|Should Match '^\?\? CLAUDE\.md$'
            }
        }
        finally{& git -C $target worktree remove --force $linkedRoot|Out-Null}
    }

    # Scenario: Worktree A tracks a manifest-owned Claude Rule while linked worktree B tracks its own Claude base and Rule.
    # Purpose: Remediate A using only A's ownership decision while preserving B's bytes and omitting repository-wide Claude paths from the shared exclude.
    It 'InterT129_remediates_A_without_mutating_linked_B_project_Claude_files' {
        $root=Join-Path $script:ExternalRoot 'p9b-active-remediation-linked-Claude';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'worktree-a';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $linkedRoot=Join-Path $root 'worktree-b'
        & git -C $target worktree add --quiet -b linked-Claude-active-remediation $linkedRoot
        $LASTEXITCODE|Should Be 0
        try{
            $linkedClaude=Join-Path $linkedRoot 'CLAUDE.md'
            $linkedRule=Join-Path $linkedRoot '.claude/AI-Rules/Project.en.md'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $linkedRule)|Out-Null
            [IO.File]::WriteAllText($linkedClaude,"# Project Claude base`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($linkedRule,"# Project Claude rule`n",[Text.UTF8Encoding]::new($false))
            & git -C $linkedRoot add -f -- CLAUDE.md .claude/AI-Rules/Project.en.md
            & git -C $linkedRoot commit --quiet -m 'track project Claude family'
            $LASTEXITCODE|Should Be 0
            $linkedClaudeBytes=[IO.File]::ReadAllBytes($linkedClaude)
            $linkedRuleBytes=[IO.File]::ReadAllBytes($linkedRule)
            $managedRule='.claude/AI-Rules/Testing.en.md'
            & git -C $target add -f -- $managedRule
            & git -C $target commit --quiet -m 'track managed Claude rule in A'
            $LASTEXITCODE|Should Be 0

            $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

            $result.ExitCode|Should Be 0
            Test-Path -LiteralPath (Join-Path $target $managedRule)|Should Be $true
            (@(& git -C $target ls-files -- $managedRule)-join'')|Should BeNullOrEmpty
            [IO.File]::ReadAllBytes($linkedClaude)|Should Be $linkedClaudeBytes
            [IO.File]::ReadAllBytes($linkedRule)|Should Be $linkedRuleBytes
            (@(& git -C $linkedRoot status --porcelain=v1 --untracked-files=all)-join"`n")|Should BeNullOrEmpty
            $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
            if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
            $exclude=[IO.File]::ReadAllText($excludePath)
            $exclude|Should Not Match '(?m)^/CLAUDE\.md$'
            $exclude|Should Not Match '(?m)^/\.claude/'
        }
        finally{& git -C $target worktree remove --force $linkedRoot|Out-Null}
    }

    # Scenario: Syntactically valid source provenance disagrees with the verified routing envelope or runtime Lock identity.
    # Purpose: Return closure-invalid with the mismatched field name before worktree, manifest, or shared-exclude mutation.
    It 'InterT130_refuses_provenance_<Field>_mismatch_before_REPO_mutation' -TestCases @(
        @{Field='catalogId';Value='different-catalog'},
        @{Field='lockSha256';Value=('f'*64)}
    ) {
        param($Field,$Value)
        $root=Join-Path $script:ExternalRoot "p9b-provenance-mismatch-$Field";New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $provenance=Get-Content -Raw -LiteralPath $context.ProvenancePath|ConvertFrom-Json
        $provenance.$Field=$Value
        Set-P9bJson -Path $context.ProvenancePath -Document $provenance
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match ([regex]::Escape($Field))
        (Get-P9bRepoSnapshot $target)|Should Be $before
        Test-Path -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|Should Be $false
    }

    if($IsWindows){
    # Scenario: PersonalAgent finalization fails after a project-owned Claude family caused repository-wide protected exclude prefixes to be computed.
    # Purpose: Restore the complete original exclude bytes, including unrelated Codex and Copilot lines, instead of treating protected prefixes as managed paths.
    It 'InterT131_restores_complete_exclude_bytes_after_PersonalAgent_failure_with_Claude_protection' {
        $root=Join-Path $script:ExternalRoot 'p9b-protected-exclude-rollback';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        [IO.File]::WriteAllText((Join-Path $target 'CLAUDE.md'),"# Project-owned Claude`n",[Text.UTF8Encoding]::new($false))
        $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
        $originalExclude="# personal prefix`r`n# BEGIN Codex AI Instructions managed paths`r`n/AGENTS.md`r`n/.github/copilot-instructions.md`r`n# END Codex AI Instructions managed paths`r`n"
        [IO.File]::WriteAllText($excludePath,$originalExclude,[Text.UTF8Encoding]::new($false))
        $excludeBefore=[IO.File]::ReadAllBytes($excludePath)
        $wrapperRoot=Join-Path $root 'git-wrapper';New-Item -ItemType Directory -Path $wrapperRoot|Out-Null
        $realGit=(Get-Command git.exe).Source
        $findString=Join-Path $env:SystemRoot 'System32/findstr.exe'
        $appliedExcludePath=Join-Path $wrapperRoot 'exclude-after-mutation.bin'
        $gitWrapperPath=Join-Path $wrapperRoot 'git.cmd'
        $gitWrapper=@"
@echo off
echo %* | "$findString" /C:"stash store" >nul
if errorlevel 1 goto forward
copy /b "$excludePath" "$appliedExcludePath" >nul
if errorlevel 1 exit /b 85
exit /b 86
:forward
"$realGit" %*
exit /b %errorlevel%
"@
        [IO.File]::WriteAllText($gitWrapperPath,$gitWrapper,[Text.UTF8Encoding]::new($false))

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target -GitExecutable $gitWrapperPath

        $result.ExitCode|Should Not Be 0
        $result.Output|Should Match 'stash store'
        Test-Path -LiteralPath $appliedExcludePath -PathType Leaf|Should Be $true
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($appliedExcludePath))|Should Not Be ([Convert]::ToBase64String($excludeBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be ([Convert]::ToBase64String($excludeBefore))
        $restoredExclude=[IO.File]::ReadAllText($excludePath).Replace("`r`n","`n").Replace("`r","`n")
        $restoredExclude|Should Match '(?m)^/AGENTS\.md$'
        $restoredExclude|Should Match '(?m)^/\.github/copilot-instructions\.md$'
        Test-Path -LiteralPath (Join-Path $target 'AGENTS.md')|Should Be $false
        Test-Path -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|Should Be $false
        [IO.File]::ReadAllText((Join-Path $target 'CLAUDE.md'))|Should Be "# Project-owned Claude`n"
    }
    }

    # Scenario: Primary worktree A and linked worktree B first retain unmodified managed CLAUDE.md files, then B customizes its managed base.
    # Purpose: Keep the shared base exclude while every worktree is managed, then remove it repository-wide without changing B's project-owned bytes.
    It 'InterT132_reconciles_shared_CLAUDE_exclude_across_managed_and_project_owned_worktrees' {
        $root=Join-Path $script:ExternalRoot 'p9b-linked-Claude-exclude-transition';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'worktree-a';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $linkedRoot=Join-Path $root 'worktree-b'
        & git -C $target worktree add --quiet -b linked-Claude-exclude-transition $linkedRoot
        $LASTEXITCODE|Should Be 0
        try{
            (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $linkedRoot).ExitCode|Should Be 0
            $managedResult=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
            $managedResult.ExitCode|Should Be 0

            $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
            if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
            [IO.File]::ReadAllText($excludePath)|Should Match '(?m)^/CLAUDE\.md\r?$'
            foreach($worktree in @($target,$linkedRoot)){
                $manifest=Get-Content -Raw -LiteralPath (Join-Path $worktree '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
                $entry=@($manifest.files|Where-Object{[string]$_.targetPath-ceq'CLAUDE.md'})[0]
                $entry|Should Not BeNullOrEmpty
                (Get-FileHash -LiteralPath (Join-Path $worktree 'CLAUDE.md') -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$entry.sha256)
            }

            $linkedClaude=Join-Path $linkedRoot 'CLAUDE.md'
            [IO.File]::AppendAllText($linkedClaude,"project-owned linked worktree Claude`n",[Text.UTF8Encoding]::new($false))
            $linkedClaudeBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedClaude))
            $projectOwnedResult=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

            $projectOwnedResult.ExitCode|Should Be 0
            [IO.File]::ReadAllText($excludePath)|Should Not Match '(?m)^/CLAUDE\.md\r?$'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkedClaude))|Should Be $linkedClaudeBytes
        }
        finally{& git -C $target worktree remove --force $linkedRoot|Out-Null}
    }

    # Scenario: The stable launcher has opened a verified closure file with its read-only sharing contract.
    # Purpose: Bind verified bytes through import/inventory assertion by denying concurrent writes and deletion until disposal.
    It 'UnitT95_holds_launcher_closure_bytes_against_write_and_delete' {
        $launcherPath=Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-installed.ps1'
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($launcherPath,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $definition=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Open-TrustedRuntimeFileLease'},$true))[0]
        $definition|Should Not BeNullOrEmpty
        Invoke-Expression $definition.Extent.Text
        $path=Join-Path $script:ExternalRoot 'ai-instructions-runtime-contract.psm1';Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Destination $path
        $lease=Open-TrustedRuntimeFileLease -Path $path
        try{
            { $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose() }|Should Throw
            { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }|Should Throw
        }
        finally{$lease.Dispose()}
        { [IO.File]::AppendAllText($path,"# released`n",[Text.UTF8Encoding]::new($false)) }|Should Not Throw
    }
}
