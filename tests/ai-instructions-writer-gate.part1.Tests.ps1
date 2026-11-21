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

    # Scenario: Windows production explicitly opts in to V3V5 with the projection-aware production Catalog.
    # Purpose: Enable the approved production writer, preserve it under Auto, and reject an explicit downgrade without mutation.
    It 'InterT10_installs_production_v3v5_when_explicitly_requested_on_Windows' {
        $fixtureHome=Join-Path $script:ExternalRoot 'prod-v3'
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V3V5
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 3
        $configuration=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json
        $configuration.schemaVersion|Should Be 5
        (@($configuration.projections.user)-join ',')|Should Be 'user-agents,user-claude'

        $auto=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema Auto
        $auto.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 3
        $configuration=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json
        $configuration.schemaVersion|Should Be 5
        (@($configuration.projections.user)-join ',')|Should Be 'user-agents,user-claude'

        $before=Get-P7eTreeSnapshot $fixtureHome
        $downgrade=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V2V4
        $downgrade.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $downgrade.Output)|Should Be downgrade-refused
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: A fresh production Auto install applies and verifies legacy USER state before explicitly upgrading the same isolated home to V3V5.
    # Purpose: Preserve the v2/v4 default with Catalog/Lock v3, then prove opt-in enables both managed USER projections through the public updater.
    It 'InterT20_keeps_fresh_auto_on_v2v4_and_updates_USER_state_before_opt_in' {
        $fixtureHome=Join-Path $script:ExternalRoot 'auto-v2'
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 2
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        $configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $configuration.schemaVersion|Should Be 4
        $productionCatalog=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\catalog\skills-catalog.json')|ConvertFrom-Json
        $configuration.catalog.profiles=@();$configuration.catalog.includeSkills=@();$configuration.catalog.excludeSkills=@($productionCatalog.skills|Where-Object{[string]$_.lifecycle.status-cne'removed'}|ForEach-Object{[string]$_.id})
        [IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
        $userHome=Join-Path $script:ExternalRoot 'auto-v2-user'
        $entry=Join-Path $script:RepositoryRoot 'scripts\update-agent-environment.ps1'

        $applyOutput=@(& $script:PowerShellExecutable -NoProfile -NonInteractive -File $entry -CodexHome $fixtureHome -UserHome $userHome -Apply -OutputFormat Json)
        $applyExit=$LASTEXITCODE;$apply=$applyOutput[-1]|ConvertFrom-Json
        if($applyExit-ne0){throw "legacy public Apply failed with exit $applyExit`: $($applyOutput-join ' | ')"}
        $apply.outcome|Should Be 'applied'
        $verifyOutput=@(& $script:PowerShellExecutable -NoProfile -NonInteractive -File $entry -CodexHome $fixtureHome -UserHome $userHome -VerifyOnly -OutputFormat Json)
        $verifyExit=$LASTEXITCODE;$verify=$verifyOutput[-1]|ConvertFrom-Json
        if($verifyExit-ne0){throw "legacy public VerifyOnly failed with exit $verifyExit`: $($verifyOutput-join ' | ')"}
        $verify.outcome|Should Be 'current'
        $legacyManifest=Get-Content -Raw -LiteralPath (Join-Path $userHome '.agents\catalog-skills.manifest.json')|ConvertFrom-Json
        [int]$legacyManifest.schemaVersion|Should Be 2
        Test-Path -LiteralPath (Join-Path $userHome '.claude')|Should Be $false

        $upgrade=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V3V5
        $upgrade.ExitCode|Should Be 0
        $applyOutput=@(& $script:PowerShellExecutable -NoProfile -NonInteractive -File $entry -CodexHome $fixtureHome -UserHome $userHome -Apply -OutputFormat Json)
        $applyExit=$LASTEXITCODE;$apply=$applyOutput[-1]|ConvertFrom-Json
        if($applyExit-ne0){throw "projection public Apply failed with exit $applyExit`: $($applyOutput-join ' | ')"}
        $apply.outcome|Should Be 'applied'
        $verifyOutput=@(& $script:PowerShellExecutable -NoProfile -NonInteractive -File $entry -CodexHome $fixtureHome -UserHome $userHome -VerifyOnly -OutputFormat Json)
        $verifyExit=$LASTEXITCODE;$verify=$verifyOutput[-1]|ConvertFrom-Json
        if($verifyExit-ne0){throw "projection public VerifyOnly failed with exit $verifyExit`: $($verifyOutput-join ' | ')"}
        $verify.outcome|Should Be 'current'
        $projectionManifest=Get-Content -Raw -LiteralPath (Join-Path $userHome '.agents\catalog-skills.manifest.json')|ConvertFrom-Json
        [int]$projectionManifest.schemaVersion|Should Be 3
        (@($projectionManifest.projections)-join ',')|Should Be 'user-agents,user-claude'
        Test-Path -LiteralPath (Join-Path $userHome '.claude\CLAUDE.md') -PathType Leaf|Should Be $true
    }

    # Scenario: The isolated Catalog v3 candidate writes v3/v5 and the stable launcher invokes its bound fan-out entry.
    # Purpose: Exercise the successful writer journal path and reader gate without exposing a production fixture switch.
    It 'InterT30_writes_v3v5_and_launches_verified_fan_out_from_the_fixture' {
        $bundle=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        $configuration=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'ai-instructions-sync.json')|ConvertFrom-Json
        $bundle.schemaVersion|Should Be 3;$configuration.schemaVersion|Should Be 5
        $sectionPath=Join-Path $script:BaseV3Home 'hooks\ai-instructions-runtime\bootstrap-section.md'
        Test-Path -LiteralPath $sectionPath -PathType Leaf|Should Be $true
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($sectionPath))|Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'instructions\common\bootstrap-section.md'))))
        @($bundle.inventory|Where-Object path -ceq 'bootstrap-section.md').Count|Should Be 1
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

    # Scenario: The isolated v3/v5 writer selects no project root, one root, or all three project roots.
    # Purpose: Exercise the complete P9c writer matrix, v4 projection parity, exact ignores, and idempotent generation without changing production pins.
    It 'InterT113_writes_project_Skills_for_<Case>_idempotently' -TestCases @(
        @{Case='empty';Projections=@()},
        @{Case='single';Projections=@('project-agents')},
        @{Case='all';Projections=@('project-agents','project-claude','project-github')}
    ) {
        param($Case,$Projections)
        $root=Join-Path $script:ExternalRoot "p9c-project-$Case";New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $fixture=$null
        $context=if(@($Projections).Count-eq0){New-P9bBootstrapContext -Root $root}else{$fixture=New-P9cProjectFixture -Root $root -ProjectionIds $Projections;$fixture.Context}
        $target=Join-Path $root 'target';New-P9bTargetRepository $target

        $first=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        if($first.ExitCode-ne0){throw "P9c initial bootstrap failed: $($first.Output)"}
        $first.ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json';$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        @($manifest.projections)|Should Be @($Projections|Sort-Object)
        $skillEntries=@($manifest.files|Where-Object artifactType -ceq skill)
        if(@($Projections).Count-eq0){$skillEntries.Count|Should Be 0}
        else{
            @($skillEntries.projectionId|Sort-Object -Unique)|Should Be @($Projections|Sort-Object)
            foreach($projection in $Projections){@($skillEntries|Where-Object projectionId -ceq $projection).Count|Should BeGreaterThan 0}
            Assert-ManagedManifestV4 -Manifest $manifest
            $exclude=[IO.File]::ReadAllText((Join-Path $target '.git/info/exclude'))
            foreach($entry in $skillEntries){$exclude|Should Match ([regex]::Escape('/'+[string]$entry.targetPath))}
        }
        [int64]$generation=$manifest.generation;$before=Get-P9bRepoSnapshot $target
        $second=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $second.ExitCode|Should Be 0
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be $generation
        (Get-P9bRepoSnapshot $target)|Should Be $before
        if($Case-ceq'all'){
            $inventoryPath=Join-Path $fixture.CandidateRoot 'project-candidate.json';$inventory=Get-Content -Raw -LiteralPath $inventoryPath|ConvertFrom-Json;$inventory.projections=@('project-agents');Set-P9bJson -Path $inventoryPath -Document $inventory
            $singleArchive=Join-Path $root 'project-candidate-single.zip';New-ComposedBootstrapArchive -SourceRoot $fixture.CandidateRoot -DestinationPath $singleArchive|Out-Null
            $singleContext=New-P9bBootstrapContext -Root (Join-Path $root 'single-context') -CodexHome $fixture.Home -ProjectProjectionIds @('project-agents') -ProjectCandidateArchivePath $singleArchive -SkillProvenance $fixture.SkillProvenance
            $changed=Invoke-P9bRepoBootstrap -Context $singleContext -ArchivePath $source.ArchivePath -TargetRoot $target
            $changed.ExitCode|Should Be 0
            $changedManifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
            [int64]$changedManifest.generation|Should Be ($generation+1)
            @($changedManifest.projections)|Should Be @('project-agents')
            @(Get-ChildItem -LiteralPath (Join-Path $target '.claude/skills') -File -Recurse -ErrorAction SilentlyContinue).Count|Should Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $target '.github/skills') -File -Recurse -ErrorAction SilentlyContinue).Count|Should Be 0
        }
    }

    # Scenario: A desired project Skill becomes tracked, staged, unmanaged, customized, or project-owned in a linked worktree.
    # Purpose: Refuse the whole project transaction before remediation, report every ownership state, and preserve all repository bytes and history.
    It 'InterT133_refuses_project_owned_Skill_<Case>_before_mutation' -TestCases @(
        @{Case='tracked'},@{Case='staged'},@{Case='unmanaged'},@{Case='drift'},@{Case='linked-unmanaged'}
    ) {
        param($Case)
        $root=Join-Path $script:ExternalRoot "p9c-owned-$Case";New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $fixture=New-P9cProjectFixture -Root $root -ProjectionIds @('project-agents')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $skillPath=@((Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json).files|Where-Object{[string]$_.artifactType-ceq'skill'-and[string]$_.targetPath-like'*/SKILL.md'}|Select-Object -First 1 -ExpandProperty targetPath)
        $skillPath=[string]$skillPath[0];$linkedRoot=$null
        switch($Case){
            'tracked' {& git -C $target add -f -- $skillPath;& git -C $target commit --quiet -m 'track project Skill fixture'}
            'staged' {& git -C $target add -f -- $skillPath}
            'unmanaged' {[IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Join-Path $target $skillPath)) 'local.txt'),"local`n",[Text.UTF8Encoding]::new($false))}
            'drift' {[IO.File]::AppendAllText((Join-Path $target $skillPath),"custom`n",[Text.UTF8Encoding]::new($false))}
            'linked-unmanaged' {
                $linkedRoot=Join-Path $root 'linked';& git -C $target worktree add --quiet -b "p9c-owned-$Case" $linkedRoot
                $linkedSkill=Join-Path $linkedRoot $skillPath;New-Item -ItemType Directory -Force -Path (Split-Path -Parent $linkedSkill)|Out-Null
                [IO.File]::WriteAllText($linkedSkill,"linked project Skill`n",[Text.UTF8Encoding]::new($false))
            }
        }
        $before=Get-P9bRepoSnapshot $target;$headBefore=(& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()
        try{
            $result=Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $source.ArchivePath -TargetRoot $target
            $result.ExitCode|Should Not Be 0
            (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
            $result.Output|Should Match 'Project Skill transaction refused before remediation or project mutation'
            $result.Output|Should Match $(if($Case-like'*unmanaged'){'unmanaged'}else{$Case})
            (Get-P9bRepoSnapshot $target)|Should Be $before
            (& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()|Should Be $headBefore
            $result.Output|Should Not Match 'Agent artifact remediation commit created'
        }
        finally{if($null-ne$linkedRoot){& git -C $target worktree remove --force $linkedRoot|Out-Null}}
    }

    if($IsWindows){
    # Scenario: A core.ignoreCase repository records a manifest-owned project Skill under a case-variant Git path.
    # Purpose: Use Git's repository comparer to refuse the tracked file before mutation and preserve its exact bytes.
    It 'InterT133_refuses_case_variant_tracked_project_Skill_before_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9c-owned-case-variant';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $fixture=New-P9cProjectFixture -Root $root -ProjectionIds @('project-agents')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        & git -C $target config core.ignoreCase true
        (Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $skillPath=[string]@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object{[string]$_.artifactType-ceq'skill'-and[string]$_.targetPath-like'*/SKILL.md'}|Select-Object -First 1 -ExpandProperty targetPath)[0]
        $caseVariant=$skillPath -replace '^\.agents/','.Agents/'
        $blob=(@(& git -C $target hash-object -w -- $skillPath)-join'').Trim()
        & git -C $target update-index --add --cacheinfo "100644,$blob,$caseVariant"
        $LASTEXITCODE|Should Be 0
        & git -C $target commit --quiet -m 'track case-variant project Skill fixture'
        $LASTEXITCODE|Should Be 0
        @(& git -C $target ls-files)|Should Contain $caseVariant
        $skillBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target $skillPath)))
        $manifestBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))

        $result=Invoke-P9bRepoBootstrap -Context $fixture.Context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'tracked'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target $skillPath)))|Should Be $skillBytes
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))|Should Be $manifestBytes
    }
    }
}
