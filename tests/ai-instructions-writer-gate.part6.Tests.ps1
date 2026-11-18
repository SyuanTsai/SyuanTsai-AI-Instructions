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

    # Scenario: Production explicitly requests V3V5 while the production Catalog remains v2.
    # Purpose: Enforce D4 before Codex Home staging, lock, journal, or any other target mutation.

    # Scenario: A previously verified unchanged project Skill is edited immediately before a changed manifest would be published.
    # Purpose: Recompute its raw-byte SHA-256 inside the project transaction, refuse publication, and roll back every owned mutation.
    It 'InterT134_refuses_project_Skill_drift_rechecked_before_manifest_publication' {
        $root=Join-Path $script:ExternalRoot 'p9c-pre-manifest-drift';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $fixture=New-P9cProjectFixture -Root $root -ProjectionIds @('project-agents')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $skillPath=[string]@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object{[string]$_.artifactType-ceq'skill'-and[string]$_.targetPath-like'*/SKILL.md'}|Select-Object -First 1 -ExpandProperty targetPath)[0]
        $skillFullPath=Join-Path $target $skillPath
        $beforeSnapshot=Get-P9bRepoSnapshot $target
        $manifestBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))
        $skillBytes=[IO.File]::ReadAllBytes($skillFullPath)
        $hookBootstrap=New-P9cPreManifestTamperBootstrap -Root (Join-Path $root 'tamper-runtime') -TargetRelativePath $skillPath

        $result=Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $changed.ArchivePath -TargetRoot $target -BootstrapPath $hookBootstrap

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'final raw-byte verification failed'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))|Should Be $manifestBytes
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($skillFullPath))|Should Be `
            ([Convert]::ToBase64String([byte[]]($skillBytes+[Text.UTF8Encoding]::new($false).GetBytes("concurrent project edit`n"))))
        $afterSnapshot=Get-P9bRepoSnapshot $target
        $skillRowPrefix="$skillPath`t"
        (@($afterSnapshot-split"`n"|Where-Object{-not$_.StartsWith($skillRowPrefix,[StringComparison]::Ordinal)})-join"`n")|Should Be `
            (@($beforeSnapshot-split"`n"|Where-Object{-not$_.StartsWith($skillRowPrefix,[StringComparison]::Ordinal)})-join"`n")
    }

    # Scenario: Recovery observes a fixed journal.stage before first journal publication, beside journal.json, beside journal.prev, or beside both durable journal generations.
    # Purpose: Apply the P7 publication authority order, finish recovery safely, and leave no orphan transaction-private file at any journal interruption point.
    It 'InterT135_recovers_fixed_project_journal_stage_for_<Case>_without_orphans' -TestCases @(
        @{Case='stage-only';Journal=$false;Previous=$false},
        @{Case='stage-and-journal';Journal=$true;Previous=$false},
        @{Case='stage-and-prev';Journal=$false;Previous=$true},
        @{Case='stage-journal-and-prev';Journal=$true;Previous=$true}
    ) {
        param($Case,$Journal,$Previous)
        $root=Join-Path $script:ExternalRoot "p9c-recovery-$Case";New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $fixture=New-P9cProjectFixture -Root $root -ProjectionIds @('project-agents')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $transactionRoot=Get-P9cRepositoryTransactionRoot -Repository $target
        if(-not$Journal-and-not$Previous){
            $transactionId=[guid]::NewGuid().ToString('N');$transactionPath=Join-Path $transactionRoot $transactionId
            New-Item -ItemType Directory -Force -Path $transactionPath|Out-Null
            [IO.File]::WriteAllText((Join-Path $transactionPath 'op-000001.stage'),"unpublished payload`n",[Text.UTF8Encoding]::new($false))
        }else{
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $root 'prepared-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $changed.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should Not Be 0
            $transactions=@(Get-ChildItem -LiteralPath $transactionRoot -Directory -Force);$transactions.Count|Should Be 1
            $transactionPath=$transactions[0].FullName
            if($Previous){Copy-Item -LiteralPath (Join-Path $transactionPath 'journal.json') -Destination (Join-Path $transactionPath 'journal.prev')}
            if(-not$Journal){Remove-Item -LiteralPath (Join-Path $transactionPath 'journal.json') -Force}
        }
        [IO.File]::WriteAllText((Join-Path $transactionPath 'journal.stage'),"interrupted stage`n",[Text.UTF8Encoding]::new($false))

        $result=Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $changed.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        Test-Path -LiteralPath $transactionPath|Should Be $false
        @(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: Shared-exclude reconciliation evaluates multiple Skill files across two live worktrees.
    # Purpose: Cache comparer-aware tracked and staged Git path sets once per worktree instead of repeating repository-wide enumeration per Skill file.
    It 'UnitT136_collects_each_worktree_Git_path_set_once_regardless_of_Skill_file_count' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1'),[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $cacheFunction=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Get-WorktreeGitPathSetCache'},$true))
        $cacheFunction.Count|Should Be 1
        Invoke-Expression $cacheFunction[0].Extent.Text
        $sharedFunction=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Get-SharedManagedExcludePaths'},$true))[0]
        $sharedCalls=@($sharedFunction.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()})
        @($sharedCalls|Where-Object{$_-ceq'Get-WorktreeGitPathSetCache'}).Count|Should Be 1
        @($sharedCalls|Where-Object{$_-ceq'Get-GitListedPathSet'}).Count|Should Be 0
        $counts=@{}
        function Get-GitPathComparer { param([string]$Repository) return [StringComparer]::OrdinalIgnoreCase }
        function Get-GitListedPathSet {
            param([string]$Repository,$Comparer,[string]$Kind)
            $key="$Repository|$Kind";$counts[$key]=1+[int]$counts[$key]
            $set=New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
            foreach($index in 1..12){[void]$set.Add(".agents/skills/skill-$index/SKILL.md")}
            return $set
        }
        $worktrees=@('C:/repo/main','C:/repo/linked')

        $cache=Get-WorktreeGitPathSetCache -WorktreeRoots $worktrees

        $cache.Count|Should Be 2
        foreach($worktree in $worktrees){
            $counts["$worktree|Tracked"]|Should Be 1
            $counts["$worktree|Staged"]|Should Be 1
            $cache[$worktree].Tracked.Count|Should Be 12
            $cache[$worktree].Staged.Count|Should Be 12
        }
    }

    # Scenario: Two selected project Skills conflict while a changed Instructions archive is ready to publish.
    # Purpose: Refuse the entire bootstrap before mutation, enumerate every conflict and remedy, and preserve all Base, Rule, manifest, and shared-exclude bytes.
    It 'InterT137_refuses_all_project_Skill_conflicts_before_any_Instructions_or_repository_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9c-all-conflicts';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $fixture=New-P9cProjectFixture -Root $root -ProjectionIds @('project-agents')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $instructionEntries=@($manifest.files|Where-Object{
            [string]$_.artifactType-ceq'instruction'-and(
                [string]$_.targetPath-cin@('AGENTS.md','.github/copilot-instructions.md','CLAUDE.md')-or
                [string]$_.targetPath-cmatch'^\.(codex|github|claude)/AI-Rules/'
            )
        })
        (@($instructionEntries.host|Sort-Object -Unique)-join',')|Should Be 'claude,codex,copilot'
        $instructionBytes=@{}
        foreach($entry in $instructionEntries){$instructionBytes[[string]$entry.targetPath]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target ([string]$entry.targetPath))))}
        $manifestBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))
        $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
        $excludeBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
        $conflicts=New-Object System.Collections.Generic.List[object]
        foreach($group in @($manifest.files|Where-Object artifactType -ceq skill|Group-Object projectionId,artifactId)){
            $entry=$group.Group[0];$segments=([string]$entry.targetPath).Split('/');$conflictPath=([string]::Join('/',[string[]]$segments[0..2]))+'/local.txt'
            [IO.File]::WriteAllText((Join-Path $target $conflictPath),"project-owned`n",[Text.UTF8Encoding]::new($false))
            $conflicts.Add([pscustomobject]@{SkillId=[string]$entry.artifactId;Projection=[string]$entry.projectionId;Path=$conflictPath})
        }
        $conflicts.Count|Should Be 2

        $result=Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $changed.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        foreach($conflict in $conflicts){
            $diagnosticPattern='(?m)^Project Skill conflict: skillId='+[regex]::Escape($conflict.SkillId)+', projection='+[regex]::Escape($conflict.Projection)+', path='+[regex]::Escape($conflict.Path)+', status=unmanaged, worktree=.+$'
            $result.Output|Should Match $diagnosticPattern
            $result.Output|Should Match ([regex]::Escape("skillId=$($conflict.SkillId)"))
            $result.Output|Should Match ([regex]::Escape("projection=$($conflict.Projection)"))
            $result.Output|Should Match ([regex]::Escape("path=$($conflict.Path)"))
            $result.Output|Should Match 'status=unmanaged'
        }
        $result.Output|Should Match '(?m)^Project Skill conflict resolution: remove or rename the project-owned Skill, or remove that Skill from projections\.project\.\r?$'
        $result.Output|Should Match 'remove that Skill from projections\.project'
        foreach($entry in $instructionEntries){[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target ([string]$entry.targetPath))))|Should Be $instructionBytes[[string]$entry.targetPath]}
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))|Should Be $manifestBytes
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be $excludeBytes
    }

    # Scenario: Each project-owned CLAUDE.md ownership form is crossed with tracked or untracked Claude Rules/licenses, including a linked worktree.
    # Purpose: Skip the complete Claude family, preserve every protected byte and HEAD, avoid remediation commits, and still update other host families.
    It 'InterT114_preserves_project_owned_Claude_family_for_<Case>' -TestCases @(
        @{Case='tracked-base-tracked-rule';Base='tracked';Companion='tracked-rule';Linked=$false},
        @{Case='staged-base-untracked-license';Base='staged';Companion='untracked-license';Linked=$false},
        @{Case='unmanaged-base-tracked-license';Base='unmanaged';Companion='tracked-license';Linked=$false},
        @{Case='manifest-customized-untracked-rule';Base='managed-customized';Companion='untracked-rule';Linked=$false},
        @{Case='manifest-tracked-tracked-rule';Base='managed-tracked';Companion='tracked-rule';Linked=$false},
        @{Case='linked-unmanaged-tracked-license';Base='unmanaged';Companion='tracked-license';Linked=$true}
    ) {
        param($Case,$Base,$Companion,$Linked)
        $root=Join-Path $script:ExternalRoot ("p9b-owned-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $context=New-P9bBootstrapContext -Root $root
        $primary=Join-Path $root 'primary';New-P9bTargetRepository $primary
        $target=$primary
        if($Linked){
            $target=Join-Path $root 'linked'
            & git -C $primary worktree add --quiet -b p9b-linked $target
            if($LASTEXITCODE-ne0){throw 'Could not create linked-worktree fixture.'}
        }
        if($Base-like'managed-*'){
            (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        }
        $rulePath=Join-Path $target '.claude/AI-Rules/Database.en.md'
        $licensePath=Join-Path $target '.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/delivery.json'
        $companionPath=if($Companion-like'*-rule'){$rulePath}else{$licensePath}
        if(-not(Test-Path -LiteralPath $companionPath -PathType Leaf)){
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $companionPath)|Out-Null
            [IO.File]::WriteAllText($companionPath,"project companion $Case`n",[Text.UTF8Encoding]::new($false))
        }
        if($Companion-like'tracked-*'){
            & git -C $target add -f -- ($companionPath.Substring($target.Length).TrimStart([char[]]@('\','/')).Replace('\','/'))
            & git -C $target commit --quiet -m 'track project Claude companion'
        }
        $claudePath=Join-Path $target 'CLAUDE.md'
        switch($Base){
            'tracked' {[IO.File]::WriteAllText($claudePath,"tracked project Claude`n",[Text.UTF8Encoding]::new($false));& git -C $target add -f -- CLAUDE.md;& git -C $target commit --quiet -m 'track project Claude base'}
            'staged' {[IO.File]::WriteAllText($claudePath,"staged project Claude`n",[Text.UTF8Encoding]::new($false));& git -C $target add -f -- CLAUDE.md}
            'unmanaged' {[IO.File]::WriteAllText($claudePath,"unmanaged project Claude`n",[Text.UTF8Encoding]::new($false))}
            'managed-customized' {[IO.File]::AppendAllText($claudePath,"project customization`n",[Text.UTF8Encoding]::new($false))}
            'managed-tracked' {& git -C $target add -f -- CLAUDE.md;& git -C $target commit --quiet -m 'track formerly managed Claude base'}
        }
        $claudeBefore=[IO.File]::ReadAllBytes($claudePath)
        $companionBefore=[IO.File]::ReadAllBytes($companionPath)
        $claudeFamilyBefore=Get-P7eTreeSnapshot (Join-Path $target '.claude')
        $headBefore=(& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $result.Output|Should Match 'claude-base-skipped-project-owned'
        [IO.File]::ReadAllBytes($claudePath)|Should Be $claudeBefore
        [IO.File]::ReadAllBytes($companionPath)|Should Be $companionBefore
        (Get-P7eTreeSnapshot (Join-Path $target '.claude'))|Should Be $claudeFamilyBefore
        Test-Path -LiteralPath (Join-Path $target '.claude/AI-Rules/CodeReview.en.md')|Should Be ($Base-like'managed-*')
        ([IO.File]::ReadAllText((Join-Path $target 'AGENTS.md')))|Should Match '<!-- changed -->'
        Test-Path -LiteralPath (Join-Path $target '.github/copilot-instructions.md')|Should Be $true
        (& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()|Should Be $headBefore
        $result.Output|Should Not Match 'Agent artifact remediation commit created'
    }
    # Scenario: Legacy production v2/v4 fan-out runs after Claude support is present in the source contract.
    # Purpose: Preserve all v2/v3 behavior and prove the legacy writer never creates Claude base, Rules, or license paths.
    It 'InterT115_keeps_legacy_writer_free_of_Claude_artifacts' {
        $root=Join-Path $script:ExternalRoot 'p9b-legacy-no-claude';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $configuration=Join-Path $root 'routing-v3.json';Set-P9bJson -Path $configuration -Document ([ordered]@{schemaVersion=3;excludedRepositoryUrls=@();excludedRepositoryPaths=@()})
        $provenance=Join-Path $root 'provenance.json';Set-P9bJson -Path $provenance -Document ([ordered]@{
            schemaVersion=1;catalogId='test-catalog';lockSha256=('a'*64)
            instruction=[ordered]@{sourceId='ai-instructions';sourceRepository='https://example.com/ai-instructions.git';sourceRef=('c'*40);sourceCommit=('c'*40);sourceVersion='test@cccccccc'};skills=@()
        })
        $output=& $script:PowerShellExecutable -NoProfile -NonInteractive -File (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1') -SourceArchivePath $source.ArchivePath -ConfigurationPath $configuration -ProvenancePath $provenance -TargetRoot $target -UserHome (Join-Path $root 'user') 2>&1
        $LASTEXITCODE|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 2
        @($manifest.files|Where-Object{[string]$_.targetPath-like'CLAUDE.md'-or[string]$_.targetPath-like'.claude/*'}).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md')|Should Be $false
        Test-Path -LiteralPath (Join-Path $target '.claude')|Should Be $false
    }

    # Scenario: Installed runtime state is mixed, unknown, gate-invalid, or Catalog/Lock-incompatible before fan-out.
    # Purpose: Return the J4 typed refusal matrix and preserve the complete consumer REPO tree for every rejected v3/v5 input.
    It 'InterT116_rejects_invalid_writer_context_without_REPO_mutation_<Case>' -TestCases @(
        @{Case='v3-v4-mixed';Code='mixed-generation'},
        @{Case='v2-v5-mixed';Code='mixed-generation'},
        @{Case='unknown-bundle';Code='unsupported-version'},
        @{Case='platform-gate';Code='platform-mismatch'},
        @{Case='catalog-lock-incompatible';Code='closure-invalid'}
    ) {
        param($Case,$Code)
        $root=Join-Path $script:ExternalRoot ("p9b-writer-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $root 'home')
        $bundlePath=Join-Path $fixtureHome 'hooks/ai-instructions-runtime/runtime-bundle.json'
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        if($Case-ceq'v3-v4-mixed'){$configuration=Get-Content -Raw $configurationPath|ConvertFrom-Json;$configuration.schemaVersion=4;$configuration.PSObject.Properties.Remove('projections');Set-P9bJson $configurationPath $configuration}
        elseif($Case-ceq'v2-v5-mixed'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.schemaVersion=2;Set-P9bJson $bundlePath $bundle}
        elseif($Case-ceq'unknown-bundle'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.schemaVersion=99;Set-P9bJson $bundlePath $bundle}
        elseif($Case-ceq'platform-gate'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.platform.architecture=if($bundle.platform.architecture-ceq'x64'){'arm64'}else{'x64'};Set-P9bJson $bundlePath $bundle}
        else{$lockPath=Join-Path $fixtureHome 'hooks/ai-instructions-runtime/catalog/skills-catalog-lock.json';$lock=Get-Content -Raw $lockPath|ConvertFrom-Json;$lock.catalogId='incompatible-catalog';Set-P9bJson $lockPath $lock}
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P7eLauncherFailure -CodexHome $fixtureHome -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be $Code
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Bootstrap receives a routing envelope whose embedded v5 identity no longer matches the verified v3 bundle.
    # Purpose: Prove the final layer re-runs the P7e gate instead of trusting the installed or multi-source caller.
    It 'InterT117_bootstrap_revalidates_the_embedded_v5_context_without_REPO_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9b-bootstrap-regate';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $routing=Get-Content -Raw -LiteralPath $context.RoutingPath|ConvertFrom-Json
        $routing.syncConfiguration.catalog.ref='d'*40
        Set-P9bJson -Path $context.RoutingPath -Document $routing
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }
}
