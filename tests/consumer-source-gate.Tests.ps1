Describe 'Authority-owned consumer source gate' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:GateModule = Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1'
        Import-Module $script:GateModule -Force
        function Write-FixtureJson([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false))) }
        function Invoke-SourceFixtureGit([string]$Root,[string[]]$Arguments){$output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join' ')"};$output}
        function Get-SourceFixtureGitScalar([string]$Root,[string[]]$Arguments){([string](@(Invoke-SourceFixtureGit $Root $Arguments)[0])).Trim()}
        function Copy-FixtureValue($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
        function Get-SourceFixtureFailure([scriptblock]$Action){try{& $Action;return $null}catch{return [string]$_.Exception.Message}}
        function New-MinimalConsumerFixture([string]$Root,$Entry,[string]$SkillId){
            [void][IO.Directory]::CreateDirectory($Root);[void](Invoke-SourceFixtureGit $Root @('init','-q','-b','main'));[void](Invoke-SourceFixtureGit $Root @('config','user.name','Fixture'));[void](Invoke-SourceFixtureGit $Root @('config','user.email','fixture@example.test'))
            foreach($path in @("skills/$SkillId/SKILL.md",'config/consumer-gate.json')+@($Entry.requiredRepositoryChecks|Where-Object kind -eq general|ForEach-Object path)){[void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $Root $path)))}
            [IO.File]::WriteAllText((Join-Path $Root "skills/$SkillId/SKILL.md"),'---`nname: fixture`ndescription: fixture`n---`n')
            foreach($check in @($Entry.requiredRepositoryChecks|Where-Object kind -eq general)){[IO.File]::WriteAllText((Join-Path $Root ([string]$check.path)),'param([string]$RepositoryRoot)`n')}
            $config=[ordered]@{schemaVersion=1;repositoryId=[string]$Entry.id;sourceRepository=[string]$Entry.repository;activeSkills=@($SkillId);repositoryChecks=@($Entry.requiredRepositoryChecks)}
            Write-FixtureJson (Join-Path $Root 'config/consumer-gate.json') $config;[void](Invoke-SourceFixtureGit $Root @('add','.'));[void](Invoke-SourceFixtureGit $Root @('commit','-q','-m','fixture'))
            $config
        }
    }

    # Scenario: The legacy manifest is consumed as the exact five-repository conversion contract.
    # Purpose: Keep four ready migrations and the deferred Darktide inventory explicit.
    It 'UnitT10_binds_five_unique_legacy_inventories_and_defers_darktide' {
        $manifestText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')
        $schemaText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-legacy-migration-v1.schema.json')
        Test-Json -Json $manifestText -Schema $schemaText | Should Be $true
        $manifest = $manifestText | ConvertFrom-Json
        @($manifest.repositories).Count | Should Be 5
        @($manifest.repositories.id | Select-Object -Unique).Count | Should Be 5
        @($manifest.repositories | Where-Object status -eq ready).Count | Should Be 4
        $darktide = @($manifest.repositories | Where-Object id -eq skill-darktide-translate)[0]
        $darktide.status | Should Be deferred
        foreach ($entry in $manifest.repositories) {
            $entry.inventoryCommit | Should Match '^[0-9a-f]{40}$'; $entry.inventoryTree | Should Match '^[0-9a-f]{40}$'
            @($entry.files).Count | Should BeGreaterThan 0
            @($entry.files.path | Select-Object -Unique).Count | Should Be (@($entry.files).Count)
            @($entry.requiredRepositoryChecks.id | Select-Object -Unique).Count | Should Be (@($entry.requiredRepositoryChecks).Count)
            @($entry.requiredRepositoryChecks.path | Select-Object -Unique).Count | Should Be (@($entry.requiredRepositoryChecks).Count)
        }
    }

    # Scenario: The migration manifest preserves repository behavior while removing authority-owned copies.
    # Purpose: General history, CC catalog checks, and each legacy driver receive an explicit disposition.
    It 'UnitT20_records_the_required_delete_split_and_history_decisions' {
        $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json') | ConvertFrom-Json
        $text = $manifest | ConvertTo-Json -Depth 30
        foreach ($required in @('PR12','tests/validate-catalog.ps1','scripts/Test-CodeCollaborationCatalog.ps1','scripts/Validate.ps1','scripts/Get-SourcePin.ps1','scripts/Test-Repository.ps1')) { $text | Should Match ([regex]::Escape($required) -replace '\\\.','\.') }
        $general = @($manifest.repositories | Where-Object id -eq 'skill-general')[0]
        $driver = @($general.files | Where-Object path -eq 'scripts/Validate.ps1')[0]
        $driver.disposition | Should Be 'delete'
        $driver.reason | Should Match 'historical evidence remains in Git and central authority records'
    }

    # Scenario: Conversion starts with exact authority templates, then changes a protected byte, adds a workflow, or restores a deleted legacy path.
    # Purpose: Exercise positive and negative bootstrap, workflow, and legacy-file barriers before candidate code runs.
    It 'UnitT25_accepts_only_exact_protected_conversion_files' {
        $authority=Join-Path $TestDrive 'protected-authority';$base=Join-Path $TestDrive 'protected-base';$candidate=Join-Path $TestDrive 'protected-candidate'
        foreach($root in @($authority,$base,$candidate)){[void][IO.Directory]::CreateDirectory($root)}
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer/bootstrap'));[void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer/workflows'))
        Copy-Item (Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
        foreach($name in @('consumer-gate.yml','consumer-gate-transition.yml')){Copy-Item (Join-Path $script:RepositoryRoot "consumer/workflows/$name") (Join-Path $authority "consumer/workflows/$name")}
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'scripts'));[void][IO.Directory]::CreateDirectory((Join-Path $candidate '.github/workflows'))
        Copy-Item (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1')
        foreach($name in @('consumer-gate.yml','consumer-gate-transition.yml')){Copy-Item (Join-Path $authority "consumer/workflows/$name") (Join-Path $candidate ".github/workflows/$name")}
        $entry=[pscustomobject]@{files=@([pscustomobject]@{path='scripts/Legacy.ps1';disposition='delete'})}
        Assert-GateProtectedFiles $authority $base $candidate $entry $true
        Add-Content -LiteralPath (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1') -Value '# changed';{Assert-GateProtectedFiles $authority $base $candidate $entry $true}|Should Throw
        Copy-Item (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1') -Force
        [IO.File]::WriteAllText((Join-Path $candidate '.github/workflows/extra.yml'),'name: extra');{Assert-GateProtectedFiles $authority $base $candidate $entry $true}|Should Throw
        Remove-Item (Join-Path $candidate '.github/workflows/extra.yml');[IO.File]::WriteAllText((Join-Path $candidate 'scripts/Legacy.ps1'),'legacy');{Assert-GateProtectedFiles $authority $base $candidate $entry $true}|Should Throw
    }

    # Scenario: Success, HTTP failure, timeout, and cancellation all reach the same owned-root scan; a cleanup failure leaves a sentinel.
    # Purpose: Every preparation outcome clears aliases and refuses to enter validate when credential bytes remain.
    It 'UnitT30_scans_all_preparation_outcomes_for_credential_bytes' {
        foreach($outcome in @('success','http-error','timeout','cancellation')){
            $root=Join-Path $TestDrive "credential-$outcome";[void][IO.Directory]::CreateDirectory($root)
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,'unique-consumer-token-sentinel','Process')}
            $action={
                foreach($file in @('diagnostic.txt','summary.txt','receipt.json','artifact.bin')){[IO.File]::WriteAllText((Join-Path $root $file),"$outcome without credential",(New-Object Text.UTF8Encoding($false)))}
                if($outcome-ne'success'){throw "$outcome fixture"}
            }.GetNewClosure()
            if($outcome-eq'success'){Invoke-GateCredentialScopedPreparation $root 'unique-consumer-token-sentinel' $action}else{{Invoke-GateCredentialScopedPreparation $root 'unique-consumer-token-sentinel' $action}|Should Throw}
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::GetEnvironmentVariable($name,'Process')|Should BeNullOrEmpty}
            Assert-GateCredentialAbsent $root 'unique-consumer-token-sentinel'
        }
        $residue=Join-Path $TestDrive 'credential-cleanup-failure';[void][IO.Directory]::CreateDirectory($residue)
        $enteredValidate=$false
        {Invoke-GateCredentialScopedPreparation $residue 'unique-consumer-token-sentinel' { [IO.File]::WriteAllText((Join-Path $residue 'artifact.txt'),'unique-consumer-token-sentinel',(New-Object Text.UTF8Encoding($false))) };$enteredValidate=$true}|Should Throw
        $enteredValidate|Should Be $false
        $entry=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1')
        $entry|Should Match 'Invoke-GateCredentialScopedPreparation \$WorkRoot \$token'
    }

    # Scenario: Consumer config has the exact public fields and a safe repository-check declaration.
    # Purpose: Reject extension fields, unsafe general paths, and an omitted complete Pester check at schema/runtime boundaries.
    It 'UnitT35_rejects_invalid_consumer_config_shapes' {
        $schema=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-gate-config-v1.schema.json')
        $valid=[ordered]@{schemaVersion=1;repositoryId='skill-general';sourceRepository='https://github.com/example/skill.git';activeSkills=@('general');repositoryChecks=@([ordered]@{id='repository-general';kind='general';path='scripts/Test-Repository.ps1'},[ordered]@{id='repository-pester';kind='pester';path='tests'})}
        Test-Json -Json ($valid|ConvertTo-Json -Depth 10) -Schema $schema|Should Be $true
        $invalid=Copy-FixtureValue $valid;$invalid|Add-Member -NotePropertyName extra -NotePropertyValue $true;Test-Json -Json ($invalid|ConvertTo-Json -Depth 10) -Schema $schema -ErrorAction SilentlyContinue|Should Be $false
        $invalid=Copy-FixtureValue $valid;$invalid.repositoryChecks=@([pscustomobject]@{id='repository-general';kind='general';path='../outside.ps1'});Test-Json -Json ($invalid|ConvertTo-Json -Depth 10) -Schema $schema -ErrorAction SilentlyContinue|Should Be $false
    }

    # Scenario: Each ready legacy repository declares a minimal tracked Skill and every exact required repository check.
    # Purpose: Conversion fixtures prove the manifest can drive valid configs while missing or duplicate required checks fail closed.
    It 'UnitT37_accepts_all_four_ready_manifest_configs_and_rejects_required_check_drift' {
        $manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json
        foreach($entry in @($manifest.repositories|Where-Object status -eq ready)){
            $root=Join-Path $TestDrive ("ready-"+[string]$entry.id);$skillId='fixture-'+([string]$entry.id-replace'^skill-','')
            $config=New-MinimalConsumerFixture $root $entry $skillId
            $validated=Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)
            @($validated.ActiveSkills)|Should Be @($skillId)
            $config.repositoryChecks=@($config.repositoryChecks|Select-Object -Skip 1);Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
            {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)}|Should Throw
        }
    }

    # Scenario: A declared general check is untracked, is a Tests file, or points at a legacy delete disposition.
    # Purpose: Repository-specific execution remains limited to tracked regular non-test scripts that migration permits.
    It 'UnitT37a_rejects_unsafe_general_repository_check_paths_at_runtime' {
        $manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json
        $entry=@($manifest.repositories|Where-Object id -eq 'skill-general')[0];$root=Join-Path $TestDrive 'general-path-rules';$config=New-MinimalConsumerFixture $root $entry 'fixture-general'
        $untracked=Join-Path $root 'scripts/Untracked.ps1';[IO.File]::WriteAllText($untracked,'param()',[Text.UTF8Encoding]::new($false))
        $config.repositoryChecks=@($config.repositoryChecks)+@([pscustomobject]@{id='untracked';kind='general';path='scripts/Untracked.ps1'});Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)})|Should Match 'not a tracked file'
        $config.repositoryChecks=@($config.repositoryChecks|Where-Object id -ne 'untracked')+@([pscustomobject]@{id='test-script';kind='general';path='tests/Unsafe.Tests.ps1'});Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)})|Should Match 'path is invalid'
        $deletedPath='scripts/Validate.ps1';[IO.File]::WriteAllText((Join-Path $root $deletedPath),'param()',[Text.UTF8Encoding]::new($false));[void](Invoke-SourceFixtureGit $root @('add',$deletedPath))
        $config.repositoryChecks=@($config.repositoryChecks|Where-Object id -ne 'test-script')+@([pscustomobject]@{id='deleted-reader';kind='general';path=$deletedPath});Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)})|Should Match 'deleted legacy path'
    }

    # Scenario: Transition inventory is exact, then its commit, tree, or deferred state changes.
    # Purpose: A stale or deferred migration must stop before any disposition is reused.
    It 'UnitT38_requires_the_exact_transition_commit_and_tree' {
        $root=Join-Path $TestDrive 'transition-base';[void][IO.Directory]::CreateDirectory($root);[void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'));[void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'));[void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'));[IO.File]::WriteAllText((Join-Path $root 'file.txt'),'fixture');[void](Invoke-SourceFixtureGit $root @('add','.'));[void](Invoke-SourceFixtureGit $root @('commit','-q','-m','fixture'))
        $commit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD');$tree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}');$entry=[pscustomobject]@{status='ready';inventoryCommit=$commit;inventoryTree=$tree}
        Assert-GateTransitionInventory $root $entry $commit $true
        $entry.inventoryTree='f'*40;{Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw
        $entry.inventoryTree=$tree;$entry.status='deferred';{Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw
    }

    # Scenario: A candidate changes the exception aggregate or one per-Skill exception baseline.
    # Purpose: PR-1 blocks every exception-set mutation until the signed PR-2 path exists.
    It 'UnitT39_blocks_exception_set_changes_before_prepare' {
        $root=Join-Path $TestDrive 'exception-diff';[void][IO.Directory]::CreateDirectory((Join-Path $root 'config/skillspector-exceptions'));[void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'));[void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'));[void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'));[IO.File]::WriteAllText((Join-Path $root 'config/skillspector-exceptions.json'),'{}');[void](Invoke-SourceFixtureGit $root @('add','.'));[void](Invoke-SourceFixtureGit $root @('commit','-q','-m','base'));$base=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        Assert-GateExceptionSetUnchanged $root $base $base
        [IO.File]::WriteAllText((Join-Path $root 'config/skillspector-exceptions/fixture.baseline.json'),'{}');[void](Invoke-SourceFixtureGit $root @('add','.'));[void](Invoke-SourceFixtureGit $root @('commit','-q','-m','candidate'));$candidate=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        {Assert-GateExceptionSetUnchanged $root $base $candidate}|Should Throw
    }

    # Scenario: Three valid legs are aggregated and one binding is then changed.
    # Purpose: Aggregate accepts only the complete platform set with identical candidate and event identity.
    It 'UnitT40_rejects_missing_duplicate_nonpass_and_mismatched_leg_bindings' {
        $binding = [pscustomobject]@{runId='1234567890abcdef1234567890abcdef';candidateRevision=('a'*40);headRevision=('b'*40);baseRevision=('c'*40);commit=('d'*40);aiiMainTip=('e'*40);triggerEvent='pull_request_target';canonicalEvent='pull_request'}
        $work = Join-Path $TestDrive 'aggregate'; $receipts = Join-Path $work 'receipts'; [void][IO.Directory]::CreateDirectory($receipts)
        $inventory=[ordered]@{sha256=('1'*64);caseDiscoveryCount=2;caseExecutionCount=2;testFileInventory=@('tests/a.Tests.ps1');containerFileInventory=@('tests/a.Tests.ps1');discoveredCaseFileInventory=@('tests/a.Tests.ps1')}
        foreach ($platform in @('windows','linux','macos')) { Write-FixtureJson (Join-Path $receipts "leg-$platform.json") ([ordered]@{schemaVersion=1;report='consumer-gate-leg-receipt-v1';result='PASS';platform=$platform;runId=$binding.runId;candidateRevision=$binding.candidateRevision;headRevision=$binding.headRevision;baseRevision=$binding.baseRevision;authorityCommit=$binding.commit;aiiMainTip=$binding.aiiMainTip;interface='consumer-gate-v1';triggerEvent=$binding.triggerEvent;canonicalEvent=$binding.canonicalEvent;platformTestInventory=$inventory;evidenceSha256=('f'*64)}) }
        Invoke-GateAggregate $work $binding
        Remove-Item -LiteralPath (Join-Path $work 'aggregate-receipt.json')
        $changed = Get-Content -Raw (Join-Path $receipts 'leg-linux.json') | ConvertFrom-Json; $changed.canonicalEvent='push'; Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.canonicalEvent='pull_request'; $changed.result='FAILED'; Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.result='PASS';$changed.candidateRevision='9'*40;Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.candidateRevision=$binding.candidateRevision;$changed.triggerEvent='push';Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.triggerEvent=$binding.triggerEvent;Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        $mac=Get-Content -Raw (Join-Path $receipts 'leg-macos.json')|ConvertFrom-Json;$mac.platform='linux';Write-FixtureJson (Join-Path $receipts 'leg-macos.json') $mac
        { Invoke-GateAggregate $work $binding } | Should Throw
        Remove-Item -LiteralPath (Join-Path $receipts 'leg-macos.json'); { Invoke-GateAggregate $work $binding } | Should Throw
    }

    # Scenario: A platform reports zero, partial, or duplicate Pester case identity inventories.
    # Purpose: Leg receipts cannot claim PASS unless complete discovery and execution identity agree.
    It 'UnitT42_rejects_incomplete_or_ambiguous_platform_test_inventory' {
        $valid=[pscustomobject]@{sha256=('1'*64);caseDiscoveryCount=2;caseExecutionCount=2;testFileInventory=@('tests/a.Tests.ps1');containerFileInventory=@('tests/a.Tests.ps1');discoveredCaseFileInventory=@('tests/a.Tests.ps1')}
        Assert-GatePlatformTestInventory $valid
        $invalid=Copy-FixtureValue $valid;$invalid.caseExecutionCount=1;(Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'counts are invalid'
        $invalid=Copy-FixtureValue $valid;$invalid.testFileInventory=@('tests/a.Tests.ps1','tests/a.Tests.ps1');(Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'testFileInventory'
        $invalid=Copy-FixtureValue $valid;$invalid.caseDiscoveryCount=0;$invalid.caseExecutionCount=0;(Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'counts are invalid'
    }

    # Scenario: Authority source code is inspected for setup and validation ordering.
    # Purpose: Verified PowerShell precedes Pester/tools, token aliases are cleared, and Core v2 performs the final source-report assertion.
    It 'UnitT50_preserves_runtime_tool_and_source_report_ordering' {
        $entry = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1')
        $module = Get-Content -Raw -Encoding UTF8 $script:GateModule
        $entry.IndexOf('Install-GatePowerShell') | Should BeLessThan $entry.IndexOf('New-GateSourceSetup')
        $pesterIndex=$module.IndexOf("foreach(`$tool in @('pester','skill-validator','skill-tools','skillspector')",[StringComparison]::Ordinal)
        $sourceReportIndex=$module.IndexOf('Assert-StandardCoreSourceCheckReport',[StringComparison]::Ordinal)
        $pesterIndex | Should BeGreaterThan -1
        $sourceReportIndex | Should BeGreaterThan $pesterIndex
        $entry | Should Match 'Invoke-GateCredentialScopedPreparation'; $module | Should Match "'GITHUB_TOKEN','GH_TOKEN'"
        $module | Should Match 'Assert-StandardCoreSourceCheckReport';$module | Should Match 'platformUnavailableException'
        $repositoryCheck=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1')
        foreach($name in @('STANDARD_VALIDATION_CORE_RUN_ID','STANDARD_VALIDATION_CORE_CHECK_ID','STANDARD_VALIDATION_CORE_SKILLS')){$repositoryCheck|Should Match $name}
        $repositoryCheck|Should Not Match 'STANDARD_VALIDATION_CANDIDATE_ROOT|STANDARD_VALIDATION_ACTIVE_SKILLS'
        foreach($required in @('Assert-PesterClosure','receipt-pester.json','dependencyClosureSha256','installedClosureSha256','PesterReceiptSha256','standard-core-pester-case-inventory-v1','complete-unfiltered-tests-tree','candidateSnapshotSha256','shardCaseIdentities')){$repositoryCheck|Should Match ([regex]::Escape($required))}
    }

    # Scenario: The migrated repository-check wrapper is inspected for full discovery and stable case identity evidence.
    # Purpose: Preserve the KC Pester integrity contract without keeping a consumer-local runtime implementation.
    It 'UnitT55_binds_complete_pester_discovery_and_case_identity' {
        $repositoryCheck=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1')
        foreach($required in @('New-PesterConfiguration',"Get-ChildItem -LiteralPath `$testRoot -Recurse -File -Filter '*.Tests.ps1'",'$configuration.Run.Path = $testRoot','caseDiscoveryCount','caseExecutionCount','containerFileInventory','discoveredCaseFileInventory','Pester did not report a complete unskipped pass','Pester case, container, or test-file identity is incomplete','candidateSnapshotSha256','complete-unfiltered-tests-tree')){$repositoryCheck|Should Match ([regex]::Escape($required))}
        $repositoryCheck|Should Match 'Sort-Object -Unique'
        $repositoryCheck|Should Match 'identitySet\.Count-ne\$identities\.Count'
    }

    # Scenario: Config and protected-file gates are reviewed as a single authority contract.
    # Purpose: Require tracked checks, exact required coverage, exception blocking, byte-equivalent templates, and no deleted legacy path.
    It 'UnitT60_keeps_config_workflow_exception_and_legacy_barriers_fail_closed' {
        $module = Get-Content -Raw -Encoding UTF8 $script:GateModule
        foreach ($required in @('Required repository check is missing','General repository check is not a tracked file','General repository check points to a deleted legacy path','SkillSpector exception set changed','Unexpected workflow','Candidate consumer-gate.yml is missing','Deleted legacy path is present','Repository has advanced')) { $module | Should Match ([regex]::Escape($required)) }
    }
}
