# Shared fixtures for source validation contract tests.
$script:SourceGateTestRoot = $PSScriptRoot

        $script:SourceGateRunnerPath = Join-Path (Split-Path -Parent $script:SourceGateTestRoot) 'scripts/Invoke-StandardValidation.ps1'
        . $script:SourceGateRunnerPath -CandidateRoot $TestDrive -AdapterPath (Join-Path $TestDrive 'adapter.json') -ArtifactsRoot (Join-Path $TestDrive 'artifacts') -SourceRepository 'https://example.com/example/skills.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly

        function Write-SourceGateFixtureJson {
            param([string] $Path, $Value)
            [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
        }
        function New-SourceGateFixture {
            param([switch] $CentralRawTests, [switch] $LargeSkillToolsClosure, [switch] $OutsideArtifactCommand, [switch] $UnownedSharedControl)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $runId = 'c' * 32
            $runRoot = Join-Path $root ('runs/' + $runId)
            $snapshot = Join-Path $runRoot 'candidate'
            $skills = @('alpha', 'beta')
            foreach ($id in $skills) {
                $skillRoot = Join-Path $snapshot ('skills/' + $id)
                [void][IO.Directory]::CreateDirectory($skillRoot)
                [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), ('fixture ' + $id), (New-Object Text.UTF8Encoding($false)))
            }
            if (-not $CentralRawTests) {
                [void][IO.Directory]::CreateDirectory((Join-Path $snapshot 'tests'))
                [IO.File]::WriteAllText((Join-Path $snapshot 'tests/Fixture.Tests.ps1'), '# source gate case fixture', (New-Object Text.UTF8Encoding($false)))
            }
            $fixtureAuthority = if ($CentralRawTests) { (git -C (Split-Path -Parent $script:SourceGateTestRoot) rev-parse HEAD).Trim() } else { 'e' * 40 }
            $inventory = Get-StandardValidationInventory -Root $snapshot -Context 'source gate fixture'
            $contentHash = Get-StandardValidationInventorySha256 -Inventory $inventory
            $caseSnapshotRows=@($inventory | Sort-Object -Property path -CaseSensitive | ForEach-Object { [pscustomobject]@{ path=$_.path; sha256=$_.sha256 } })
            $caseSnapshotSha256=Get-StandardValidationTextSha256 -Value (ConvertTo-Json -InputObject $caseSnapshotRows -Depth 3 -Compress)
            $fixtureToolsRoot=Join-Path $TestDrive ([IO.Path]::GetFileName($root) + '-tools')
            [void][IO.Directory]::CreateDirectory($fixtureToolsRoot)
            $toolPath = if($OutsideArtifactCommand){Join-Path $fixtureToolsRoot 'source-wrapper.bin'}else{Join-Path $root 'fixture-tool.bin'}
            [IO.File]::WriteAllText($toolPath, 'fixture tool', (New-Object Text.UTF8Encoding($false)))
            $frozen = @([pscustomobject]@{ path = $toolPath; sha256 = Get-StandardValidationFileSha256 -Path $toolPath -Context 'fixture tool' })
            $receipts = @()
            $receiptValues = @{}
            $policy = Get-Content -Raw (Join-Path (Split-Path -Parent $script:SourceGateTestRoot) 'docs/standards/validation-toolchain.json') | ConvertFrom-Json
            foreach ($name in @('skill-validator','skill-tools','skillspector')) {
                $receiptPath = Join-Path $root ($name + '.json')
                $installRoot=Join-Path $fixtureToolsRoot ($name + '-install')
                [void][IO.Directory]::CreateDirectory($installRoot)
                [IO.File]::WriteAllText((Join-Path $installRoot 'dependency.bin'), ('fixture dependency ' + $name), (New-Object Text.UTF8Encoding($false)))
                $launcher=[pscustomobject][ordered]@{kind='direct-executable';shimPath=$null;shimSha256=$null;payloadPath=$null;payloadSha256=$null;runtimePath=$null;runtimeSha256=$null}
                $identityKind=switch($name) {'skill-validator' {'go-module-version-build-info-and-binary-hash'}; 'skill-tools' {'registry-integrity-and-locked-dependency-closure'}; 'skillspector' {'release-commit-asset-metadata-dependency-closure-and-executable'}}
                $receiptValue=[pscustomobject]@{ schemaVersion=1; toolName=$name; resolutionRunId=$runId; resolvedAtUtc=[DateTime]::UtcNow.ToString('o'); executionContext='local'; frozenForRun=$true; channel='latest-stable'; source=$policy.tools.$name.source; resolvedVersion='1.0.0'; resolvedIdentity='fixture identity'; identityKind=$identityKind; executablePath=$toolPath; executableSha256=$frozen[0].sha256; installRoot=$installRoot; installedClosureSha256=$null; dependencyClosureSha256=$null; dependencyClosure=@(); launcher=$launcher;launcherDigestSha256=$null }
                if ($name -ceq 'skill-tools') {
                    $shim=Join-Path $installRoot 'skill-tools.cmd';$payload=Join-Path $installRoot 'index.js';$node=Join-Path $fixtureToolsRoot 'node.exe'
                    [IO.File]::WriteAllText($shim, '@echo off', (New-Object Text.UTF8Encoding($false)))
                    [IO.File]::WriteAllText($payload, '// fixture package payload', (New-Object Text.UTF8Encoding($false)))
                    [IO.File]::WriteAllText($node, 'fixture Node runtime', (New-Object Text.UTF8Encoding($false)))
                    foreach ($filePath in @($shim,$payload,$node)) { $frozen += [pscustomobject]@{path=$filePath;sha256=Get-StandardValidationFileSha256 -Path $filePath -Context 'fixture package launcher'} }
                    $receiptValue.executablePath=$shim;$receiptValue.executableSha256=Get-StandardValidationFileSha256 -Path $shim -Context 'fixture shim'
                    $receiptValue | Add-Member -NotePropertyName entryPointPath -NotePropertyValue $payload
                    $receiptValue | Add-Member -NotePropertyName entryPointSha256 -NotePropertyValue (Get-StandardValidationFileSha256 -Path $payload -Context 'fixture payload')
                    $receiptValue | Add-Member -NotePropertyName nodePath -NotePropertyValue $node
                    $receiptValue | Add-Member -NotePropertyName nodeSha256 -NotePropertyValue (Get-StandardValidationFileSha256 -Path $node -Context 'fixture runtime')
                    $receiptValue | Add-Member -NotePropertyName executableVerified -NotePropertyValue $true
                    $launcher.kind='windows-cmd-shim';$launcher.shimPath=$shim;$launcher.shimSha256=$receiptValue.executableSha256;$launcher.payloadPath=$payload;$launcher.payloadSha256=$receiptValue.entryPointSha256;$launcher.runtimePath=$node;$launcher.runtimeSha256=$receiptValue.nodeSha256
                }
                else {
                    $installedExecutable=Join-Path $installRoot ($name + '.exe')
                    [IO.File]::WriteAllText($installedExecutable, ('fixture executable ' + $name), (New-Object Text.UTF8Encoding($false)))
                    $receiptValue.executablePath=$installedExecutable;$receiptValue.executableSha256=Get-StandardValidationFileSha256 -Path $installedExecutable -Context 'fixture installed executable'
                    $frozen += [pscustomobject]@{path=$installedExecutable;sha256=$receiptValue.executableSha256}
                }
                if ($LargeSkillToolsClosure -and $name -ceq 'skill-tools') {
                    foreach ($dependencyIndex in 1..2) {
                        [IO.File]::WriteAllBytes((Join-Path $installRoot ("dependency-large-$dependencyIndex.bin")), (New-Object byte[] 32768))
                    }
                }
                $installedClosureSha256=Get-StandardValidationDirectoryClosureSha256 -Root $installRoot -Context 'fixture installed closure'
                $receiptValue.installedClosureSha256=$installedClosureSha256;$receiptValue.dependencyClosureSha256=$installedClosureSha256
                $receiptValue.launcherDigestSha256=Get-StandardValidationLauncherDigest -Launcher $launcher -Context 'fixture unsigned launcher'
                Write-SourceGateFixtureJson -Path $receiptPath -Value $receiptValue
                $receiptValues[$name]=$receiptValue
                $binding = [pscustomobject]@{ path=$receiptPath; sha256=Get-StandardValidationFileSha256 -Path $receiptPath -Context 'fixture receipt' }
                $frozen += $binding; $receipts += $binding
            }
            $unownedSharedControlPath=$null
            if($UnownedSharedControl){
                $unownedSharedControlPath=Join-Path $fixtureToolsRoot 'common-control.bin'
                [IO.File]::WriteAllText($unownedSharedControlPath,'unowned shared validation control',(New-Object Text.UTF8Encoding($false)))
                $frozen += [pscustomobject]@{path=$unownedSharedControlPath;sha256=Get-StandardValidationFileSha256 -Path $unownedSharedControlPath -Context 'fixture shared control'}
            }
            $sourceSpec=[pscustomobject]@{
                packageAdapter=[pscustomobject]@{command=$toolPath;arguments=@()}
                skillValidator=[pscustomobject]@{command=$toolPath;arguments=@()}
                skillTools=[pscustomobject]@{command=$toolPath;arguments=@()}
                staticAnalyzer=[pscustomobject]@{command=$toolPath;arguments=@()}
                frozenFiles=$frozen;toolReceipts=$receipts
            }
            $centralTestFiles=@('third-party-skill-source.Tests.ps1','third-party-source-envelope.Tests.ps1')
            $centralBindings=@()
            if ($CentralRawTests) {
                $sourceSpec | Add-Member -NotePropertyName testOwnership -NotePropertyValue 'central-third-party-raw-skill-v1'
                foreach ($file in $centralTestFiles) {
                    $testPath=Join-Path $script:SourceGateTestRoot $file
                    $testHash=Get-StandardValidationFileSha256 -Path $testPath -Context 'central fixture test'
                    $centralBindings += [pscustomobject]@{path=('tests/'+$file);sha256=$testHash}
                    $sourceSpec.frozenFiles += [pscustomobject]@{path=$testPath;sha256=$testHash}
                }
            }
            $adapterPath=Join-Path $runRoot 'source-adapter.json'
            Write-SourceGateFixtureJson $adapterPath ([pscustomobject]@{
                schemaVersion=2;adapter='standard-core-adapter-v2';skillsRoot='skills';activeSkills=$skills;sourceValidation=$sourceSpec
                checks=@([pscustomobject]@{id='repository-general';kind='general';executable=$toolPath;executableSha256=$frozen[0].sha256;arguments=@()},[pscustomobject]@{id='repository-pester';kind='pester';executable=$toolPath;executableSha256=$frozen[0].sha256;arguments=@()})
            })
            $adapterHash=Get-StandardValidationFileSha256 -Path $adapterPath -Context 'fixture retained adapter'
            $adapterBinding=[pscustomobject]@{path=$adapterPath;sha256=$adapterHash}
            $candidateId = Get-StandardValidationTextSha256 -Value "$('a' * 40)`n$contentHash`n$adapterHash`n$runId"
            $dispatches = @([pscustomobject]@{ stage='package-validation'; tool='package-adapter'; skill=$null })
            foreach ($id in $skills) {
                $dispatches += [pscustomobject]@{ stage='package-validation'; tool='skill-validator'; skill=$id }
                $dispatches += [pscustomobject]@{ stage='package-validation'; tool='skill-tools'; skill=$id }
            }
            $dispatches += [pscustomobject]@{ stage='skillspector-static'; tool='static-analyzer'; skill=$null }
            $events = @()
            foreach ($dispatch in $dispatches) {
                $eventId = [guid]::NewGuid().ToString()
                $envelope = [pscustomobject]@{ schemaVersion=1; status='passed'; decision='PASS'; candidateIdentity=$candidateId; activeSkills=$skills; findings=@(); analyzerCompleteness='complete'; skillId=$dispatch.skill; skillInventorySha256=$null }
                if ($CentralRawTests -and $dispatch.tool -ceq 'package-adapter') {
                    $envelope | Add-Member -NotePropertyName rawSourceEvidence -NotePropertyValue ([pscustomobject]@{contract='third-party-raw-skill-source-v1';validationKind='third-party-package-only';status='passed';releaseEligible=$false;archiveProjectionVerified=$true;candidateIdentity=[pscustomobject]@{repository='https://example.com/example/skills.git';resolvedCommit=('a'*40)};skills=@($skills | ForEach-Object {[pscustomobject]@{id=$_;sourcePath=('skills/'+$_)}})})
                }
                if ($null -ne $dispatch.skill) {
                    $skillInventory = Get-StandardValidationInventory -Root (Join-Path $snapshot ('skills/' + $dispatch.skill)) -Context 'source gate skill fixture'
                    $envelope.skillInventorySha256 = Get-StandardValidationInventorySha256 -Inventory $skillInventory
                }
                if ($dispatch.tool -cne 'package-adapter') {
                    $nativeReports=@()
                    $nativeSkills=if ($null -ne $dispatch.skill) {@($dispatch.skill)} else {$skills}
                    foreach ($nativeSkill in $nativeSkills) {
                        $nativePath=Join-Path $runRoot ($eventId + '-' + $nativeSkill + '-native.json')
                        Write-SourceGateFixtureJson $nativePath ([pscustomobject]@{fixture=$true;tool=$dispatch.tool;skillId=$nativeSkill;status='passed'})
                        $nativeName=if($dispatch.tool -ceq 'static-analyzer'){'skillspector'}else{$dispatch.tool}
                        $nativeReceipt=$receiptValues[$nativeName]
                        $nativeCommand=if($nativeName -ceq 'skill-tools'){$nativeReceipt.nodePath}else{$nativeReceipt.executablePath}
                        $nativeCommandHash=if($nativeName -ceq 'skill-tools'){$nativeReceipt.nodeSha256}else{$nativeReceipt.executableSha256}
                        $nativeArguments=if($nativeName -ceq 'skill-tools'){@($nativeReceipt.entryPointPath,'validate',$nativeSkill)}else{@('validate',$nativeSkill)}
                        $nativeReports += [pscustomobject]@{skillId=$nativeSkill;command=$nativeCommand;commandSha256=$nativeCommandHash;arguments=$nativeArguments;exitCode=0;path=$nativePath;sha256=Get-StandardValidationFileSha256 -Path $nativePath -Context 'fixture native tool report'}
                    }
                    $envelope | Add-Member -NotePropertyName nativeReports -NotePropertyValue $nativeReports
                }
                $stdout = $envelope | ConvertTo-Json -Depth 20 -Compress
                $process = [pscustomobject]@{ status='passed'; exitCode=0; cleanedUp=$true; stdout=$stdout; stderr=''; startedAt='2026-01-01T00:00:00Z'; endedAt='2026-01-01T00:00:01Z' }
                $rawPath = Join-Path $runRoot ($eventId + '.json')
                Write-SourceGateFixtureJson -Path $rawPath -Value ([pscustomobject]@{ schemaVersion=1; eventId=$eventId; stageId=$dispatch.stage; toolId=$dispatch.tool; skillId=$dispatch.skill; candidateId=$candidateId; process=$process; stdout=$stdout; stderr='' })
                $events += [pscustomobject]@{ eventId=$eventId; stageId=$dispatch.stage; toolId=$dispatch.tool; skillId=$dispatch.skill; candidateId=$candidateId; commandSha256=$frozen[0].sha256; exitCode=0; status='passed'; outputSha256=Get-StandardValidationOutputHash -Stdout $stdout -Stderr ''; outputPath=$rawPath; cleanedUp=$true }
            }
            $checks = @()
            foreach ($kind in @('general','pester')) {
                $stdoutPath=Join-Path $runRoot ($kind + '.stdout.txt'); $stderrPath=Join-Path $runRoot ($kind + '.stderr.txt')
                $counts = [pscustomobject]@{ total=2; passed=2; failed=0; skipped=0 }
                $stdout = if ($kind -ceq 'pester') { [pscustomobject]@{ schemaVersion=1; report='standard-core-pester-result-v1'; total=2; passed=2; failed=0; skipped=0 } | ConvertTo-Json -Compress } else { 'Repository fixture passed.' }
                [IO.File]::WriteAllText($stdoutPath, $stdout, (New-Object Text.UTF8Encoding($false)))
                [IO.File]::WriteAllText($stderrPath, '', (New-Object Text.UTF8Encoding($false)))
                $checks += [pscustomobject]@{ id=('repository-' + $kind); kind=$kind; status='passed'; exitCode=0; cleanedUp=$true; stdoutPath=$stdoutPath; stdoutSha256=Get-StandardValidationFileSha256 -Path $stdoutPath -Context 'fixture repository output'; stderrPath=$stderrPath; stderrSha256=Get-StandardValidationFileSha256 -Path $stderrPath -Context 'fixture repository errors'; testCounts=if ($kind -ceq 'pester') { $counts } else { $null }; executableSha256=$frozen[0].sha256; argumentsSha256=Get-StandardValidationTextSha256 -Value '[]'; processId=123; startedAt='2026-01-01T00:00:00Z'; endedAt='2026-01-01T00:00:01Z' }
            }
            $casePath=Join-Path $runRoot 'repository-pester-case-inventory-v1.json'
            $caseRows=@(1..2 | ForEach-Object {
                $expandedPath='Fixture.UnitT' + $_
                $caseFile=if($CentralRawTests){$centralTestFiles[$_-1]}else{'Fixture.Tests.ps1'}
                $tuple=ConvertTo-Json -InputObject ([object[]]@($caseFile.ToUpperInvariant(), $_, $expandedPath)) -Compress -Depth 3
                [pscustomobject]@{ identity=[Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($tuple)); sourceFile=$caseFile; sourceStartOffset=$_; sourceStartLine=$_; expandedPath=$expandedPath; result='Passed'; identityError=$null }
            })
            Write-SourceGateFixtureJson $casePath ([pscustomobject]@{
                schemaVersion=1; report='standard-core-pester-case-inventory-v1'; coreRunId=$runId
                candidateSnapshotIdentity=[pscustomobject]@{coreRunId=$runId;root=$snapshot}; candidateSnapshotSha256=$caseSnapshotSha256
                pesterModule=[pscustomobject]@{version='6.0.0';manifestPath='fixture';moduleRoot='fixture';lockPath='fixture';lockSha256='1' * 64;closureSha256Before='2' * 64;closureSha256After='2' * 64}
                runPath='tests';runScope='complete-unfiltered-tests-tree';testFileInventory=@('Fixture.Tests.ps1');containerFileInventory=@('Fixture.Tests.ps1');discoveredCaseFileInventory=@('Fixture.Tests.ps1')
                caseDiscoveryCount=2;caseExecutionCount=2;containerCount=1;failedBlockCount=0;failedContainerCount=0;terminalStatus='complete'
                reportedCounts=[pscustomobject]@{Passed=2;Failed=0;Skipped=0;Inconclusive=0;NotRun=0};shardIdentity='core-full';shardCaseIdentities=@($caseRows.identity)
                shardUnion=[pscustomobject]@{discoveryCount=2;executionUnionCount=2;complete=$true};discoveryCases=$caseRows;executionCases=$caseRows;complete=$true;errors=@()
            })
            if ($CentralRawTests) {
                $cases=Get-Content -Raw $casePath | ConvertFrom-Json
                $cases.runScope='complete-central-raw-skill-suite'
                foreach ($field in @('testFileInventory','containerFileInventory','discoveredCaseFileInventory')) { $cases.$field=$centralTestFiles }
                $cases | Add-Member -NotePropertyName testSourceIdentity -NotePropertyValue ([pscustomobject]@{ownership='central-third-party-raw-skill-v1';root=(Split-Path -Parent $script:SourceGateTestRoot);authorityRevision=$fixtureAuthority;files=$centralBindings})
                Write-SourceGateFixtureJson $casePath $cases
            }
            $caseBinding=[pscustomobject]@{path=$casePath;sha256=Get-StandardValidationFileSha256 -Path $casePath -Context 'fixture case ledger'}
            $fixtureReport=[pscustomobject]@{
                schemaVersion=2; evidence='standard-core-validation-evidence-v2'; generatedAt='2026-01-01T00:00:01Z'; state='PASS'; exitCode=0; runId=$runId; releaseEligible=$false; contentMode='immutable-source'; failure=$null
                candidate=[pscustomobject]@{ repository='https://example.com/example/skills.git'; sourceRevision='a' * 40; baseRevision='b' * 40; contentSha256=$contentHash; inventory=$inventory; activeSkills=$skills; contentMode='immutable-source'; eventName='pull_request' }
                authority=[pscustomobject]@{ repository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'; revision=$fixtureAuthority; contentMode='source'; runnerSha256='3' * 64; contractSha256='4' * 64 }
                adapter=[pscustomobject]@{ schemaVersion=2; identity='standard-core-adapter-v2'; sha256=$adapterHash }
                artifacts=[pscustomobject]@{ runId=$runId; root=$root; outputPath=Join-Path $root 'result.json'; runRoot=$runRoot; snapshotRoot=$snapshot }
                sourceValidation=[pscustomobject]@{ status='passed'; runId=$runId; candidateId=$candidateId; sourceRevision='a' * 40; contentSha256=$contentHash; authorityRevision=$fixtureAuthority; activeSkills=$skills; skillsRoot='skills'; toolReceipts=$receipts; frozenFiles=$sourceSpec.frozenFiles; events=$events; pesterCaseInventory=$caseBinding; adapterSnapshot=$adapterBinding }
                checks=$checks
            }
            if ($CentralRawTests) { $fixtureReport.sourceValidation | Add-Member -NotePropertyName testOwnership -NotePropertyValue 'central-third-party-raw-skill-v1' }
            if($null -ne $unownedSharedControlPath){$fixtureReport | Add-Member -NotePropertyName unownedSharedControlPath -NotePropertyValue $unownedSharedControlPath}
            return $fixtureReport
        }
        function Invoke-SourceGateFixture {
            param($Report, [int] $ExitCode=0, [string] $ExpectedAuthorityRevision=('e'*40))
            Assert-StandardCoreSourceCheckReport -Report $Report -ExpectedSourceRevision ('a' * 40) -ExpectedBaseRevision ('b' * 40) -ExpectedAuthorityRevision $ExpectedAuthorityRevision -ExpectedEventName 'pull_request' -ArtifactsRoot $Report.artifacts.root -OutputPath $Report.artifacts.outputPath -ProcessExitCode $ExitCode
        }
        function Set-SourceGateEnvelope {
            param($Report, [int] $Index, [scriptblock] $Mutate)
            $event=$Report.sourceValidation.events[$Index]
            $raw=Get-Content -Raw $event.outputPath | ConvertFrom-Json
            $envelope=$raw.stdout | ConvertFrom-Json
            & $Mutate $envelope
            $raw.stdout=$envelope | ConvertTo-Json -Depth 30 -Compress
            $raw.process.stdout=$raw.stdout
            $event.outputSha256=Get-StandardValidationOutputHash -Stdout $raw.stdout -Stderr $raw.stderr
            Write-SourceGateFixtureJson -Path $event.outputPath -Value $raw
        }
        function Set-SourceGateCases {
            param($Report, [scriptblock] $Mutate)
            $binding=$Report.sourceValidation.pesterCaseInventory
            $cases=Get-Content -Raw $binding.path | ConvertFrom-Json
            & $Mutate $cases
            Write-SourceGateFixtureJson $binding.path $cases
            $binding.sha256=Get-StandardValidationFileSha256 -Path $binding.path -Context 'mutated case ledger'
        }
        function Set-SourceGateReceipt {
            param($Report, [scriptblock] $Mutate, [int] $Index=0)
            $binding=$Report.sourceValidation.toolReceipts[$Index]
            $receipt=Get-Content -Raw $binding.path | ConvertFrom-Json
            & $Mutate $receipt
            Write-SourceGateFixtureJson $binding.path $receipt
            $binding.sha256=Get-StandardValidationFileSha256 -Path $binding.path -Context 'mutated receipt'
        }

        function Set-SourceGateToolTransportMock {
            param([object[]] $Receipts, [scriptblock] $AfterChild)
            $script:SourceToolLaunches=New-Object 'System.Collections.Generic.List[string]'
            $script:SourceFakeReceipts=@($Receipts)
            $script:SourceAfterChild=$AfterChild
            Mock Invoke-StandardValidationCommandAndRecord {
                param($CommandSpec,[string]$RunRoot,[string]$ChildWorkingRoot,[string]$StageId,[string]$ToolId,[string]$CandidateId,[string]$SkillId,[string[]]$ExpectedActiveSkills)
                $script:SourceToolLaunches.Add([string]$ToolId)
                $nativeReports=@()
                if([string]$ToolId -cin @('skill-validator','skill-tools','static-analyzer')){
                    $nativeName=if([string]$ToolId -ceq 'static-analyzer'){'skillspector'}else{[string]$ToolId}
                    $binding=@($script:SourceFakeReceipts | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq ($nativeName+'.json')})[0]
                    $receipt=Get-Content -Raw $binding.path | ConvertFrom-Json
                    $nativeCommand=if($nativeName -ceq 'skill-tools'){$receipt.nodePath}else{$receipt.executablePath}
                    $nativeCommandHash=if($nativeName -ceq 'skill-tools'){$receipt.nodeSha256}else{$receipt.executableSha256}
                    $nativeSkills=if(-not [string]::IsNullOrEmpty([string]$SkillId)){@([string]$SkillId)}else{@($ExpectedActiveSkills)}
                    foreach($nativeSkill in $nativeSkills){
                        $nativePath=Join-Path $RunRoot (([guid]::NewGuid().ToString('N'))+'-native.json')
                        Write-SourceGateFixtureJson -Path $nativePath -Value ([pscustomobject]@{tool=$ToolId;skillId=$nativeSkill;status='passed'})
                        $nativeArguments=if($nativeName -ceq 'skill-tools'){@($receipt.entryPointPath,'validate',$nativeSkill)}else{@('validate',$nativeSkill)}
                        $nativeReports += [pscustomobject]@{skillId=$nativeSkill;command=$nativeCommand;commandSha256=$nativeCommandHash;arguments=$nativeArguments;exitCode=0;path=$nativePath;sha256=Get-StandardValidationFileSha256 -Path $nativePath -Context 'source transport native report'}
                    }
                }
                $envelope=[pscustomobject]@{nativeReports=@($nativeReports);findings=@();analyzerCompleteness='complete'}
                $result=[pscustomobject]@{event=[pscustomobject]@{tool=$ToolId;skill=$SkillId};envelope=$envelope}
                if($null -ne $script:SourceAfterChild){& $script:SourceAfterChild -ToolId $ToolId -SkillId $SkillId -CommandSpec $CommandSpec -RunRoot $RunRoot -Receipts $script:SourceFakeReceipts}
                return $result
            }
        }

        function Invoke-SourceGateDispatchFixture {
            param($Report)
            $adapter=Get-Content -Raw $Report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
            $spec=$adapter.sourceValidation
            $skillSet=Get-StandardValidationSkillSet -CandidateRoot $Report.artifacts.snapshotRoot -SkillsRootRelative 'skills' -DeclaredSkills $adapter.activeSkills
            $trustedRoot=Split-Path -Parent ([string]$spec.packageAdapter.command)
            return Invoke-StandardCoreSourceTools -Spec $spec -SkillSet $skillSet -RunId $Report.runId -SourceRevision $Report.candidate.sourceRevision `
                -AuthorityRevision $Report.authority.revision -SnapshotRoot $Report.artifacts.snapshotRoot -ContentSha256 $Report.candidate.contentSha256 `
                -RunRoot $Report.artifacts.runRoot -AdapterPath $Report.sourceValidation.adapterSnapshot.path -AdapterSha256 $Report.sourceValidation.adapterSnapshot.sha256 `
                -ArtifactsRoot $Report.artifacts.root -TrustedToolRoot $trustedRoot -TimeoutSeconds 5 -CancellationPath (Join-Path $Report.artifacts.root 'cancelled')
        }
