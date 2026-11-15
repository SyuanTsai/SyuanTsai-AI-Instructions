Describe 'Authority-owned consumer source gate' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:GateModule = Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1'
        Import-Module $script:GateModule -Force
        $script:GitHooksRoot = Join-Path $TestDrive 'gate-hooks-root'
        [void][IO.Directory]::CreateDirectory($script:GitHooksRoot)
        Initialize-GateGitHooks $script:GitHooksRoot
        function Write-FixtureJson([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 30),(New-Object `
            Text.UTF8Encoding($false))) }
        function Invoke-SourceFixtureGit([string]$Root,[string[]]$Arguments){$output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1)
        if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join' ')"}
        $output}
        function Get-SourceFixtureGitScalar([string]$Root,[string[]]$Arguments){([string](@(Invoke-SourceFixtureGit $Root $Arguments)[0])).Trim()}
        function Copy-FixtureValue($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
        function Get-SourceFixtureFailure([scriptblock]$Action){try{& $Action
        return $null}catch{return [string]$_.Exception.Message}}
        function New-MinimalConsumerFixture([string]$Root,$Entry,[string]$SkillId){
            [void][IO.Directory]::CreateDirectory($Root)
            [void](Invoke-SourceFixtureGit $Root @('init','-q','-b','main'))
            [void](Invoke-SourceFixtureGit $Root @('config','user.name','Fixture'))
            [void](Invoke-SourceFixtureGit $Root @('config','user.email','fixture@example.test'))
            foreach($path in @("skills/$SkillId/SKILL.md",'config/consumer-gate.json')+@($Entry.requiredRepositoryChecks|Where-Object kind -eq `
                general|ForEach-Object path)){[void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $Root $path)))}
            [IO.File]::WriteAllText((Join-Path $Root "skills/$SkillId/SKILL.md"),'---`nname: fixture`ndescription: fixture`n---`n')
            foreach ($check in @($Entry.requiredRepositoryChecks | Where-Object kind -eq general)) {
                [IO.File]::WriteAllText(
                    (Join-Path $Root ([string]$check.path)),
                    'param([string]$RepositoryRoot)`n'
                )
            }
            $config=[ordered]@{schemaVersion=1
            repositoryId=[string]$Entry.id
            sourceRepository=[string]$Entry.repository
            activeSkills=@($SkillId)
            repositoryChecks=@($Entry.requiredRepositoryChecks)}
            Write-FixtureJson (Join-Path $Root 'config/consumer-gate.json') $config
            [void](Invoke-SourceFixtureGit $Root @('add','.'))
            [void](Invoke-SourceFixtureGit $Root @('commit','-q','-m','fixture'))
            $config
        }
    }

    # Scenario: The legacy manifest is consumed as the exact five-repository conversion contract.
    # Purpose: Keep four ready migrations and the blocked Darktide prerequisites explicit.
    It 'UnitT10_binds_five_unique_legacy_inventories_and_blocks_darktide_prerequisites' {
        $manifestText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')
        $schemaText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-legacy-migration-v1.schema.json')
        Test-Json -Json $manifestText -Schema $schemaText | Should Be $true
        $manifest = $manifestText | ConvertFrom-Json
        @($manifest.repositories).Count | Should Be 5
        @($manifest.repositories.id | Select-Object -Unique).Count | Should Be 5
        @($manifest.repositories | Where-Object status -eq ready).Count | Should Be 4
        $darktide = @($manifest.repositories | Where-Object id -eq skill-darktide-translate)[0]
        $darktide.status | Should Be pending-prerequisites
        @($darktide.prerequisites).Count | Should BeGreaterThan 0
        $darktide.additionalScope | Should Be @('skills/auto-update-darktide-mod/scripts/')
        foreach ($entry in $manifest.repositories) {
            $entry.inventoryCommit | Should Match '^[0-9a-f]{40}$'
             $entry.inventoryTree | Should Match '^[0-9a-f]{40}$'
            @($entry.files).Count | Should BeGreaterThan 0
            @($entry.files.path | Select-Object -Unique).Count | Should Be (@($entry.files).Count)
            @($entry.requiredRepositoryChecks.id | Select-Object -Unique).Count | Should Be (@($entry.requiredRepositoryChecks).Count)
            @($entry.requiredRepositoryChecks.path | Select-Object -Unique).Count | Should Be (@($entry.requiredRepositoryChecks).Count)
        }
    }

    # Scenario: Distinct JSON objects reuse an ID or path projection that JSON Schema cannot express as unique.
    # Purpose: Format validation stays in schema while the gate enforces projected uniqueness and membership.
    It 'UnitT12_layers_schema_format_validation_and_runtime_projection_uniqueness' {
        $manifestPath = Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json'
        $schema = Get-Content -Raw -Encoding UTF8 (
            Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-legacy-migration-v1.schema.json'
        )
        $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json -Depth 100
        $entry = @($manifest.repositories | Where-Object id -eq 'skill-general')[0]
        $duplicate = Copy-FixtureValue $entry.requiredRepositoryChecks[0]
        $duplicate.path = 'scripts/ProjectionCollision.ps1'
        $entry.requiredRepositoryChecks = @($entry.requiredRepositoryChecks) + @($duplicate)
        $json = $manifest | ConvertTo-Json -Depth 100
        Test-Json -Json $json -Schema $schema | Should Be $true

        $authority = Join-Path $TestDrive 'projection-authority'
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer'))
        [IO.File]::WriteAllText(
            (Join-Path $authority 'consumer/legacy-migration.json'),
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        { Get-GateManifestEntry $authority 'skill-general' } | Should Throw 'unique and valid'
    }

    # Scenario: The migration manifest preserves repository behavior while removing authority-owned copies.
    # Purpose: General history, CC catalog checks, and each legacy driver receive an explicit disposition.
    It 'UnitT20_records_the_required_delete_split_and_history_decisions' {
        $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json') | ConvertFrom-Json
        $text = $manifest | ConvertTo-Json -Depth 30
        $requiredPaths = @(
            'PR12', 'tests/validate-catalog.ps1', 'scripts/Test-CodeCollaborationCatalog.ps1',
            'scripts/Validate.ps1', 'scripts/Get-SourcePin.ps1', 'scripts/Test-Repository.ps1'
        )
        foreach ($required in $requiredPaths) {
            $text | Should Match ([regex]::Escape($required) -replace '\\\.','\.')
        }
        $general = @($manifest.repositories | Where-Object id -eq 'skill-general')[0]
        $driver = @($general.files | Where-Object path -eq 'scripts/Validate.ps1')[0]
        $driver.disposition | Should Be 'delete'
        $driver.reason | Should Match 'historical evidence remains in Git and central authority records'
    }

    # Scenario: Synthetic retained files use the supported PowerShell folds, unsafe parameter forms, aliases, and text encodings.
    # Purpose: The closure scanner behavior is proven from Git blobs without copying any consumer repository content.
    It 'InterT22_executes_manifest_closure_golden_vectors' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $root = Join-Path $TestDrive 'closure-golden'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'docs'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        $legacy = Join-Path $root 'scripts/Legacy.ps1'
        [IO.File]::WriteAllText($legacy, 'param()', [Text.UTF8Encoding]::new($false))
        $powershell = @'
. ('scripts/' + 'Legacy.ps1')
Copy-Item -Lit $source -Destination ('scripts/' + 'Legacy.ps1')
Set-Content -Path $dynamic -Value 'x'
sc $dynamic 'x'
Out-File -FilePath $dynamic
Move-Item -Path $source -Destination $dynamic
mv $source $dynamic
$cast = ([string]('scripts/' + 'Legacy.ps1'))
'@
        [IO.File]::WriteAllText(
            (Join-Path $root 'scripts/Retained.ps1'),
            $powershell,
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $root 'scripts/reference.py'),
            "path = 'scripts/Legacy.ps1'`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $root 'docs/history.md'),
            "Historical scripts/Legacy.ps1 reference.`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $root 'scripts/utf16.ps1'),
            [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes(". 'scripts/Legacy.ps1'`n")
        )
        [IO.File]::WriteAllBytes((Join-Path $root 'scripts/payload.bin'), [byte[]](0,255,0,254,1,2,3))
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','closure golden'))
        $commit = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $tree = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $files = @(
            [ordered]@{ path='scripts/Legacy.ps1'
             disposition='delete'
             reason='fixture legacy' },
            [ordered]@{ path='scripts/Retained.ps1'
             disposition='retain'
             reason='fixture retained' },
            [ordered]@{ path='scripts/reference.py'
             disposition='retain'
             reason='fixture retained' },
            [ordered]@{ path='docs/history.md'
             disposition='retain'
             reason='fixture retained' },
            [ordered]@{ path='scripts/utf16.ps1'
             disposition='retain'
             reason='fixture retained' },
            [ordered]@{ path='scripts/payload.bin'
             disposition='retain'
             reason='fixture retained' }
        )
        $manifest = [ordered]@{ schemaVersion=1
         repositories=@([ordered]@{
                    id='fixture'
                     repository='https://example.test/fixture.git'
                     status='ready'
                    inventoryCommit=$commit
                     inventoryTree=$tree
                     requiredRepositoryChecks=@()
                     files=$files
                }) }
        $manifestPath = Join-Path $TestDrive 'closure-golden.json'
        Write-FixtureJson $manifestPath $manifest
        $result = Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory `
            -Manifest $manifestPath -RepositoryId fixture -AuthorityRoot $script:RepositoryRoot
        $result.result | Should Be FAILED
        $result.counts.legacyReference | Should BeGreaterOrEqual 4
        $result.counts.dynamicReference | Should BeGreaterOrEqual 5
        $result.counts.documentationReference | Should Be 1
        $result.counts.binary | Should Be 1
        @($result.violations | Where-Object file -eq 'scripts/reference.py').Count | Should Be 1
        @($result.violations | Where-Object file -eq 'scripts/utf16.ps1').Count | Should Be 1
    }

    # Scenario: Conversion starts with exact authority templates, then changes a protected byte, adds a workflow, or restores a deleted legacy path.
    # Purpose: Exercise positive and negative bootstrap, workflow, and legacy-file barriers before candidate code runs.
    It 'UnitT25_accepts_only_exact_protected_conversion_files' {
        $authority=Join-Path $TestDrive 'protected-authority'
        $base=Join-Path $TestDrive 'protected-base'
        $candidate=Join-Path $TestDrive 'protected-candidate'
        foreach($root in @($authority,$base,$candidate)){[void][IO.Directory]::CreateDirectory($root)}
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer/bootstrap'))
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer/workflows'))
        Copy-Item (Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $authority `
            'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
        foreach($name in @('consumer-gate.yml','consumer-gate-transition.yml')){Copy-Item (Join-Path $script:RepositoryRoot `
            "consumer/workflows/$name") (Join-Path $authority "consumer/workflows/$name")}
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'scripts'))
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate '.github/workflows'))
        Copy-Item (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1')
        foreach ($name in @('consumer-gate.yml','consumer-gate-transition.yml')) {
            Copy-Item (Join-Path $authority "consumer/workflows/$name") `
                (Join-Path $candidate ".github/workflows/$name")
        }
        $entry=[pscustomobject]@{files=@([pscustomobject]@{path='scripts/Legacy.ps1'
        disposition='delete'})}
        Assert-GateProtectedFiles $authority $base $candidate $entry '' '' $true
        Add-Content -LiteralPath (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1') -Value '# changed'
        {Assert-GateProtectedFiles $authority $base $candidate $entry '' '' $true}|Should Throw
        Copy-Item (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1') -Force
        [IO.File]::WriteAllText((Join-Path $candidate '.github/workflows/extra.yml'),'name: extra')
        {Assert-GateProtectedFiles $authority $base $candidate $entry '' '' $true}|Should Throw
        Remove-Item (Join-Path $candidate '.github/workflows/extra.yml')
        $nested = Join-Path $candidate '.github/workflows/nested'
        [void][IO.Directory]::CreateDirectory($nested)
        [IO.File]::WriteAllText((Join-Path $nested 'consumer-gate.yml'), 'name: nested')
        { Assert-GateProtectedFiles $authority $base $candidate $entry '' '' $true } | Should Throw 'Nested workflow directories'
        Remove-Item -LiteralPath $nested -Recurse
        [IO.File]::WriteAllText((Join-Path $candidate 'scripts/Legacy.ps1'),'legacy')
        {Assert-GateProtectedFiles $authority $base $candidate $entry '' '' $true}|Should Throw
    }

    # Scenario: Success, HTTP failure, timeout, and cancellation all reach the same owned-root scan; a cleanup failure leaves a sentinel.
    # Purpose: Every preparation outcome clears aliases and refuses to enter validate when credential bytes remain.
    It 'UnitT30_scans_all_preparation_outcomes_for_credential_bytes' {
        foreach($outcome in @('success','http-error','timeout','cancellation')){
            $sentinel='unique-consumer-token-sentinel'
            $root=Join-Path $TestDrive "credential-$outcome"
            [void][IO.Directory]::CreateDirectory($root)
            $summary=Join-Path $TestDrive "summary-$outcome.txt"
            $artifacts=Join-Path $TestDrive "artifacts-$outcome"
            [void][IO.Directory]::CreateDirectory($artifacts)
            [Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY',$summary,'Process')
            [Environment]::SetEnvironmentVariable('CONSUMER_GATE_ARTIFACT_PATHS',$artifacts,'Process')
            foreach ($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')) {
                [Environment]::SetEnvironmentVariable($name,$sentinel,'Process')
            }
            $cancellation=[Threading.CancellationTokenSource]::new()
            if($outcome-eq'cancellation'){$cancellation.Cancel()}
            $transport={param($operation,$uri,$headers,$destination,$token)
                if($outcome-eq'http-error'){throw [Net.WebException]::new('fixture HTTP error')}
                if($outcome-eq'timeout'){throw [TimeoutException]::new('fixture timeout')}
                if($operation-eq'metadata'){return [pscustomobject]@{tag='fixture'}}
                [IO.File]::WriteAllBytes($destination,[byte[]](1,2,3))
            }.GetNewClosure()
            $enteredValidate=$false
            $captured=''
            $action={
                $metadata=Invoke-GateAcquisitionRequest metadata ([uri]'https://example.test/release') @{'Authorization'="Bearer $sentinel"} `
                    $null $transport $cancellation.Token
                if ($outcome -eq 'success') {
                    Invoke-GateAcquisitionRequest download ([uri]'https://example.test/archive') `
                        @{'Authorization'="Bearer $sentinel"} (Join-Path $root 'download.bin') `
                        $transport $cancellation.Token
                }
                [IO.File]::WriteAllText((Join-Path $root 'receipt.json'),'{"result":"clean"}')
                [IO.File]::WriteAllText($summary,'clean summary')
                [IO.File]::WriteAllText((Join-Path $artifacts 'artifact.txt'),'clean artifact')
            }.GetNewClosure()
            try{$records=@(Invoke-GateCredentialScopedPreparation $root $sentinel $action *>&1)
            $captured=$records-join"`n"
            if($outcome-ne'success'){throw 'Expected acquisition failure.'}
            $enteredValidate=$true}catch{if($outcome-eq'success'){throw}
            $captured+=[string]$_.Exception.Message}
            $captured|Should Not Match ([regex]::Escape($sentinel))
            if($outcome-eq'success'){$enteredValidate|Should Be $true}else{$enteredValidate|Should Be $false}
            foreach ($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')) {
                [Environment]::GetEnvironmentVariable($name,'Process') | Should BeNullOrEmpty
            }
            Assert-GateCredentialAbsent $root $sentinel
            $cancellation.Dispose()
        }
        [Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY',$null,'Process')
        [Environment]::SetEnvironmentVariable('CONSUMER_GATE_ARTIFACT_PATHS',$null,'Process')
        $residue=Join-Path $TestDrive 'credential-cleanup-failure'
        [void][IO.Directory]::CreateDirectory($residue)
        $enteredValidate=$false
        {Invoke-GateCredentialScopedPreparation $residue 'unique-consumer-token-sentinel' { [IO.File]::WriteAllText((Join-Path $residue `
            'artifact.txt'),'unique-consumer-token-sentinel',(New-Object Text.UTF8Encoding($false))) }
        $enteredValidate=$true}|Should Throw
        $enteredValidate|Should Be $false
        $entry=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1')
        $entry|Should Match 'Invoke-GateCredentialScopedPreparation \$WorkRoot \$token'
    }

    # Scenario: Consumer config has the exact public fields and a safe repository-check declaration.
    # Purpose: Reject extension fields, unsafe general paths, and an omitted complete Pester check at schema/runtime boundaries.
    It 'UnitT35_rejects_invalid_consumer_config_shapes' {
        $schema=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-gate-config-v1.schema.json')
        $valid=[ordered]@{schemaVersion=1
        repositoryId='skill-general'
        sourceRepository='https://github.com/example/skill.git'
        activeSkills=@('general')
        repositoryChecks=@([ordered]@{id='repository-general'
        kind='general'
        path='scripts/Test-Repository.ps1'},[ordered]@{id='repository-pester'
        kind='pester'
        path='tests'})}
        Test-Json -Json ($valid|ConvertTo-Json -Depth 10) -Schema $schema|Should Be $true
        $invalid=Copy-FixtureValue $valid
        $invalid|Add-Member -NotePropertyName extra -NotePropertyValue $true
        Test-Json -Json ($invalid|ConvertTo-Json -Depth 10) -Schema $schema -ErrorAction SilentlyContinue|Should Be $false
        $invalid=Copy-FixtureValue $valid
        $invalid.repositoryChecks=@([pscustomobject]@{id='repository-general'
        kind='general'
        path='../outside.ps1'})
        Test-Json -Json ($invalid|ConvertTo-Json -Depth 10) -Schema $schema -ErrorAction SilentlyContinue|Should Be $false
        foreach ($path in @('scripts/../evil.ps1','tests/../config/evil.ps1','scripts\evil.ps1')) {
            $invalid = Copy-FixtureValue $valid
            $invalid.repositoryChecks[0].path = $path
            Test-Json -Json ($invalid | ConvertTo-Json -Depth 10) -Schema $schema -ErrorAction SilentlyContinue | Should Be $false
        }
    }

    # Scenario: Each ready legacy repository declares a minimal tracked Skill and every exact required repository check.
    # Purpose: Conversion fixtures prove the manifest can drive valid configs while missing or duplicate required checks fail closed.
    It 'UnitT37_accepts_all_four_ready_manifest_configs_and_rejects_required_check_drift' {
        $manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json
        foreach($entry in @($manifest.repositories|Where-Object status -eq ready)){
            $root=Join-Path $TestDrive ("ready-"+[string]$entry.id)
            $skillId='fixture-'+([string]$entry.id-replace'^skill-','')
            $config=New-MinimalConsumerFixture $root $entry $skillId
            $validated=Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)
            @($validated.ActiveSkills)|Should Be @($skillId)
            $config.repositoryChecks=@($config.repositoryChecks|Select-Object -Skip 1)
            Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
            {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)}|Should Throw
        }
    }

    # Scenario: Every ready manifest is materialized as a complete base tree and converted according to every disposition.
    # Purpose: Exercise delete, split, retain, and update-tests behavior against tracked Git objects instead of samples.
    It 'InterT37c_enforces_complete_ready_repository_dispositions' {
        $manifest = Get-Content -Raw -Encoding UTF8 (
            Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json'
        ) | ConvertFrom-Json -Depth 100
        foreach ($entry in @($manifest.repositories | Where-Object status -eq ready)) {
            $root = Join-Path $TestDrive ("dispositions-" + [string]$entry.id)
            [void][IO.Directory]::CreateDirectory($root)
            [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
            [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
            [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
            foreach ($record in @($entry.files)) {
                $path = Join-Path $root ([string]$record.path)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                [IO.File]::WriteAllText($path, "base $($record.path)`n", [Text.UTF8Encoding]::new($false))
            }
            [void](Invoke-SourceFixtureGit $root @('add','.'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','base inventory'))
            $baseRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')

            foreach ($record in @($entry.files)) {
                $path = Join-Path $root ([string]$record.path)
                if ($record.disposition -in @('delete','split') -or
                    ($record.disposition -eq 'update-tests' -and $record.expectedOutcome -eq 'delete')) {
                    Remove-Item -LiteralPath $path -Force
                }
                elseif ($record.disposition -eq 'update-tests') {
                    [IO.File]::AppendAllText($path, "rewritten`n", [Text.UTF8Encoding]::new($false))
                }
                if ($record.disposition -eq 'split') {
                    $target = Join-Path $root ([string]$record.target)
                    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                    [IO.File]::WriteAllText($target, "split target`n", [Text.UTF8Encoding]::new($false))
                }
            }
            Copy-Item -Force (
                Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
            ) (Join-Path $root 'scripts/Invoke-PinnedAuthority.ps1')
            $workflowRoot = Join-Path $root '.github/workflows'
            [void][IO.Directory]::CreateDirectory($workflowRoot)
            Get-ChildItem -LiteralPath $workflowRoot -Force | Remove-Item -Force -Recurse
            foreach ($name in @('consumer-gate.yml','consumer-gate-transition.yml')) {
                Copy-Item (Join-Path $script:RepositoryRoot "consumer/workflows/$name") (Join-Path $workflowRoot $name)
            }
            [void](Invoke-SourceFixtureGit $root @('add','-A'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','converted'))
            $candidateRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
            Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                $baseRevision $candidateRevision $true

            $removed = @($entry.files | Where-Object {
                    $_.disposition -in @('delete','split') -and $_.path -notlike '.github/workflows/*'
                })[0]
            $removedPath = Join-Path $root ([string]$removed.path)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $removedPath))
            [IO.File]::WriteAllText($removedPath, 'leftover', [Text.UTF8Encoding]::new($false))
            { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                    $baseRevision $candidateRevision $true } | Should Throw 'Removed legacy path'
            Remove-Item -LiteralPath $removedPath -Force

            foreach ($split in @($entry.files | Where-Object disposition -eq split)) {
                Remove-Item -LiteralPath (Join-Path $root ([string]$split.target)) -Force
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','wrong split target'))
                $wrongRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                        $baseRevision $wrongRevision $true } | Should Throw 'Split target'
                break
            }
        }
    }

    # Scenario: A declared general check is untracked, is a Tests file, or points at a legacy delete disposition.
    # Purpose: Repository-specific execution remains limited to tracked regular non-test scripts that migration permits.
    It 'UnitT37a_rejects_unsafe_general_repository_check_paths_at_runtime' {
        $manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json
        $entry=@($manifest.repositories|Where-Object id -eq 'skill-general')[0]
        $root=Join-Path $TestDrive 'general-path-rules'
        $config=New-MinimalConsumerFixture $root $entry 'fixture-general'
        $untracked=Join-Path $root 'scripts/Untracked.ps1'
        [IO.File]::WriteAllText($untracked,'param()',[Text.UTF8Encoding]::new($false))
        $config.repositoryChecks=@($config.repositoryChecks)+@([pscustomobject]@{id='untracked'
        kind='general'
        path='scripts/Untracked.ps1'})
        Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {
                Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)
            }) | Should Match 'not a canonical tracked file'
        $config.repositoryChecks=@($config.repositoryChecks|Where-Object id -ne 'untracked')+@([pscustomobject]@{id='test-script'
        kind='general'
        path='tests/Unsafe.Tests.ps1'})
        Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)})|Should Match 'path is invalid'
        $deletedPath='scripts/Validate.ps1'
        [IO.File]::WriteAllText((Join-Path $root $deletedPath),'param()',[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $root @('add',$deletedPath))
        $config.repositoryChecks=@($config.repositoryChecks|Where-Object id -ne 'test-script')+@([pscustomobject]@{id='deleted-reader'
        kind='general'
        path=$deletedPath})
        Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
        (Get-SourceFixtureFailure {Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)})|Should Match 'deleted legacy path'
        foreach ($path in @('scripts/../evil.ps1','tests/../config/evil.ps1','scripts\evil.ps1')) {
            $config.repositoryChecks = @($config.repositoryChecks | Where-Object id -ne 'deleted-reader') + @(
                [pscustomobject]@{ id='unsafe-path'
                 kind='general'
                 path=$path }
            )
            Write-FixtureJson (Join-Path $root 'config/consumer-gate.json') $config
            (Get-SourceFixtureFailure {
                    Assert-GateConfig $script:RepositoryRoot $root ([string]$entry.repository)
                }) | Should Match 'path is invalid'
        }
    }

    # Scenario: Gate Git isolation is asked to reuse an existing path or a redirected WorkRoot.
    # Purpose: Candidate-controlled hooks cannot be planted before the gate invokes Git.
    It 'UnitT37b_creates_gate_hooks_only_in_a_new_empty_physical_workroot_directory' {
        $root = Join-Path $TestDrive 'gate-hook-hardening'
        [void][IO.Directory]::CreateDirectory($root)
        $name = 'git-hooks-' + ('d' * 32)
        $created = New-GateGitHooksDirectory $root $name
        @(Get-ChildItem -LiteralPath $created -Force).Count | Should Be 0
        { New-GateGitHooksDirectory $root $name } | Should Throw 'already exists'

        $physical = Join-Path $TestDrive 'gate-hook-physical'
        $junction = Join-Path $TestDrive 'gate-hook-junction'
        [void][IO.Directory]::CreateDirectory($physical)
        [void](New-Item -ItemType Junction -Path $junction -Target $physical)
        { New-GateGitHooksDirectory $junction ('git-hooks-' + ('e' * 32)) } | Should Throw 'physical directory'
    }

    # Scenario: Transition inventory is exact, then its commit, tree, or deferred state changes.
    # Purpose: A stale or deferred migration must stop before any disposition is reused.
    It 'UnitT38_requires_the_exact_transition_commit_and_tree' {
        $root=Join-Path $TestDrive 'transition-base'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/file.txt'),'fixture')
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','fixture'))
        $commit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $tree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $entry=[pscustomobject]@{status='ready'
        inventoryCommit=$commit
        inventoryTree=$tree
        files=@([pscustomobject]@{path='scripts/file.txt'})}
        Assert-GateTransitionInventory $root $entry $commit $true
        $entry.inventoryTree='f'*40
        {Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw
        $entry.inventoryTree=$tree
        $entry.status='pending-prerequisites'
        {Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw
    }

    # Scenario: A candidate changes the exception aggregate or one per-Skill exception baseline.
    # Purpose: PR-1 blocks every exception-set mutation until the signed PR-2 path exists.
    It 'UnitT39_blocks_exception_set_changes_before_prepare' {
        $root=Join-Path $TestDrive 'exception-diff'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'config/skillspector-exceptions'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'config/skillspector-exceptions.json'),'{}')
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','base'))
        $base=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        Assert-GateExceptionSetUnchanged $root $base $base
        [IO.File]::WriteAllText((Join-Path $root 'config/skillspector-exceptions/fixture.baseline.json'),'{}')
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','candidate'))
        $candidate=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        {Assert-GateExceptionSetUnchanged $root $base $candidate}|Should Throw
    }

    # Scenario: Three valid legs are aggregated and one binding is then changed.
    # Purpose: Aggregate accepts only the complete platform set with identical candidate and event identity.
    It 'UnitT40_rejects_missing_duplicate_nonpass_and_mismatched_leg_bindings' {
        $binding = [pscustomobject]@{runId='1234567890abcdef1234567890abcdef'
        candidateRevision=('a'*40)
        headRevision=('b'*40)
        baseRevision=('c'*40)
        commit=('d'*40)
        aiiMainTip=('e'*40)
        triggerEvent='pull_request_target'
        canonicalEvent='pull_request'}
        $work = Join-Path $TestDrive 'aggregate'
         $receipts = Join-Path $work 'receipts'
         [void][IO.Directory]::CreateDirectory($receipts)
        $inventory=[ordered]@{sha256=('1'*64)
        caseDiscoveryCount=2
        caseExecutionCount=2
        testFileInventory=@('tests/a.Tests.ps1')
        containerFileInventory=@('tests/a.Tests.ps1')
        discoveredCaseFileInventory=@('tests/a.Tests.ps1')}
        foreach ($platform in @('windows','linux','macos')) { Write-FixtureJson (Join-Path $receipts "leg-$platform.json") ([ordered]@{schemaVersion=1
        report='consumer-gate-leg-receipt-v1'
        result='PASS'
        platform=$platform
        runId=$binding.runId
        candidateRevision=$binding.candidateRevision
        headRevision=$binding.headRevision
        baseRevision=$binding.baseRevision
        authorityCommit=$binding.commit
        aiiMainTip=$binding.aiiMainTip
        interface='consumer-gate-v1'
        triggerEvent=$binding.triggerEvent
        canonicalEvent=$binding.canonicalEvent
        platformTestInventory=$inventory
        evidenceSha256=('f'*64)}) }
        Invoke-GateAggregate $work $binding
        Remove-Item -LiteralPath (Join-Path $work 'aggregate-receipt.json')
        $changed = Get-Content -Raw (Join-Path $receipts 'leg-linux.json') | ConvertFrom-Json
         $changed.canonicalEvent='push'
         Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.canonicalEvent='pull_request'
         $changed.result='FAILED'
         Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.result='PASS'
        $changed.candidateRevision='9'*40
        Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.candidateRevision=$binding.candidateRevision
        $changed.triggerEvent='push'
        Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.triggerEvent=$binding.triggerEvent
        Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        $mac=Get-Content -Raw (Join-Path $receipts 'leg-macos.json')|ConvertFrom-Json
        $mac.platform='linux'
        Write-FixtureJson (Join-Path $receipts 'leg-macos.json') $mac
        { Invoke-GateAggregate $work $binding } | Should Throw
        Remove-Item -LiteralPath (Join-Path $receipts 'leg-macos.json')
         { Invoke-GateAggregate $work $binding } | Should Throw
    }

    # Scenario: A platform reports zero, partial, or duplicate Pester case identity inventories.
    # Purpose: Leg receipts cannot claim PASS unless complete discovery and execution identity agree.
    It 'UnitT42_rejects_incomplete_or_ambiguous_platform_test_inventory' {
        $valid=[pscustomobject]@{sha256=('1'*64)
        caseDiscoveryCount=2
        caseExecutionCount=2
        testFileInventory=@('tests/a.Tests.ps1')
        containerFileInventory=@('tests/a.Tests.ps1')
        discoveredCaseFileInventory=@('tests/a.Tests.ps1')}
        Assert-GatePlatformTestInventory $valid
        $invalid=Copy-FixtureValue $valid
        $invalid.caseExecutionCount=1
        (Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'counts are invalid'
        $invalid=Copy-FixtureValue $valid
        $invalid.testFileInventory=@('tests/a.Tests.ps1','tests/a.Tests.ps1')
        (Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'testFileInventory'
        $invalid=Copy-FixtureValue $valid
        $invalid.caseDiscoveryCount=0
        $invalid.caseExecutionCount=0
        (Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'counts are invalid'
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
        $entry | Should Match 'Invoke-GateCredentialScopedPreparation'
         $module | Should Match "'GITHUB_TOKEN','GH_TOKEN'"
        $module | Should Match 'Assert-StandardCoreSourceCheckReport'
        $module | Should Match 'platformUnavailableException'
        $repositoryCheck=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1')
        foreach ($name in @(
                'STANDARD_VALIDATION_CORE_RUN_ID',
                'STANDARD_VALIDATION_CORE_CHECK_ID',
                'STANDARD_VALIDATION_CORE_SKILLS'
            )) {
            $repositoryCheck | Should Match $name
        }
        $repositoryCheck|Should Not Match 'STANDARD_VALIDATION_CANDIDATE_ROOT|STANDARD_VALIDATION_ACTIVE_SKILLS'
        $requiredPesterBindings = @(
            'Assert-PesterClosure', 'receipt-pester.json', 'dependencyClosureSha256',
            'installedClosureSha256', 'PesterReceiptSha256', 'standard-core-pester-case-inventory-v1',
            'complete-unfiltered-tests-tree', 'candidateSnapshotSha256', 'shardCaseIdentities'
        )
        foreach ($required in $requiredPesterBindings) {
            $repositoryCheck | Should Match ([regex]::Escape($required))
        }
    }

    # Scenario: The migrated repository-check wrapper is inspected for full discovery and stable case identity evidence.
    # Purpose: Preserve the KC Pester integrity contract without keeping a consumer-local runtime implementation.
    It 'UnitT55_binds_complete_pester_discovery_and_case_identity' {
        $repositoryCheck=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1')
        $requiredDiscoveryBindings = @(
            'New-PesterConfiguration',
            "Get-ChildItem -LiteralPath `$testRoot -Recurse -File -Filter '*.Tests.ps1'",
            '$configuration.Run.Path = $testRoot', 'caseDiscoveryCount', 'caseExecutionCount',
            'containerFileInventory', 'discoveredCaseFileInventory',
            'Pester did not report a complete unskipped pass',
            'Pester case, container, or test-file identity is incomplete',
            'candidateSnapshotSha256', 'complete-unfiltered-tests-tree'
        )
        foreach ($required in $requiredDiscoveryBindings) {
            $repositoryCheck | Should Match ([regex]::Escape($required))
        }
        $repositoryCheck|Should Match 'Sort-Object -Unique'
        $repositoryCheck | Should Match 'identitySet\.Count'
    }

    # Scenario: A synthetic verified Pester closure returns complete, partial, duplicate, skipped, and not-run inventories.
    # Purpose: Execute the repository wrapper and prove closure bytes plus complete case identity are enforced behaviorally.
    It 'InterT56_executes_verified_pester_closure_and_complete_discovery' {
        $runId = '1234567890abcdef1234567890abcdef'
        foreach ($scenario in @('success','tampered','partial','duplicate','skipped','notrun')) {
            $workRoot = Join-Path $TestDrive "pester-wrapper-$scenario"
            $candidate = Join-Path $workRoot "$runId/candidate"
            $runtime = Join-Path $workRoot 'runtime/consumer'
            $installRoot = Join-Path $workRoot 'runtime/installed/pester'
            $sourceTools = Join-Path $workRoot 'source-tools'
            foreach ($directory in @($candidate,$runtime,$installRoot,$sourceTools,(Join-Path $candidate 'config'),(Join-Path $candidate 'tests'))) {
                [void][IO.Directory]::CreateDirectory($directory)
            }
            Copy-Item (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1') `
                (Join-Path $runtime 'Invoke-ConsumerRepositoryCheck.ps1')
            Write-FixtureJson (Join-Path $candidate 'config/consumer-gate.json') ([ordered]@{
                    repositoryChecks=@([ordered]@{ id='pester'
                     kind='pester'
                     path='tests' })
                    activeSkills=@('fixture')
                })
            [IO.File]::WriteAllText(
                (Join-Path $candidate 'tests/Fixture.Tests.ps1'),
                "Describe 'fixture' { It 'passes' { 1 | Should Be 1 } }`n",
                [Text.UTF8Encoding]::new($false)
            )
            if ($scenario -eq 'partial') {
                [IO.File]::WriteAllText(
                    (Join-Path $candidate 'tests/Unreported.Tests.ps1'),
                    "Describe 'unreported' { It 'passes' { 1 | Should Be 1 } }`n",
                    [Text.UTF8Encoding]::new($false)
                )
            }
            $module = @'
function New-PesterConfiguration {
    [pscustomobject]@{
        Run = [pscustomobject]@{ Path=$null; PassThru=$false; RepoRoot=$null }
        Output = [pscustomobject]@{ Verbosity=$null }
        TestRegistry = [pscustomobject]@{ Enabled=$true }
    }
}
function Invoke-Pester {
    param($Configuration)
    $file = Get-ChildItem -LiteralPath $Configuration.Run.Path -Filter '*.Tests.ps1' | Sort-Object Name | Select-Object -First 1
    $block = (Get-Command $file.FullName -CommandType ExternalScript).ScriptBlock
    $scenario = [string]$env:FAKE_PESTER_SCENARIO
    $resultName = if ($scenario -eq 'skipped') { 'Skipped' } elseif ($scenario -eq 'notrun') { 'NotRun' } else { 'Passed' }
    $executed = $scenario -ne 'notrun'
    $test = [pscustomobject]@{ ScriptBlock=$block; ExpandedPath='fixture/passes'; Result=$resultName; Executed=$executed }
    $tests = if ($scenario -eq 'duplicate') { @($test,$test) } else { @($test) }
    $total = $tests.Count
    [pscustomobject]@{
        Result = if ($scenario -in @('skipped','notrun')) { 'Failed' } else { 'Passed' }
        Tests = $tests
        Containers = @([pscustomobject]@{ Name=$file.FullName })
        TotalCount = $total
        PassedCount = if ($resultName -eq 'Passed') { $total } else { 0 }
        FailedCount = 0
        SkippedCount = if ($resultName -eq 'Skipped') { $total } else { 0 }
        InconclusiveCount = 0
        NotRunCount = if ($resultName -eq 'NotRun') { $total } else { 0 }
        FailedBlocksCount = 0
        FailedContainersCount = 0
    }
}
Export-ModuleMember -Function New-PesterConfiguration,Invoke-Pester
'@
            $modulePath = Join-Path $installRoot 'Pester.psm1'
            $manifestPath = Join-Path $installRoot 'Pester.psd1'
            [IO.File]::WriteAllText($modulePath,$module,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText(
                $manifestPath,
                "@{ RootModule='Pester.psm1'; ModuleVersion='6.2.0'; FunctionsToExport=@('New-PesterConfiguration','Invoke-Pester') }",
                [Text.UTF8Encoding]::new($false)
            )
            $closure = @('Pester.psd1','Pester.psm1') | ForEach-Object {
                [ordered]@{ path=$_
                 sha256=(Get-FileHash (Join-Path $installRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            $closureText = (@($closure | Sort-Object path | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join '')
            $closureSha = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($closureText))
            ).ToLowerInvariant()
            $manifestSha = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $receiptPath = Join-Path $sourceTools 'receipt-pester.json'
            Write-FixtureJson $receiptPath ([ordered]@{
                    toolName='pester'
                     resolvedVersion='6.2.0'
                    identityKind='approved-payload-and-installed-closure'
                     frozenForRun=$true
                    installRoot=$installRoot
                     modulePath=$manifestPath
                     executableSha256=$manifestSha
                    dependencyClosure=@($closure)
                     dependencyClosureSha256=$closureSha
                     installedClosureSha256=$closureSha
                })
            $receiptSha = (Get-FileHash $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($scenario -eq 'tampered') {
                [IO.File]::AppendAllText($modulePath, "`n# tampered", [Text.UTF8Encoding]::new($false))
            }
            $oldScenario = $env:FAKE_PESTER_SCENARIO
            $oldRunId = $env:STANDARD_VALIDATION_CORE_RUN_ID
            $oldCheckId = $env:STANDARD_VALIDATION_CORE_CHECK_ID
            $oldSkills = $env:STANDARD_VALIDATION_CORE_SKILLS
            try {
                $env:FAKE_PESTER_SCENARIO = $scenario
                $env:STANDARD_VALIDATION_CORE_RUN_ID = $runId
                $env:STANDARD_VALIDATION_CORE_CHECK_ID = 'fixture-pester'
                $env:STANDARD_VALIDATION_CORE_SKILLS = 'fixture'
                Push-Location $candidate
                try {
                    $output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File `
                            (Join-Path $runtime 'Invoke-ConsumerRepositoryCheck.ps1') -Mode pester `
                            -PesterReceiptSha256 $receiptSha -PesterManifestSha256 $manifestSha `
                            -PesterVersion 6.2.0 2>&1)
                    $exitCode = $LASTEXITCODE
                }
                finally { Pop-Location }
            }
            finally {
                $env:FAKE_PESTER_SCENARIO = $oldScenario
                $env:STANDARD_VALIDATION_CORE_RUN_ID = $oldRunId
                $env:STANDARD_VALIDATION_CORE_CHECK_ID = $oldCheckId
                $env:STANDARD_VALIDATION_CORE_SKILLS = $oldSkills
            }
            if ($scenario -eq 'success') {
                $exitCode | Should Be 0
                ($output -join "`n") | Should Match '"passed":1'
                (Get-Content -Raw (Join-Path $workRoot "$runId/repository-pester-case-inventory-v1.json") | `
                        ConvertFrom-Json).complete | Should Be $true
            }
            else {
                $exitCode | Should Be 1
            }
        }
    }

    # Scenario: Config and protected-file gates are reviewed as a single authority contract.
    # Purpose: Require tracked checks, exact required coverage, exception blocking, byte-equivalent templates, and no deleted legacy path.
    It 'UnitT60_keeps_config_workflow_exception_and_legacy_barriers_fail_closed' {
        $module = Get-Content -Raw -Encoding UTF8 $script:GateModule
        $requiredBarriers = @(
            'Required repository check is missing', 'General repository check is not a canonical tracked file',
            'General repository check points to a deleted legacy path', 'SkillSpector exception set changed',
            'Unexpected workflow', 'Candidate consumer-gate.yml is missing',
            'Removed legacy path is present', 'Repository has advanced'
        )
        foreach ($required in $requiredBarriers) {
            $module | Should Match ([regex]::Escape($required))
        }
    }
}
