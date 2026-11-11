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
    It 'InterT10_refuses_production_v3v5_without_any_target_mutation' {
        $fixtureHome=Join-Path $script:ExternalRoot 'prod-v3';$before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V3V5
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be projection-runtime-unavailable
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: A fresh production install uses the default Auto writer.
    # Purpose: Protect the v2/v4 default until production projection pins are available.
    It 'InterT20_keeps_fresh_auto_on_v2v4' {
        $fixtureHome=Join-Path $script:ExternalRoot 'auto-v2'
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 2
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json).schemaVersion|Should Be 4
    }

    # Scenario: The isolated Catalog v3 candidate writes v3/v5 and the stable launcher invokes its bound fan-out entry.
    # Purpose: Exercise the successful writer journal path and reader gate without exposing a production fixture switch.
    It 'InterT30_writes_v3v5_and_launches_verified_fan_out_from_the_fixture' {
        $bundle=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        $configuration=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'ai-instructions-sync.json')|ConvertFrom-Json
        $bundle.schemaVersion|Should Be 3;$configuration.schemaVersion|Should Be 5
        $target=Join-Path $script:ExternalRoot 'fanout';$user=Join-Path $script:ExternalRoot 'user';New-Item -ItemType Directory -Path $user|Out-Null
        & (Join-Path $script:BaseV3Home 'hooks\bootstrap-ai-instructions.ps1') -TargetRoot $target -UserHome $user -SkipUpdateCheck
        (Get-Content -Raw -LiteralPath (Join-Path $target 'p7e-fanout.txt')).Trim()|Should Be v3v5
    }

    # Scenario: Auto runs again over a consistent installed v3/v5 fixture.
    # Purpose: Re-run the live gate and preserve the new generation instead of silently downgrading.
    It 'InterT40_preserves_v3v5_when_auto_reinstalls_the_fixture' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'auto-v3')
        $result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 3
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json).schemaVersion|Should Be 5
    }

    # Scenario: A real v3/v5 installer advances the immutable Catalog pin from commit A to commit B.
    # Purpose: Preserve v5 exclusions, projections, and update policy while applying the new repository/ref.
    It 'InterT45_advances_v3v5_to_a_new_commit_without_losing_personal_configuration' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'advance-v3')
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        $configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $configuration.excludedRepositoryUrls=@('https://example.com/preserved.git')
        $configuration.excludedRepositoryPaths=@('preserved/path')
        $configuration.updates.mode='auto-install-approved'
        $configuration.updates.minimumCheckIntervalMinutes=60
        $configuration.projections.project=@('project-agents')
        [IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
        $commitB='b'*40
        $result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto -SourceCommit $commitB
        $result.ExitCode|Should Be 0
        $updated=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $bundle=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        [string]$updated.catalog.ref|Should Be $commitB
        [string]$bundle.commit|Should Be $commitB
        @($updated.excludedRepositoryUrls)|Should Be @('https://example.com/preserved.git')
        @($updated.excludedRepositoryPaths)|Should Be @('preserved/path')
        [string]$updated.updates.mode|Should Be 'auto-install-approved'
        [int]$updated.updates.minimumCheckIntervalMinutes|Should Be 60
        @($updated.projections.user)|Should Be @('user-agents','user-claude')
        @($updated.projections.project)|Should Be @('project-agents')
    }

    # Scenario: V2V4 targets an installed state containing v3 and v5.
    # Purpose: Refuse rollback before target bytes change.
    It 'InterT50_refuses_explicit_v2v4_downgrade_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'down');$before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V2V4
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be downgrade-refused
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: A buggy candidate selects v2/v4 while the updater requires the installed v3/v5 generation to be preserved.
    # Purpose: Detect the downgrade after journaled publication but before commit, roll back, and retain the exact original tree.
    It 'InterT55_rolls_back_a_candidate_downgrade_before_transaction_commit' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'transaction-downgrade')
        $candidate=Join-Path $script:ExternalRoot 'downgrade-src';New-P7eV3Candidate -Destination $candidate
        $contractPath=Join-Path $candidate 'scripts\ai-instructions-runtime-contract.psm1'
        $contract=[IO.File]::ReadAllText($contractPath)
        $old="if (`$WriterSchema -ceq 'V2V4' -or (`$WriterSchema -ceq 'Auto' -and `$installedGeneration -cne 'v3v5')) { return 'v2v4' }"
        if(-not$contract.Contains($old)){throw 'P7e downgrade selector fixture marker was not found.'}
        $contract=$contract.Replace($old,"if (`$WriterSchema -ceq 'V2V4' -or `$WriterSchema -ceq 'Auto') { return 'v2v4' }")
        [IO.File]::WriteAllText($contractPath,$contract,[Text.UTF8Encoding]::new($false))
        $installerPath=Join-Path $candidate 'scripts\install-ai-instructions-bootstrap.ps1'
        $installer=[IO.File]::ReadAllText($installerPath)
        $oldConfig='ExistingConfiguration=$existingConfiguration;CatalogRepository=$catalogRepository;CatalogRef=$catalogRef'
        if(-not$installer.Contains($oldConfig)){throw 'P7e downgrade configuration fixture marker was not found.'}
        $installer=$installer.Replace($oldConfig,'ExistingConfiguration=$null;CatalogRepository=$catalogRepository;CatalogRef=$catalogRef')
        [IO.File]::WriteAllText($installerPath,$installer,[Text.UTF8Encoding]::new($false))
        $before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $candidate -CodexHome $fixtureHome -WriterSchema Auto -ExpectedCurrentGeneration v3v5
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be downgrade-refused
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The v3 bundle is paired with a v4 configuration.
    # Purpose: Reject D11 mixed generation before runtime import or mutation.
    It 'InterT60_rejects_a_mixed_pair_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'mixed')
        $path=Join-Path $fixtureHome 'ai-instructions-sync.json';$configuration=Get-Content -Raw $path|ConvertFrom-Json;$configuration.schemaVersion=4;$configuration.PSObject.Properties.Remove('projections');$configuration|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be mixed-generation
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: Installed runtime files are missing, or existing JSON documents omit one or both schemaVersion fields.
    # Purpose: Distinguish partial absence from invalid present documents and refuse before journal or target mutation.
    It 'InterT65_installer_refuses_missing_or_versionless_live_state_without_mutation_<Variant>' -TestCases @(
        @{Variant='missing-bundle';Code='mixed-generation'},
        @{Variant='missing-configuration';Code='mixed-generation'},
        @{Variant='both-versionless';Code='unsupported-version'},
        @{Variant='bundle-versionless';Code='unsupported-version'}
    ) {
        param($Variant,$Code)
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot ("invalid-$Variant"))
        $bundlePath=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        if($Variant-ceq'missing-bundle'){Remove-Item -LiteralPath $bundlePath -Force}
        elseif($Variant-ceq'missing-configuration'){Remove-Item -LiteralPath $configurationPath -Force}
        else{
            $bundle=Get-Content -Raw -LiteralPath $bundlePath|ConvertFrom-Json;$bundle.PSObject.Properties.Remove('schemaVersion');[IO.File]::WriteAllText($bundlePath,(($bundle|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
            if($Variant-ceq'both-versionless'){$configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json;$configuration.PSObject.Properties.Remove('schemaVersion');[IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))}
        }
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be $Code
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The bundle declares a different host architecture.
    # Purpose: Return the fixed platform-mismatch code after the trusted capability probe and preserve all bytes.
    It 'InterT70_rejects_platform_mismatch_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'platform')
        $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.platform.architecture=if($bundle.platform.architecture-ceq'x64'){'arm64'}else{'x64'};$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be platform-mismatch
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    if(-not[string]::IsNullOrWhiteSpace($script:P7eUnavailableCapability)){
        # Scenario: The bundle adds a capability that the current native host receipt reports unavailable or unverified.
        # Purpose: Satisfy D14 with a dynamically selected real receipt rather than a production override.
        It 'InterT80_rejects_a_real_unavailable_capability_without_mutation' {
            $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'capability')
            $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.requiredCapabilities=@($bundle.requiredCapabilities)+@($script:P7eUnavailableCapability);$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
            $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
        }

        # Scenario: Auto reinstalls an existing v3/v5 runtime whose declared capability is no longer available.
        # Purpose: Prove the installer re-runs the real host gate under its install lease and performs zero mutation.
        It 'InterT85_installer_auto_refuses_real_capability_loss_without_mutation' {
            $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'installer-capability')
            $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.requiredCapabilities=@($bundle.requiredCapabilities)+@($script:P7eUnavailableCapability);$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
            $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
        }
    }

    # Scenario: platform-runtime.psm1 is tampered with a side-effect marker before launcher validation.
    # Purpose: Prove the inline closure verifier rejects bytes before importing any candidate runtime code.
    It 'InterT90_rejects_tampered_closure_before_its_side_effect_can_run' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'closure');$marker=Join-Path $script:ExternalRoot 'imported.txt'
        $module=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\platform-runtime.psm1';[IO.File]::AppendAllText($module,"`n[IO.File]::WriteAllText('$($marker.Replace("'","''"))','imported')`n",[Text.UTF8Encoding]::new($false))
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        (Test-Path -LiteralPath $marker)|Should Be $false
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The installed launcher, multi-source coordinator, and REPO bootstrap each receive projection-aware state.
    # Purpose: Require every layer to invoke the P7e gate from its own inputs and forbid a public parameter or environment-variable v4 bypass.
    It 'UnitT110_requires_independent_P7e_gates_and_exposes_no_v4_bypass' {
        $paths=@(
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-installed.ps1'),
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-multisource.ps1'),
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1')
        )
        foreach($path in $paths){
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0
            $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Assert-AiInstructionsRuntimeGate'},$true))
            $calls.Count|Should BeGreaterThan 0
            $gateText=@($calls|ForEach-Object{$_.Extent.Text})-join"`n"
            foreach($argument in @('-Bundle','-Configuration','-RuntimeRoot','-CapabilityReceipt')){$gateText|Should Match ([regex]::Escape($argument))}
            $parameterNames=@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
            @($parameterNames|Where-Object{$_-match'(?i)(writer|manifest.*v4|enable.*v4|projection.*bypass)'}).Count|Should Be 0
            $text=[IO.File]::ReadAllText($path)
            $text|Should Not Match '(?i)env:[A-Z0-9_]*(?:WRITER|MANIFEST_V4|ENABLE_V4|PROJECTION_BYPASS)'
        }
        $multi=[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-multisource.ps1'))
        foreach($identity in @('syncConfiguration','catalogId','lockSha256','projectionContractSha256')){$multi|Should Match ([regex]::Escape($identity))}
        $multi|Should Match 'schemaVersion\s*=\s*4'
        $multi|Should Match 'RuntimeRoot\s*=\s*\$RuntimeRoot'
        ([IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-installed.ps1')))|Should Match 'RuntimeRoot\s*=\s*\$runtimeRoot'
    }

    # Scenario: A verified v3/v5 routing context reaches an ordinary repository with no project-owned CLAUDE.md and no project projection selected.
    # Purpose: Preserve an explicit empty Claude protection set, emit complete v4 output, and repeat idempotently.
    It 'InterT111_writes_complete_v4_manifest_and_exact_excludes_idempotently' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-complete';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md')|Should Be $false

        $first=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $first.ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        [int64]$manifest.generation|Should Be 1
        [string]$manifest.lockSha256|Should Be $context.LockSha256
        [string]$manifest.projectionContractSha256|Should Be $context.ProjectionContractSha256
        @($manifest.projections).Count|Should Be 0
        (@($manifest.files|Where-Object artifactType -eq instruction|Select-Object -ExpandProperty host -Unique|Sort-Object)-join',')|Should Be 'claude,codex,copilot'
        foreach($entry in @($manifest.files|Where-Object artifactType -eq instruction)){
            [string]$entry.rendererId|Should Be 'build-ai-instructions'
            [string]$entry.rendererSha256|Should Be $source.RendererSha256
        }
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-ceq'CLAUDE.md'}).Count|Should Be 1
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-like'.claude/AI-Rules/*.en.md'}).Count|Should BeGreaterThan 0
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-like'.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/*'}).Count|Should BeGreaterThan 0
        foreach($entry in @($manifest.files|Where-Object host -eq claude)){
            $path=Join-Path $target ([string]$entry.targetPath)
            Test-Path -LiteralPath $path -PathType Leaf|Should Be $true
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$entry.sha256)
        }
        $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
        $excludeLines=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-like'/*'}|Sort-Object)
        $expectedLines=@('/.codex/ai-instructions.manifest.json')
        $expectedLines+=@($manifest.files|ForEach-Object{'/'+[string]$_.targetPath})
        $expectedLines=@($expectedLines|Sort-Object -Unique)
        $excludeLines|Should Be $expectedLines
        ([IO.File]::ReadAllText($excludePath))|Should Not Match '(?m)^/\.claude/\*\*$'
        $before=Get-P9bRepoSnapshot $target

        $second=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $second.ExitCode|Should Be 0
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 1
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A v4 desired state changes once, repeats, and then reaches Int64 generation maximum before another change.
    # Purpose: Increment generation only for changed desired state and fail closed without REPO mutation on overflow.
    It 'InterT112_advances_v4_generation_only_on_change_and_refuses_overflow' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-generation';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 2
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        $manifest.generation=[int64]::MaxValue;Set-P9bJson -Path $manifestPath -Document $manifest
        $before=Get-P9bRepoSnapshot $target

        $overflow=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target
        $overflow.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $overflow.Output)|Should Be closure-invalid
        $overflow.Output|Should Match 'generation would overflow'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Sync v5 selects a project projection before the P9c project runtime exists.
    # Purpose: Return the typed J9 refusal before any REPO byte, index, history, or exclude mutation.
    It 'InterT113_refuses_project_projection_before_REPO_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9b-project-unavailable';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root -SelectProjectProjection
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be projection-runtime-unavailable
        (Get-P9bRepoSnapshot $target)|Should Be $before
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
