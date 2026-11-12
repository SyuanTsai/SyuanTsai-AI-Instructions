. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions unified repository transaction failpoint matrix' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:P9cBaseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'baseline-work') -ArchivePath (Join-Path $script:ExternalRoot 'baseline.zip') -Marker baseline
        $script:P9cChanged=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'changed-work') -ArchivePath (Join-Path $script:ExternalRoot 'changed.zip') -Marker changed
        $initialFiles=@{'work-with-jira'=@{'resources/state.txt'="jira old`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff old`n"}}
        $updatedFiles=@{'work-with-jira'=@{'resources/state.txt'="jira new`n";'resources/added.txt'="jira added`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff new`n";'resources/added.txt'="handoff added`n"}}
        $script:P9cInitial=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'initial') -ProjectionIds @('project-agents') -AdditionalSkillFiles $initialFiles
        $script:P9cUpdated=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'updated') -ProjectionIds @('project-agents') -AdditionalSkillFiles $updatedFiles
        $script:P9cSeeds=@{}
        foreach($withRemediation in @($false,$true)){
            $seed=Join-Path $script:ExternalRoot ("seed-$withRemediation");New-P9bTargetRepository $seed
            $result=Invoke-P9bRepoBootstrap -Context $script:P9cInitial.Context -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $seed
            if($result.ExitCode-ne0){throw "Could not create InterT140 seed: $($result.Output)"}
            if($withRemediation){& git -C $seed add -f -- AGENTS.md;& git -C $seed commit --quiet -m 'tracked Agent artifact fixture';if($LASTEXITCODE-ne0){throw 'Could not create remediation seed.'}}
            $script:P9cSeeds[[string]$withRemediation]=$seed
        }
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: With and without tracked-artifact remediation, representative index, ref, file, Skill, license, manifest, and shared-exclude roles stop immediately before mutation or after mutation but before journal update, through both process catch and next-run recovery.
    # Purpose: Preserve every fix4 InterT140 state assertion, select sequences by durable role instead of number, and prove both recovery paths produce identical complete repository snapshots.
    It 'InterT140_recovers_each_repository_role_failpoint_with_and_without_remediation_through_both_paths' {
        $normalizeCrossCloneSnapshot={param([string]$Snapshot)$state=$Snapshot|ConvertFrom-Json;$state.indexRaw='<clone-local-stat-cache>';return ($state|ConvertTo-Json -Depth 6 -Compress)}
        $rolesByRemediation=@{
            'False'=@('instruction','project-skill','license','manifest','shared-exclude')
            'True'=@('git-index','git-ref','remediation-and-instruction')
        }
        foreach($withRemediation in @($false,$true)){
            $discovery=Join-Path $script:ExternalRoot ("discovery-$withRemediation");Copy-Item -LiteralPath $script:P9cSeeds[[string]$withRemediation] -Destination $discovery -Recurse
            $discoveryBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "discovery-runtime-$withRemediation") -Failpoint 'after-journal-prepared' -RecoveryPath NextRun
            $discoveryResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $discoveryBootstrap
            $discoveryResult.ExitCode|Should -Not -Be 0
            $transactions=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$transactions.Count|Should -Be 1
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transactions[0].FullName 'journal.json')|ConvertFrom-Json
            $roleSequences=@{}
            foreach($role in $rolesByRemediation[[string]$withRemediation]){
                $operation=@($journal.operations|Where-Object{[string]$_.role-ceq$role}|Sort-Object sequence|Select-Object -First 1)
                if($operation.Count-ne1){throw "InterT140 discovery for remediation=$withRemediation is missing role '$role'. Roles: $(@($journal.operations.role)-join', '). Output: $($discoveryResult.Output)"}
                $roleSequences[$role]=[int]$operation[0].sequence
            }
            foreach($role in $rolesByRemediation[[string]$withRemediation]){
                foreach($position in @('before','after-before-journal')){
                    $sequence=$roleSequences[$role]
                    $failpoint=if($position-ceq'before'){"before-operation-$sequence"}else{"after-operation-$sequence-before-journal"}
                    $decisionSnapshots=@{};$finalSnapshots=@{}
                    foreach($recoveryPath in @('InProcess','NextRun')){
                        $caseRoot=Join-Path $script:ExternalRoot ("case-$withRemediation-$role-$position-$recoveryPath");Copy-Item -LiteralPath $script:P9cSeeds[[string]$withRemediation] -Destination $caseRoot -Recurse
                        $before=Get-P9cPublicationStateSnapshot $caseRoot
                        $failpointBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "runtime-$withRemediation-$role-$position-$recoveryPath") -Failpoint $failpoint -RecoveryPath $recoveryPath
                        $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $caseRoot -BootstrapPath $failpointBootstrap
                        $failed.ExitCode|Should -Not -Be 0
                        if($recoveryPath-ceq'NextRun'){
                            $active=@(Get-ChildItem -LiteralPath (Join-Path $caseRoot '.ai-instructions-txn') -Directory -Force);$active.Count|Should -Be 1
                            $failedJournal=Get-Content -Raw -LiteralPath (Join-Path $active[0].FullName 'journal.json')|ConvertFrom-Json
                            [string]$failedJournal.phase|Should -Be applying
                            [string](@($failedJournal.operations|Where-Object sequence -eq $sequence)[0].role)|Should -Be $role
                            @($failedJournal.operations|Where-Object{[string]$_.target.kind-ceq'repository-relative'-and[string]$_.target.value-ceq'AGENTS.md'}).Count|Should -Be 1
                            @($failedJournal.operations|Where-Object{[string]$_.role-ceq'manifest'}).Count|Should -Be 1
                            @($failedJournal.operations|Where-Object{[string]$_.role-ceq'project-skill'-and[string]$_.target.value-like'*/resources/state.txt'}).Count|Should -Be 2
                            @($failedJournal.operations|Where-Object{[string]$_.role-ceq'shared-exclude'}).Count|Should -Be 1
                            ($null-ne$failedJournal.scope.externalBackup)|Should -Be $withRemediation
                            $recoveryOnly=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "recovery-$withRemediation-$role-$position") -Failpoint RecoveryOnly
                            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $caseRoot -BootstrapPath $recoveryOnly).ExitCode|Should -Not -Be 0
                        }else{(Get-AiInstructionsRefusalCode $failed.Output)|Should -Be interrupted-install}
                        @(Get-ChildItem -Force -LiteralPath (Join-Path $caseRoot '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should -Be 0
                        $afterDecision=Get-P9cPublicationStateSnapshot $caseRoot;$afterDecision|Should -Be $before;$decisionSnapshots[$recoveryPath]=$afterDecision

                        $recovered=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $caseRoot
                        if($recovered.ExitCode-ne0){throw "Project publication retry failed for $withRemediation/$role/$position/$recoveryPath`: $($recovered.Output)"}
                        $manifestPath=Join-Path $caseRoot '.codex/ai-instructions.manifest.json';$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
                        [IO.File]::ReadAllText((Join-Path $caseRoot 'AGENTS.md'))|Should -Match '<!-- changed -->'
                        $agentsEntry=@($manifest.files|Where-Object{[string]$_.targetPath-ceq'AGENTS.md'})[0];(Get-P9bNormalizedSha256 (Join-Path $caseRoot 'AGENTS.md'))|Should -Be ([string]$agentsEntry.sha256)
                        $skillEntries=@($manifest.files|Where-Object{[string]$_.artifactType-ceq'skill'});@($skillEntries|Where-Object{[string]$_.targetPath-like'*/resources/added.txt'}).Count|Should -Be 2
                        foreach($entry in $skillEntries){(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $caseRoot ([string]$entry.targetPath))).Hash.ToLowerInvariant()|Should -Be ([string]$entry.sha256)}
                        $exclude=[IO.File]::ReadAllText((Join-Path $caseRoot '.git/info/exclude'));foreach($path in @($manifest.files.targetPath)+@('.codex/ai-instructions.manifest.json')){$exclude|Should -Match ("(?m)^/"+[regex]::Escape([string]$path)+"`r?$")}
                        $beforeState=$before|ConvertFrom-Json;$afterState=(Get-P9cPublicationStateSnapshot $caseRoot)|ConvertFrom-Json
                        if($withRemediation){$afterState.headObject|Should -Not -Be $beforeState.headObject}else{$afterState.headObject|Should -Be $beforeState.headObject}
                        $beforeRepeat=Get-P9cPublicationStateSnapshot $caseRoot
                        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $caseRoot).ExitCode|Should -Be 0
                        (Get-P9cPublicationStateSnapshot $caseRoot)|Should -Be $beforeRepeat
                        $finalSnapshots[$recoveryPath]=$beforeRepeat
                    }
                    (&$normalizeCrossCloneSnapshot $decisionSnapshots.InProcess)|Should -Be (&$normalizeCrossCloneSnapshot $decisionSnapshots.NextRun)
                    (&$normalizeCrossCloneSnapshot $finalSnapshots.InProcess)|Should -Be (&$normalizeCrossCloneSnapshot $finalSnapshots.NextRun)
                }
            }
        }
        ([IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1')))|Should -Not -Match 'P9C_TEST_HOOK'
    }
}
