Describe 'Authority-owned consumer source gate' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:GateModule = Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1'
        Import-Module $script:GateModule -Force
        $script:GitHooksRoot = Join-Path $TestDrive 'gate-hooks-root'
        [void][IO.Directory]::CreateDirectory($script:GitHooksRoot)
        Initialize-GateGitHooks $script:GitHooksRoot
        function Restore-GateFixtureModule {
            Import-Module $script:GateModule -Force
            Initialize-GateGitHooks $script:GitHooksRoot
        }
        function Restore-ClosureFixtureModule {
            Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        }
        function Write-FixtureJson([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 30),(New-Object `
            Text.UTF8Encoding($false))) }
        function Invoke-SourceFixtureGit([string]$Root,[string[]]$Arguments){$output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1)
        if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join' ')"}
        $output}
        function Get-SourceFixtureGitScalar([string]$Root,[string[]]$Arguments){([string](@(Invoke-SourceFixtureGit $Root $Arguments)[0])).Trim()}
        function Copy-FixtureValue($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
        function Assert-ExactObjectShape($Value,[string[]]$Properties){
            (@($Value.PSObject.Properties.Name)-join',')|Should Be ($Properties-join',')
        }
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
        (@($manifest.repositories.id)-join"`n") | Should Be (@(
                'skill-general','skill-atlassian-ecosystem','skill-code-collaboration','skill-knowledge-content','skill-darktide-translate'
            )-join"`n")
        @($manifest.repositories | Where-Object status -eq ready).Count | Should Be 4
        $darktide = @($manifest.repositories | Where-Object id -eq skill-darktide-translate)[0]
        $darktide.status | Should Be pending-prerequisites
        $darktide.additionalScope | Should Be @('skills/auto-update-darktide-mod/scripts/')
        $expectedFileRows=@(
            '.github/workflows/standard-v1-candidate-windows.yml|delete||','config/standard-v1.json|delete||',
            'scripts/Get-SourcePin.ps1|delete||','scripts/Install-LatestPowerShell.ps1|delete||',
            'scripts/Invoke-PrePushValidation.ps1|delete||','scripts/PowerShellRelease.psm1|delete||',
            'scripts/Test-CleanRepositoryHead.ps1|retain||','scripts/Test-Repository.ps1|split||scripts/Test-DarktideRepository.ps1',
            'scripts/Validate.ps1|delete||',
            'skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1|retain||',
            'skills/auto-update-darktide-mod/scripts/mod-update.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/PathSafety.psm1|retain||',
            'skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|retain||',
            'skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|retain||',
            'skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|retain||',
            'tests/AtomicValidationOutput.Tests.ps1|update-tests|rewrite|','tests/BootstrapTransition.Tests.ps1|update-tests|rewrite|',
            'tests/CanonicalValidation.Tests.ps1|update-tests|rewrite|','tests/InstalledClosureOrdering.Tests.ps1|update-tests|rewrite|',
            'tests/Invoke-Tests.ps1|retain||','tests/LocalizationWorkset.Tests.ps1|update-tests|rewrite|',
            'tests/ModUpdateAutomation.Tests.ps1|update-tests|rewrite|','tests/RepositoryContract.Tests.ps1|update-tests|rewrite|',
            'tests/RepositoryValidation.Tests.ps1|update-tests|rewrite|','tests/Schema15Coordination.Tests.ps1|update-tests|rewrite|',
            'tests/Schema15SourceAcquisition.Tests.ps1|update-tests|rewrite|','tests/SkillContract.Tests.ps1|update-tests|rewrite|',
            'tests/SkillSpectorOutput.Tests.ps1|update-tests|rewrite|','tests/SourcePin.Tests.ps1|update-tests|rewrite|',
            'tests/StandardV1Conformance.Tests.ps1|update-tests|rewrite|','tests/Test-Repository.Tests.ps1|update-tests|rewrite|',
            'tests/TestSupport.ps1|update-tests|rewrite|','tests/ValidationTransition.Tests.ps1|update-tests|rewrite|'
        )
        $actualFileRows=@($darktide.files|ForEach-Object{
                $outcome=if($null-ne$_.PSObject.Properties['expectedOutcome']){[string]$_.expectedOutcome}else{''}
                $target=if($null-ne$_.PSObject.Properties['target']){[string]$_.target}else{''}
                "$($_.path)|$($_.disposition)|$outcome|$target"
            })
        @($actualFileRows).Count | Should Be 42
        (@($actualFileRows)-join"`n") | Should Be (@($expectedFileRows)-join"`n")
        $expectedChecks=@(
            'repository-darktide|general|scripts/Test-DarktideRepository.ps1','repository-pester|pester|tests'
        )
        (@($darktide.requiredRepositoryChecks|ForEach-Object{"$($_.id)|$($_.kind)|$($_.path)"})-join"`n") |
            Should Be (@($expectedChecks)-join"`n")
        $portableRequirement='S8 must make the retained or rewritten file portable on Windows, Linux, and macOS without skips.'
        $scriptRequirement='S8 must verify this retained Skill runtime script and its exercised branches on Windows, Linux, and macOS.'
        $expectedPrerequisiteRows=@(
            "portable-01|tests/InstalledClosureOrdering.Tests.ps1|$portableRequirement",
            "portable-02|tests/LocalizationWorkset.Tests.ps1|$portableRequirement",
            "portable-03|tests/ModUpdateAutomation.Tests.ps1|$portableRequirement",
            "portable-04|tests/RepositoryContract.Tests.ps1|$portableRequirement",
            "portable-05|tests/Schema15Coordination.Tests.ps1|$portableRequirement",
            "portable-06|tests/Schema15SourceAcquisition.Tests.ps1|$portableRequirement",
            "portable-07|tests/SkillContract.Tests.ps1|$portableRequirement",
            "portable-08|tests/SkillSpectorOutput.Tests.ps1|$portableRequirement",
            "portable-09|tests/TestSupport.ps1|$portableRequirement","portable-10|tests/Invoke-Tests.ps1|$portableRequirement",
            "portable-12|scripts/Test-CleanRepositoryHead.ps1|$portableRequirement",
            'portable-13|scripts/Test-Repository.ps1|S8 must extract the Darktide-specific contract into portable scripts/Test-DarktideRepository.ps1 and remove the split source before re-inventory.',
            "portable-skill-script-01|skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|$scriptRequirement",
            "portable-skill-script-02|skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|$scriptRequirement",
            "portable-skill-script-03|skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|$scriptRequirement",
            "portable-skill-script-04|skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|$scriptRequirement",
            "portable-skill-script-05|skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1|$scriptRequirement",
            "portable-skill-script-06|skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1|$scriptRequirement",
            "portable-skill-script-07|skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|$scriptRequirement",
            "portable-skill-script-08|skills/auto-update-darktide-mod/scripts/PathSafety.psm1|$scriptRequirement",
            "portable-skill-script-09|skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|$scriptRequirement",
            "portable-skill-script-10|skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|$scriptRequirement",
            "portable-skill-script-11|skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|$scriptRequirement",
            "portable-skill-script-12|skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|$scriptRequirement",
            "portable-skill-script-13|skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|$scriptRequirement",
            "portable-skill-script-14|skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|$scriptRequirement",
            "portable-skill-script-15|skills/auto-update-darktide-mod/scripts/mod-update.ps1|$scriptRequirement",
            'remove-legacy-installed-closure|tests/InstalledClosureOrdering.Tests.ps1|Remove extraction of helpers from scripts/Validate.ps1 and rewrite the test for the consumer layout.',
            'remove-legacy-repository-contract|tests/RepositoryContract.Tests.ps1|Remove assertions and execution paths for deleted workflow, configuration, scripts/Validate.ps1, and legacy-layout branches.',
            'remove-legacy-skillspector-output|tests/SkillSpectorOutput.Tests.ps1|Remove the dependency on scripts/Validate.ps1 and exercise the consumer gate evidence contract instead.',
            'support-consumer-layout|tests/TestSupport.ps1|Support the consumer layout with config/authority-pin.json and config/consumer-gate.json while preserving the required transition coverage.',
            'replace-legacy-pre-push|scripts/Invoke-PrePushValidation.ps1|Delete this legacy entry or replace it with a separate portable consumer bootstrap development entry before re-inventory.',
            'portable-link-helper|tests/RepositoryContract.Tests.ps1|Replace the unconditional Junction fixture with the existing platform-aware link helper.',
            'portable-pwsh-fixture|tests/SkillSpectorOutput.Tests.ps1|Resolve pwsh or pwsh.exe by platform and use a native shell fixture on Unix.',
            'portable-long-path-expectations|tests/ModUpdateAutomation.Tests.ps1|Register Windows long-path assertions only on Windows and add corresponding Unix behavior assertions.',
            'portable-path-comparer|tests/ModUpdateAutomation.Tests.ps1|Register the case-insensitive InterT109 only on Windows and add Unix case-sensitive coverage.',
            'portable-path-safety-native|skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Exercise and verify the non-Windows branch without requiring the Windows-only native type.',
            'portable-multiprocess-coordination|tests/Schema15Coordination.Tests.ps1|Demonstrate InterT180 completes on Windows, Linux, and macOS.'
        )
        $actualPrerequisiteRows=@($darktide.prerequisites|ForEach-Object{"$($_.id)|$($_.path)|$($_.requirement)"})
        @($actualPrerequisiteRows).Count | Should Be 38
        (@($actualPrerequisiteRows)-join"`n") | Should Be (@($expectedPrerequisiteRows)-join"`n")
        $fileCountOracle=[ordered]@{
            'skill-general'=45;'skill-atlassian-ecosystem'=99;'skill-code-collaboration'=23
            'skill-knowledge-content'=17;'skill-darktide-translate'=42
        }
        foreach ($entry in $manifest.repositories) {
            $entry.inventoryCommit | Should Match '^[0-9a-f]{40}$'
             $entry.inventoryTree | Should Match '^[0-9a-f]{40}$'
            @($entry.files).Count | Should Be $fileCountOracle[[string]$entry.id]
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

    # Scenario: Every frozen section 7.2 schema and cross-field rule is mutated independently.
    # Purpose: Invalid status, scope, prerequisite, exemption, check, and outcome shapes fail at their owning validation layer.
    It 'UnitT14_rejects_the_complete_legacy_manifest_negative_matrix' {
        $manifestPath=Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json'
        $schema=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-legacy-migration-v1.schema.json')
        $base=Get-Content -Raw -Encoding UTF8 $manifestPath|ConvertFrom-Json -Depth 100
        foreach($allowedPath in @('tests/Legacy fixture.Tests.ps1','tests/傳統測試.Tests.ps1')){
            $positive=Copy-FixtureValue $base
            $positiveEntry=@($positive.repositories|Where-Object{$_.id-eq'skill-general'})[0]
            $positiveEntry.files[0].path=$allowedPath
            (Test-Json -Json ($positive|ConvertTo-Json -Depth 100) -Schema $schema)|Should Be $true
            $positiveAuthority=Join-Path $TestDrive ('path-positive-'+[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($allowedPath)))
            [void][IO.Directory]::CreateDirectory((Join-Path $positiveAuthority 'consumer'))
            Write-FixtureJson (Join-Path $positiveAuthority 'consumer/legacy-migration.json') $positive
            {Get-GateManifestEntry $positiveAuthority 'skill-general'}|Should Not Throw
        }
        $schemaCases=@(
            @{Id='ready-prerequisites';Apply={param($m)$e=@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0];$e|Add-Member prerequisites @([pscustomobject]@{id='x';path=$e.files[0].path;requirement='x'})}},
            @{Id='pending-missing-prerequisites';Apply={param($m)$e=@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0];$e.PSObject.Properties.Remove('prerequisites')}},
            @{Id='pending-empty-prerequisites';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).prerequisites=@()}},
            @{Id='retired-deferred-status';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).status='deferred'}},
            @{Id='prerequisite-glob';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).prerequisites[0].path='tests/*.ps1'}},
            @{Id='scope-glob';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('skills/*/')}},
            @{Id='scope-dot';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('skills/./scripts/')}},
            @{Id='scope-dotdot';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('skills/x/../scripts/')}},
            @{Id='scope-backslash';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('skills\x\')}},
            @{Id='scope-no-trailing-slash';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('skills/x')}},
            @{Id='outcome-missing';Apply={param($m)$f=@(@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0].files|Where-Object{$_.disposition-eq'update-tests'})[0];$f.PSObject.Properties.Remove('expectedOutcome')}},
            @{Id='outcome-invalid';Apply={param($m)$f=@(@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0].files|Where-Object{$_.disposition-eq'update-tests'})[0];$f.expectedOutcome='keep'}},
            @{Id='outcome-on-retain';Apply={param($m)$f=@(@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0].files|Where-Object{$_.disposition-eq'retain'})[0];$f|Add-Member expectedOutcome rewrite}}
        )
        $exemptionMutations=@(
            @{Id='missing-file';Apply={param($x)$x.PSObject.Properties.Remove('file')}},
            @{Id='missing-blob';Apply={param($x)$x.PSObject.Properties.Remove('blobOid')}},
            @{Id='missing-line';Apply={param($x)$x.PSObject.Properties.Remove('line')}},
            @{Id='missing-column';Apply={param($x)$x.PSObject.Properties.Remove('column')}},
            @{Id='missing-ordinal';Apply={param($x)$x.PSObject.Properties.Remove('occurrenceOrdinal')}},
            @{Id='missing-target';Apply={param($x)$x.PSObject.Properties.Remove('targetPath')}},
            @{Id='missing-reason';Apply={param($x)$x.PSObject.Properties.Remove('reason')}},
            @{Id='extra-field';Apply={param($x)$x|Add-Member extra blocked}},
            @{Id='blob-short';Apply={param($x)$x.blobOid='f'*39}},
            @{Id='blob-uppercase';Apply={param($x)$x.blobOid='F'*40}},
            @{Id='file-glob';Apply={param($x)$x.file='tests/*.ps1'}},
            @{Id='target-dotdot';Apply={param($x)$x.targetPath='tests/../legacy.ps1'}},
            @{Id='line-zero';Apply={param($x)$x.line=0}},@{Id='line-negative';Apply={param($x)$x.line=-1}},
            @{Id='line-double';Apply={param($x)$x.line=[double]1.5}},@{Id='line-string';Apply={param($x)$x.line='1'}},
            @{Id='line-bool';Apply={param($x)$x.line=$true}},
            @{Id='column-zero';Apply={param($x)$x.column=0}},@{Id='column-negative';Apply={param($x)$x.column=-1}},
            @{Id='column-double';Apply={param($x)$x.column=[double]1.5}},@{Id='column-string';Apply={param($x)$x.column='1'}},
            @{Id='column-bool';Apply={param($x)$x.column=$true}},
            @{Id='ordinal-zero';Apply={param($x)$x.occurrenceOrdinal=0}},
            @{Id='ordinal-negative';Apply={param($x)$x.occurrenceOrdinal=-1}},
            @{Id='ordinal-double';Apply={param($x)$x.occurrenceOrdinal=[double]1.5}},
            @{Id='ordinal-string';Apply={param($x)$x.occurrenceOrdinal='1'}},
            @{Id='ordinal-bool';Apply={param($x)$x.occurrenceOrdinal=$true}},
            @{Id='reason-empty';Apply={param($x)$x.reason=''}},@{Id='reason-null';Apply={param($x)$x.reason=$null}}
        )
        foreach($mutation in $exemptionMutations){
            $schemaCases+=@{Id="exemption-$($mutation.Id)";Apply={param($m)
                    $entry=@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0]
                    $retain=@($entry.files|Where-Object{$_.disposition-eq'retain'})[0]
                    $legacy=@($entry.files|Where-Object{$_.disposition-in@('delete','split','update-tests')})[0]
                    $item=[pscustomobject]@{file=$retain.path;blobOid=('a'*40);line=1;column=1;occurrenceOrdinal=1;targetPath=$legacy.path;reason='fixture'}
                    & $mutation.Apply $item
                    $entry|Add-Member literalReferenceExemptions @($item)
                }.GetNewClosure()}
        }
        @($schemaCases).Count | Should Be 42
        foreach($case in $schemaCases){
            $candidate=Copy-FixtureValue $base
            & $case.Apply $candidate
            (Test-Json -Json ($candidate|ConvertTo-Json -Depth 100) -Schema $schema -ErrorAction SilentlyContinue) | Should Be $false
        }

        $semanticCases=@(
            @{Id='duplicate-prerequisite-id';RepositoryId='skill-darktide-translate';Apply={param($m)$e=@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0];$x=Copy-FixtureValue $e.prerequisites[0];$x.path=$e.prerequisites[1].path;$e.prerequisites=@($e.prerequisites)+@($x)}},
            @{Id='prerequisite-path-not-in-files';RepositoryId='skill-darktide-translate';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).prerequisites[0].path='tests/not-listed.ps1'}},
            @{Id='duplicate-required-check-path';RepositoryId='skill-general';Apply={param($m)$e=@($m.repositories|Where-Object{$_.id-eq'skill-general'})[0];$x=Copy-FixtureValue $e.requiredRepositoryChecks[0];$x.id='different-id';$e.requiredRepositoryChecks=@($e.requiredRepositoryChecks)+@($x)}},
            @{Id='scope-overlaps-basic-scope';RepositoryId='skill-darktide-translate';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).additionalScope=@('scripts/additional/')}},
            @{Id='exemption-file-not-listed';RepositoryId='skill-general';Exemption='file-missing'},
            @{Id='exemption-file-not-retain';RepositoryId='skill-general';Exemption='file-delete'},
            @{Id='exemption-target-not-legacy';RepositoryId='skill-general';Exemption='target-retain'},
            @{Id='exemption-duplicate-tuple';RepositoryId='skill-general';Exemption='duplicate'}
        )
        @($semanticCases).Count | Should Be 8
        foreach($case in $semanticCases){
            $candidate=Copy-FixtureValue $base
            if($null-ne$case.Apply){& $case.Apply $candidate}else{
                $entry=@($candidate.repositories|Where-Object{$_.id-eq$case.RepositoryId})[0]
                $retain=@($entry.files|Where-Object{$_.disposition-eq'retain'})[0]
                $legacy=@($entry.files|Where-Object{$_.disposition-in@('delete','split','update-tests')})[0]
                $item=[pscustomobject]@{file=$retain.path;blobOid=('a'*40);line=1;column=1;occurrenceOrdinal=1;targetPath=$legacy.path;reason='fixture'}
                if($case.Exemption-eq'file-missing'){$item.file='tests/not-listed.ps1'}
                if($case.Exemption-eq'file-delete'){$item.file=$legacy.path}
                if($case.Exemption-eq'target-retain'){$item.targetPath=$retain.path}
                $entry|Add-Member literalReferenceExemptions $(if($case.Exemption-eq'duplicate'){@($item,(Copy-FixtureValue $item))}else{@($item)})
            }
            $authority=Join-Path $TestDrive ("semantic-"+$case.Id)
            [void][IO.Directory]::CreateDirectory((Join-Path $authority 'consumer'))
            Write-FixtureJson (Join-Path $authority 'consumer/legacy-migration.json') $candidate
            {Get-GateManifestEntry $authority $case.RepositoryId}|Should Throw
        }
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
        $darktide = @($manifest.repositories | Where-Object id -eq 'skill-darktide-translate')[0]
        foreach ($path in @(
                'tests/LocalizationWorkset.Tests.ps1','tests/ModUpdateAutomation.Tests.ps1',
                'tests/Schema15Coordination.Tests.ps1','tests/Schema15SourceAcquisition.Tests.ps1',
                'tests/SkillContract.Tests.ps1'
            )) {
            $record = @($darktide.files | Where-Object path -eq $path)[0]
            $record.disposition | Should Be 'update-tests'
            $record.expectedOutcome | Should Be 'rewrite'
            $record.reason | Should Match 'dot-sources tests/TestSupport.ps1'
        }
        @($darktide.prerequisites | Where-Object id -eq 'portable-11').Count | Should Be 0
        @($darktide.prerequisites | Where-Object id -eq 'replace-legacy-pre-push').Count | Should Be 1
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
. 'scripts/sub/../Legacy.ps1'
$binary = 'scripts','Legacy.ps1' -join '/'
$unary = -join ('scripts/','Legacy.ps1')
$array = @('scripts','Legacy.ps1') -join '/'
$format = 'scripts/{0}.{1}' -f 'Legacy','ps1'
'scripts/Legacy.ps1' + ';' + ('scripts/' + 'Legacy.ps1')
Copy-Item -Path ([string]$source) -Destination 'scripts/Legacy.ps1'
Copy-Item -Lit $source -Destination 'scripts/Legacy.ps1'
Write-Output 'scripts/Legacy.ps1'
'@
        [IO.File]::WriteAllText(
            (Join-Path $root 'scripts/Retained.ps1'),
            $powershell,
            [Text.UTF8Encoding]::new($false)
        )
        $dynamicCommands = @(
            'Get-Content $dynamic','Test-Path $dynamic','Get-Item $dynamic','Get-ChildItem $dynamic',
            'Resolve-Path $dynamic','Set-Content -Path $dynamic -Value x','Out-File -FilePath $dynamic',
            'Import-PowerShellDataFile $dynamic','Copy-Item $dynamic','Move-Item $dynamic','Import-Module $dynamic',
            'gc $dynamic','cat $dynamic','type $dynamic','gi $dynamic','ls $dynamic','dir $dynamic','gci $dynamic',
            'cp $dynamic','copy $dynamic','mv $dynamic','move $dynamic','ipmo $dynamic',
            '. $dynamic','& $dynamic','[IO.File]::ReadAllText($dynamic)',
            '[IO.Directory]::GetFiles($dynamic)',
            '[System.Management.Automation.Language.Parser]::ParseFile($dynamic,[ref]$null,[ref]$null)'
        )
        [IO.File]::WriteAllText(
            (Join-Path $root 'scripts/dynamic.ps1'),
            ($dynamicCommands -join "`n") + "`n",
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
            [ordered]@{ path='scripts/dynamic.ps1'
             disposition='retain'
             reason='fixture dynamic consumers' },
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
        $retainedOid = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD:scripts/Retained.ps1')
        $lines = $powershell -split "`n"
        $exemptions = @(
            [ordered]@{
                file='scripts/Retained.ps1';blobOid=$retainedOid;line=7
                column=$lines[6].IndexOf('scripts/Legacy.ps1')+1;occurrenceOrdinal=1
                targetPath='scripts/Legacy.ps1';reason='Blocked by cast source operand.'
            },
            [ordered]@{
                file='scripts/Retained.ps1';blobOid=$retainedOid;line=8
                column=$lines[7].IndexOf('scripts/Legacy.ps1')+1;occurrenceOrdinal=1
                targetPath='scripts/Legacy.ps1';reason='Blocked by abbreviated parameter.'
            },
            [ordered]@{
                file='scripts/Retained.ps1';blobOid=$retainedOid;line=9
                column=$lines[8].IndexOf('scripts/Legacy.ps1')+1;occurrenceOrdinal=1
                targetPath='scripts/Legacy.ps1';reason='Message-only literal.'
            }
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
                      literalReferenceExemptions=$exemptions
                }) }
        $manifestPath = Join-Path $TestDrive 'closure-golden.json'
        Write-FixtureJson $manifestPath $manifest
        $result = Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory `
            -Manifest $manifestPath -RepositoryId fixture -AuthorityRoot $script:RepositoryRoot
        $result.result | Should Be FAILED
        $result.counts.scannedFiles | Should Be 6
        $result.counts.legacyReference | Should Be 11
        $result.counts.parseError | Should Be 0
        $result.counts.templateIntegrity | Should Be 0
        $result.counts.splitSourcePresent | Should Be 0
        $result.counts.updateTestsOutcome | Should Be 0
        $result.counts.staleExemption | Should Be 2
        $result.counts.exemptedReference | Should Be 1
        $result.counts.dynamicReference | Should Be 29
        $result.counts.documentationReference | Should Be 1
        $result.counts.binary | Should Be 1
        @($result.violations | Where-Object file -eq 'scripts/reference.py').Count | Should Be 1
        @($result.violations | Where-Object file -eq 'scripts/utf16.ps1').Count | Should Be 1
        @($result.violations | Where-Object {
                $_.file -eq 'scripts/reference.py' -and $_.kind -eq 'legacy-reference' -and
                $_.line -eq 1 -and $_.column -eq 9 -and $_.occurrenceOrdinal -eq 1
            }).Count | Should Be 1
        @($result.violations | Where-Object {
                $_.file -eq 'scripts/utf16.ps1' -and $_.kind -eq 'legacy-reference' -and
                $_.line -eq 1 -and $_.column -eq 4 -and $_.occurrenceOrdinal -eq 1
            }).Count | Should Be 1
        @($result.violations | Where-Object {
                $_.kind -eq 'stale-exemption' -and $_.file -eq 'scripts/Retained.ps1' -and
                $_.line -eq 7 -and $_.column -eq ($lines[6].IndexOf('scripts/Legacy.ps1') + 1) -and
                $_.occurrenceOrdinal -eq 1 -and $_.targetPath -eq 'scripts/Legacy.ps1'
            }).Count | Should Be 1
        @($result.violations | Where-Object {
                $_.kind -eq 'stale-exemption' -and $_.file -eq 'scripts/Retained.ps1' -and
                $_.line -eq 8 -and $_.column -eq ($lines[7].IndexOf('scripts/Legacy.ps1') + 1) -and
                $_.occurrenceOrdinal -eq 1 -and $_.targetPath -eq 'scripts/Legacy.ps1'
            }).Count | Should Be 1
        $forms = @($result.violations | Where-Object {
                $_.file -eq 'scripts/Retained.ps1' -and $_.kind -eq 'legacy-reference'
            })
        @($forms).Count | Should Be 9
        @($forms | Where-Object { $_.line -eq 1 -and $_.column -eq 4 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 2 -and $_.column -eq 11 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 3 -and $_.column -eq 10 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 4 -and $_.column -eq 10 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 5 -and $_.column -eq 11 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 6 -and $_.column -eq 2 -and $_.occurrenceOrdinal -eq 1 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -eq 6 -and $_.column -eq 1 -and $_.occurrenceOrdinal -eq 2 }).Count | Should Be 1
        @($forms | Where-Object { $_.line -in @(7,8) -and $_.kind -eq 'legacy-reference' }).Count | Should Be 2
        for ($index = 0; $index -lt $dynamicCommands.Count; $index++) {
            $expectedLine = $index + 1
            $expectedColumn = $dynamicCommands[$index].IndexOf('$dynamic') + 1
            @($result.advisories | Where-Object {
                    $_.kind -eq 'dynamic-reference' -and $_.file -eq 'scripts/dynamic.ps1' -and
                    $_.line -eq $expectedLine -and $_.column -eq $expectedColumn -and
                    $_.reference -eq '$dynamic' -and $null -eq $_.targetPath
                }).Count | Should Be 1
        }
        @($result.advisories | Where-Object {
                $_.kind -eq 'dynamic-reference' -and $_.file -eq 'scripts/Retained.ps1' -and
                $_.line -eq 7 -and $_.column -eq 17 -and $_.reference -eq '([string]$source)'
            }).Count | Should Be 1
        @($result.advisories | Where-Object {
                $_.kind -eq 'documentation-reference' -and $_.file -eq 'docs/history.md' -and
                $_.line -eq 1 -and $_.column -eq 12 -and $_.targetPath -eq 'scripts/Legacy.ps1'
            }).Count | Should Be 1
        @($result.advisories | Where-Object {
                $_.kind -eq 'binary' -and $_.file -eq 'scripts/payload.bin' -and
                $null -eq $_.line -and $null -eq $_.column -and $null -eq $_.reference -and $null -eq $_.targetPath
            }).Count | Should Be 1
    }

    # Scenario: Inventory and conversion each produce every structural violation kind with an exact identity and count.
    # Purpose: Keep parse, stale-exemption, template, split, and update outcome failures independently observable.
    It 'InterT23_reports_exact_inventory_and_conversion_violation_unions' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $inventoryRoot = Join-Path $TestDrive 'closure-inventory-kinds'
        [void][IO.Directory]::CreateDirectory((Join-Path $inventoryRoot 'scripts'))
        [void](Invoke-SourceFixtureGit $inventoryRoot @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $inventoryRoot @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $inventoryRoot @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $inventoryRoot 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $inventoryRoot 'scripts/Bad.ps1'),'if (',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $inventoryRoot 'scripts/Clean.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $inventoryRoot @('add','.'))
        [void](Invoke-SourceFixtureGit $inventoryRoot @('commit','-q','-m','inventory kinds'))
        $inventoryCommit = Get-SourceFixtureGitScalar $inventoryRoot @('rev-parse','HEAD')
        $inventoryTree = Get-SourceFixtureGitScalar $inventoryRoot @('rev-parse','HEAD^{tree}')
        $cleanOid = Get-SourceFixtureGitScalar $inventoryRoot @('rev-parse','HEAD:scripts/Clean.ps1')
        $inventoryManifest = [ordered]@{schemaVersion=1;repositories=@([ordered]@{
                    id='inventory-kinds';repository='https://example.test/inventory.git';status='ready'
                    inventoryCommit=$inventoryCommit;inventoryTree=$inventoryTree;requiredRepositoryChecks=@()
                    files=@(
                        [ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'},
                        [ordered]@{path='scripts/Bad.ps1';disposition='retain';reason='parse fixture'},
                        [ordered]@{path='scripts/Clean.ps1';disposition='retain';reason='stale fixture'}
                    )
                    literalReferenceExemptions=@([ordered]@{
                            file='scripts/Clean.ps1';blobOid=$cleanOid;line=1;column=1;occurrenceOrdinal=1
                            targetPath='scripts/Legacy.ps1';reason='Deliberately stale fixture.'
                        })
                })}
        $inventoryManifestPath = Join-Path $TestDrive 'closure-inventory-kinds.json'
        Write-FixtureJson $inventoryManifestPath $inventoryManifest
        $inventoryResult = Get-ConsumerManifestClosure -RepositoryRoot $inventoryRoot -Commit $inventoryCommit `
            -Stage inventory -Manifest $inventoryManifestPath -RepositoryId inventory-kinds `
            -AuthorityRoot $script:RepositoryRoot
        $inventoryResult.result | Should Be 'FAILED'
        @($inventoryResult.violations).Count | Should Be 2
        @($inventoryResult.violations | Where-Object kind -eq 'parse-error').Count | Should Be 1
        Assert-ExactObjectShape (@($inventoryResult.violations|Where-Object kind -eq 'parse-error')[0]) `
            @('kind','file','line','column','message')
        Assert-ExactObjectShape (@($inventoryResult.violations|Where-Object kind -eq 'stale-exemption')[0]) `
            @('kind','file','blobOid','line','column','occurrenceOrdinal','targetPath')
        @($inventoryResult.violations | Where-Object {
                $_.kind -eq 'parse-error' -and $_.file -eq 'scripts/Bad.ps1' -and $_.line -eq 1 -and $_.column -eq 5
            }).Count | Should Be 1
        @($inventoryResult.violations | Where-Object {
                $_.kind -eq 'stale-exemption' -and $_.file -eq 'scripts/Clean.ps1' -and
                $_.line -eq 1 -and $_.column -eq 1 -and $_.occurrenceOrdinal -eq 1
            }).Count | Should Be 1
        $inventoryResult.counts.scannedFiles | Should Be 2
        $inventoryResult.counts.parseError | Should Be 1
        $inventoryResult.counts.staleExemption | Should Be 1

        $conversionRoot = Join-Path $TestDrive 'closure-conversion-kinds'
        foreach ($directory in @('scripts','tests','.github/workflows')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $conversionRoot $directory))
        }
        [void](Invoke-SourceFixtureGit $conversionRoot @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $conversionRoot @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $conversionRoot @('config','user.email','fixture@example.test'))
        foreach ($path in @(
                'scripts/Split.ps1','tests/Delete.Tests.ps1','tests/Rewrite.Tests.ps1',
                'scripts/Invoke-PinnedAuthority.ps1','.github/workflows/consumer-gate.yml',
                '.github/workflows/consumer-gate-transition.yml'
            )) {
            [IO.File]::WriteAllText((Join-Path $conversionRoot $path),'fixture mismatch',[Text.UTF8Encoding]::new($false))
        }
        [void](Invoke-SourceFixtureGit $conversionRoot @('add','.'))
        [void](Invoke-SourceFixtureGit $conversionRoot @('commit','-q','-m','conversion base'))
        $conversionCommit = Get-SourceFixtureGitScalar $conversionRoot @('rev-parse','HEAD')
        $conversionTree = Get-SourceFixtureGitScalar $conversionRoot @('rev-parse','HEAD^{tree}')
        $conversionManifest = [ordered]@{schemaVersion=1;repositories=@([ordered]@{
                    id='conversion-kinds';repository='https://example.test/conversion.git';status='ready'
                    inventoryCommit=$conversionCommit;inventoryTree=$conversionTree;requiredRepositoryChecks=@()
                    files=@(
                        [ordered]@{path='scripts/Split.ps1';disposition='split';target='scripts/New.ps1';reason='split'},
                        [ordered]@{path='tests/Delete.Tests.ps1';disposition='update-tests';expectedOutcome='delete';reason='delete'},
                        [ordered]@{path='tests/Rewrite.Tests.ps1';disposition='update-tests';expectedOutcome='rewrite';reason='rewrite'},
                        [ordered]@{path='scripts/Invoke-PinnedAuthority.ps1';disposition='retain';reason='template'},
                        [ordered]@{path='.github/workflows/consumer-gate.yml';disposition='retain';reason='template'},
                        [ordered]@{path='.github/workflows/consumer-gate-transition.yml';disposition='retain';reason='template'}
                    )
                })}
        $conversionManifestPath = Join-Path $TestDrive 'closure-conversion-kinds.json'
        Write-FixtureJson $conversionManifestPath $conversionManifest
        $conversionResult = Get-ConsumerManifestClosure -RepositoryRoot $conversionRoot -Commit $conversionCommit `
            -Stage conversion -InventoryCommit $conversionCommit -Manifest $conversionManifestPath `
            -RepositoryId conversion-kinds -AuthorityRoot $script:RepositoryRoot
        $conversionResult.result | Should Be 'FAILED'
        @($conversionResult.violations).Count | Should Be 6
        @($conversionResult.violations | Where-Object kind -eq 'template-integrity').Count | Should Be 3
        Assert-ExactObjectShape (@($conversionResult.violations|Where-Object kind -eq 'template-integrity')[0]) `
            @('kind','file','expectedSha256','actualSha256')
        Assert-ExactObjectShape (@($conversionResult.violations|Where-Object kind -eq 'split-source-present')[0]) `
            @('kind','file')
        Assert-ExactObjectShape (@($conversionResult.violations|Where-Object kind -eq 'update-tests-outcome')[0]) `
            @('kind','file','expectedOutcome','actual')
        @($conversionResult.violations | Where-Object {
                $_.kind -eq 'split-source-present' -and $_.file -eq 'scripts/Split.ps1'
            }).Count | Should Be 1
        @($conversionResult.violations | Where-Object {
                $_.kind -eq 'update-tests-outcome' -and $_.file -eq 'tests/Delete.Tests.ps1' -and
                $_.expectedOutcome -eq 'delete' -and $_.actual -eq 'unchanged'
            }).Count | Should Be 1
        @($conversionResult.violations | Where-Object {
                $_.kind -eq 'update-tests-outcome' -and $_.file -eq 'tests/Rewrite.Tests.ps1' -and
                $_.expectedOutcome -eq 'rewrite' -and $_.actual -eq 'unchanged'
            }).Count | Should Be 1
        $conversionResult.counts.scannedFiles | Should Be 3
        $conversionResult.counts.templateIntegrity | Should Be 3
        $conversionResult.counts.splitSourcePresent | Should Be 1
        $conversionResult.counts.updateTestsOutcome | Should Be 2
    }

    # Scenario: Every closure violation and advisory constructor is discovered from production AST and matched to a frozen property shape.
    # Purpose: Field deletion, rename, or an unknown field changes the machine-readable union contract immediately.
    It 'UnitT64_closes_every_manifest_union_property_shape' {
        $expected=[ordered]@{
            'legacy-reference'=@('kind','file','line','column','occurrenceOrdinal','reference','targetPath','targetDisposition')
            'parse-error'=@('kind','file','line','column','message')
            'template-integrity'=@('kind','file','expectedSha256','actualSha256')
            'split-source-present'=@('kind','file')
            'update-tests-outcome'=@('kind','file','expectedOutcome','actual')
            'stale-exemption'=@('kind','file','blobOid','line','column','occurrenceOrdinal','targetPath')
            'dynamic-reference'=@('kind','file','line','column','reference','targetPath')
            'documentation-reference'=@('kind','file','line','column','reference','targetPath')
            'binary'=@('kind','file','line','column','reference','targetPath')
        }
        $moduleText=Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($moduleText,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $actual=[ordered]@{}
        foreach($table in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.HashtableAst]},$true))){
            $pairs=@($table.KeyValuePairs)
            $kindPair=@($pairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq'kind'})
            if($kindPair.Count-ne1){continue}
            $kind=[string]$kindPair[0].Item2.SafeGetValue()
            if($expected.Keys-cnotcontains$kind){continue}
            $properties=@($pairs|ForEach-Object{[string]$_.Item1.SafeGetValue()})
            if($actual.Contains($kind)){(@($actual[$kind])-join',')|Should Be ($properties-join',')}else{$actual[$kind]=$properties}
        }
        (@($actual.Keys|Sort-Object)-join"`n")|Should Be (@($expected.Keys|Sort-Object)-join"`n")
        foreach($kind in $expected.Keys){
            (@($actual[$kind])-join',')|Should Be (@($expected[$kind])-join',')
            foreach($property in $expected[$kind]){
                (@($actual[$kind]|Where-Object{$_-cne$property})-join',')|Should Not Be (@($expected[$kind])-join',')
            }
            (@($actual[$kind])+@('unknown')-join',')|Should Not Be (@($expected[$kind])-join',')
        }
    }

    # Scenario: Each cmdlet and alias row is independently removed from an external copy of the path-consumer tables.
    # Purpose: Every table row has a golden vector that fails when that exact production mapping is deleted.
    It 'InterT24_detects_each_path_consumer_table_deletion_mutation' {
        $consumerOracle = [ordered]@{
            'Get-Content'=@('Path','LiteralPath','FilePath');'Test-Path'=@('Path','LiteralPath','FilePath')
            'Get-Item'=@('Path','LiteralPath','FilePath');'Get-ChildItem'=@('Path','LiteralPath','FilePath')
            'Resolve-Path'=@('Path','LiteralPath','FilePath');'Set-Content'=@('Path','LiteralPath','FilePath')
            'Out-File'=@('Path','LiteralPath','FilePath');'Import-PowerShellDataFile'=@('Path','LiteralPath','FilePath')
            'Copy-Item'=@('Path','LiteralPath','Destination');'Move-Item'=@('Path','LiteralPath','Destination')
            'Import-Module'=@('Name')
        }
        $aliasOracle = [ordered]@{
            gc='Get-Content';cat='Get-Content';type='Get-Content';gi='Get-Item';ls='Get-ChildItem';dir='Get-ChildItem'
            gci='Get-ChildItem';cp='Copy-Item';copy='Copy-Item';mv='Move-Item';move='Move-Item';ipmo='Import-Module'
        }
        $cases = @(
            @{Kind='consumer';Name='Get-Content';Command='Get-Content $dynamic'},
            @{Kind='consumer';Name='Test-Path';Command='Test-Path $dynamic'},
            @{Kind='consumer';Name='Get-Item';Command='Get-Item $dynamic'},
            @{Kind='consumer';Name='Get-ChildItem';Command='Get-ChildItem $dynamic'},
            @{Kind='consumer';Name='Resolve-Path';Command='Resolve-Path $dynamic'},
            @{Kind='consumer';Name='Set-Content';Command='Set-Content -Path $dynamic -Value x'},
            @{Kind='consumer';Name='Out-File';Command='Out-File -FilePath $dynamic'},
            @{Kind='consumer';Name='Import-PowerShellDataFile';Command='Import-PowerShellDataFile $dynamic'},
            @{Kind='consumer';Name='Copy-Item';Command='Copy-Item $dynamic'},
            @{Kind='consumer';Name='Move-Item';Command='Move-Item $dynamic'},
            @{Kind='consumer';Name='Import-Module';Command='Import-Module $dynamic'},
            @{Kind='alias';Name='gc';Command='gc $dynamic'},
            @{Kind='alias';Name='cat';Command='cat $dynamic'},
            @{Kind='alias';Name='type';Command='type $dynamic'},
            @{Kind='alias';Name='gi';Command='gi $dynamic'},
            @{Kind='alias';Name='ls';Command='ls $dynamic'},
            @{Kind='alias';Name='dir';Command='dir $dynamic'},
            @{Kind='alias';Name='gci';Command='gci $dynamic'},
            @{Kind='alias';Name='cp';Command='cp $dynamic'},
            @{Kind='alias';Name='copy';Command='copy $dynamic'},
            @{Kind='alias';Name='mv';Command='mv $dynamic'},
            @{Kind='alias';Name='move';Command='move $dynamic'},
            @{Kind='alias';Name='ipmo';Command='ipmo $dynamic'}
        )
        $modulePath = Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1'
        $moduleText = Get-Content -Raw -Encoding UTF8 $modulePath
        $tokens=$null;$parseErrors=$null
        $moduleAst=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count | Should Be 0
        $tableAssignments=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]},$true)|
            Where-Object{$_.Left.Extent.Text -in @('$script:ClosureAliases','$script:ClosurePathConsumers')})
        @($tableAssignments).Count | Should Be 2
        $productionTables=@{}
        foreach($assignment in $tableAssignments){
            $table=$assignment.Right.Expression
            $table -is [Management.Automation.Language.HashtableAst] | Should Be $true
            $rows=[ordered]@{}
            foreach($pair in $table.KeyValuePairs){
                $key=[string]$pair.Item1.SafeGetValue()
                $value=$pair.Item2.SafeGetValue()
                $rows[$key]=if($value-is[array]){@($value|ForEach-Object{[string]$_})}else{[string]$value}
            }
            $productionTables[$assignment.Left.Extent.Text]=[pscustomobject]@{Rows=$rows;Ast=$table}
        }
        (@($productionTables['$script:ClosureAliases'].Rows.Keys)-join"`n") | Should Be (@($aliasOracle.Keys)-join"`n")
        (@($productionTables['$script:ClosurePathConsumers'].Rows.Keys)-join"`n") | Should Be (@($consumerOracle.Keys)-join"`n")
        foreach($key in $aliasOracle.Keys){$productionTables['$script:ClosureAliases'].Rows[$key] | Should Be $aliasOracle[$key]}
        foreach($key in $consumerOracle.Keys){
            (@($productionTables['$script:ClosurePathConsumers'].Rows[$key])-join"`n") | Should Be (@($consumerOracle[$key])-join"`n")
        }
        foreach ($case in $cases) {
            $root = Join-Path $TestDrive ("mapping-" + $case.Name)
            [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
            [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
            [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
            [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
            [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'scripts/Dynamic.ps1'),$case.Command,[Text.UTF8Encoding]::new($false))
            [void](Invoke-SourceFixtureGit $root @('add','.'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','mapping fixture'))
            $commit = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
            $tree = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
            $manifestPath = Join-Path $TestDrive ("mapping-" + $case.Name + '.json')
            Write-FixtureJson $manifestPath ([ordered]@{schemaVersion=1;repositories=@([ordered]@{
                            id='mapping';repository='https://example.test/mapping.git';status='ready'
                            inventoryCommit=$commit;inventoryTree=$tree;requiredRepositoryChecks=@()
                            files=@(
                                [ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'},
                                [ordered]@{path='scripts/Dynamic.ps1';disposition='retain';reason='dynamic'}
                            )
                        })})
            $parameters = @{
                RepositoryRoot=$root;Commit=$commit;Stage='inventory';Manifest=$manifestPath
                RepositoryId='mapping';AuthorityRoot=$script:RepositoryRoot
            }
            $production = Get-ConsumerManifestClosure @parameters
            $production.counts.dynamicReference | Should Be 1

            $tableName=if($case.Kind-eq'alias'){'$script:ClosureAliases'}else{'$script:ClosurePathConsumers'}
            $tableAst=$productionTables[$tableName].Ast
            $pair=@($tableAst.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq[string]$case.Name})
            @($pair).Count | Should Be 1
            $startOffset=$pair[0].Item1.Extent.StartOffset
            $endOffset=$pair[0].Item2.Extent.EndOffset
            $mutatedText = $moduleText.Remove($startOffset,$endOffset-$startOffset)
            $mutatedText | Should Not Be $moduleText
            $mutantPath = Join-Path $TestDrive ("ConsumerManifestClosure-mutant-" + $case.Name + '.psm1')
            [IO.File]::WriteAllText($mutantPath, $mutatedText, [Text.UTF8Encoding]::new($false))
            $mutantModule = Import-Module $mutantPath -Force -PassThru
            try {
                $mutant = Get-ConsumerManifestClosure @parameters
                $mutant.counts.dynamicReference | Should Be 0
                $mutant.counts.dynamicReference | Should Not Be $production.counts.dynamicReference
            }
            finally {
                Remove-Module $mutantModule -Force
                Restore-ClosureFixtureModule
            }
        }
    }

    # Scenario: Folded occurrences appear before, between, and after a raw occurrence of the same legacy target.
    # Purpose: Raw/folded pairing follows source provenance so ordinals and occurrence-scoped exemptions stay stable.
    It 'InterT26_pairs_folded_and_raw_occurrences_by_source_provenance' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $root=Join-Path $TestDrive 'folded-provenance'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        $foldedFirst="('scripts/' + 'Legacy.ps1') + ';' + 'scripts/Legacy.ps1'"
        $interleaved="('scripts/' + 'Legacy.ps1') + ';' + 'scripts/Legacy.ps1' + ';' + ('scripts/' + 'Legacy.ps1')"
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/FoldedFirst.ps1'),$foldedFirst,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Exempted.ps1'),$interleaved,[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','fold provenance'))
        $commit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $tree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $exemptedOid=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD:scripts/Exempted.ps1')
        $manifest=[ordered]@{schemaVersion=1;repositories=@([ordered]@{
                    id='folded';repository='https://example.test/folded.git';status='ready'
                    inventoryCommit=$commit;inventoryTree=$tree;requiredRepositoryChecks=@()
                    files=@(
                        [ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'},
                        [ordered]@{path='scripts/FoldedFirst.ps1';disposition='retain';reason='pairing'},
                        [ordered]@{path='scripts/Exempted.ps1';disposition='retain';reason='exemptions'}
                    )
                    literalReferenceExemptions=@(
                        [ordered]@{file='scripts/Exempted.ps1';blobOid=$exemptedOid;line=1;column=1;occurrenceOrdinal=1
                            targetPath='scripts/Legacy.ps1';reason='fixture folded occurrence one'},
                        [ordered]@{file='scripts/Exempted.ps1';blobOid=$exemptedOid;line=1;column=1;occurrenceOrdinal=3
                            targetPath='scripts/Legacy.ps1';reason='fixture folded occurrence three'},
                        [ordered]@{file='scripts/Exempted.ps1';blobOid=$exemptedOid;line=1
                            column=($interleaved.IndexOf('scripts/Legacy.ps1')+1);occurrenceOrdinal=1
                            targetPath='scripts/Legacy.ps1';reason='fixture raw occurrence'}
                    )
                })}
        $manifestPath=Join-Path $TestDrive 'folded-provenance.json'
        Write-FixtureJson $manifestPath $manifest
        $result=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory -Manifest $manifestPath `
            -RepositoryId folded -AuthorityRoot $script:RepositoryRoot
        $result.result | Should Be FAILED
        $result.counts.scannedFiles | Should Be 2
        $result.counts.legacyReference | Should Be 2
        $result.counts.exemptedReference | Should Be 3
        $result.counts.staleExemption | Should Be 0
        $violations=@($result.violations|Where-Object kind -eq 'legacy-reference')
        @($violations).Count | Should Be 2
        @($violations|Where-Object{
                $_.file-eq'scripts/FoldedFirst.ps1'-and$_.line-eq1-and$_.column-eq1-and$_.occurrenceOrdinal-eq1
            }).Count | Should Be 1
        @($violations|Where-Object{
                $_.file-eq'scripts/FoldedFirst.ps1'-and$_.line-eq1-and
                $_.column-eq($foldedFirst.IndexOf('scripts/Legacy.ps1')+1)-and$_.occurrenceOrdinal-eq1
            }).Count | Should Be 1
    }

    # Scenario: Every supported folding operator appears before, after, and around raw occurrences of the same target.
    # Purpose: Unary/binary join, format, expandable strings, Join-Path, Combine, and casts preserve per-character provenance.
    It 'InterT27_preserves_provenance_for_every_supported_fold_operator' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $root=Join-Path $TestDrive 'folded-operator-provenance'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        $operators=[ordered]@{
            unary="(-join @('scripts/','Legacy.ps1'))"
            binary="(@('scripts/','Legacy.ps1') -join '')"
            format="('scripts/{0}' -f 'Legacy.ps1')"
            expandable='"scripts/Legacy.ps1$tail"'
            joinpath="(Join-Path 'scripts' 'Legacy.ps1')"
            combine="[IO.Path]::Combine('scripts','Legacy.ps1')"
            cast="[string]('scripts/'+'Legacy.ps1')"
        }
        foreach($pair in $operators.GetEnumerator()){
            $folded=[string]$pair.Value
            $rows=@(
                "$folded + ';' + 'scripts/Legacy.ps1'",
                "'scripts/Legacy.ps1' + ';' + $folded",
                "$folded + ';' + 'scripts/Legacy.ps1' + ';' + $folded"
            )
            [IO.File]::WriteAllText((Join-Path $root "scripts/$($pair.Key).ps1"),($rows-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
        }
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','all fold provenance'))
        $commit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $tree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $files=@([ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'})
        foreach($name in $operators.Keys){$files+=@([ordered]@{path="scripts/$name.ps1";disposition='retain';reason='operator provenance'})}
        $manifestPath=Join-Path $TestDrive 'folded-operator-provenance.json'
        Write-FixtureJson $manifestPath ([ordered]@{schemaVersion=1;repositories=@([ordered]@{
                        id='operators';repository='https://example.test/operators.git';status='ready';inventoryCommit=$commit
                        inventoryTree=$tree;requiredRepositoryChecks=@();files=$files})})
        $result=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory -Manifest $manifestPath `
            -RepositoryId operators -AuthorityRoot $script:RepositoryRoot
        $result.result|Should Be FAILED
        foreach($name in $operators.Keys){
            $rows=@($result.violations|Where-Object{$_.kind-eq'legacy-reference'-and$_.file-ceq"scripts/$name.ps1"})
            @($rows).Count|Should Be 7
            (@($rows|Group-Object line|Sort-Object Name|ForEach-Object Count)-join',')|Should Be '2,2,3'
        }
        $result.counts.legacyReference|Should Be 49
    }

    # Scenario: Every frozen section 5.6 reference, boundary, exemption, classification, and advisory family has an independent row.
    # Purpose: The closure contract is protected by an exact table-driven oracle rather than an aggregate non-empty assertion.
    It 'InterT28_executes_the_complete_section_5_6_golden_vector_matrix' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $root=Join-Path $TestDrive 'closure-complete-matrix'
        foreach($directory in @('scripts','config','docs')){[void][IO.Directory]::CreateDirectory((Join-Path $root $directory))}
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        $lines=@(
            "Import-Module 'scripts/Legacy.ps1'",
            "& 'scripts/Legacy.ps1'",
            "Get-Content 'scripts/Legacy.ps1'",
            "Test-Path 'scripts/Legacy.ps1'",
            "'scripts/Legacy.ps1' | Should -Exist",
            ". 'scripts\Legacy.ps1'",
            ". './scripts/Legacy.ps1'",
            ". 'SCRIPTS/legacy.PS1'",
            "if(`$false){. 'scripts/Legacy.ps1'}",
            "[IO.Path]::Combine(`$root,'scripts','Legacy.ps1')",
            "foreach(`$item in `$items){Copy-Item `$item 'scripts/Legacy.ps1'}",
            "Assert-True (`$value -match [regex]::Escape('scripts/Legacy.ps1'))",
            "Copy-Item @params -Destination 'scripts/Legacy.ps1'",
            "Invoke-Expression (`$code + ' scripts/Legacy.ps1')",
            "cp `$dynamic 'scripts/Legacy.ps1'",
            "Copy-Item 'scripts/Legacy.ps1' -Destination 'scripts/Legacy.ps1'",
            "& git show HEAD:scripts/Legacy.ps1",
            "Write-Output 'scripts/Legacy.ps1'",
            "'scripts/'+'Legacy.ps1'+';'+'scripts/'+'Legacy.ps1'",
            "'scripts/Legacy.ps1.bak';'myscripts/Legacy.ps1'",
            "`$partial='scripts/'",
            "Join-Path `$root 'scripts' 'Legacy.ps1'",
            "Copy-Item -LiteralPath (Join-Path `$root 'Other.ps1') -Destination 'scripts/Legacy.ps1'",
            'Get-Content $dynamic',
            "Copy-Item -LiteralPath ([string]'fixture.bin') -Destination 'scripts/Legacy.ps1'"
        )
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Matrix.ps1'),($lines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
        $textFiles=[ordered]@{
            'scripts/check.cs'='var p = "scripts/Legacy.ps1";'
            'scripts/check.lua'='local p = "scripts/Legacy.ps1"'
            'scripts/runner'='scripts/Legacy.ps1'
            'config/check.json'='{"path":"scripts/Legacy.ps1","backup":"scripts/Legacy.ps1.bak"}'
            'config/check.yml'="path: scripts/Legacy.ps1`nbackup: scripts/Legacy.ps1.bak"
            'config/check.yaml'="path: scripts/Legacy.ps1`nbackup: scripts/Legacy.ps1.bak"
            'config/check.toml'="path = `"scripts/Legacy.ps1`"`nbackup = `"scripts/Legacy.ps1.bak`""
            'config/check.ini'="path=scripts/Legacy.ps1`nbackup=scripts/Legacy.ps1.bak"
            'config/check.xml'='<root><path>scripts/Legacy.ps1</path><backup>scripts/Legacy.ps1.bak</backup></root>'
            'docs/history.md'='Historical scripts/Legacy.ps1 only.'
        }
        foreach($pair in $textFiles.GetEnumerator()){
            [IO.File]::WriteAllText((Join-Path $root $pair.Key),[string]$pair.Value,[Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllBytes((Join-Path $root 'scripts/payload.bin'),[byte[]](0,255,0,254,1,2,3))
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','complete closure matrix'))
        $commit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $tree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $oid=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD:scripts/Matrix.ps1')
        $exemptionRows=@(
            @{Line=13;Column=$lines[12].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='splat fail-closed'},
            @{Line=14;Column=$lines[13].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='iex fail-closed'},
            @{Line=15;Column=$lines[14].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='alias fail-closed'},
            @{Line=16;Column=$lines[15].LastIndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='same-line destination'},
            @{Line=17;Column=$lines[16].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='external command argument'},
            @{Line=18;Column=$lines[17].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='message-only literal'},
            @{Line=19;Column=1;Ordinal=1;Reason='first folded fixture'},
            @{Line=19;Column=1;Ordinal=2;Reason='second folded fixture'},
            @{Line=23;Column=$lines[22].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='partial source fail-closed'}
            @{Line=25;Column=$lines[24].IndexOf('scripts/Legacy.ps1')+1;Ordinal=1;Reason='cast constant source remains certain'}
        )
        $exemptions=@($exemptionRows|ForEach-Object{[ordered]@{file='scripts/Matrix.ps1';blobOid=$oid
                    line=$_.Line;column=$_.Column;occurrenceOrdinal=$_.Ordinal;targetPath='scripts/Legacy.ps1';reason=$_.Reason}})
        $exemptions+=@(
            [ordered]@{file='scripts/Matrix.ps1';blobOid=('f'*40);line=1
                column=$lines[0].IndexOf('scripts/Legacy.ps1')+1;occurrenceOrdinal=1;targetPath='scripts/Legacy.ps1';reason='blob drift fixture'},
            [ordered]@{file='scripts/Matrix.ps1';blobOid=$oid;line=99
                column=$lines[1].IndexOf('scripts/Legacy.ps1')+1;occurrenceOrdinal=1;targetPath='scripts/Legacy.ps1';reason='line drift fixture'}
        )
        $files=@([ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'})
        foreach($path in @('scripts/Matrix.ps1')+@($textFiles.Keys)+@('scripts/payload.bin')){
            $files+=@([ordered]@{path=$path;disposition='retain';reason='matrix'})
        }
        $manifestPath=Join-Path $TestDrive 'closure-complete-matrix.json'
        Write-FixtureJson $manifestPath ([ordered]@{schemaVersion=1;repositories=@([ordered]@{
                        id='matrix';repository='https://example.test/matrix.git';status='ready';inventoryCommit=$commit
                        inventoryTree=$tree;requiredRepositoryChecks=@();files=$files;literalReferenceExemptions=$exemptions})})
        $result=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory `
            -Manifest $manifestPath -RepositoryId matrix -AuthorityRoot $script:RepositoryRoot
        $result.result|Should Be 'FAILED'
        $result.counts.scannedFiles|Should Be 12
        $result.counts.legacyReference|Should Be 26
        if($result.counts.exemptedReference-ne7){
            $details=[ordered]@{counts=$result.counts;violations=@($result.violations);advisories=@($result.advisories)}|ConvertTo-Json -Depth 20 -Compress
            throw "Complete matrix exemption oracle mismatch: $details"
        }
        $result.counts.exemptedReference|Should Be 7
        $result.counts.staleExemption|Should Be 5
        $result.counts.dynamicReference|Should Be 4
        $result.counts.documentationReference|Should Be 1
        $result.counts.binary|Should Be 1
        $expectedPowerShell=@(
            1,2,3,4,5,6,7,8,9,10,11,12,13,15,16,22,23
        )
        $actualPowerShell=@($result.violations|Where-Object{$_.kind-eq'legacy-reference'-and$_.file-eq'scripts/Matrix.ps1'})
        @($actualPowerShell).Count|Should Be 17
        ((@($actualPowerShell.line)|Sort-Object)-join',')|Should Be (($expectedPowerShell|Sort-Object)-join',')
        foreach($violation in $actualPowerShell){
            Assert-ExactObjectShape $violation @('kind','file','line','column','occurrenceOrdinal','reference','targetPath','targetDisposition')
            $violation.targetPath|Should Be 'scripts/Legacy.ps1'
            $violation.occurrenceOrdinal|Should Be 1
            $expectedColumn=if($violation.line-in@(10,22)){1}else{$lines[$violation.line-1].IndexOf('scripts',[StringComparison]::OrdinalIgnoreCase)+1}
            $violation.column|Should Be $expectedColumn
        }
        $expectedTextFiles=@('scripts/check.cs','scripts/check.lua','scripts/runner','config/check.json','config/check.yml',
            'config/check.yaml','config/check.toml','config/check.ini','config/check.xml')
        (@($result.violations|Where-Object kind -eq 'legacy-reference').file|Where-Object{$_-ne'scripts/Matrix.ps1'}|Sort-Object)-join"`n"|Should Be `
            (($expectedTextFiles|Sort-Object)-join"`n")
        $dynamic=@($result.advisories|Where-Object{$_.kind-eq'dynamic-reference'-and$_.file-eq'scripts/Matrix.ps1'})
        (@($dynamic.line)-join',')|Should Be '11,15,23,24'
        foreach($row in $dynamic){
            Assert-ExactObjectShape $row @('kind','file','line','column','reference','targetPath')
            $needle=if($row.line-eq11){'$item'}elseif($row.line-in@(15,24)){'$dynamic'}else{'(Join-Path'}
            $expectedDynamicColumn=if($row.line-eq11){$lines[$row.line-1].LastIndexOf($needle)+1}else{
                $lines[$row.line-1].IndexOf($needle)+1}
            $row.column|Should Be $expectedDynamicColumn
        }
        $documentation=@($result.advisories|Where-Object{$_.kind-eq'documentation-reference'-and$_.file-eq'docs/history.md'})
        @($documentation).Count|Should Be 1
        Assert-ExactObjectShape $documentation[0] @('kind','file','line','column','reference','targetPath')
        $binary=@($result.advisories|Where-Object{$_.kind-eq'binary'-and$_.file-eq'scripts/payload.bin'})
        @($binary).Count|Should Be 1
        Assert-ExactObjectShape $binary[0] @('kind','file','line','column','reference','targetPath')

        $closureModulePath=Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1'
        $closureText=Get-Content -Raw -LiteralPath $closureModulePath
        $closureTokens=$null;$closureErrors=$null
        $closureAst=[Management.Automation.Language.Parser]::ParseInput($closureText,[ref]$closureTokens,[ref]$closureErrors)
        @($closureErrors).Count|Should Be 0
        $valueFunction=@($closureAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'ConvertTo-ClosureFoldedValue'},$true))[0]
        $castBranch=@($valueFunction.Body.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and
                    $node.Extent.Text.Contains('ConvertExpressionAst',[StringComparison]::Ordinal)},$true))
        @($castBranch).Count|Should Be 1
        $mutantText=$closureText.Remove($castBranch[0].Extent.StartOffset,$castBranch[0].Extent.EndOffset-$castBranch[0].Extent.StartOffset)
        $mutantPath=Join-Path $TestDrive 'ConsumerManifestClosure-mutant-cast.psm1'
        [IO.File]::WriteAllText($mutantPath,$mutantText,[Text.UTF8Encoding]::new($false))
        $mutantModule=Import-Module $mutantPath -Force -PassThru
        try{
            $mutantResult=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $commit -Stage inventory `
                -Manifest $manifestPath -RepositoryId matrix -AuthorityRoot $script:RepositoryRoot
            $mutantResult.counts.exemptedReference|Should Be 6
            $mutantResult.counts.legacyReference|Should Be 27
            @($mutantResult.violations|Where-Object{$_.kind-eq'legacy-reference'-and$_.file-eq'scripts/Matrix.ps1'-and$_.line-eq25}).Count|Should Be 1
        }finally{Remove-Module $mutantModule -Force;Restore-ClosureFixtureModule}
    }

    # Scenario: Conversion rewrites split and update targets, modifies an exempted blob, and deletes another exempted file.
    # Purpose: Candidate content is rescanned, modified blobs lose exemptions, and removed files do not create stale exemptions.
    It 'InterT29_rechecks_conversion_targets_and_exemption_blob_identity' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
        $root=Join-Path $TestDrive 'closure-conversion-reference-matrix'
        foreach($directory in @('scripts','tests')){[void][IO.Directory]::CreateDirectory((Join-Path $root $directory))}
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Split.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'tests/Rewrite.Tests.ps1'),'Describe fixture {}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Exempt.ps1'),"Write-Output 'scripts/Legacy.ps1'`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Deleted.ps1'),"Write-Output 'scripts/Legacy.ps1'`n",[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','conversion inventory'))
        $inventoryCommit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $inventoryTree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        $exemptions=@()
        foreach($file in @('scripts/Exempt.ps1','scripts/Deleted.ps1')){
            $exemptions+=@([ordered]@{file=$file;blobOid=Get-SourceFixtureGitScalar $root @('rev-parse',"HEAD:$file")
                    line=1;column=15;occurrenceOrdinal=1;targetPath='scripts/Legacy.ps1';reason='message fixture'})
        }
        $manifestPath=Join-Path $TestDrive 'closure-conversion-reference-matrix.json'
        Write-FixtureJson $manifestPath ([ordered]@{schemaVersion=1;repositories=@([ordered]@{
                        id='conversion-matrix';repository='https://example.test/conversion.git';status='ready'
                        inventoryCommit=$inventoryCommit;inventoryTree=$inventoryTree;requiredRepositoryChecks=@()
                        files=@(
                            [ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='legacy'},
                            [ordered]@{path='scripts/Split.ps1';disposition='split';target='scripts/New.ps1';reason='split'},
                            [ordered]@{path='tests/Rewrite.Tests.ps1';disposition='update-tests';expectedOutcome='rewrite';reason='rewrite'},
                            [ordered]@{path='scripts/Exempt.ps1';disposition='retain';reason='exemption'},
                            [ordered]@{path='scripts/Deleted.ps1';disposition='retain';reason='deleted exemption'})
                        literalReferenceExemptions=$exemptions})})
        Remove-Item (Join-Path $root 'scripts/Legacy.ps1'),(Join-Path $root 'scripts/Split.ps1'),(Join-Path $root 'scripts/Deleted.ps1')
        [IO.File]::WriteAllText((Join-Path $root 'scripts/New.ps1'),". 'scripts/Legacy.ps1'`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'tests/Rewrite.Tests.ps1'),". 'scripts/Legacy.ps1'`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText((Join-Path $root 'scripts/Exempt.ps1'),'# changed',[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $root @('add','-A'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','conversion candidate'))
        $candidateCommit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $result=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $candidateCommit -Stage conversion `
            -InventoryCommit $inventoryCommit -Manifest $manifestPath -RepositoryId conversion-matrix `
            -AuthorityRoot $script:RepositoryRoot
        $result.result|Should Be 'FAILED'
        $result.counts.legacyReference|Should Be 3
        $result.counts.staleExemption|Should Be 0
        $result.counts.splitSourcePresent|Should Be 0
        $result.counts.updateTestsOutcome|Should Be 0
        (@($result.violations|Where-Object kind -eq 'legacy-reference').file|Sort-Object)-join"`n"|Should Be `
            ((@('scripts/Exempt.ps1','scripts/New.ps1','tests/Rewrite.Tests.ps1')|Sort-Object)-join"`n")
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

    # Scenario: Production prepare runs through the real gate entry, local HTTP transport, runtime source, and resolver child.
    # Purpose: Success, HTTP error, timeout, and cancellation remain distinct without leaking credential bytes.
    It 'UnitT30_executes_the_production_prepare_entry_for_all_credential_outcomes' {
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        $expected=[ordered]@{success=0;'http-error'=20;timeout=20;cancellation=40}
        foreach($outcome in @('success','http-error','timeout','cancellation')){
            $root=Join-Path $TestDrive "credential-$outcome"
            $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture `
                -RepositoryRoot $script:RepositoryRoot -FixtureRoot $root -Outcome $outcome `
                -Sentinel 'unique-production-credential-sentinel' 2>&1)
            if($LASTEXITCODE-ne0){throw "Credential fixture '$outcome' failed: $($records-join' | ')"}
            $result=($records -join [Environment]::NewLine)|ConvertFrom-Json -Depth 30
            if($result.exitCode-ne$expected[$outcome]){
                throw "Credential outcome '$outcome' expected exit $($expected[$outcome]) but got $($result.exitCode): stdout=$($result.stdout) stderr=$($result.stderr)"
            }
            $result.exitCode | Should Be $expected[$outcome]
            if($result.outputContainsSentinel-or@($result.surfaceLeaks).Count-ne0){
                throw "Credential outcome '$outcome' leaked through an output surface: $($result|ConvertTo-Json -Depth 20 -Compress)"
            }
            $result.outputContainsSentinel | Should Be $false
            @($result.surfaceLeaks).Count | Should Be 0
            if($outcome-eq'http-error'){$result.stderr|Should Match 'GATE_ACQUISITION_HTTP_ERROR'}
            if($outcome-eq'timeout'){$result.stderr|Should Match 'GATE_ACQUISITION_TIMEOUT'}
            if($outcome-eq'cancellation'){$result.stderr|Should Match 'GATE_ACQUISITION_CANCELLED'}
            if($outcome-eq'success'){
                if((@($result.events)-join',')-ne'runtime-installed,source-tools-prepared'-or@($result.resolverDumps).Count-ne4){
                    throw "Credential success boundary evidence mismatch: $($result|ConvertTo-Json -Depth 20 -Compress)"
                }
                @($result.events) | Should Be @('runtime-installed','source-tools-prepared')
                @($result.resolverDumps).Count | Should Be 4
                foreach($dump in $result.resolverDumps){
                    @($dump.tokenNames) | Should Be @('STANDARD_VALIDATION_GITHUB_API_TOKEN')
                    @($dump.sentinelValueNames) | Should Be @('STANDARD_VALIDATION_GITHUB_API_TOKEN')
                    $dump.standardPresent | Should Be $true
                    $dump.githubPresent | Should Be $false
                    $dump.ghPresent | Should Be $false
                }
            }else{
                if(@($result.events).Count-ne0-or@($result.resolverDumps).Count-ne0){
                    throw "Credential failure outcome '$outcome' emitted success evidence: $($result|ConvertTo-Json -Depth 20 -Compress)"
                }
                @($result.events).Count | Should Be 0
                @($result.resolverDumps).Count | Should Be 0
            }
        }
    }

    # Scenario: PowerShell asset acquisition follows only bounded approved redirects and filters credentials per hop.
    # Purpose: Real prepare accepts approved 302 chains while rejecting host changes and redirect exhaustion without sending Authorization to assets.
    It 'UnitT61_enforces_redirect_hosts_limits_and_per_hop_authorization' {
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        $sentinel='unique-redirect-credential-sentinel'
        $expected=[ordered]@{'redirect-success'=0;'redirect-unapproved'=20;'redirect-limit'=20}
        foreach($outcome in $expected.Keys){
            $root=Join-Path $TestDrive "credential-$outcome"
            $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture `
                -RepositoryRoot $script:RepositoryRoot -FixtureRoot $root -Outcome $outcome -Sentinel $sentinel 2>&1)
            $LASTEXITCODE|Should Be 0
            $result=($records-join[Environment]::NewLine)|ConvertFrom-Json -Depth 30
            $result.exitCode|Should Be $expected[$outcome]
            $result.outputContainsSentinel|Should Be $false
            $requests=@(Get-Content -LiteralPath (Join-Path $root 'http-headers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
            @($requests).Count|Should Be $(if($outcome-eq'redirect-success'){5}elseif($outcome-eq'redirect-unapproved'){3}else{8})
            $metadata=@($requests|Where-Object path -eq '/metadata')
            @($metadata).Count|Should Be 1
            [string]$metadata[0].headers.Authorization|Should Be "Bearer $sentinel"
            $assetHops=@($requests|Where-Object path -ne '/metadata')
            foreach($hop in $assetHops){
                @($hop.headers.PSObject.Properties.Name)|Should Not Contain 'Authorization'
                ($hop.headers|ConvertTo-Json -Compress)|Should Not Match ([regex]::Escape($sentinel))
            }
            if($outcome-eq'redirect-unapproved'){$result.stderr|Should Match 'GATE_ACQUISITION_REDIRECT_HOST'}
            if($outcome-eq'redirect-limit'){$result.stderr|Should Match 'GATE_ACQUISITION_REDIRECT_LIMIT'}
        }
    }

    # Scenario: Each credential output surface independently receives the sentinel through a fixture source.
    # Purpose: The formal prepare entry rejects summary, artifact, receipt, stdout, and stderr leaks without echoing the credential.
    It 'UnitT31_rejects_each_credential_output_surface_through_the_formal_entry' {
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        foreach($surface in @('summary','artifact','receipt','stdout','stderr')){
            $root=Join-Path $TestDrive "credential-surface-$surface"
            $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture `
                -RepositoryRoot $script:RepositoryRoot -FixtureRoot $root -Outcome success `
                -Sentinel 'unique-surface-credential-sentinel' -LeakSurface $surface 2>&1)
            $LASTEXITCODE | Should Be 0
            $result=($records-join[Environment]::NewLine)|ConvertFrom-Json -Depth 30
            $result.exitCode | Should Be 20
            $result.outputContainsSentinel | Should Be $false
            if($surface-in@('summary','artifact','receipt')){@($result.surfaceLeaks).Count|Should Be 1}else{
                @($result.surfaceLeaks).Count|Should Be 0}
            $result.stderr | Should Match 'credential sentinel|Credential sentinel'
            if($surface-in@('summary','artifact','receipt')){@($result.events)|Should Be @('runtime-installed','source-tools-prepared')}
            else{@($result.events)|Should Be @('runtime-installed')}
        }
    }

    # Scenario: Token-bearing holders and cleanup statements are enumerated from production ASTs as an exact fixed inventory.
    # Purpose: Adding a holder or deleting cleanup for headers, environments, buffers, or processes changes the closed inventory.
    It 'UnitT32_closes_the_complete_credential_holder_and_cleanup_inventory' {
        $inventory=[ordered]@{
            'ConsumerGate.Install.headers.Authorization'=@('$headers.Remove(''Authorization'')',1)
            'ConsumerGate.Install.Token'=@('Remove-Variable Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.Install.TokenNull'=@('$Token=$null',1)
            'ConsumerGate.Install.processEnvironment'=@('[Environment]::SetEnvironmentVariable(''STANDARD_VALIDATION_GITHUB_API_TOKEN'',$null,''Process'')',1)
            'ConsumerGate.Acquisition.Headers'=@('$Headers=$null',1)
            'ConsumerGate.Acquisition.request'=@('$request=$null',2)
            'ConsumerGate.Acquisition.response'=@('$response=$null',2)
            'ConsumerGate.Acquisition.bytes'=@('$bytes=$null',1)
            'ConsumerGate.Acquisition.buffer'=@('$buffer=$null',1)
            'ConsumerGate.Acquisition.stream'=@('$stream=$null',1)
            'ConsumerGate.Acquisition.memory'=@('$memory=$null',1)
            'ConsumerGate.Acquisition.requestDispose'=@('$request.Dispose()',2)
            'ConsumerGate.Acquisition.responseDispose'=@('$response.Dispose()',2)
            'ConsumerGate.Acquisition.streamDispose'=@('$stream.Dispose()',1)
            'ConsumerGate.Acquisition.memoryDispose'=@('$memory.Dispose()',1)
            'ConsumerGate.Resolver.processEnvironment'=@('foreach($name in @(''STANDARD_VALIDATION_GITHUB_API_TOKEN'',''GITHUB_TOKEN'',''GH_TOKEN'')){[Environment]::SetEnvironmentVariable($name,$null,''Process'')}',1)
            'ConsumerGate.Resolver.start.Environment'=@('[void]$start.Environment.Remove(''STANDARD_VALIDATION_GITHUB_API_TOKEN'')',1)
            'ConsumerGate.Resolver.preserved'=@('$preserved.Clear()',1)
            'ConsumerGate.Resolver.standardOutput'=@('$standardOutput=$null',1)
            'ConsumerGate.Resolver.standardError'=@('$standardError=$null',1)
            'ConsumerGate.Resolver.stdout'=@('$stdout=$null',1)
            'ConsumerGate.Resolver.stderr'=@('$stderr=$null',1)
            'ConsumerGate.Resolver.process'=@('$process.Dispose()',1)
            'ConsumerGate.Resolver.start'=@('$start=$null',1)
            'ConsumerGate.Resolver.Token'=@('Remove-Variable Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.Scoped.processEnvironment'=@('foreach($name in @(''STANDARD_VALIDATION_GITHUB_API_TOKEN'',''GITHUB_TOKEN'',''GH_TOKEN'')){[Environment]::SetEnvironmentVariable($name,$null,''Process'')}',1)
            'ConsumerGate.Scoped.Token'=@('Remove-Variable runtime,receipt,Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.SourceSetup.Token'=@('Remove-Variable Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.CredentialScan.Token'=@('Remove-Variable content,needle,Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.CredentialScan.needle'=@('Remove-Variable content,needle,Token -ErrorAction SilentlyContinue',1)
            'ConsumerGate.CredentialScan.content'=@('Remove-Variable content,needle,Token -ErrorAction SilentlyContinue',1)
            'Bootstrap.preserved'=@('$preserved.Clear()',1)
            'Bootstrap.start.Environment'=@('[void]$start.Environment.Remove([string]$name)',1)
            'Bootstrap.sentinel'=@('Remove-Variable sentinel -ErrorAction SilentlyContinue',1)
            'Bootstrap.standardOutput'=@('$standardOutput = $null',1)
            'Bootstrap.standardError'=@('$standardError = $null',1)
            'Bootstrap.stdout'=@('$stdout = $null',1)
            'Bootstrap.stderr'=@('$stderr = $null',1)
            'Bootstrap.process'=@('$process.Dispose()',1)
            'Bootstrap.value'=@('Remove-Variable value -ErrorAction SilentlyContinue',1)
            'GateEntry.phaseEnvironment'=@('$phaseEnvironment=$null',1)
            'GateEntry.processEnvironment'=@('[Environment]::SetEnvironmentVariable($name,$null,''Process'')',2)
            'GateEntry.Token'=@('$token=$null',1)
            'GateEntry.message'=@('$message=$null',1)
            'GateEntry.tokenVariable'=@('$tokenVariable=$null',1)
            'GateEntry.localRemoval'=@('Remove-Variable token, tokenVariable, message, phaseEnvironmentDumpPath -ErrorAction SilentlyContinue',1)
            'GateEntry.phaseDumpValueRemoval'=@('Remove-Variable phaseEnvironment,phaseEnvironmentDump,phaseTokenNames,phaseSentinelNames,sentinelHash,value -ErrorAction SilentlyContinue',1)
        }
        @($inventory.Keys).Count | Should Be 47
        $sources=[ordered]@{
            ConsumerGate=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1')
            Bootstrap=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
            GateEntry=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1')
        }
        $actual=[Collections.Generic.List[string]]::new()
        foreach($sourceName in $sources.Keys){
            $tokens=$null
            $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($sources[$sourceName],[ref]$tokens,[ref]$errors)
            @($errors).Count | Should Be 0
            foreach($entry in $inventory.GetEnumerator()){
                if(-not$entry.Key.StartsWith("$sourceName.",[StringComparison]::Ordinal)){continue}
                $searchRoot=$ast
                $functionName=if($entry.Key.StartsWith('ConsumerGate.Install.')){'Install-GatePowerShell'}elseif(
                    $entry.Key.StartsWith('ConsumerGate.Acquisition.')){'Invoke-GateAcquisitionRequest'}elseif(
                    $entry.Key.StartsWith('ConsumerGate.Resolver.')){'Invoke-GateResolver'}elseif(
                    $entry.Key.StartsWith('ConsumerGate.Scoped.')){'Invoke-GateCredentialScopedPreparation'}elseif(
                    $entry.Key.StartsWith('ConsumerGate.SourceSetup.')){'New-GateSourceSetup'}elseif(
                    $entry.Key.StartsWith('ConsumerGate.CredentialScan.')){'Assert-GateCredentialAbsent'}elseif(
                    $entry.Key.StartsWith('Bootstrap.')){'Invoke-ConsumerGateProcess'}else{$null}
                if($null-ne$functionName){
                    $searchRoot=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                                $node.Name-ceq$functionName},$true))[0]
                }
                $statementType=if(([string]$entry.Value[0]).StartsWith('foreach',[StringComparison]::Ordinal)){
                    [Management.Automation.Language.ForEachStatementAst]
                }elseif(([string]$entry.Value[0])-match'^\$[^=]+(?:=|\+=|-=)'){
                    [Management.Automation.Language.AssignmentStatementAst]
                }else{[Management.Automation.Language.PipelineAst]}
                $matches=@($searchRoot.FindAll({param($node)
                            $node.GetType()-eq$statementType -and
                            $node.Extent.Text.Trim()-ceq[string]($entry.Value[0])
                        },$true))
                @($matches).Count | Should Be ([int]$entry.Value[1])
                $actual.Add([string]$entry.Key)
                $mutated=$sources[$sourceName].Remove($matches[0].Extent.StartOffset,
                    $matches[0].Extent.EndOffset-$matches[0].Extent.StartOffset)
                $mutantTokens=$null
                $mutantErrors=$null
                $mutantAst=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$mutantTokens,[ref]$mutantErrors)
                @($mutantErrors).Count | Should Be 0
                $mutantSearchRoot=$mutantAst
                if($null-ne$functionName){$mutantSearchRoot=@($mutantAst.FindAll({param($node)
                                $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName
                            },$true))[0]}
                @($mutantSearchRoot.FindAll({param($node)
                            $node.GetType()-eq$statementType -and
                            $node.Extent.Text.Trim()-ceq[string]($entry.Value[0])
                        },$true)).Count | Should Be (([int]$entry.Value[1])-1)
            }
        }
        (@($actual)-join[Environment]::NewLine) | Should Be (@($inventory.Keys)-join[Environment]::NewLine)
        $productionAsts=[ordered]@{}
        foreach($sourceName in $sources.Keys){$tokens=$null;$errors=$null
            $productionAsts[$sourceName]=[Management.Automation.Language.Parser]::ParseInput($sources[$sourceName],[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0}
        $protectedFunctions=@('Install-GatePowerShell','Invoke-GateAcquisitionRequest','Invoke-GateResolver','New-GateSourceSetup',
            'Invoke-GateCredentialScopedPreparation','Assert-GateCredentialAbsent','Invoke-ConsumerGateProcess')
        $scriptBlockParameters=@()
        foreach($ast in $productionAsts.Values){
            foreach($function in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                            $protectedFunctions-ccontains$node.Name},$true))){
                foreach($parameter in @($function.Parameters)){
                    $typeNames=@($parameter.Attributes|Where-Object{$_-is[Management.Automation.Language.TypeConstraintAst]}|ForEach-Object{$_.TypeName.FullName})
                    if($typeNames-ccontains'scriptblock'){$scriptBlockParameters+="$($function.Name)|$($parameter.Name.VariablePath.UserPath)|scriptblock"}
                }
            }
        }
        @($scriptBlockParameters).Count|Should Be 0
        $formalEnvironment=@('CONSUMER_GATE_ARTIFACT_PATHS','CONSUMER_GATE_EVENT_REPOSITORY','GITHUB_STEP_SUMMARY','RUNNER_TEMP',
            'STANDARD_GO_RUNTIME_VERSION','STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_OUTPUT')
        $approvedSeams=@('CONSUMER_GATE_ACQUISITION_CANCEL_PATH','CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS',
            'CONSUMER_GATE_EVENT_LOG_PATH','CONSUMER_GATE_PHASE_ENV_DUMP_PATH','CONSUMER_GATE_POWERSHELL_METADATA_URI',
            'CONSUMER_GATE_RESOLVER_SCRIPT_PATH','CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH','CONSUMER_GATE_RUNTIME_SOURCE_ROOT')
        $environmentAccesses=@($productionAsts.Values|ForEach-Object{$_.FindAll({param($node)
                        $node-is[Management.Automation.Language.VariableExpressionAst]-and
                        ([string]$node.VariablePath.UserPath).StartsWith('env:CONSUMER_GATE_',[StringComparison]::OrdinalIgnoreCase)
                    },$true)|ForEach-Object{([string]$_.VariablePath.UserPath).Substring(4).ToUpperInvariant()}}|
                Where-Object{$formalEnvironment-cnotcontains$_-and$_-cne'CONSUMER_GATE_TEST_TEMP_ROOT'}|Sort-Object -Unique)
        (@($environmentAccesses)-join"`n")|Should Be (($approvedSeams|Sort-Object)-join"`n")
        foreach($seam in $approvedSeams){
            $deleted=@($environmentAccesses|Where-Object{$_-cne$seam})
            (@($deleted)-join"`n")|Should Not Be (($approvedSeams|Sort-Object)-join"`n")
            $added=@($environmentAccesses)+@('CONSUMER_GATE_UNAPPROVED_FIXTURE_SEAM')
            (@($added|Sort-Object -Unique)-join"`n")|Should Not Be (($approvedSeams|Sort-Object)-join"`n")
        }
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
    It 'InterT36_enforces_complete_ready_repository_dispositions' {
        $manifest = Get-Content -Raw -Encoding UTF8 (
            Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json'
        ) | ConvertFrom-Json -Depth 100
        $expectedDispositionOracle = @{
            'skill-general' = @{ Count=45; Sha256='5af3bb77584eb77ded51442e1f5bb9c01fa5f7b4819041e82d8a78ea7715d43c' }
            'skill-atlassian-ecosystem' = @{ Count=99; Sha256='e719c37bb75a8a7570d9e21a4b1d579f9294d3f238a2d57b8b342fe41ad5742a' }
            'skill-code-collaboration' = @{ Count=23; Sha256='dbf9332f204eda3d15c8777c4e73ad0b846a0e653367ea188c03d47c2766ce2a' }
            'skill-knowledge-content' = @{ Count=17; Sha256='78704317aea1f2678901f671ecc6fb297640e8e1282eaf3f40dcb3f980a8c2a3' }
        }
        foreach ($entry in @($manifest.repositories | Where-Object status -eq ready)) {
            $oracleLines = @($entry.files | ForEach-Object {
                    "$($_.path)|$($_.disposition)|$($_.expectedOutcome)|$($_.target)"
                } | Sort-Object)
            $oracleBytes = [Text.UTF8Encoding]::new($false).GetBytes(($oracleLines -join "`n") + "`n")
            $oracleSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oracleBytes)).ToLowerInvariant()
            $oracleLines.Count | Should Be $expectedDispositionOracle[[string]$entry.id].Count
            $oracleSha | Should Be $expectedDispositionOracle[[string]$entry.id].Sha256

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

            foreach ($removed in @($entry.files | Where-Object {
                        $_.disposition -in @('delete','split') -and $_.path -notlike '.github/workflows/*'
                    })) {
                $removedPath = Join-Path $root ([string]$removed.path)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $removedPath))
                [IO.File]::WriteAllText($removedPath, 'leftover', [Text.UTF8Encoding]::new($false))
                { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                        $baseRevision $candidateRevision $true } | Should Throw 'Removed legacy path'
                Remove-Item -LiteralPath $removedPath -Force
            }

            foreach ($split in @($entry.files | Where-Object disposition -eq split)) {
                $splitTarget = Join-Path $root ([string]$split.target)
                $splitContent = Get-Content -Raw -LiteralPath $splitTarget
                Remove-Item -LiteralPath $splitTarget -Force
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','wrong split target'))
                $wrongRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                        $baseRevision $wrongRevision $true } | Should Throw 'Split target'
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $splitTarget))
                [IO.File]::WriteAllText($splitTarget, $splitContent, [Text.UTF8Encoding]::new($false))
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','restore split target'))
                $candidateRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
            }

            $rewrite = @($entry.files | Where-Object {
                    $_.disposition -eq 'update-tests' -and $_.expectedOutcome -eq 'rewrite'
                })[0]
            $rewritePath = Join-Path $root ([string]$rewrite.path)
            [IO.File]::WriteAllText($rewritePath, "base $($rewrite.path)`n", [Text.UTF8Encoding]::new($false))
            [void](Invoke-SourceFixtureGit $root @('add','-A'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','unchanged rewrite mismatch'))
            $wrongRewriteRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
            { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                    $baseRevision $wrongRewriteRevision $true } | Should Throw 'must be rewritten'
            [IO.File]::AppendAllText($rewritePath, "rewritten`n", [Text.UTF8Encoding]::new($false))
            [void](Invoke-SourceFixtureGit $root @('add','-A'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','restore rewritten test'))
            $candidateRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')

            $deleteExpectation = Copy-FixtureValue $entry
            $deleteExpectation.files = @($deleteExpectation.files)
            $deleteRecord = @($deleteExpectation.files | Where-Object disposition -eq 'update-tests')[0]
            $deleteRecord.expectedOutcome = 'delete'
            { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $deleteExpectation `
                    $baseRevision $candidateRevision $true } | Should Throw 'must be deleted'

            $retained = @($entry.files | Where-Object disposition -eq retain)[0]
            if ($null -ne $retained) {
                $retainedPath = Join-Path $root ([string]$retained.path)
                $renamedPath = "$retainedPath.renamed"
                Move-Item -LiteralPath $retainedPath -Destination $renamedPath
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','rename retained path'))
                $renameRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry `
                        $baseRevision $renameRevision $true } | Should Throw 'Retained path must remain unchanged'
                Move-Item -LiteralPath $renamedPath -Destination $retainedPath
                [IO.File]::AppendAllText($retainedPath, "scripts/Validate.ps1`n", [Text.UTF8Encoding]::new($false))
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','retained legacy dependency'))
                $dependencyRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                $fixtureManifest = Copy-FixtureValue $manifest
                $fixtureEntry = @($fixtureManifest.repositories | Where-Object id -eq $entry.id)[0]
                $fixtureEntry.inventoryCommit = $baseRevision
                $fixtureEntry.inventoryTree = Get-SourceFixtureGitScalar $root @('rev-parse',"$baseRevision^{tree}")
                $fixtureManifestPath = Join-Path $TestDrive "disposition-manifest-$($entry.id).json"
                Write-FixtureJson $fixtureManifestPath $fixtureManifest
                $closure = Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $dependencyRevision -Stage conversion `
                    -InventoryCommit $baseRevision -Manifest $fixtureManifestPath -RepositoryId $entry.id `
                    -AuthorityRoot $script:RepositoryRoot
                $closure.result | Should Be 'FAILED'
                @($closure.violations | Where-Object {
                        $_.kind -eq 'legacy-reference' -and $_.file -eq $retained.path
                    }).Count | Should Be 1
            }
        }
    }

    # Scenario: A declared general check is untracked, is a Tests file, or points at a legacy delete disposition.
    # Purpose: Repository-specific execution remains limited to tracked regular non-test scripts that migration permits.
    It 'UnitT41_rejects_unsafe_general_repository_check_paths_at_runtime' {
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
    It 'UnitT43_creates_gate_hooks_only_in_a_new_empty_physical_workroot_directory' {
        $root = Join-Path $TestDrive 'gate-hook-hardening'
        [void][IO.Directory]::CreateDirectory($root)
        $name = 'git-hooks-' + ('d' * 32)
        $created = New-GateGitHooksDirectory $root $name
        @(Get-ChildItem -LiteralPath $created -Force).Count | Should Be 0
        { New-GateGitHooksDirectory $root $name } | Should Throw 'already exists'

    }

    if ($IsWindows) {
        # Scenario: A Windows gate WorkRoot is redirected through a Junction ancestor.
        # Purpose: Register the Windows-only reparse fixture only on Windows.
        It 'UnitT33_rejects_a_windows_junction_gate_workroot_ancestor' {
            $physical = Join-Path $TestDrive 'gate-hook-physical'
            $junction = Join-Path $TestDrive 'gate-hook-junction'
            [void][IO.Directory]::CreateDirectory($physical)
            [void](New-Item -ItemType Junction -Path $junction -Target $physical)
            { New-GateGitHooksDirectory $junction ('git-hooks-' + ('e' * 32)) } | Should Throw 'physical directory'
        }
    }
    else {
        # Scenario: A Unix gate WorkRoot is redirected through a symbolic-link ancestor.
        # Purpose: Exercise the Unix link-redirection fixture without registering a Windows-only item.
        It 'UnitT34_rejects_a_unix_symbolic_link_gate_workroot_ancestor' {
            $physical = Join-Path $TestDrive 'gate-hook-physical'
            $symbolicLink = Join-Path $TestDrive 'gate-hook-symbolic-link'
            [void][IO.Directory]::CreateDirectory($physical)
            [void](New-Item -ItemType SymbolicLink -Path $symbolicLink -Target $physical)
            { New-GateGitHooksDirectory $symbolicLink ('git-hooks-' + ('e' * 32)) } | Should Throw 'physical directory'
        }
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
        $entry.status='ready'
        $entry.files=@($entry.files)+@([pscustomobject]@{path='scripts/extra.txt'})
        {Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw 'inventory tree scope'
        $entry.files=@()
        {Assert-GateTransitionInventory $root $entry $commit $true}|Should Throw 'inventory tree scope'
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
        foreach($value in @('2',[double]2,$true)){
            $invalid=Copy-FixtureValue $valid
            $invalid.caseDiscoveryCount=$value
            $invalid.caseExecutionCount=$value
            (Get-SourceFixtureFailure {Assert-GatePlatformTestInventory $invalid})|Should Match 'counts are invalid'
        }
        foreach($value in @([int]::MaxValue,[long]::MaxValue)){
            $boundary=Copy-FixtureValue $valid
            $boundary.caseDiscoveryCount=$value
            $boundary.caseExecutionCount=$value
            Assert-GatePlatformTestInventory $boundary
        }
        $gateAst=(Get-Module ConsumerGate).ExportedFunctions['Write-GateLegReceipt'].ScriptBlock.Ast
        @($gateAst.FindAll({param($node)$node-is[Management.Automation.Language.ConvertExpressionAst]-and
                    $node.Type.TypeName.FullName-eq'int'},$true)).Count | Should Be 0
        @($gateAst.FindAll({param($node)$node-is[Management.Automation.Language.ConvertExpressionAst]-and
                    $node.Type.TypeName.FullName-eq'long'},$true)).Count | Should Be 2
    }

    # Scenario: Two required general checks run in order even when the first child calls exit, and the second child can fail.
    # Purpose: A candidate check cannot terminate the trusted wrapper before every required general check has executed.
    It 'UnitT44_runs_each_general_check_in_an_independent_verified_powershell_process' {
        $candidate=Join-Path $TestDrive 'general-check-processes'
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'config'))
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'scripts'))
        $marker=Join-Path $candidate 'second-check-ran.txt'
        [IO.File]::WriteAllText((Join-Path $candidate 'scripts/first.ps1'),"exit 0`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $candidate 'scripts/second.ps1'),
            "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','ran'); exit 0`n",[Text.UTF8Encoding]::new($false))
        Write-FixtureJson (Join-Path $candidate 'config/consumer-gate.json') ([ordered]@{
                schemaVersion=1;repositoryId='fixture';sourceRepository='https://example.test/fixture.git'
                activeSkills=@('fixture');repositoryChecks=@(
                    [ordered]@{id='first';kind='general';path='scripts/first.ps1'},
                    [ordered]@{id='second';kind='general';path='scripts/second.ps1'}
                )
            })
        $trusted=Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1'
        function Invoke-GeneralFixture {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Process -Id $PID).Path
            $start.WorkingDirectory=$candidate
            $start.UseShellExecute=$false
            $start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            foreach($argument in @('-NoProfile','-NonInteractive','-File',$trusted,'-Mode','general')){[void]$start.ArgumentList.Add($argument)}
            $start.Environment['STANDARD_VALIDATION_CORE_RUN_ID']='fixture-run'
            $start.Environment['STANDARD_VALIDATION_CORE_CHECK_ID']='repository-general'
            $start.Environment['STANDARD_VALIDATION_CORE_SKILLS']='fixture'
            $process=[Diagnostics.Process]::new()
            try{$process.StartInfo=$start;[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                $process.WaitForExit();[pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result;Error=$stderr.Result}}
            finally{$process.Dispose()}
        }
        $success=Invoke-GeneralFixture
        $success.ExitCode | Should Be 0
        (Test-Path -LiteralPath $marker -PathType Leaf) | Should Be $true
        Remove-Item -LiteralPath $marker
        [IO.File]::WriteAllText((Join-Path $candidate 'scripts/second.ps1'),"exit 7`n",[Text.UTF8Encoding]::new($false))
        $failure=Invoke-GeneralFixture
        $failure.ExitCode | Should Be 1
        $failure.Error | Should Match 'failed with exit code 7'
    }

    # Scenario: Runtime and tool boundaries record events in prepare, then the production final report assertion records the final event.
    # Purpose: Execute control flow and prove a failed source-report prerequisite cannot record a later successful step.
    It 'UnitT50_preserves_runtime_tool_and_source_report_ordering' {
        $authority=Join-Path $TestDrive 'source-report-order-authority'
        $work=Join-Path $TestDrive 'source-report-order-work'
        $candidate=Join-Path $TestDrive 'source-report-order-candidate'
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'scripts'))
        [void][IO.Directory]::CreateDirectory((Join-Path $authority 'docs/standards'))
        [void][IO.Directory]::CreateDirectory((Join-Path $work 'validation-artifacts'))
        [void][IO.Directory]::CreateDirectory($candidate)
        $runner=@'
param([switch]$DefineFunctionsOnly,[string]$CandidateRoot,[string]$AdapterPath,[string]$ArtifactsRoot,[string]$OutputPath,
    [string]$SourceRepository,[string]$SourceRevision,[string]$BaseRevision)
function Assert-StandardCoreSourceCheckReport { param($Report,$ExpectedSourceRevision,$ExpectedBaseRevision,
    $ExpectedAuthorityRevision,$ExpectedEventName,$ArtifactsRoot,$OutputPath,$ProcessExitCode,$ValidationSecurityPolicy) }
if($DefineFunctionsOnly){return}
'@
        [IO.File]::WriteAllText((Join-Path $authority 'scripts/Invoke-StandardValidation.ps1'),$runner,[Text.UTF8Encoding]::new($false))
        Write-FixtureJson (Join-Path $authority 'docs/standards/validation-security-gate.json') ([ordered]@{
                stages=@([ordered]@{id='skillspector-static';platformUnavailableException=[ordered]@{allowed=$false}})
            })
        $evidence=Join-Path $work 'validation-artifacts/consumer-core-evidence.json'
        [IO.File]::WriteAllText($evidence,'{}',[Text.UTF8Encoding]::new($false))
        $binding=[pscustomobject]@{candidateRevision=('a'*40);baseRevision=('b'*40);commit=('c'*40);canonicalEvent='pull_request'}
        $eventLog=Join-Path $work 'events.log'
        $env:CONSUMER_GATE_EVENT_LOG_PATH=$eventLog
        $env:CONSUMER_GATE_EVENT_REPOSITORY='https://example.test/fixture.git'
        try{
            Assert-GateFinalSourceReport $authority $candidate $work $binding ([pscustomobject]@{}) $evidence
            @(Get-Content -LiteralPath $eventLog) | Should Be @('source-report-asserted')
            Remove-Item -LiteralPath $eventLog
            Write-FixtureJson (Join-Path $authority 'docs/standards/validation-security-gate.json') ([ordered]@{stages=@()})
            {Assert-GateFinalSourceReport $authority $candidate $work $binding ([pscustomobject]@{}) $evidence}|Should Throw
            (Test-Path -LiteralPath $eventLog) | Should Be $false
        }finally{
            Remove-Item Env:CONSUMER_GATE_EVENT_LOG_PATH,Env:CONSUMER_GATE_EVENT_REPOSITORY -ErrorAction SilentlyContinue
        }
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
