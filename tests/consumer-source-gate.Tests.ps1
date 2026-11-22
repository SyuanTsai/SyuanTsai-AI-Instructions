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
        function Invoke-SourceFixtureGitWithInputBytes([string]$Root,[string[]]$Arguments,[byte[]]$InputBytes) {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
            $start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            foreach($argument in @('-c','core.autocrlf=false','-C',$Root)+$Arguments){[void]$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            try{
                [void]$process.Start()
                $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                $process.StandardInput.BaseStream.Write($InputBytes,0,$InputBytes.Length);$process.StandardInput.Close()
                $process.WaitForExit();$output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
                if($process.ExitCode-ne0){throw "fixture git failed: $errorText"}
                $output.Trim()
            }finally{$process.Dispose()}
        }
        function Invoke-SourceFixtureGitBytes([string]$Root,[string[]]$Arguments) {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($argument in @('-C',$Root)+$Arguments){[void]$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$memory=[IO.MemoryStream]::new()
            try{
                [void]$process.Start();$copy=$process.StandardOutput.BaseStream.CopyToAsync($memory);$errorRead=$process.StandardError.ReadToEndAsync()
                $process.WaitForExit();$null=$copy.GetAwaiter().GetResult();$errorText=$errorRead.GetAwaiter().GetResult()
                if($process.ExitCode-ne0){throw "fixture git failed: $errorText"}
                Write-Output -NoEnumerate ([byte[]]$memory.ToArray())
            }finally{$memory.Dispose();$process.Dispose()}
        }
        function New-WindowsGitOwnedProcessShim([string]$Root,[ValidateSet('credential','hang')][string]$Mode,
            [string]$ObservationPath,[string]$ShimPidPath,[string]$DescendantPidPath) {
            $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            if(-not(Test-Path -LiteralPath $csc -PathType Leaf)){throw "Required Windows .NET Framework compiler is missing: $csc"}
            [void][IO.Directory]::CreateDirectory($Root)
            $shim=Join-Path $Root 'git.exe'
            $source=Join-Path $script:RepositoryRoot 'tests/fixtures/windows-git-owned-process-shim.cs'
            $compilerOutput=@(& $csc /nologo /target:exe "/out:$shim" $source 2>&1)
            if($LASTEXITCODE-ne0-or-not(Test-Path -LiteralPath $shim -PathType Leaf)){
                throw "Windows Git owned-process shim compilation failed: $($compilerOutput-join' ')"
            }
            [IO.File]::WriteAllText((Join-Path $Root 'mode.txt'),$Mode,[Text.UTF8Encoding]::new($false))
            if($Mode-ceq'credential'){
                $realGit=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
                [IO.File]::WriteAllText((Join-Path $Root 'real-git-path.txt'),$realGit,[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $Root 'observation-path.txt'),$ObservationPath,[Text.UTF8Encoding]::new($false))
            }else{
                [IO.File]::WriteAllText((Join-Path $Root 'shim-pid-path.txt'),$ShimPidPath,[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $Root 'descendant-pid-path.txt'),$DescendantPidPath,[Text.UTF8Encoding]::new($false))
            }
            $Root
        }
        function New-GitCredentialPresenceShim([string]$Root,[string]$ObservationPath) {
            [void][IO.Directory]::CreateDirectory($Root)
            $realGit=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
            if($IsWindows){
                return New-WindowsGitOwnedProcessShim $Root credential $ObservationPath $null $null
            }else{
                $path=Join-Path $Root 'git';$log=$ObservationPath.Replace('"','\"');$git=$realGit.Replace('"','\"')
                $text="#!/bin/sh`ns=0; g=0; h=0`n[ -n `"`${STANDARD_VALIDATION_GITHUB_API_TOKEN+x}`" ] && s=1`n[ -n `"`${GITHUB_TOKEN+x}`" ] && g=1`n[ -n `"`${GH_TOKEN+x}`" ] && h=1`nprintf '%s,%s,%s\n' `"`$s`" `"`$g`" `"`$h`" >> `"$log`"`nexec `"$git`" `"`$@`"`n"
            }
            [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
            if(-not$IsWindows){[IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite-bor[IO.UnixFileMode]::UserExecute)}
            $Root
        }
        function Copy-FixtureValue($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
        function Set-FixturePendingPrerequisites($Manifest,[string]$RepositoryId='skill-darktide-translate') {
            $entry=@($Manifest.repositories|Where-Object{$_.id-eq$RepositoryId})[0]
            $entry.status='pending-prerequisites'
            $entry|Add-Member -Force prerequisites @([pscustomobject]@{
                    id='fixture-prerequisite'
                    path=[string]$entry.files[0].path
                    requirement='Fixture prerequisite remains incomplete.'
                })
            $entry
        }
        $script:ExceptionFixtureConfigRoot = Join-Path $script:RepositoryRoot 'tests/fixtures/syp500'
        function New-ExceptionFixtureRepository([string]$Name,[switch]$WithoutExceptionSet) {
            $root=Join-Path $TestDrive $Name
            [void][IO.Directory]::CreateDirectory($root)
            [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
            [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
            [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
            if($WithoutExceptionSet){
                [IO.File]::WriteAllText((Join-Path $root 'README.md'),'fixture',[Text.UTF8Encoding]::new($false))
            }else{
                Copy-Item -LiteralPath $script:ExceptionFixtureConfigRoot -Destination (Join-Path $root 'config') -Recurse
                $registry=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'config/skillspector-exceptions.json')|ConvertFrom-Json
                foreach($exception in @($registry.exceptions)){
                    $path=Join-Path $root "skills/$($exception.skillId)/$($exception.file)"
                    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                    if(-not(Test-Path -LiteralPath $path)){[IO.File]::WriteAllText($path,"fixture: $($exception.file)",[Text.UTF8Encoding]::new($false))}
                }
            }
            [void](Invoke-SourceFixtureGit $root @('add','.'))
            [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','base'))
            [pscustomobject]@{Root=$root;Base=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')}
        }
        function Save-ExceptionFixtureCandidate([string]$Root,[string]$Message) {
            [void](Invoke-SourceFixtureGit $Root @('add','-A'))
            [void](Invoke-SourceFixtureGit $Root @('commit','-q','-m',$Message))
            Get-SourceFixtureGitScalar $Root @('rev-parse','HEAD')
        }
        function New-ExceptionFixtureRawPathCandidate([string]$Root,[string]$Base,[byte[]]$PathBytes,[string]$Message) {
            $blob=Get-SourceFixtureGitScalar $Root @('rev-parse','HEAD:config/skillspector-exceptions.json')
            $indexInput=[Collections.Generic.List[byte]]::new()
            $indexInput.AddRange([Text.Encoding]::ASCII.GetBytes("100644 $blob`t"))
            $indexInput.AddRange($PathBytes);$indexInput.Add(0)
            [void](Invoke-SourceFixtureGitWithInputBytes $Root @('update-index','--add','-z','--index-info') $indexInput.ToArray())
            $tree=Get-SourceFixtureGitScalar $Root @('write-tree')
            Get-SourceFixtureGitScalar $Root @('commit-tree',$tree,'-p',$Base,'-m',$Message)
        }
        function Get-ExceptionFixtureRegistry([string]$Root) {
            Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'config/skillspector-exceptions.json')|ConvertFrom-Json
        }
        function Set-ExceptionFixtureRegistry([string]$Root,$Registry) {
            # Candidate JSON is intentionally reformatted: semantic comparison must ignore object/array presentation and member order.
            Write-FixtureJson (Join-Path $Root 'config/skillspector-exceptions.json') $Registry
        }
        function Get-ExceptionFixtureBaseline([string]$Root,[string]$SkillId='review-bitbucket-pull-request') {
            Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root "config/skillspector-exceptions/$SkillId.baseline.json")|ConvertFrom-Json
        }
        function Set-ExceptionFixtureBaseline([string]$Root,$Baseline,[string]$SkillId='review-bitbucket-pull-request') {
            Write-FixtureJson (Join-Path $Root "config/skillspector-exceptions/$SkillId.baseline.json") $Baseline
        }
        function New-ScannerTransitionFixture {
            param(
                [string]$Name,
                [string]$OldVersion='2.13.4',
                [string]$OldWheel='c5e7f290897c65018013a6e37022fabdd2ba1aeeb4994b65df2de8b0d536bea0',
                [string]$NewVersion='2.13.6',
                [string]$NewWheel='e7b46c55e726405b2a068d375d1ee8e799e15d86f3fc05f84feb5ba962198b15',
                [scriptblock]$BaseMutation,
                [scriptblock]$Mutation
            )
            $fixture=New-ExceptionFixtureRepository $Name
            if($null-ne$BaseMutation){
                $baseRegistry=Get-ExceptionFixtureRegistry $fixture.Root
                $baseBaseline=Get-ExceptionFixtureBaseline $fixture.Root
                & $BaseMutation $baseRegistry $baseBaseline $fixture.Root
                Set-ExceptionFixtureRegistry $fixture.Root $baseRegistry
                Set-ExceptionFixtureBaseline $fixture.Root $baseBaseline
                $fixture.Base=Save-ExceptionFixtureCandidate $fixture.Root 'establish scanner transition base mutation'
            }
            if($OldVersion-cne'2.13.4'-or$OldWheel-cne'c5e7f290897c65018013a6e37022fabdd2ba1aeeb4994b65df2de8b0d536bea0'){
                $oldRegistry=Get-ExceptionFixtureRegistry $fixture.Root
                $oldRegistry.scanner.version=$OldVersion;$oldRegistry.scanner.wheelSha256=$OldWheel
                Set-ExceptionFixtureRegistry $fixture.Root $oldRegistry
                foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'config/skillspector-exceptions') -Filter '*.baseline.json')){
                    $oldBaseline=Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName|ConvertFrom-Json
                    $oldBaseline.scanner_version=$OldVersion;Write-FixtureJson $file.FullName $oldBaseline
                }
                $fixture.Base=Save-ExceptionFixtureCandidate $fixture.Root 'establish retained scanner base'
            }
            $registry=Get-ExceptionFixtureRegistry $fixture.Root
            $registry.scanner.version=$NewVersion;$registry.scanner.wheelSha256=$NewWheel
            $registry.baselines=@($registry.baselines|Where-Object skillId -ceq 'review-bitbucket-pull-request')
            $registry.exceptions=@($registry.exceptions|Where-Object skillId -ceq 'review-bitbucket-pull-request')
            $baseline=Get-ExceptionFixtureBaseline $fixture.Root
            $baseline.scanner_version=$NewVersion
            $newHashes=@(
                'sha256:cd03ffaa57a764f8a960ca4af6dc774b56f8374b008a9e116be86274b81bcb13',
                'sha256:9cd21ec5e6c12ebcfd4e4c5161fccfbfe197a8c56f81aa6ce872ba2d21f61d03',
                'sha256:07daccad20dd2bc1d865c5d7657d9242d4866c66017c25256139f14163c97806'
            )
            for($index=0;$index-lt$baseline.fingerprints.Count;$index++){
                $oldHash=[string]$baseline.fingerprints[$index].hash;$newHash=$newHashes[$index]
                $exception=@($registry.exceptions|Where-Object fingerprint -ceq $oldHash)
                if($exception.Count-ne1){throw "Transition fixture fingerprint '$oldHash' has no unique exception."}
                $baseline.fingerprints[$index].hash=$newHash;$exception[0].fingerprint=$newHash
            }
            if($null-ne$Mutation){& $Mutation $registry $baseline $fixture.Root}
            Set-ExceptionFixtureRegistry $fixture.Root $registry
            Set-ExceptionFixtureBaseline $fixture.Root $baseline
            Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'config/skillspector-exceptions') -Filter '*.baseline.json'|Where-Object Name -cne `
                'review-bitbucket-pull-request.baseline.json'|Remove-Item -Force
            [pscustomobject]@{Root=$fixture.Root;Base=$fixture.Base;Candidate=Save-ExceptionFixtureCandidate $fixture.Root 'scanner transition candidate'}
        }
        function Get-ScannerTransitionSuppressedFindings($Fixture) {
            @(Get-GateCandidateTransitionExpectations $Fixture.Root $Fixture.Candidate|ForEach-Object{
                [pscustomobject]@{skillId=$_.skillId;ruleId=$_.ruleId;severity='medium';file=$_.file;line=[long]$_.startLine;suppressionReason=$_.reason}
            })
        }
        function Get-ScannerTransitionOutputHash([string]$Stdout,[string]$Stderr) {
            $sha=[Security.Cryptography.SHA256]::Create()
            try{
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Stdout+"`n---stderr---`n"+$Stderr)
                ([BitConverter]::ToString($sha.ComputeHash($bytes))-replace'-','').ToLowerInvariant()
            }finally{$sha.Dispose()}
        }
        function New-ScannerTransitionEvidenceFixture($Fixture,[object[]]$Suppressed,[string]$Status='passed') {
            $artifacts=Join-Path $TestDrive ('transition-evidence-'+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($artifacts)
            $eventId=[guid]::NewGuid().ToString();$stageId='skillspector-static';$candidateId='candidate-fixture'
            $eventPath=Join-Path $artifacts "event-$eventId.json"
            $envelope=if($Status-ceq'platform-unavailable'){
                [ordered]@{schemaVersion=1;status='platform-unavailable';decision='PLATFORM_UNAVAILABLE'}
            }else{[ordered]@{suppressedFindings=@($Suppressed)}}
            $stdout=$envelope|ConvertTo-Json -Depth 20 -Compress;$stderr=''
            $process=[ordered]@{startedAt='2026-11-20T00:00:00Z';endedAt='2026-11-20T00:00:01Z'
                exitCode=if($Status-ceq'platform-unavailable'){1}else{0};status=$Status;stdout=$stdout;stderr=$stderr
                cleanedUp=$true;processOwnership=$null}
            Write-FixtureJson $eventPath ([ordered]@{schemaVersion=1;eventId=$eventId;stageId=$stageId;toolId='static-analyzer'
                skillId=$null;candidateId=$candidateId;process=$process;stdout=$stdout;stderr=$stderr})
            $report=[pscustomobject]@{sourceValidation=[pscustomobject]@{events=@([pscustomobject]@{
                eventId=$eventId;stageId=$stageId;toolId='static-analyzer';skillId=$null;candidateId=$candidateId
                commandSha256=('a'*64);exitCode=$process.exitCode;status=$Status
                outputPath=$eventPath;outputSha256=Get-ScannerTransitionOutputHash $stdout $stderr;cleanedUp=$true;processOwnership=$null
            })}}
            [pscustomobject]@{Artifacts=$artifacts;EventPath=$eventPath;Report=$report}
        }
        function Assert-ScannerTransitionEvidenceFixture($Fixture,[object[]]$Suppressed,[string]$Status='passed') {
            $evidence=New-ScannerTransitionEvidenceFixture $Fixture $Suppressed $Status
            Assert-GateExceptionScannerTransitionEvidence $script:RepositoryRoot $Fixture.Root $Fixture.Base $Fixture.Candidate `
                $evidence.Report $evidence.Artifacts
        }
        function Replace-ExceptionFixtureRegistryText([string]$Root,[string]$Pattern,[string]$Replacement) {
            $path=Join-Path $Root 'config/skillspector-exceptions.json'
            $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            $updated=[regex]::new($Pattern).Replace($text,$Replacement,1)
            if($updated-ceq$text){throw "Fixture registry pattern was not found: $Pattern"}
            [IO.File]::WriteAllText($path,$updated,[Text.UTF8Encoding]::new($false))
        }
        function Move-ExceptionFixtureIndexPath([string]$Root,[string]$Source,[string]$Destination) {
            $oid=Get-SourceFixtureGitScalar $Root @('rev-parse',"HEAD:$Source")
            [void](Invoke-SourceFixtureGit $Root @('update-index','--force-remove','--',$Source))
            [void](Invoke-SourceFixtureGit $Root @('update-index','--add','--cacheinfo',"100644,$oid,$Destination"))
            [void](Invoke-SourceFixtureGit $Root @('commit','-q','-m','case-only rename'))
            Get-SourceFixtureGitScalar $Root @('rev-parse','HEAD')
        }
        function Assert-ExactObjectShape($Value,[string[]]$Properties){
            (@($Value.PSObject.Properties.Name)-join',')|Should Be ($Properties-join',')
        }
        function Get-SourceFixtureFailure([scriptblock]$Action){try{& $Action
        return $null}catch{return [string]$_.Exception.Message}}
        function New-SourceFixtureLease([string]$Name) {
            $boundary=if(-not[string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
                [IO.Path]::GetFullPath($env:RUNNER_TEMP)
            }else{[IO.Path]::GetFullPath([IO.Path]::GetTempPath())}
            $safeName=$Name-replace'[^A-Za-z0-9-]','-'
            $root=Join-Path $boundary ("p11-s-$safeName-"+[guid]::NewGuid().ToString('N').Substring(0,8))
            if(Test-Path -LiteralPath $root){throw 'Source-gate fixture lease already exists.'}
            [void][IO.Directory]::CreateDirectory($root)
            [pscustomobject]@{Root=$root;Boundary=$boundary}
        }
        function Remove-SourceFixtureLease($Lease) {
            if($null-eq$Lease-or-not(Test-Path -LiteralPath $Lease.Root)){return}
            $root=[IO.Path]::GetFullPath([string]$Lease.Root)
            $boundary=[IO.Path]::GetFullPath([string]$Lease.Boundary).TrimEnd(
                [IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if(-not$root.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){
                throw 'Source-gate fixture lease escaped its cleanup boundary.'
            }
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        function Copy-GatePlatformRuntimeFixture([string]$AuthorityRoot) {
            $sourceRoot=Join-Path $script:RepositoryRoot 'scripts'
            $manifestPath=Join-Path $sourceRoot 'platform-runtime.psd1'
            $manifest=Import-PowerShellDataFile $manifestPath
            foreach($relative in @('platform-runtime.psd1')+@($manifest.FileList)|Select-Object -Unique){
                $source=Join-Path $sourceRoot $relative
                $destination=Join-Path (Join-Path $AuthorityRoot 'scripts') $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                Copy-Item -LiteralPath $source -Destination $destination
            }
        }
        . (Join-Path $script:RepositoryRoot 'tests/fixtures/consumer-gate-credential-oracle.ps1')
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

    BeforeEach {
        Restore-GateFixtureModule
    }

    # Scenario: The legacy manifest is consumed as the exact five-repository conversion contract.
    # Purpose: Keep all five ready migrations and the refreshed Darktide inventory explicit.
    It 'UnitT10_binds_five_unique_ready_legacy_inventories_and_the_refreshed_darktide_tree' {
        $manifestText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')
        $schemaText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/schemas/consumer-legacy-migration-v1.schema.json')
        Test-Json -Json $manifestText -Schema $schemaText | Should Be $true
        $manifest = $manifestText | ConvertFrom-Json
        @($manifest.repositories).Count | Should Be 5
        @($manifest.repositories.id | Select-Object -Unique).Count | Should Be 5
        (@($manifest.repositories.id)-join"`n") | Should Be (@(
                'skill-general','skill-atlassian-ecosystem','skill-code-collaboration','skill-knowledge-content','skill-darktide-translate'
            )-join"`n")
        @($manifest.repositories | Where-Object status -eq ready).Count | Should Be 5
        $darktide = @($manifest.repositories | Where-Object id -eq skill-darktide-translate)[0]
        $darktide.status | Should Be ready
        $darktide.inventoryCommit | Should Be '44c9fef7e36c36ecab0011ba35c799ddc79a3927'
        $darktide.inventoryTree | Should Be '648234d5fed2d75817b67663ecc4483b33bac30e'
        $null -ne $darktide.PSObject.Properties['prerequisites'] | Should Be $false
        $darktide.additionalScope | Should Be @('skills/auto-update-darktide-mod/scripts/')
        $expectedFileRows=@(
            '.github/workflows/standard-v1-candidate-windows.yml|delete||','config/standard-v1.json|delete||',
            'scripts/Get-SourcePin.ps1|delete||','scripts/Install-LatestPowerShell.ps1|delete||',
            'scripts/Invoke-PrePushValidation.ps1|delete||','scripts/New-SkillSourcePin.ps1|retain||',
            'scripts/PowerShellRelease.psm1|delete||',
            'scripts/Test-CleanRepositoryHead.ps1|retain||','scripts/Test-DarktideRepository.ps1|retain||',
            'scripts/Test-Repository.ps1|split||scripts/Test-DarktideRepository.ps1',
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
            'tests/AtomicValidationOutput.Tests.ps1|update-tests|delete|','tests/BootstrapTransition.Tests.ps1|update-tests|delete|',
            'tests/CanonicalValidation.Tests.ps1|update-tests|delete|','tests/InstalledClosureOrdering.Tests.ps1|retain||',
            'tests/Invoke-Tests.ps1|retain||','tests/LocalizationWorkset.Tests.ps1|retain||',
            'tests/ModUpdateAutomation.Tests.ps1|retain||','tests/PathSafetyAst.Tests.ps1|update-tests|rewrite|',
            'tests/RepositoryContract.Tests.ps1|retain||','tests/RepositoryValidation.Tests.ps1|retain||',
            'tests/Schema15Coordination.Tests.ps1|retain||','tests/Schema15SourceAcquisition.Tests.ps1|retain||',
            'tests/SkillContract.Tests.ps1|retain||','tests/SkillSourcePinGenerator.Tests.ps1|retain||',
            'tests/SkillSpectorOutput.Tests.ps1|retain||',
            'tests/SourcePin.Tests.ps1|update-tests|delete|','tests/StandardV1Conformance.Tests.ps1|update-tests|delete|',
            'tests/support/ProcessEnvironment.psm1|retain||','tests/Test-DarktideRepository.Tests.ps1|retain||',
            'tests/Test-Repository.Tests.ps1|update-tests|delete|','tests/TestSupport.ps1|retain||',
            'tests/TestSupportLayout.Tests.ps1|retain||','tests/ValidationTransition.Tests.ps1|update-tests|delete|'
        )
        $actualFileRows=@($darktide.files|ForEach-Object{
                $outcome=if($null-ne$_.PSObject.Properties['expectedOutcome']){[string]$_.expectedOutcome}else{''}
                $target=if($null-ne$_.PSObject.Properties['target']){[string]$_.target}else{''}
                "$($_.path)|$($_.disposition)|$outcome|$target"
            })
        @($actualFileRows).Count | Should Be 49
        (@($actualFileRows)-join"`n") | Should Be (@($expectedFileRows)-join"`n")
        $expectedChecks=@(
            'repository-darktide|general|scripts/Test-DarktideRepository.ps1','repository-pester|pester|tests'
        )
        (@($darktide.requiredRepositoryChecks|ForEach-Object{"$($_.id)|$($_.kind)|$($_.path)"})-join"`n") |
            Should Be (@($expectedChecks)-join"`n")
        $fileCountOracle=[ordered]@{
            'skill-general'=46;'skill-atlassian-ecosystem'=100;'skill-code-collaboration'=23
            'skill-knowledge-content'=17;'skill-darktide-translate'=49
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
            @{Id='pending-missing-prerequisites';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).status='pending-prerequisites'}},
            @{Id='pending-empty-prerequisites';Apply={param($m)$e=@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0];$e.status='pending-prerequisites';$e|Add-Member prerequisites @()}},
            @{Id='retired-deferred-status';Apply={param($m)(@($m.repositories|Where-Object{$_.id-eq'skill-darktide-translate'})[0]).status='deferred'}},
            @{Id='prerequisite-glob';Apply={param($m)$e=Set-FixturePendingPrerequisites $m;$e.prerequisites[0].path='tests/*.ps1'}},
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
            @{Id='duplicate-prerequisite-id';RepositoryId='skill-darktide-translate';Apply={param($m)$e=Set-FixturePendingPrerequisites $m;$x=Copy-FixtureValue $e.prerequisites[0];$x.path=$e.files[1].path;$e.prerequisites=@($e.prerequisites)+@($x)}},
            @{Id='prerequisite-path-not-in-files';RepositoryId='skill-darktide-translate';Apply={param($m)$e=Set-FixturePendingPrerequisites $m;$e.prerequisites[0].path='tests/not-listed.ps1'}},
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

    # Scenario: A consumer explicitly checks protected PowerShell and workflow files out as CRLF while their committed blobs remain exact LF template copies.
    # Purpose: Repository attributes and runner checkout filters must not make an otherwise exact protected template fail byte identity.
    It 'UnitT15_accepts_exact_protected_blobs_from_an_explicit_crlf_checkout' {
        $source=Join-Path $TestDrive 'protected-crlf-source'
        $candidate=Join-Path $TestDrive 'protected-crlf-candidate'
        $base=Join-Path $TestDrive 'protected-crlf-base'
        [void][IO.Directory]::CreateDirectory($source)
        [void](Invoke-SourceFixtureGit $source @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $source @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $source @('config','user.email','fixture@example.test'))
        foreach($directory in @('scripts','.github/workflows')){[void][IO.Directory]::CreateDirectory((Join-Path $source $directory))}
        Copy-Item (Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') `
            (Join-Path $source 'scripts/Invoke-PinnedAuthority.ps1')
        foreach($name in @('consumer-gate.yml','consumer-gate-transition.yml')){
            Copy-Item (Join-Path $script:RepositoryRoot "consumer/workflows/$name") (Join-Path $source ".github/workflows/$name")
        }
        [IO.File]::WriteAllText((Join-Path $source '.gitattributes'),"*.ps1 text eol=crlf`n*.yml text eol=crlf`n",[Text.UTF8Encoding]::new($false))
        [void](Invoke-SourceFixtureGit $source @('add','.'))
        [void](Invoke-SourceFixtureGit $source @('commit','-q','-m','protected templates'))
        foreach($number in 1..2){
            [IO.File]::WriteAllText((Join-Path $source "marker-$number.txt"),"$number`n",[Text.UTF8Encoding]::new($false))
            [void](Invoke-SourceFixtureGit $source @('add',"marker-$number.txt"))
            [void](Invoke-SourceFixtureGit $source @('commit','-q','-m',"marker $number"))
        }
        $revision=Get-SourceFixtureGitScalar $source @('rev-parse','HEAD')
        $sourceUri=[Uri]::new($source).AbsoluteUri
        [void](Invoke-SourceFixtureGit $TestDrive @('clone','-q','--depth=2',$sourceUri,$candidate))
        [void](Invoke-SourceFixtureGit $TestDrive @('clone','-q',$sourceUri,$base))
        (Get-SourceFixtureGitScalar $candidate @('rev-parse','--is-shallow-repository'))|Should BeExactly 'true'
        (Get-SourceFixtureGitScalar $candidate @('rev-list','--count','HEAD'))|Should BeExactly '2'
        (Get-SourceFixtureGitScalar $base @('rev-parse','--is-shallow-repository'))|Should BeExactly 'false'
        (Get-SourceFixtureGitScalar $base @('rev-list','--count','HEAD'))|Should BeExactly '3'
        foreach($root in @($candidate,$base)){
            $bootstrapBytes=[IO.File]::ReadAllBytes((Join-Path $root 'scripts/Invoke-PinnedAuthority.ps1'))
            ([Text.Encoding]::ASCII.GetString($bootstrapBytes).Contains("`r`n"))|Should Be $true
        }
        $entry=[pscustomobject]@{files=@()}
        Assert-GateProtectedFiles $script:RepositoryRoot $base $candidate $entry $revision $revision $true
        Add-Content -LiteralPath (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1') -Value '# changed'
        {Assert-GateProtectedFiles $script:RepositoryRoot $base $candidate $entry $revision $revision $true}|Should Throw `
            'Candidate bootstrap differs'
        [void](Invoke-SourceFixtureGit $candidate @('add','scripts/Invoke-PinnedAuthority.ps1'))
        [void](Invoke-SourceFixtureGit $candidate @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $candidate @('config','user.email','fixture@example.test'))
        [void](Invoke-SourceFixtureGit $candidate @('commit','-q','-m','tamper template'))
        $tampered=Get-SourceFixtureGitScalar $candidate @('rev-parse','HEAD')
        {Assert-GateProtectedFiles $script:RepositoryRoot $base $candidate $entry $revision $tampered $true}|Should Throw `
            'Candidate bootstrap differs'
    }

    # Scenario: The migration manifest preserves portable Darktide regressions while removing authority-owned copies.
    # Purpose: General history, legacy-only tests, the split target, and the pathname-ledger rewrite stay explicit.
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
                'tests/SkillContract.Tests.ps1','tests/TestSupport.ps1'
            )) {
            $record = @($darktide.files | Where-Object path -eq $path)[0]
            $record.disposition | Should Be 'retain'
            $null -ne $record.PSObject.Properties['expectedOutcome'] | Should Be $false
            $record.reason | Should Match 'Portable|portable'
        }
        $pathSafety = @($darktide.files | Where-Object path -eq 'tests/PathSafetyAst.Tests.ps1')[0]
        $pathSafety.disposition | Should Be 'update-tests'
        $pathSafety.expectedOutcome | Should Be 'rewrite'
        $pathSafety.reason | Should Match 'literal entries for legacy files'
        foreach ($path in @(
                'tests/AtomicValidationOutput.Tests.ps1','tests/BootstrapTransition.Tests.ps1',
                'tests/CanonicalValidation.Tests.ps1','tests/SourcePin.Tests.ps1',
                'tests/StandardV1Conformance.Tests.ps1','tests/Test-Repository.Tests.ps1',
                'tests/ValidationTransition.Tests.ps1'
            )) {
            $record = @($darktide.files | Where-Object path -eq $path)[0]
            $record.disposition | Should Be 'update-tests'
            $record.expectedOutcome | Should Be 'delete'
        }
        $null -ne $darktide.PSObject.Properties['prerequisites'] | Should Be $false
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
            $lease=New-SourceFixtureLease "credential-$outcome"
            try{
            $root=$lease.Root
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
            }finally{Remove-SourceFixtureLease $lease}
        }
        $mutantLease=New-SourceFixtureLease 'resolver-home-token-mutant'
        try{
        $mutantRoot=$mutantLease.Root
        foreach($relative in @(& git -C $script:RepositoryRoot ls-files|Where-Object{Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf})){
            $destination=Join-Path $mutantRoot $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $destination
        }
        foreach($relative in @('tests/fixtures/consumer-bootstrap-cleanup-fixture.ps1',
                'tests/fixtures/consumer-gate-credential-oracle.ps1')){
            $destination=Join-Path $mutantRoot $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $destination -Force
        }
        $modulePath=Join-Path $mutantRoot 'scripts/consumer/ConsumerGate.psm1'
        $moduleText=Get-Content -Raw -LiteralPath $modulePath;$tokens=$null;$errors=$null
        $moduleAst=[Management.Automation.Language.Parser]::ParseInput($moduleText,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $resolver=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateResolver'},$true))[0]
        $tokenEnvironmentWrite=@($resolver.Body.FindAll({param($node)
                    $node-is[Management.Automation.Language.AssignmentStatementAst]-and
                    $node.Left.Extent.Text-ceq"`$environment['STANDARD_VALIDATION_GITHUB_API_TOKEN']"-and
                    $node.Right.Extent.Text-ceq'$Token'
                },$true))
        @($tokenEnvironmentWrite).Count|Should Be 1
        $replacement="`$environment['HOME']=`$Token"
        $moduleText=$moduleText.Remove($tokenEnvironmentWrite[0].Extent.StartOffset,
            $tokenEnvironmentWrite[0].Extent.EndOffset-$tokenEnvironmentWrite[0].Extent.StartOffset).Insert(
                $tokenEnvironmentWrite[0].Extent.StartOffset,$replacement)
        [IO.File]::WriteAllText($modulePath,$moduleText,[Text.UTF8Encoding]::new($false))
        $mutantFixture=Join-Path $mutantRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        $mutantCaseLease=New-SourceFixtureLease 'resolver-home-token-case'
        try{
        $mutantRecords=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $mutantFixture `
            -RepositoryRoot $mutantRoot -FixtureRoot $mutantCaseLease.Root -Outcome success `
            -Sentinel 'unique-production-credential-sentinel' 2>&1)
        $LASTEXITCODE|Should Be 0
        $mutantResult=($mutantRecords-join[Environment]::NewLine)|ConvertFrom-Json -Depth 30
        $mutantResult.exitCode|Should Be 0
        foreach($dump in $mutantResult.resolverDumps){@($dump.sentinelValueNames)|Should Be @('HOME')}
        {foreach($dump in $mutantResult.resolverDumps){
                if((@($dump.sentinelValueNames)-join"`n")-cne'STANDARD_VALIDATION_GITHUB_API_TOKEN'){
                    throw "SENTINEL_VALUE_ORACLE_MISMATCH|$(@($dump.sentinelValueNames)-join',')"
                }
            }}|Should Throw 'SENTINEL_VALUE_ORACLE_MISMATCH'
        }finally{Remove-SourceFixtureLease $mutantCaseLease}
        }finally{Remove-SourceFixtureLease $mutantLease}
    }

    # Scenario: PowerShell asset acquisition follows only bounded approved redirects and filters credentials per hop.
    # Purpose: Real prepare accepts approved 302 chains while rejecting host changes and redirect exhaustion without sending Authorization to assets.
    It 'UnitT61_enforces_redirect_hosts_limits_and_per_hop_authorization' {
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        $sentinel='unique-redirect-credential-sentinel'
        $expected=[ordered]@{'redirect-success'=0;'redirect-unapproved'=20;'redirect-limit'=20}
        foreach($outcome in $expected.Keys){
            $lease=New-SourceFixtureLease "credential-$outcome"
            try{
            $root=$lease.Root
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
            }finally{Remove-SourceFixtureLease $lease}
        }
    }

    # Scenario: Each credential output surface independently receives the sentinel through a fixture source.
    # Purpose: The formal prepare entry rejects summary, artifact, receipt, stdout, and stderr leaks without echoing the credential.
    It 'UnitT31_rejects_each_credential_output_surface_through_the_formal_entry' {
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        foreach($surface in @('summary','artifact','receipt','stdout','stderr')){
            $lease=New-SourceFixtureLease "credential-surface-$surface"
            try{
            $root=$lease.Root
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
            }finally{Remove-SourceFixtureLease $lease}
        }
    }

    # Scenario: Token-bearing holders and cleanup statements are enumerated from production ASTs as an exact fixed inventory.
    # Purpose: Adding a holder or deleting cleanup for headers, environments, buffers, or processes changes the closed inventory.
    It 'UnitT32_closes_the_complete_credential_holder_and_cleanup_inventory' {
        $sources=[ordered]@{
            'scripts/consumer/ConsumerGate.psm1'=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1')
            'consumer/bootstrap/Invoke-PinnedAuthority.ps1'=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
            'scripts/consumer/ConsumerBootstrapSupervisor.psm1'=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerBootstrapSupervisor.psm1')
            'scripts/consumer/Invoke-ConsumerSourceGate.ps1'=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1')
        }
        $expectedHolders=@'
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|bootstrapToken
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|message
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|environment
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|sentinel
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|standardError
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|standardOutput
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|Token
scripts/consumer/ConsumerBootstrapSupervisor.psm1|New-ConsumerBootstrapEnvironment|Token
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|content
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|needle
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|Token
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|headers
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|Token
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|buffer
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|bytes
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|Headers
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|memory
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|request
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|response
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|stream
scripts/consumer/ConsumerGate.psm1|Invoke-GateCredentialScopedPreparation|Token
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|environment
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|standardError
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|standardOutput
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|Token
scripts/consumer/ConsumerGate.psm1|New-GateSourceSetup|Token
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|message
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|phaseEnvironment
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|token
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|tokenVariable
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|value
'@ -split '\r?\n'|Where-Object{$_}
        $expectedCleanups=@'
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|null|$bootstrapToken=$null
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|null|$message=$null
consumer/bootstrap/Invoke-PinnedAuthority.ps1|<script>|remove-variable|Remove-Variable bootstrapToken,message -ErrorAction SilentlyContinue
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|null|$sentinel=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|remove-variable|Remove-Variable sentinel -ErrorAction SilentlyContinue
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|remove|[void]$environment.Remove([string]$name)
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|null|$standardOutput=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|null|$standardError=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|null|$sentinel=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|null|$Token=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|clear|$environment.Clear()
scripts/consumer/ConsumerBootstrapSupervisor.psm1|Invoke-ConsumerGateProcess|remove-variable|Remove-Variable standardOutput,standardError,sentinel,Token,credentialLeak -ErrorAction SilentlyContinue
scripts/consumer/ConsumerBootstrapSupervisor.psm1|New-ConsumerBootstrapEnvironment|null|$Token=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1|New-ConsumerBootstrapEnvironment|remove-variable|Remove-Variable Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|null|$content=$null
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|null|$content=$null
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|null|$needle=$null
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|Assert-GateCredentialAbsent|remove-variable|Remove-Variable content,needle,Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|remove|$headers.Remove('Authorization')
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|environment-null|[Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|remove-variable|Remove-Variable Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$request.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$request=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$response.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$response=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$stream.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$memory.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$response.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|dispose|$request.Dispose()
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$bytes=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$buffer=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$response=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$request=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$stream=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$memory=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|null|$Headers=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|remove-variable|Remove-Variable bytes,buffer,response,request,stream,memory,Headers -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Invoke-GateCredentialScopedPreparation|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1|Invoke-GateCredentialScopedPreparation|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateCredentialScopedPreparation|remove-variable|Remove-Variable runtime,receipt,Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|remove|[void]$environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN')
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|clear|$environment.Clear()
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|null|$standardOutput=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|null|$standardError=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|remove-variable|Remove-Variable standardOutput,standardError,credentialLeak,executionFailure,result,runtime,environment,Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|remove-variable|Remove-Variable Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1|New-GateSourceSetup|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1|New-GateSourceSetup|null|$Token=$null
scripts/consumer/ConsumerGate.psm1|New-GateSourceSetup|remove-variable|Remove-Variable Token -ErrorAction SilentlyContinue
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|null|$phaseEnvironment=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|null|$value=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|remove-variable|Remove-Variable phaseEnvironment,phaseEnvironmentDump,phaseTokenNames,phaseSentinelNames,sentinelHash,value -ErrorAction SilentlyContinue
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|environment-null|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|null|$token=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|null|$tokenVariable=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|null|$message=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|remove-variable|Remove-Variable token, tokenVariable, message, phaseEnvironmentDumpPath, credentialNames -ErrorAction SilentlyContinue
'@ -split '\r?\n'|Where-Object{$_}
        $oracle=Get-ConsumerCredentialOracle $sources
        $actualHolders=@($oracle.Holders|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Variable)"})
        $actualCleanups=@($oracle.Cleanups|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Shape)|$($_.Text)"})
        @($actualHolders).Count|Should Be 31
        (@($actualHolders)-join"`n")|Should Be (@($expectedHolders)-join"`n")
        @($actualCleanups).Count|Should Be 65
        (@($actualCleanups)-join"`n")|Should Be (@($expectedCleanups)-join"`n")
        foreach($holder in $oracle.Holders){
            @($oracle.Cleanups|Where-Object{$_.Source-ceq$holder.Source-and$_.Function-ceq$holder.Function-and$_.InFinally-and
                    @($_.Targets)-icontains$holder.Variable}).Count|Should BeGreaterThan 0
        }

        $consumerText=$sources['scripts/consumer/ConsumerGate.psm1'];$tokens=$null;$errors=$null
        $consumerAst=[Management.Automation.Language.Parser]::ParseInput($consumerText,[ref]$tokens,[ref]$errors)
        $install=@($consumerAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Install-GatePowerShell'},$true))[0]
        $insertion=$install.Body.Extent.EndOffset-1
        $holderMutant=$consumerText.Insert($insertion,"`n    `$copy=`$Token`n")
        $holderSources=[ordered]@{};foreach($key in $sources.Keys){$holderSources[$key]=if($key-ceq'scripts/consumer/ConsumerGate.psm1'){$holderMutant}else{$sources[$key]}}
        $holderOracle=Get-ConsumerCredentialOracle $holderSources
        (@($holderOracle.Holders|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Variable)"})-join"`n")|Should Not Be (@($expectedHolders)-join"`n")
        @($holderOracle.Holders|Where-Object{$_.Function-ceq'Install-GatePowerShell'-and$_.Variable-ceq'copy'}).Count|Should Be 1

        $productionAsts=[ordered]@{}
        foreach($sourceName in $sources.Keys){$tokens=$null;$errors=$null
            $productionAsts[$sourceName]=[Management.Automation.Language.Parser]::ParseInput($sources[$sourceName],[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0}
        $scriptBlockParameters=@()
        foreach($ast in $productionAsts.Values){
            foreach($function in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                            $true},$true))){
                foreach($parameter in @($function.Parameters)){
                    $typeNames=@($parameter.Attributes|Where-Object{$_-is[Management.Automation.Language.TypeConstraintAst]}|ForEach-Object{$_.TypeName.FullName})
                    if($typeNames-ccontains'scriptblock'){$scriptBlockParameters+="$($function.Name)|$($parameter.Name.VariablePath.UserPath)|scriptblock"}
                }
            }
        }
        @($scriptBlockParameters).Count|Should Be 0
        $expectedSeams=@'
scripts/consumer/ConsumerGate.psm1|Get-GateDeadlineBudget|CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS|env
scripts/consumer/ConsumerGate.psm1|Get-GateDeadlineBudget|CONSUMER_GATE_RESOLVER_SCRIPT_PATH|env
scripts/consumer/ConsumerGate.psm1|Write-GateBoundaryEvent|CONSUMER_GATE_EVENT_LOG_PATH|env
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|CONSUMER_GATE_POWERSHELL_METADATA_URI|env
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|CONSUMER_GATE_POWERSHELL_METADATA_URI|env
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|CONSUMER_GATE_POWERSHELL_METADATA_URI|env
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|CONSUMER_GATE_RUNTIME_SOURCE_ROOT|env
scripts/consumer/ConsumerGate.psm1|Install-GatePowerShell|CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH|env
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|CONSUMER_GATE_RESOLVER_SCRIPT_PATH|env
scripts/consumer/ConsumerGate.psm1|Invoke-GateResolver|CONSUMER_GATE_RESOLVER_SCRIPT_PATH|env
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS|env
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS|env
scripts/consumer/ConsumerGate.psm1|Invoke-GateAcquisitionRequest|CONSUMER_GATE_ACQUISITION_CANCEL_PATH|env
scripts/consumer/Invoke-ConsumerSourceGate.ps1|<script>|CONSUMER_GATE_PHASE_ENV_DUMP_PATH|env
'@ -split '\r?\n'|Where-Object{$_}
        $seams=Get-ConsumerGateSeamOracle $sources
        $actualSeams=@($seams|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Name)|$($_.Kind)"})
        (@($actualSeams)-join"`n")|Should Be (@($expectedSeams)-join"`n")

        $mutantLease=New-SourceFixtureLease 'credential-authority-copy'
        try{
        $mutantRoot=$mutantLease.Root
        foreach($relative in @(& git -C $script:RepositoryRoot ls-files|Where-Object{Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf})){
            $destination=Join-Path $mutantRoot $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $destination
        }
        foreach($relative in @('tests/fixtures/consumer-bootstrap-cleanup-fixture.ps1',
                'tests/fixtures/consumer-gate-credential-oracle.ps1')){
            $destination=Join-Path $mutantRoot $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $destination -Force
        }
        function Get-MutantSources {
            $result=[ordered]@{};foreach($key in $sources.Keys){$result[$key]=Get-Content -Raw -LiteralPath (Join-Path $mutantRoot $key)};$result
        }
        $seamMutationIndex=0
        foreach($seam in $seams){
            $seamMutationIndex++
            foreach($key in $sources.Keys){[IO.File]::WriteAllText((Join-Path $mutantRoot $key),[string]$sources[$key],[Text.UTF8Encoding]::new($false))}
            $path=Join-Path $mutantRoot $seam.Source
            $text=Get-Content -Raw -LiteralPath $path
            $deleted=$text.Remove([int]$seam.StartOffset,[int]$seam.EndOffset-[int]$seam.StartOffset)
            [IO.File]::WriteAllText($path,$deleted,[Text.UTF8Encoding]::new($false))
            $deletedSeams=@(Get-ConsumerGateSeamOracle (Get-MutantSources)|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Name)|$($_.Kind)"})
            (@($deletedSeams)-join"`n")|Should Not Be (@($expectedSeams)-join"`n")

            foreach($key in $sources.Keys){[IO.File]::WriteAllText((Join-Path $mutantRoot $key),[string]$sources[$key],[Text.UTF8Encoding]::new($false))}
            $targetText=Get-Content -Raw -LiteralPath $path
            $parameterPath=Join-Path $mutantRoot 'scripts/consumer/ConsumerGate.psm1'
            $parameterText=Get-Content -Raw -LiteralPath $parameterPath;$targetTokens=$null;$targetErrors=$null
            $targetAst=[Management.Automation.Language.Parser]::ParseInput($parameterText,[ref]$targetTokens,[ref]$targetErrors)
            $targetFunction=@($targetAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                        $node.Name-ceq'Install-GatePowerShell'},$true))[0]
            $expectedAdditionKind=if(($seamMutationIndex%2)-eq0){'environment-api'}else{'env'}
            $environmentInsertion=if($expectedAdditionKind-ceq'environment-api'){
                "`n`$unapprovedFixtureSeam=[Environment]::GetEnvironmentVariable('CONSUMER_GATE_UNAPPROVED_FIXTURE_SEAM','Process')`n"
            }else{"`n`$unapprovedFixtureSeam=`$env:CONSUMER_GATE_UNAPPROVED_FIXTURE_SEAM`n"}
            if($seam.Source-ceq'scripts/consumer/ConsumerGate.psm1'){
                $insertions=@([pscustomobject]@{Offset=[int]$seam.StartOffset;Text=$environmentInsertion},
                    [pscustomobject]@{Offset=[int]$targetFunction.Parameters[-1].Extent.EndOffset;Text=',[scriptblock]$InjectedFixtureSeam'})|Sort-Object Offset -Descending
                foreach($addition in $insertions){$targetText=$targetText.Insert($addition.Offset,$addition.Text)}
                [IO.File]::WriteAllText($path,$targetText,[Text.UTF8Encoding]::new($false))
            }else{
                $targetText=$targetText.Insert([int]$seam.StartOffset,$environmentInsertion)
                $parameterText=$parameterText.Insert([int]$targetFunction.Parameters[-1].Extent.EndOffset,',[scriptblock]$InjectedFixtureSeam')
                [IO.File]::WriteAllText($path,$targetText,[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($parameterPath,$parameterText,[Text.UTF8Encoding]::new($false))
            }
            $addedSources=Get-MutantSources
            $addedSeams=@(Get-ConsumerGateSeamOracle $addedSources|ForEach-Object{"$($_.Source)|$($_.Function)|$($_.Name)|$($_.Kind)"})
            (@($addedSeams)-join"`n")|Should Not Be (@($expectedSeams)-join"`n")
            @($addedSeams|Where-Object{$_-like "*|CONSUMER_GATE_UNAPPROVED_FIXTURE_SEAM|$expectedAdditionKind"}).Count|Should Be 1
            $addedTokens=$null;$addedErrors=$null
            $addedAst=[Management.Automation.Language.Parser]::ParseInput($addedSources['scripts/consumer/ConsumerGate.psm1'],[ref]$addedTokens,[ref]$addedErrors)
            @($addedErrors).Count|Should Be 0
            @($addedAst.FindAll({param($node)$node-is[Management.Automation.Language.ParameterAst]-and
                        @($node.Attributes|Where-Object{$_-is[Management.Automation.Language.TypeConstraintAst]-and$_.TypeName.FullName-ceq'scriptblock'}).Count-ne0},$true)).Count|Should Be 1
        }

        foreach($key in $sources.Keys){[IO.File]::WriteAllText((Join-Path $mutantRoot $key),[string]$sources[$key],[Text.UTF8Encoding]::new($false))}
        $baselineBootstrapLease=New-SourceFixtureLease 'cleanup-baseline-bootstrap'
        try{
        $baselineBootstrapRoot=$baselineBootstrapLease.Root
        $baselineBootstrap=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $mutantRoot 'tests/fixtures/consumer-bootstrap-cleanup-fixture.ps1') `
            -RepositoryRoot $mutantRoot -FixtureRoot $baselineBootstrapRoot -Sentinel 'credential-cleanup-sentinel' 2>&1)
        $LASTEXITCODE|Should Be 0
        }finally{Remove-SourceFixtureLease $baselineBootstrapLease}
        $baselineCredentialLease=New-SourceFixtureLease 'cleanup-baseline-credential'
        try{
        $baselineCredentialRoot=$baselineCredentialLease.Root
        $baselineCredential=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $mutantRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1') `
            -RepositoryRoot $mutantRoot -FixtureRoot $baselineCredentialRoot -Outcome success -Sentinel 'credential-cleanup-sentinel' -LeakSurface none 2>&1)
        $LASTEXITCODE|Should Be 0
        }finally{Remove-SourceFixtureLease $baselineCredentialLease}

        $equivalent=[Collections.Generic.List[string]]::new()
        $index=0
        foreach($cleanup in $oracle.Cleanups){
            $index++
            foreach($key in $sources.Keys){[IO.File]::WriteAllText((Join-Path $mutantRoot $key),[string]$sources[$key],[Text.UTF8Encoding]::new($false))}
            $path=Join-Path $mutantRoot $cleanup.Source
            $text=Get-Content -Raw -LiteralPath $path
            $fixtureLease=New-SourceFixtureLease ("cleanup-mutant-{0:D3}"-f$index)
            try{
            $fixtureRoot=$fixtureLease.Root
            $observation=Join-Path $mutantRoot ("cleanup-observation-{0:D3}.json"-f$index)
            $targets=if(@($cleanup.Targets).Count-eq0){@('__environment__')}else{@($cleanup.Targets)}
            $target=[string]$targets[0]
            $condition=if($cleanup.Shape-ceq'environment-null'){
                if($cleanup.Text-match'\$name'){"-not[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable(`$name,'Process'))"}
                else{"-not[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN','Process'))"}
            }elseif($cleanup.Shape-ceq'remove-variable'){
                (@($targets|ForEach-Object{"`$null-ne(Get-Variable -Name '$($_.Replace("'","''"))' -ErrorAction SilentlyContinue)"})-join'-or')
            }elseif($cleanup.Shape-ceq'clear'){
                if($cleanup.Text-match'\.Environment\.Clear'){"`$$target.Environment.Count-gt0"}else{"`$$target.Count-gt0"}
            }elseif($cleanup.Shape-ceq'remove'){
                if($cleanup.Text-match'Authorization'){"`$$target.ContainsKey('Authorization')"}
                elseif($cleanup.Text-match'Environment\.Remove'){"`$$target.Environment.ContainsKey('STANDARD_VALIDATION_GITHUB_API_TOKEN')"}
                else{"`$$target.ContainsKey(`$name)"}
            }elseif($cleanup.Shape-ceq'null'-and$cleanup.Text-match'\[\$name\]'){"`$null-ne`$$target[`$name]"}
            elseif($cleanup.Shape-ceq'null'){
                "`$null-ne(Get-Variable -Name '$($target.Replace("'","''"))' -ErrorAction SilentlyContinue)-and`$null-ne(Get-Variable -Name '$($target.Replace("'","''"))' -ValueOnly -ErrorAction SilentlyContinue)"
            }else{"`$null-ne`$$target"}
            $hitPayload=([ordered]@{hits=@($targets);shape=$cleanup.Shape}|ConvertTo-Json -Compress).Replace("'","''")
            $emptyPayload=([ordered]@{hits=@();shape=$cleanup.Shape}|ConvertTo-Json -Compress).Replace("'","''")
            $observationLiteral=$observation.Replace("'","''")
            $anchor="`nif($condition){[IO.File]::WriteAllText('$observationLiteral','$hitPayload',[Text.UTF8Encoding]::new(`$false))}elseif(-not(Test-Path -LiteralPath '$observationLiteral')){[IO.File]::WriteAllText('$observationLiteral','$emptyPayload',[Text.UTF8Encoding]::new(`$false))}`n"
            $mutated=$text.Remove([int]$cleanup.StartOffset,[int]$cleanup.EndOffset-[int]$cleanup.StartOffset).Insert([int]$cleanup.StartOffset,$anchor)
            [IO.File]::WriteAllText($path,$mutated,[Text.UTF8Encoding]::new($false))
            $mutantTokens=$null;$mutantErrors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$mutantTokens,[ref]$mutantErrors)
            if(@($mutantErrors).Count-ne0){throw "CLEANUP_MUTANT_HARNESS_PARSE_FAILED|$($cleanup.Source):$($cleanup.Line):$($cleanup.Column)"}
            $case=if($cleanup.Function-ceq'Invoke-GateAcquisitionRequest'-and$cleanup.Line-in@(1143,1144)){'redirect-success'}
                elseif($cleanup.Function-ceq'Invoke-GateResolver'-and$cleanup.Line-ge285){'resolver-error'}
                elseif($cleanup.Function-ceq'New-GateSourceSetup'){'resolver-error'}
                elseif($cleanup.Source-ceq'scripts/consumer/Invoke-ConsumerSourceGate.ps1'-and
                    (@($cleanup.Targets)-icontains'message'-or@($cleanup.Targets)-icontains'tokenVariable'-or$cleanup.Line-eq73)){'http-error'}
                else{'success'}
            $leak=if($cleanup.Function-ceq'Assert-GateCredentialAbsent'-and$cleanup.Line-ge1111){'summary'}else{'none'}
            $key="$($cleanup.Source):$($cleanup.Line):$($cleanup.Column)|$($cleanup.Text)"
            if($cleanup.Source-in@('consumer/bootstrap/Invoke-PinnedAuthority.ps1','scripts/consumer/ConsumerBootstrapSupervisor.psm1')){
                $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $mutantRoot 'tests/fixtures/consumer-bootstrap-cleanup-fixture.ps1') `
                    -RepositoryRoot $mutantRoot -FixtureRoot $fixtureRoot -Sentinel 'credential-cleanup-sentinel' 2>&1)
            }else{
                $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $mutantRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1') `
                    -RepositoryRoot $mutantRoot -FixtureRoot $fixtureRoot -Outcome $case -Sentinel 'credential-cleanup-sentinel' `
                    -LeakSurface $leak 2>&1)
            }
            $mutantExit=$LASTEXITCODE
            if($mutantExit-ne0){
                {throw "CLEANUP_MUTANT_PROCESS_FAILED|$key|case=$case|exit=$mutantExit"}|Should Throw 'CLEANUP_MUTANT_PROCESS_FAILED'
                continue
            }
            if(-not(Test-Path -LiteralPath $observation)){$equivalent.Add($key);continue}
            $observed=Get-Content -Raw -LiteralPath $observation|ConvertFrom-Json
            if(@($observed.hits).Count-eq0){$equivalent.Add($key);continue}
            {if(@($observed.hits).Count-ne0){throw "CLEANUP_MUTANT_OBSERVED|$(@($observed.hits)-join',')"}}|Should Throw 'CLEANUP_MUTANT_OBSERVED'
            }finally{Remove-SourceFixtureLease $fixtureLease}
        }
        $expectedEquivalent=@'
consumer/bootstrap/Invoke-PinnedAuthority.ps1:366:5|$bootstrapToken=$null
consumer/bootstrap/Invoke-PinnedAuthority.ps1:366:27|$message=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:218:22|$sentinel=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:241:9|$standardOutput=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:241:31|$standardError=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:241:52|$sentinel=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:241:68|$Token=$null
scripts/consumer/ConsumerBootstrapSupervisor.psm1:139:9|$Token=$null
scripts/consumer/ConsumerGate.psm1:1120:13|$content=$null
scripts/consumer/ConsumerGate.psm1:1123:9|$content=$null
scripts/consumer/ConsumerGate.psm1:1123:24|$needle=$null
scripts/consumer/ConsumerGate.psm1:1123:38|$Token=$null
scripts/consumer/ConsumerGate.psm1:222:14|$headers.Remove('Authorization')
scripts/consumer/ConsumerGate.psm1:223:5|$Token=$null
scripts/consumer/ConsumerGate.psm1:224:5|[Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')
scripts/consumer/ConsumerGate.psm1:1151:34|$request.Dispose()
scripts/consumer/ConsumerGate.psm1:1151:53|$request=$null
scripts/consumer/ConsumerGate.psm1:1152:35|$response.Dispose()
scripts/consumer/ConsumerGate.psm1:1152:55|$response=$null
scripts/consumer/ConsumerGate.psm1:1183:18|$stream.Dispose()
scripts/consumer/ConsumerGate.psm1:1183:36|$memory.Dispose()
scripts/consumer/ConsumerGate.psm1:1191:31|$response.Dispose()
scripts/consumer/ConsumerGate.psm1:1191:73|$request.Dispose()
scripts/consumer/ConsumerGate.psm1:1192:9|$bytes=$null
scripts/consumer/ConsumerGate.psm1:1192:22|$buffer=$null
scripts/consumer/ConsumerGate.psm1:1192:36|$response=$null
scripts/consumer/ConsumerGate.psm1:1192:52|$request=$null
scripts/consumer/ConsumerGate.psm1:1192:67|$stream=$null
scripts/consumer/ConsumerGate.psm1:1192:81|$memory=$null
scripts/consumer/ConsumerGate.psm1:1192:95|$Headers=$null
scripts/consumer/ConsumerGate.psm1:407:95|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1:409:43|$Token=$null
scripts/consumer/ConsumerGate.psm1:295:13|[void]$environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN')
scripts/consumer/ConsumerGate.psm1:295:79|$environment.Clear()
scripts/consumer/ConsumerGate.psm1:296:13|$standardOutput=$null
scripts/consumer/ConsumerGate.psm1:296:35|$standardError=$null
scripts/consumer/ConsumerGate.psm1:296:131|$Token=$null
scripts/consumer/ConsumerGate.psm1:297:13|Remove-Variable standardOutput,standardError,credentialLeak,executionFailure,result,runtime,environment,Token -ErrorAction SilentlyContinue
scripts/consumer/ConsumerGate.psm1:299:100|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1:300:5|$Token=$null
scripts/consumer/ConsumerGate.psm1:384:13|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/ConsumerGate.psm1:386:9|$Token=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1:41:9|$phaseEnvironment=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1:41:130|$value=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1:76:91|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/Invoke-ConsumerSourceGate.ps1:90:9|[Environment]::SetEnvironmentVariable($name,$null,'Process')
scripts/consumer/Invoke-ConsumerSourceGate.ps1:93:5|$token=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1:94:5|$tokenVariable=$null
scripts/consumer/Invoke-ConsumerSourceGate.ps1:95:5|$message=$null
'@ -split '\r?\n'|Where-Object{$_}
        if((@($equivalent)-join"`n")-cne(@($expectedEquivalent)-join"`n")){
            throw "EQUIVALENT_POINTS_MISMATCH|$(@($equivalent)-join';')"
        }
        }finally{Remove-SourceFixtureLease $mutantLease}
    }

    # Scenario: Prepare receives all GitHub token aliases while production launches Git for config and closure inspection.
    # Purpose: Every non-resolver Git child removes all credential aliases, and the oracle still detects a fully stripped defense stack.
    It 'UnitT33_removes_credentials_from_every_consumer_git_launcher' {
        $sources=@(
            (Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerGate.psm1')),
            (Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1'))
        )
        foreach($source in $sources){
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){$source|Should Match ([regex]::Escape("'$name'"))}
        }
        $sources[0]|Should Match 'SetEnvironmentVariable\(\$name,\$null,''Process''\)'
        $sources[1]|Should Match 'Environment\.Remove\(\$name\)'
        foreach($source in $sources){
            $source|Should Match '\$environment\.ContainsKey\(\$name\)'
            $source|Should Match 'credential alias'
        }
        $gateModule=(Get-Command Invoke-GateOwnedGitCapture -CommandType Function -ErrorAction Stop).Module
        $previousRuntime=$gateModule.SessionState.PSVariable.GetValue('GatePlatformRuntimeModule')
        $previousCaptureRoot=$gateModule.SessionState.PSVariable.GetValue('GateGitCaptureRoot')
        $previousRemaining=$gateModule.SessionState.PSVariable.GetValue('GateGitRemainingMilliseconds')
        $captureRoot=Join-Path $TestDrive 'git-environment-capture';[void][IO.Directory]::CreateDirectory($captureRoot)
        $global:Syp497GitEnvironment=$null;$global:Syp497GitCaptureProfile=$null
        $fakeRuntime=[pscustomobject]@{ExportedCommands=@{
                'Resolve-PlatformPhysicalPath'={param($Path)[IO.Path]::GetFullPath($Path)}
                'Open-PlatformDirectory'={param($Root,[switch]$RootOnly)$directory=[pscustomobject]@{};$directory|Add-Member ScriptMethod Dispose {}; $directory}
                'Start-PlatformOwnedProcess'={
                    param($ExecutablePath,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$StdoutPath,$StderrPath,
                        $OutputLimitCharacters,$ArgumentZero,$CaptureProfile)
                    $global:Syp497GitEnvironment=[Collections.Generic.Dictionary[string,string]]::new($Environment)
                    $global:Syp497GitCaptureProfile=$CaptureProfile
                    [IO.File]::WriteAllBytes($StdoutPath,[Text.UTF8Encoding]::new($false).GetBytes("fixture`n"))
                    [IO.File]::WriteAllBytes($StderrPath,[byte[]]::new(0))
                    $lease=[pscustomobject]@{HasExited=$true;CaptureCompletedNaturally=$true;Cleanup=$null;TerminationReason=$null
                        OutputLimitExceeded=$false;OutputLimitStream=$null;ExitCode=0;StartIdentity='fixture'}
                    $lease|Add-Member ScriptMethod Dispose {}; $lease
                }
                'Stop-PlatformOwnedProcess'={param($Lease,$GracePeriod,$Deadline,$ExpectedStartIdentity)[pscustomobject]@{CleanedUp=$true;Uncertainty=$null}}
            }}
        try{
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeModule',$fakeRuntime)
            $gateModule.SessionState.PSVariable.Set('GateGitCaptureRoot',$captureRoot)
            $gateModule.SessionState.PSVariable.Set('GateGitRemainingMilliseconds',[long]60000)
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,'git-token-sentinel','Process')}
            $capture=Invoke-GateOwnedGitCapture $script:RepositoryRoot @('--version') -ByteExact
            $capture.ExitCode|Should Be 0
            $global:Syp497GitCaptureProfile|Should Be 'raw-stdout'
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){$global:Syp497GitEnvironment.ContainsKey($name)|Should Be $false}
        }finally{
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeModule',$previousRuntime)
            $gateModule.SessionState.PSVariable.Set('GateGitCaptureRoot',$previousCaptureRoot)
            $gateModule.SessionState.PSVariable.Set('GateGitRemainingMilliseconds',$previousRemaining)
            $global:Syp497GitEnvironment=$null;$global:Syp497GitCaptureProfile=$null
        }
        $fixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        $formalLease=New-SourceFixtureLease 'git-formal-prepare'
        try{
        $formalArguments=@('-RepositoryRoot',$script:RepositoryRoot,'-FixtureRoot',$formalLease.Root,
            '-Outcome','success','-Sentinel','git-formal-token-sentinel','-TransitionFromLegacy')
        if(-not$IsWindows){$formalArguments+='-ObserveGitCredentialEnvironment'}
        $formalRecords=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture @formalArguments 2>&1)
        $LASTEXITCODE|Should Be 0
        $formalResult=($formalRecords-join[Environment]::NewLine)|ConvertFrom-Json -Depth 30
        $formalResult.exitCode|Should Be 0
        if($IsWindows){
            $productionObservation=Join-Path $TestDrive 'git-production-observation.txt'
            $productionShim=New-GitCredentialPresenceShim (Join-Path $TestDrive 'git-production-shim') $productionObservation
            $productionOldPath=$env:PATH
            $closureModule=$null
            try{
                $env:PATH=$productionShim+[IO.Path]::PathSeparator+$productionOldPath
                foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
                    [Environment]::SetEnvironmentVariable($name,'git-production-token','Process')
                }
                [void](Invoke-GateGit $script:RepositoryRoot @('rev-parse','HEAD'))
                foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
                    [Environment]::SetEnvironmentVariable($name,'git-production-token','Process')
                }
                $closureModule=Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force -PassThru
                & $closureModule {
                    param($AuthorityRoot,$RepositoryRoot)
                    Initialize-ClosureGitCapture -AuthorityRoot $AuthorityRoot -GitCommandTimeoutSeconds 10 -GitReserveSeconds 20
                    try{[void](Invoke-ClosureOwnedGitBytes -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse','HEAD'))}
                    finally{Complete-ClosureGitCapture}
                } $script:RepositoryRoot $script:RepositoryRoot
                $observations=@(Get-Content -LiteralPath $productionObservation)
            }finally{
                $env:PATH=$productionOldPath
                foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
                    [Environment]::SetEnvironmentVariable($name,$null,'Process')
                }
            }
        }else{$observations=@($formalResult.gitObservations)}
        }finally{Remove-SourceFixtureLease $formalLease}
        @($observations).Count|Should BeGreaterThan 0
        @($observations|Where-Object{$_-cne'0,0,0'}).Count|Should Be 0

        $mutantPath=Join-Path $TestDrive 'ConsumerGate-git-outer-cleanup-mutant.psm1'
        $moduleText=Get-Content -Raw -Encoding UTF8 $script:GateModule;$tokens=$null;$errors=$null
        $moduleAst=[Management.Automation.Language.Parser]::ParseInput($moduleText,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $gitFunctions=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Invoke-GateGit'},$true))
        @($gitFunctions).Count|Should Be 1
        $gitFunction=$gitFunctions[0]
        $credentialRemoval=@($gitFunction.Body.FindAll({param($node)$node-is[Management.Automation.Language.ForEachStatementAst]-and
                    $node.Extent.Text.Contains('STANDARD_VALIDATION_GITHUB_API_TOKEN',[StringComparison]::Ordinal)-and
                    $node.Extent.Text.Contains('SetEnvironmentVariable',[StringComparison]::Ordinal)},$true))
        @($credentialRemoval).Count|Should Be 1
        $mutantText=$moduleText.Remove($credentialRemoval[0].Extent.StartOffset,$credentialRemoval[0].Extent.EndOffset-$credentialRemoval[0].Extent.StartOffset)
        [IO.File]::WriteAllText($mutantPath,$mutantText,[Text.UTF8Encoding]::new($false))
        $observation=Join-Path $TestDrive 'git-mutant-observation.txt'
        $shim=New-GitCredentialPresenceShim (Join-Path $TestDrive 'git-mutant-shim') $observation
        $oldPath=$env:PATH
        try{
            $env:PATH=$shim+[IO.Path]::PathSeparator+$oldPath
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,'git-mutant-token','Process')}
            Import-Module $mutantPath -Force
            $hooks=Join-Path $TestDrive 'git-mutant-hooks';[void][IO.Directory]::CreateDirectory($hooks);Initialize-GateGitHooks $hooks $script:RepositoryRoot
            [void](Invoke-GateGit $script:RepositoryRoot @('rev-parse','HEAD'))
        }finally{
            $env:PATH=$oldPath
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
            Restore-GateFixtureModule
        }
        $mutantObservations=@(Get-Content -LiteralPath $observation)
        @($mutantObservations)|Should Be @('0,0,0')

        $ownedCaptures=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateOwnedGitCapture'},$true))
        @($ownedCaptures).Count|Should Be 1
        $ownedCapture=$ownedCaptures[0]
        $childEnvironment=@($ownedCapture.Body.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and
                    $node.GetCommandName()-ceq'New-GateChildEnvironment'-and
                    $node.Extent.Text-ceq"New-GateChildEnvironment `$null @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')"},$true))
        @($childEnvironment).Count|Should Be 1
        $credentialGuard=@($ownedCapture.Body.FindAll({param($node)$node-is[Management.Automation.Language.ForEachStatementAst]-and
                    $node.Extent.Text.Contains('STANDARD_VALIDATION_GITHUB_API_TOKEN',[StringComparison]::Ordinal)-and
                    $node.Extent.Text.Contains('ContainsKey',[StringComparison]::Ordinal)-and
                    $node.Extent.Text.Contains('credential alias',[StringComparison]::Ordinal)},$true))
        @($credentialGuard).Count|Should Be 1
        $fullMutantText=$moduleText
        $fullMutations=@(
            [pscustomobject]@{Start=$credentialRemoval[0].Extent.StartOffset;Length=$credentialRemoval[0].Extent.EndOffset-$credentialRemoval[0].Extent.StartOffset;Text=''},
            [pscustomobject]@{Start=$childEnvironment[0].Extent.StartOffset;Length=$childEnvironment[0].Extent.EndOffset-$childEnvironment[0].Extent.StartOffset;Text='New-GateChildEnvironment $null'}
        )
        if($IsWindows){$fullMutations+=@(
            [pscustomobject]@{Start=$credentialGuard[0].Extent.StartOffset;Length=$credentialGuard[0].Extent.EndOffset-$credentialGuard[0].Extent.StartOffset;Text=''}
        )}
        foreach($mutation in $fullMutations|Sort-Object Start -Descending){
            $fullMutantText=$fullMutantText.Remove($mutation.Start,$mutation.Length).Insert($mutation.Start,$mutation.Text)
        }
        $fullMutantPath=Join-Path $TestDrive 'ConsumerGate-git-full-inheritance-mutant.psm1'
        [IO.File]::WriteAllText($fullMutantPath,$fullMutantText,[Text.UTF8Encoding]::new($false))
        $fullObservation=Join-Path $TestDrive 'git-full-mutant-observation.txt'
        $fullShim=New-GitCredentialPresenceShim (Join-Path $TestDrive 'git-full-mutant-shim') $fullObservation
        try{
            $env:PATH=$fullShim+[IO.Path]::PathSeparator+$oldPath
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,'git-mutant-token','Process')}
            Import-Module $fullMutantPath -Force
            $hooks=Join-Path $TestDrive 'git-full-mutant-hooks';[void][IO.Directory]::CreateDirectory($hooks);Initialize-GateGitHooks $hooks $script:RepositoryRoot
            if($IsWindows){[void](Invoke-GateGit $script:RepositoryRoot @('rev-parse','HEAD'))}
            else{{Invoke-GateGit $script:RepositoryRoot @('rev-parse','HEAD')}|Should Throw 'credential alias'}
        }finally{
            $env:PATH=$oldPath
            foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
            Restore-GateFixtureModule
        }
        if($IsWindows){
            $fullMutantObservations=@(Get-Content -LiteralPath $fullObservation)
            @($fullMutantObservations)|Should Be @('1,1,1')
            {if(@($fullMutantObservations|Where-Object{$_-cne'0,0,0'}).Count-ne0){throw 'GIT_CREDENTIAL_ORACLE_FAILED'}}|Should Throw 'GIT_CREDENTIAL_ORACLE_FAILED'
        }else{Test-Path -LiteralPath $fullObservation -PathType Leaf|Should Be $false}
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
    It 'UnitT37_accepts_all_five_ready_manifest_configs_and_rejects_required_check_drift' {
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
            'skill-general' = @{ Count=46; Sha256='49d7b8e6a19bf728ec04ea75cf31758c5c90182c803183d29bf6f0091f2c64fe' }
            'skill-atlassian-ecosystem' = @{ Count=100; Sha256='1ff826f6bb8ffb1d7a93b2d75d54dafccc646c123b45856c2f9176878f21845b' }
            'skill-code-collaboration' = @{ Count=23; Sha256='dbf9332f204eda3d15c8777c4e73ad0b846a0e653367ea188c03d47c2766ce2a' }
            'skill-knowledge-content' = @{ Count=17; Sha256='78704317aea1f2678901f671ecc6fb297640e8e1282eaf3f40dcb3f980a8c2a3' }
            'skill-darktide-translate' = @{ Count=49; Sha256='9fcad1291facceb4e2d20be43ccf7cf772ffe21f1ef94cad6083da2958669626' }
        }
        foreach ($entry in @($manifest.repositories | Where-Object status -eq ready)) {
            Restore-GateFixtureModule
            $oracleLines = @($entry.files | ForEach-Object {
                    "$($_.path)|$($_.disposition)|$($_.expectedOutcome)|$($_.target)"
                } | Sort-Object)
            $oracleBytes = [Text.UTF8Encoding]::new($false).GetBytes(($oracleLines -join "`n") + "`n")
            $oracleSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oracleBytes)).ToLowerInvariant()
            $oracleLines.Count | Should Be $expectedDispositionOracle[[string]$entry.id].Count
            $oracleSha | Should Be $expectedDispositionOracle[[string]$entry.id].Sha256

            if ([string]$entry.id -eq 'skill-darktide-translate') {
                $darktideSplit = @($entry.files | Where-Object disposition -eq 'split')[0]
                $darktideSplitTarget = @($entry.files | Where-Object {
                        [string]$_.path -eq [string]$darktideSplit.target
                    })
                $darktideSplitTarget.Count | Should Be 1
                [string]$darktideSplitTarget[0].disposition | Should Be 'retain'
            }

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
                    $splitTargetRecord = @($entry.files | Where-Object {
                            [string]$_.path -eq [string]$record.target
                        })[0]
                    if ($null -eq $splitTargetRecord) {
                        $target = Join-Path $root ([string]$record.target)
                        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                        [IO.File]::WriteAllText($target, "split target`n", [Text.UTF8Encoding]::new($false))
                    }
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
                $splitTargetRecord = @($entry.files | Where-Object {
                        [string]$_.path -eq [string]$split.target
                    })[0]
                Remove-Item -LiteralPath $splitTarget -Force
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','wrong split target'))
                $wrongRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                $splitExpectation = $entry
                if ($null -ne $splitTargetRecord -and $splitTargetRecord.disposition -eq 'retain') {
                    { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $entry $baseRevision $wrongRevision $true } |
                        Should Throw 'Retained path must remain unchanged'
                    $splitExpectation = Copy-FixtureValue $entry
                    $splitExpectation.files = @($splitExpectation.files | Where-Object {
                            -not ([string]$_.path -eq [string]$split.target -and $_.disposition -eq 'retain')
                        })
                }
                { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $splitExpectation $baseRevision $wrongRevision $true } |
                    Should Throw 'Split target'
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
            $deleteRecord = @($deleteExpectation.files | Where-Object {
                    $_.disposition -eq 'update-tests' -and $_.expectedOutcome -eq 'rewrite'
                })[0]
            $deleteRecord.expectedOutcome = 'delete'
            { Assert-GateProtectedFiles $script:RepositoryRoot $root $root $deleteExpectation `
                    $baseRevision $candidateRevision $true } | Should Throw 'must be deleted'

            $exceptionRetained = @($entry.files | Where-Object {
                    $_.disposition -eq 'retain' -and (Test-GateExceptionPathInScope ([string]$_.path))
                })[0]
            if ($null -ne $exceptionRetained) {
                $exceptionRetainedPath = Join-Path $root ([string]$exceptionRetained.path)
                $exceptionRenamedPath = "$exceptionRetainedPath.renamed"
                Move-Item -LiteralPath $exceptionRetainedPath -Destination $exceptionRenamedPath
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','rename exception-scope retained path'))
                $exceptionRenameRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
                (Get-SourceFixtureFailure {
                        Assert-GateProtectedFilesWithExceptionShrinkOnly $script:RepositoryRoot $root $root $entry `
                            $baseRevision $exceptionRenameRevision $true
                    }) | Should BeExactly 'BLOCKED|SkillSpector exception registry was deleted while baseline files remain.'
                Move-Item -LiteralPath $exceptionRenamedPath -Destination $exceptionRetainedPath
                [void](Invoke-SourceFixtureGit $root @('add','-A'))
                [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','restore exception-scope retained path'))
                $candidateRevision = Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
            }

            $retained = @($entry.files | Where-Object {
                    $_.disposition -eq 'retain' -and -not (Test-GateExceptionPathInScope ([string]$_.path))
                })[0]
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

    # Scenario: An exception set de-identified from Atlassian 2aca2db is unchanged, reduced, removed, expanded, mutated, malformed, duplicated, or stored under adversarial tree paths.
    # Purpose: Permit only set-semantic removal, ignore non-UTF-8 paths outside scope, and fail closed on scoped Unicode variants or unsafe data.
    It 'UnitT39_enforces_SkillSpector_exception_sets_as_shrink_only' {
        $expectedBlobs=[ordered]@{
            'skillspector-exceptions.json'='e1c3304ab695faae74fa89c8ed2ea7d1d0523dee'
            'skillspector-exceptions/configure-bitbucket-api-access.baseline.json'='ccc9dd0c6e4a4da3e3fe6fefbe6019c865a4b748'
            'skillspector-exceptions/configure-confluence-api-access.baseline.json'='b71b96cc04df8b9e05c96c46552cae2042cbd0ff'
            'skillspector-exceptions/configure-jira-api-access.baseline.json'='dcf69c14da968b32412dabc5fb0b609936fbbe92'
            'skillspector-exceptions/manage-confluence-docs-as-code.baseline.json'='32d3009dd6db841f4fc7c459b9b6ff10cd561fab'
            'skillspector-exceptions/publish-requirements-to-confluence.baseline.json'='7422405fc6fa29420f9e61786ca942f911661acf'
            'skillspector-exceptions/review-bitbucket-pull-request.baseline.json'='7757758f064dabc9d3fa2731e636a5ca06a181c5'
        }
        foreach($entry in $expectedBlobs.GetEnumerator()){
            $actual=Get-SourceFixtureGitScalar $script:RepositoryRoot @('hash-object','--no-filters','--',(Join-Path $script:ExceptionFixtureConfigRoot $entry.Key))
            $actual|Should Be $entry.Value
        }

        $fixture=New-ExceptionFixtureRepository 'exception-unchanged'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Base

        foreach($rawPath in @(
            @{Name='outside-root';Prefix='outside-';Suffix='.txt'},
            @{Name='unrelated-config';Prefix='config/';Suffix='.txt'},
            @{Name='noncanonical-registry';Prefix='config/skillspector-exceptions';Suffix='.json'}
        )){
            $fixture=New-ExceptionFixtureRepository "exception-non-utf8-$($rawPath.Name)"
            $path=[Collections.Generic.List[byte]]::new()
            $path.AddRange([Text.Encoding]::ASCII.GetBytes($rawPath.Prefix));$path.Add(0x80)
            $path.AddRange([Text.Encoding]::ASCII.GetBytes($rawPath.Suffix))
            $candidate=New-ExceptionFixtureRawPathCandidate $fixture.Root $fixture.Base $path.ToArray() "non-UTF-8 $($rawPath.Name)"
            Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate
        }

        $fixture=New-ExceptionFixtureRepository 'exception-non-utf8-baseline-scope'
        $path=[Collections.Generic.List[byte]]::new()
        $path.AddRange([Text.Encoding]::ASCII.GetBytes('config/skillspector-exceptions/'));$path.Add(0x80)
        $path.AddRange([Text.Encoding]::ASCII.GetBytes('.baseline.json'))
        $candidate=New-ExceptionFixtureRawPathCandidate $fixture.Root $fixture.Base $path.ToArray() 'non-UTF-8 baseline scope'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^INVALID\|.*non-UTF-8 path within.*scope'

        $fixture=New-ExceptionFixtureRepository 'exception-delete-all'
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'config') -Recurse -Force
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'delete all exceptions'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate

        $fixture=New-ExceptionFixtureRepository 'exception-real-shrink'
        $registry=Get-ExceptionFixtureRegistry $fixture.Root
        $registry.exceptions=@($registry.exceptions|Where-Object skillId -ceq 'review-bitbucket-pull-request')
        $registry.baselines=@($registry.baselines|Where-Object skillId -ceq 'review-bitbucket-pull-request')
        Set-ExceptionFixtureRegistry $fixture.Root $registry
        Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'config/skillspector-exceptions') -File|Where-Object Name -cne `
            'review-bitbucket-pull-request.baseline.json'|Remove-Item -Force
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'retain real review baseline only'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate

        $fixture=New-ExceptionFixtureRepository 'exception-delete-one'
        $baseline=Get-ExceptionFixtureBaseline $fixture.Root
        $removedHash=[string]$baseline.fingerprints[0].hash
        $baseline.fingerprints=@($baseline.fingerprints|Where-Object hash -cne $removedHash)
        Set-ExceptionFixtureBaseline $fixture.Root $baseline
        $registry=Get-ExceptionFixtureRegistry $fixture.Root
        $registry.exceptions=@($registry.exceptions|Where-Object fingerprint -cne $removedHash)
        Set-ExceptionFixtureRegistry $fixture.Root $registry
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'delete one exact exception'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate

        foreach($number in @('1e-400','0.0')){
            $fixture=New-ExceptionFixtureRepository "exception-number-$($number.Replace('.','-'))"
            Replace-ExceptionFixtureRegistryText $fixture.Root '"startColumn": 0,' "`"startColumn`": $number,"
            $candidate=Save-ExceptionFixtureCandidate $fixture.Root "change zero token to $number"
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
                '^BLOCKED\|.*exception atl-e1-jira-configure-reference-61.*modified'
        }

        $fixture=New-ExceptionFixtureRepository 'exception-equivalent-string-escape'
        Replace-ExceptionFixtureRegistryText $fixture.Root '"ruleId": "E1"' '"ruleId": "\u0045\u0031"'
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'change string escape spelling only'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate

        $fixture=New-ExceptionFixtureRepository 'exception-iso-date-spelling'
        Replace-ExceptionFixtureRegistryText $fixture.Root '"expiresOn": "2027-05-09"' '"expiresOn": "2027-05-09T00:00:00Z"'
        $dateBase=Save-ExceptionFixtureCandidate $fixture.Root 'establish ISO date-time base spelling'
        Replace-ExceptionFixtureRegistryText $fixture.Root '"expiresOn": "2027-05-09T00:00:00Z"' `
            '"expiresOn": "2027-05-09T00:00:00.000Z"'
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'change ISO date-time spelling'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $dateBase $candidate})|Should Match `
            '^BLOCKED\|.*skillspector-exceptions\.json.*review.*modified'

        foreach($mutation in @('fingerprint-add','fingerprint-hash','fingerprint-reason')){
            $fixture=New-ExceptionFixtureRepository "exception-$mutation"
            $baseline=Get-ExceptionFixtureBaseline $fixture.Root
            if($mutation-ceq'fingerprint-add'){$baseline.fingerprints=@($baseline.fingerprints)+@((Copy-FixtureValue $baseline.fingerprints[0]));$baseline.fingerprints[-1].file='new.ps1'}
            elseif($mutation-ceq'fingerprint-hash'){$baseline.fingerprints[0].hash='sha256:'+('f'*64)}
            else{$baseline.fingerprints[0].reason='changed reason'}
            Set-ExceptionFixtureBaseline $fixture.Root $baseline
            $candidate=Save-ExceptionFixtureCandidate $fixture.Root $mutation
            $failure=Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate}
            $failure|Should Match '^BLOCKED\|.*review-bitbucket-pull-request\.baseline\.json.*(added|modified)'
        }

        $fixture=New-ExceptionFixtureRepository 'exception-new-baseline'
        Copy-Item -LiteralPath (Join-Path $fixture.Root 'config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json') `
            -Destination (Join-Path $fixture.Root 'config/skillspector-exceptions/new-skill.baseline.json')
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'new baseline'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^BLOCKED\|.*new-skill\.baseline\.json.*added'

        foreach($rename in @(
            @{Name='registry';Source='config/skillspector-exceptions.json';Destination='config/SkillSpector-exceptions.json'},
            @{Name='baseline-directory';Source='config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json';Destination='config/SkillSpector-exceptions/review-bitbucket-pull-request.baseline.json'},
            @{Name='baseline-file';Source='config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json';Destination='config/skillspector-exceptions/Review-bitbucket-pull-request.baseline.json'}
        )){
            $fixture=New-ExceptionFixtureRepository "exception-case-$($rename.Name)"
            $candidate=Move-ExceptionFixtureIndexPath $fixture.Root $rename.Source $rename.Destination
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
                "^BLOCKED\|.*$([regex]::Escape($rename.Destination)).*casing"
        }

        foreach($variant in @(
            @{Name='kelvin';Source='config/skillspector-exceptions.json';Destination="config/s$([char]0x212A)illspector-exceptions.json"},
            @{Name='long-s';Source='config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json';Destination="config/$([char]0x017F)killspector-exceptions/review-bitbucket-pull-request.baseline.json"}
        )){
            $fixture=New-ExceptionFixtureRepository "exception-unicode-$($variant.Name)"
            $candidate=Move-ExceptionFixtureIndexPath $fixture.Root $variant.Source $variant.Destination
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
                "^BLOCKED\|.*$([regex]::Escape($variant.Destination)).*(casing|Unicode variant)"
        }

        $fixture=New-ExceptionFixtureRepository 'exception-new-registry' -WithoutExceptionSet
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Root 'config'))
        Copy-Item -LiteralPath (Join-Path $script:ExceptionFixtureConfigRoot 'skillspector-exceptions.json') `
            -Destination (Join-Path $fixture.Root 'config/skillspector-exceptions.json')
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'new registry'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^BLOCKED\|.*skillspector-exceptions\.json.*added'

        foreach($mutation in @('expiry','approval')){
            $fixture=New-ExceptionFixtureRepository "exception-registry-$mutation"
            $registry=Get-ExceptionFixtureRegistry $fixture.Root
            if($mutation-ceq'expiry'){$registry.review.expiresOn='2027-06-09'}else{$registry.approval.decision='changed'}
            Set-ExceptionFixtureRegistry $fixture.Root $registry
            $candidate=Save-ExceptionFixtureCandidate $fixture.Root $mutation
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
                '^BLOCKED\|.*skillspector-exceptions\.json.*(review|approval).*modified'
        }

        $fixture=New-ExceptionFixtureRepository 'exception-registry-add'
        $registry=Get-ExceptionFixtureRegistry $fixture.Root
        $registry.exceptions=@($registry.exceptions)+@((Copy-FixtureValue $registry.exceptions[0]))
        $registry.exceptions[-1].exceptionId='new-exception'
        Set-ExceptionFixtureRegistry $fixture.Root $registry
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'add registry exception'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^BLOCKED\|.*exception new-exception.*added'

        $fixture=New-ExceptionFixtureRepository 'exception-registry-delete-only'
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'config/skillspector-exceptions.json') -Force
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'delete registry only'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^BLOCKED\|.*registry.*baseline.*remain'

        foreach($mutation in @('exception-duplicate','baseline-duplicate')){
            $fixture=New-ExceptionFixtureRepository "exception-$mutation"
            if($mutation-ceq'exception-duplicate'){
                $registry=Get-ExceptionFixtureRegistry $fixture.Root
                $registry.exceptions=@($registry.exceptions)+@((Copy-FixtureValue $registry.exceptions[0]))
                Set-ExceptionFixtureRegistry $fixture.Root $registry
            }else{
                $baseline=Get-ExceptionFixtureBaseline $fixture.Root
                $baseline.fingerprints=@($baseline.fingerprints)+@((Copy-FixtureValue $baseline.fingerprints[0]))
                Set-ExceptionFixtureBaseline $fixture.Root $baseline
            }
            $candidate=Save-ExceptionFixtureCandidate $fixture.Root $mutation
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match '^BLOCKED\|.*duplicate'
        }

        foreach($mode in @('executable','symlink')){
            $fixture=New-ExceptionFixtureRepository "exception-mode-$mode"
            $path='config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json'
            if($mode-ceq'executable'){
                [void](Invoke-SourceFixtureGit $fixture.Root @('update-index','--chmod=+x','--',$path))
            }else{
                $oid=Get-SourceFixtureGitScalar $fixture.Root @('hash-object','--no-filters','--',$path)
                [void](Invoke-SourceFixtureGit $fixture.Root @('update-index','--add','--cacheinfo',"120000,$oid,$path"))
            }
            [void](Invoke-SourceFixtureGit $fixture.Root @('commit','-q','-m',"$mode mode"))
            $candidate=Get-SourceFixtureGitScalar $fixture.Root @('rev-parse','HEAD')
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
                '^BLOCKED\|.*review-bitbucket-pull-request\.baseline\.json.*mode'
        }

        foreach($mutation in @('duplicate-key','invalid-json')){
            $fixture=New-ExceptionFixtureRepository "exception-json-$mutation"
            $text=if($mutation-ceq'duplicate-key'){'{"schemaVersion":1,"schemaVersion":1}'}else{'{"schemaVersion":'}
            [IO.File]::WriteAllText((Join-Path $fixture.Root 'config/skillspector-exceptions.json'),$text,[Text.UTF8Encoding]::new($false))
            $candidate=Save-ExceptionFixtureCandidate $fixture.Root $mutation
            (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match '^INVALID\|.*JSON'
        }

        $fixture=New-ExceptionFixtureRepository 'exception-json-lone-high-surrogate-value'
        Replace-ExceptionFixtureRegistryText $fixture.Root '"decision": "accepted-limited-risk"' '"decision": "\uD800"'
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'lone high surrogate value'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^INVALID\|.*JSON.*config/skillspector-exceptions\.json.*cannot be decoded'

        $fixture=New-ExceptionFixtureRepository 'exception-json-lone-low-surrogate-key'
        $path=Join-Path $fixture.Root 'config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json'
        $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
        $updated=[regex]::new('"version":').Replace($text,'"\uDC00":',1)
        if($updated-ceq$text){throw 'Fixture baseline version key was not found.'}
        [IO.File]::WriteAllText($path,$updated,[Text.UTF8Encoding]::new($false))
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'lone low surrogate key'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate})|Should Match `
            '^INVALID\|.*JSON.*review-bitbucket-pull-request\.baseline\.json.*cannot be decoded'

        $prepareFixture=Join-Path $script:RepositoryRoot 'tests/fixtures/Invoke-ConsumerGateCredentialFixture.ps1'
        foreach($scenario in @(
            @{Name='exception-shrink';ExitCode=0;Message=''},
            @{Name='exception-modify';ExitCode=10;Message='fingerprint .* modified'},
            @{Name='retain-outside-change';ExitCode=20;Message='Retained path must remain unchanged: scripts/Retained.ps1'}
        )){
            $lease=New-SourceFixtureLease "prepare-$($scenario.Name)"
            try{
                $records=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $prepareFixture `
                    -RepositoryRoot $script:RepositoryRoot -FixtureRoot $lease.Root -Outcome success `
                    -Sentinel 'syp500-prepare-sentinel' -TransitionFromLegacy -PrepareScenario $scenario.Name 2>&1)
                if($LASTEXITCODE-ne0){throw "Prepare fixture '$($scenario.Name)' failed: $($records-join' | ')"}
                $result=($records-join[Environment]::NewLine)|ConvertFrom-Json -Depth 30
                if($result.exitCode-ne$scenario.ExitCode){throw "Prepare scenario '$($scenario.Name)' expected exit $($scenario.ExitCode) but got $($result.exitCode): $($result.stderr)"}
                $result.exitCode|Should Be $scenario.ExitCode
                if(-not[string]::IsNullOrEmpty($scenario.Message)){$result.stderr|Should Match $scenario.Message}
                if($scenario.Name-ceq'exception-shrink'){@($result.events)|Should Be @('runtime-installed','source-tools-prepared')}
                else{@($result.events).Count|Should Be 0}
            }finally{Remove-SourceFixtureLease $lease}
        }
    }

    # Scenario: A transition conversion runs the complete manifest closure through an injected invoker that returns one non-enumerated byte array.
    # Purpose: Preserve the gate-to-closure byte contract instead of wrapping the byte array in an object array before conversion.
    It 'UnitT39a_runs_transition_manifest_closure_through_the_byte_invoker' {
        $root=Join-Path $TestDrive 'closure-byte-invoker-transition'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'docs'))
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        [void](Invoke-SourceFixtureGit $root @('config','user.name','Fixture'))
        [void](Invoke-SourceFixtureGit $root @('config','user.email','fixture@example.test'))
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Legacy.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'README.md'),'fixture',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllBytes((Join-Path $root 'docs/empty.md'),[byte[]]::new(0))
        [void](Invoke-SourceFixtureGit $root @('add','.'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','inventory'))
        $inventoryCommit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $inventoryTree=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD^{tree}')
        Remove-Item -LiteralPath (Join-Path $root 'scripts/Legacy.ps1')
        [void](Invoke-SourceFixtureGit $root @('add','-A'))
        [void](Invoke-SourceFixtureGit $root @('commit','-q','-m','conversion'))
        $conversionCommit=Get-SourceFixtureGitScalar $root @('rev-parse','HEAD')
        $manifestPath=Join-Path $TestDrive 'closure-byte-invoker-transition.json'
        Write-FixtureJson $manifestPath ([ordered]@{schemaVersion=1;repositories=@([ordered]@{
                        id='fixture';repository='https://example.test/fixture.git';status='ready'
                        inventoryCommit=$inventoryCommit;inventoryTree=$inventoryTree;requiredRepositoryChecks=@()
                        files=@([ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='fixture migration'})
                    })})
        $invocations=[Collections.Generic.List[string]]::new()
        $gitBytesCommand=Get-Command Invoke-SourceFixtureGitBytes
        $invoker={param([string]$RepositoryRoot,[string[]]$Arguments,[int[]]$AllowedExitCodes)
            $invocations.Add(($Arguments-join' '))|Out-Null
            & $gitBytesCommand $RepositoryRoot $Arguments
        }.GetNewClosure()
        $result=Get-ConsumerManifestClosure -RepositoryRoot $root -Commit $conversionCommit -Stage conversion `
            -InventoryCommit $inventoryCommit -Manifest $manifestPath -RepositoryId fixture `
            -AuthorityRoot $script:RepositoryRoot -GitByteInvoker $invoker
        $result.result|Should Be 'PASS'
        $invocations.Count|Should BeGreaterThan 0
    }

    # Scenario: A retained 2.13.4 exception set is reduced to three records while every scanner-bound field is re-pinned to active 2.13.6.
    # Purpose: Allow the exact human-approved scanner transition without weakening shrink-only semantics.
    It 'UnitT65_accepts_the_approved_SkillSpector_scanner_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-valid'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot
    }

    # Scenario: A scanner-transition candidate adds a fourth exception.
    # Purpose: Keep transition approval shrink-only and reject additions even when scanner identities are valid.
    It 'UnitT66_blocks_an_added_exception_during_scanner_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-add' -Mutation {
            param($registry,$baseline,$root)
            $added=Copy-FixtureValue $registry.exceptions[0];$added.exceptionId='added-exception';$added.file='added.ps1'
            $registry.exceptions=@($registry.exceptions)+@($added)
        }
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|'
    }

    # Scenario: A retained exception moves to another source line during scanner transition.
    # Purpose: Permit only fingerprint replacement and preserve the exact reviewed location.
    It 'UnitT67_blocks_exception_location_drift_during_scanner_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-line' -Mutation {param($registry,$baseline,$root) $registry.exceptions[0].startLine++}
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*fingerprint'
    }

    # Scenario: A retained baseline changes its human-approved reason during scanner transition.
    # Purpose: Keep all non-hash fingerprint fields immutable.
    It 'UnitT68_blocks_baseline_reason_drift_during_scanner_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-reason' -Mutation {param($registry,$baseline,$root) $baseline.fingerprints[0].reason='changed reason'}
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*hash'
    }

    # Scenario: The registry scanner source changes together with an otherwise valid version transition.
    # Purpose: Restrict scanner object changes to version and wheelSha256.
    It 'UnitT69_blocks_scanner_source_drift_during_scanner_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-source' -Mutation {param($registry,$baseline,$root) $registry.scanner.source='changed-source'}
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*source'
    }

    # Scenario: A candidate targets reviewed but non-active 2.13.0.
    # Purpose: Allow transitions only to the executing authority's active scanner entry.
    It 'UnitT70_blocks_a_scanner_transition_to_a_non_active_version' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-non-active' -NewVersion '2.13.0' `
            -NewWheel '41e097b4127c0aa0732ad31cc909f8aee0b907d97816c866a55b8e782a6ca6dc'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|'
    }

    # Scenario: The candidate version is active but its wheel digest is not the active approved digest.
    # Purpose: Bind transition permission to the exact reviewed scanner artifact.
    It 'UnitT71_blocks_an_active_scanner_transition_with_the_wrong_wheel' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-new-wheel' -NewWheel ('f'*64)
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|'
    }

    # Scenario: The base registry names a scanner version absent from approved-sources.
    # Purpose: Require the old side of a transition to be a retained reviewed entry.
    It 'UnitT72_blocks_a_scanner_transition_from_an_unknown_old_version' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-old-unknown' -OldVersion '9.9.9' -OldWheel ('e'*64)
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|'
    }

    # Scenario: Fingerprints change while scanner.version remains 2.13.4.
    # Purpose: Preserve the original shrink-only rule outside a real scanner transition.
    It 'UnitT73_blocks_fingerprint_changes_without_a_scanner_version_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-same-version' -NewVersion '2.13.4' `
            -NewWheel 'c5e7f290897c65018013a6e37022fabdd2ba1aeeb4994b65df2de8b0d536bea0'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*modified'
    }

    # Scenario: A candidate baseline declares a scanner_version different from the registry transition target.
    # Purpose: Keep every retained baseline bound to the exact active scanner version.
    It 'UnitT74_blocks_baseline_scanner_version_drift_during_transition' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-baseline-version' -Mutation {param($registry,$baseline,$root) $baseline.scanner_version='2.13.5'}
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*scanner_version'
    }

    # Scenario: A candidate exception fingerprint differs from its otherwise retained baseline hash.
    # Purpose: Preserve the registry-to-baseline one-to-one pairing after re-pinning.
    It 'UnitT75_blocks_exception_and_baseline_fingerprint_mismatch' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-pairing' -Mutation {param($registry,$baseline,$root) $registry.exceptions[0].fingerprint='sha256:'+('f'*64)}
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|Should Match '^BLOCKED\|.*exactly one'
    }

    # Scenario: Legacy callers invoke the three-argument shrink-only function for a version-changing candidate.
    # Purpose: Keep old call behavior fail-closed when no authority can approve the transition.
    It 'UnitT76_keeps_the_legacy_three_argument_gate_fail_closed' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-no-authority'
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate})|Should Match '^BLOCKED\|'
    }

    # Scenario: All three candidate fingerprints are reported once with their exact approved severity, reason and source line.
    # Purpose: Re-derive transition expectations from Git trees and accept complete run-bound evidence with matching severity.
    It 'UnitT77_accepts_three_of_three_run_bound_transition_suppressions_with_matching_severity' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-valid'
        $suppressed=Get-ScannerTransitionSuppressedFindings $fixture
        $suppressed.Count|Should Be 3
        Assert-ScannerTransitionEvidenceFixture $fixture $suppressed
    }

    # Scenario: The authority report outputSha256 differs from the hash recomputed from raw stdout and stderr.
    # Purpose: Bind transition evidence to the central output-hash contract rather than the raw event file digest.
    It 'UnitT78_blocks_a_transition_output_hash_mismatch' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-output-hash'
        $evidence=New-ScannerTransitionEvidenceFixture $fixture (Get-ScannerTransitionSuppressedFindings $fixture)
        $evidence.Report.sourceValidation.events[0].outputSha256='f'*64
        (Get-SourceFixtureFailure {Assert-GateExceptionScannerTransitionEvidence $script:RepositoryRoot $fixture.Root $fixture.Base `
            $fixture.Candidate $evidence.Report $evidence.Artifacts})|Should Match '^BLOCKED\|.*output hash'
    }

    # Scenario: A policy-validated non-Windows leg reports platform-unavailable and therefore has no suppressedFindings.
    # Purpose: Preserve the approved platform-unavailable path while Windows still supplies scanner suppression evidence.
    It 'UnitT79_accepts_platform_unavailable_transition_evidence_without_suppressions' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-platform-unavailable'
        Assert-ScannerTransitionEvidenceFixture $fixture @() 'platform-unavailable'
    }

    # Scenario: The run-bound scanner envelope omits one of three candidate fingerprints.
    # Purpose: Reject any transitioned fingerprint that was not actually produced and used in this run.
    It 'UnitT80_blocks_an_unused_transition_fingerprint' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-unused'
        $suppressed=@(Get-ScannerTransitionSuppressedFindings $fixture|Select-Object -First 2)
        (Get-SourceFixtureFailure {Assert-ScannerTransitionEvidenceFixture $fixture $suppressed})|Should Match '^BLOCKED\|.*every candidate baseline fingerprint'
    }

    # Scenario: A run-bound suppressed finding reports a line different from the paired exception startLine.
    # Purpose: Bind new fingerprints to the exact reviewed source location rather than only rule, file, and reason.
    It 'UnitT81_blocks_transition_suppression_line_mismatch' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-line'
        $suppressed=Get-ScannerTransitionSuppressedFindings $fixture;$suppressed[0].line++
        (Get-SourceFixtureFailure {Assert-ScannerTransitionEvidenceFixture $fixture $suppressed})|Should Match '^BLOCKED\|.*line'
    }

    # Scenario: The raw event file is modified after its initial digest is captured but before the final comparison.
    # Purpose: Detect a TOCTOU mutation independently from the stdout/stderr output hash.
    It 'UnitT82_blocks_a_raw_event_changed_during_final_comparison' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-toctou'
        $evidence=New-ScannerTransitionEvidenceFixture $fixture (Get-ScannerTransitionSuppressedFindings $fixture)
        $global:ScannerTransitionHashCalls=0
        Mock Get-GateSha256 {
            $hashCallCounter=Get-Variable ScannerTransitionHashCalls -Scope Global -ErrorAction SilentlyContinue
            if($null-ne$hashCallCounter){
                $hashCallCounter.Value=[int]$hashCallCounter.Value+1
                if($hashCallCounter.Value-eq2){[IO.File]::AppendAllText($Path," ",[Text.UTF8Encoding]::new($false))}
            }
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        } -ModuleName ConsumerGate
        try{
            (Get-SourceFixtureFailure {Assert-GateExceptionScannerTransitionEvidence $script:RepositoryRoot $fixture.Root $fixture.Base `
                $fixture.Candidate $evidence.Report $evidence.Artifacts})|Should Match '^BLOCKED\|.*changed during final comparison'
        }finally{Remove-Variable ScannerTransitionHashCalls -Scope Global -ErrorAction SilentlyContinue}
    }

    # Scenario: Scanner version, wheel, exception fingerprints, and baseline hashes change while every referenced Skill file stays unchanged.
    # Purpose: Accept the approved scanner transition only when immutable base and candidate trees bind every exception to the same blob.
    It 'UnitT83_accepts_a_transition_with_unchanged_referenced_files' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-references-unchanged'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot
    }

    # Scenario: A scanner transition also changes one byte in a file referenced by a retained exception.
    # Purpose: Prevent a regenerated fingerprint from hiding changed Skill content in the scanner-version transition.
    It 'UnitT84_blocks_a_transition_that_changes_a_referenced_file' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-reference-changed' -Mutation {
            param($registry,$baseline,$root)
            [IO.File]::AppendAllText((Join-Path $root 'skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1'),'x',`
                [Text.UTF8Encoding]::new($false))
        }
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|`
            Should Match '^BLOCKED\|.*skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions\.ps1'
    }

    # Scenario: A scanner transition deletes a file referenced by a retained exception from the candidate tree.
    # Purpose: Require every transition exception target to remain a regular blob in both immutable revisions.
    It 'UnitT85_blocks_a_transition_that_deletes_a_referenced_file' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-reference-deleted' -Mutation {
            param($registry,$baseline,$root)
            Remove-Item -LiteralPath (Join-Path $root 'skills/review-bitbucket-pull-request/references/bitbucket-cloud-api.md') -Force
        }
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|`
            Should Match '^BLOCKED\|.*skills/review-bitbucket-pull-request/references/bitbucket-cloud-api\.md'
    }

    # Scenario: A retained exception uses a parent-directory segment in both the base and transitioned candidate registries.
    # Purpose: Reject an exception target that could escape skills/<skillId>/ even when all other transition fields are valid.
    It 'UnitT86_blocks_a_transition_with_an_unsafe_exception_file' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-reference-unsafe' -BaseMutation {
            param($registry,$baseline,$root)
            $exception=@($registry.exceptions|Where-Object skillId -ceq 'review-bitbucket-pull-request')[0]
            $oldFile=[string]$exception.file;$exception.file='../escape.ps1'
            @($baseline.fingerprints|Where-Object file -ceq $oldFile)[0].file='../escape.ps1'
        }
        (Get-SourceFixtureFailure {Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $fixture.Candidate $script:RepositoryRoot})|`
            Should Match '^BLOCKED\|.*unsafe referenced file'
    }

    # Scenario: A referenced Skill file changes while scanner.version and all exception metadata remain unchanged.
    # Purpose: Keep non-transition shrink-only behavior unchanged by the transition-only blob identity rule.
    It 'UnitT87_preserves_non_transition_behavior_for_referenced_file_changes' {
        $fixture=New-ExceptionFixtureRepository 'scanner-non-transition-reference-changed'
        [IO.File]::AppendAllText((Join-Path $fixture.Root 'skills/review-bitbucket-pull-request/SKILL.md'),'x',`
            [Text.UTF8Encoding]::new($false))
        $candidate=Save-ExceptionFixtureCandidate $fixture.Root 'change referenced file without scanner transition'
        Assert-GateExceptionSetShrinkOnly $fixture.Root $fixture.Base $candidate $script:RepositoryRoot
    }

    # Scenario: A transitioned finding has the same identity and location as its approved exception but reports a higher severity.
    # Purpose: Prevent a LOW approval from suppressing a MEDIUM finding after only its fingerprint and hash are re-pinned.
    It 'UnitT88_blocks_transition_suppression_severity_mismatch' {
        $fixture=New-ScannerTransitionFixture 'scanner-transition-evidence-severity' -BaseMutation {
            param($registry,$baseline,$root)
            @($registry.exceptions|Where-Object skillId -ceq 'review-bitbucket-pull-request')[0].severity='LOW'
        }
        $suppressed=Get-ScannerTransitionSuppressedFindings $fixture
        (Get-SourceFixtureFailure {Assert-ScannerTransitionEvidenceFixture $fixture $suppressed})|Should Match '^BLOCKED\|.*severity'
    }

    # Scenario: Three valid legs were fetched at different official-main tips and one stable binding is then changed.
    # Purpose: Aggregate tolerates normal main advancement while keeping authority, candidate, and event identity closed.
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
        $tips=@{windows=('1'*40);linux=('2'*40);macos=('3'*40)}
        foreach ($platform in @('windows','linux','macos')) { Write-FixtureJson (Join-Path $receipts "leg-$platform.json") ([ordered]@{schemaVersion=1
        report='consumer-gate-leg-receipt-v1'
        result='PASS'
        platform=$platform
        runId=$binding.runId
        candidateRevision=$binding.candidateRevision
        headRevision=$binding.headRevision
        baseRevision=$binding.baseRevision
        authorityCommit=$binding.commit
        aiiMainTip=$tips[$platform]
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
        $changed.authorityCommit='8'*40
        Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw 'authorityCommit'
        $changed.authorityCommit=$binding.commit
        $changed.aiiMainTip='invalid-tip'
        Write-FixtureJson (Join-Path $receipts 'leg-linux.json') $changed
        { Invoke-GateAggregate $work $binding } | Should Throw
        $changed.aiiMainTip=$tips.linux
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
        $ledgerKeys=@('schemaVersion','report','coreRunId','candidateSnapshotIdentity','candidateSnapshotSha256','pesterModule',
            'runPath','runScope','testFileInventory','containerFileInventory','discoveredCaseFileInventory','caseDiscoveryCount',
            'caseExecutionCount','containerCount','failedBlockCount','failedContainerCount','terminalStatus','reportedCounts',
            'shardIdentity','shardCaseIdentities','shardUnion','discoveryCases','executionCases','complete','errors')|Sort-Object
        foreach($source in @(
                @{Path=(Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1');Variable='ledger'},
                @{Path=(Join-Path $script:RepositoryRoot 'tests/fixtures/consumer-gate-validation-runner-fixture.ps1');Variable='caseInventory'}
            )){
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($source.Path,[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0
            $assignment=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and
                        $node.Left.Extent.Text-ceq("`$"+$source.Variable)},$true))
            @($assignment).Count|Should Be 1
            $hashtable=$assignment[0].Right.Expression.Child
            $hashtable|Should BeOfType ([Management.Automation.Language.HashtableAst])
            @($hashtable.KeyValuePairs|ForEach-Object{$_.Item1.Extent.Text.Trim([char[]]@("'",'"'))}|Sort-Object)|Should Be $ledgerKeys
        }
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

    # Scenario: A Linux repository check creates and commits a fixture repository through the production owned-process boundary.
    # Purpose: Git automatic maintenance must not detach an unattributed adopted child after the check exits.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if($IsLinux){
        It 'InterT45_disables_detached_git_maintenance_in_the_owned_repository_check' {
            $candidate=Join-Path $TestDrive 'git-maintenance-check'
            foreach($directory in @((Join-Path $candidate 'config'),(Join-Path $candidate 'scripts'))){
                [void][IO.Directory]::CreateDirectory($directory)
            }
            $check=@'
param([string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$fixture=Join-Path $RepositoryRoot 'fixture-repo'
& git init -q -b main $fixture
& git -C $fixture config user.name Fixture
& git -C $fixture config user.email fixture@example.test
& git -C $fixture config maintenance.auto true
& git -C $fixture config maintenance.autoDetach true
& git -C $fixture config gc.autoDetach true
$effectiveMaintenanceAuto=& git -C $fixture config --get maintenance.auto
if($LASTEXITCODE-ne0-or$effectiveMaintenanceAuto-cne'false'){throw 'Effective maintenance.auto must be false.'}
$effectiveGcAutoDetach=& git -C $fixture config --get gc.autoDetach
if($LASTEXITCODE-ne0-or$effectiveGcAutoDetach-cne'false'){throw 'Effective gc.autoDetach must be false.'}
[IO.File]::WriteAllText((Join-Path $fixture 'README.md'),'fixture',[Text.UTF8Encoding]::new($false))
& git -C $fixture add README.md
& git -C $fixture commit -q -m fixture
if($LASTEXITCODE-ne0){throw 'Fixture git commit failed.'}
'@
            [IO.File]::WriteAllText((Join-Path $candidate 'scripts/check.ps1'),$check,[Text.UTF8Encoding]::new($false))
            Write-FixtureJson (Join-Path $candidate 'config/consumer-gate.json') ([ordered]@{
                    schemaVersion=1;repositoryId='fixture';sourceRepository='https://example.test/fixture.git'
                    activeSkills=@('fixture');repositoryChecks=@([ordered]@{id='general';kind='general';path='scripts/check.ps1'})
                })
            $runner=Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
            . $runner -CandidateRoot $candidate -AdapterPath (Join-Path $candidate 'unused-adapter.json') `
                -ArtifactsRoot (Join-Path $candidate 'unused-artifacts') -SourceRepository 'https://example.test/fixture.git' `
                -SourceRevision ('a'*40) -BaseRevision ('b'*40) -DefineFunctionsOnly
            $result=Invoke-StandardValidationProcess `
                -Command (Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1') `
                -Arguments @('-Mode','general') -WorkingDirectory $candidate -TimeoutSeconds 30 -Environment @{
                    STANDARD_VALIDATION_CORE_RUN_ID='fixture-run'
                    STANDARD_VALIDATION_CORE_CHECK_ID='repository-general'
                    STANDARD_VALIDATION_CORE_SKILLS='fixture'
                }
            $result.exitCode | Should Be 0
            $result.cleanedUp | Should Be $true
            (@($result.processOwnership.cleanup.Uncertainty)-join"`n") | Should Not Match 'unattributed-adopted-child'
        }
    }

    # Scenario: The trusted repository check is invoked by pwsh -File with valid and malformed native parameter tokens.
    # Purpose: Use the normal non-positional parameter binder and fail closed on unknown, duplicate, positional, or invalid values.
    It 'UnitT45_binds_repository_check_parameters_with_the_native_file_contract' {
        $candidate=Join-Path $TestDrive 'repository-check-arguments'
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'config'))
        [void][IO.Directory]::CreateDirectory((Join-Path $candidate 'scripts'))
        [IO.File]::WriteAllText((Join-Path $candidate 'scripts/check.ps1'),"exit 0`n",[Text.UTF8Encoding]::new($false))
        Write-FixtureJson (Join-Path $candidate 'config/consumer-gate.json') ([ordered]@{
                schemaVersion=1;repositoryId='fixture';sourceRepository='https://example.test/fixture.git'
                activeSkills=@('fixture');repositoryChecks=@([ordered]@{id='general';kind='general';path='scripts/check.ps1'})
            })
        $trusted=Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1'
        function Invoke-ArgumentFixture([string[]]$Tokens) {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Process -Id $PID).Path
            $start.WorkingDirectory=$candidate
            $start.UseShellExecute=$false
            $start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            foreach($argument in @('-NoProfile','-NonInteractive','-File',$trusted)+$Tokens){[void]$start.ArgumentList.Add($argument)}
            $start.Environment['STANDARD_VALIDATION_CORE_RUN_ID']='fixture-run'
            $start.Environment['STANDARD_VALIDATION_CORE_CHECK_ID']='repository-general'
            $start.Environment['STANDARD_VALIDATION_CORE_SKILLS']='fixture'
            $process=[Diagnostics.Process]::new()
            try{$process.StartInfo=$start;[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                $process.WaitForExit();[pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result;Error=$stderr.Result}}
            finally{$process.Dispose()}
        }
        $validHash='a'*64
        $cases=@(
            [pscustomobject]@{Name='general';Tokens=@('-Mode','general');Exit=0},
            [pscustomobject]@{Name='case-insensitive';Tokens=@('-mOdE','GENERAL');Exit=0},
            [pscustomobject]@{Name='general-with-pester-values';Tokens=@('-Mode','general','-PesterReceiptSha256',$validHash,
                    '-PesterManifestSha256',$validHash,'-PesterVersion','6.2.0');Exit=0},
            [pscustomobject]@{Name='unknown';Tokens=@('-Unknown','value','-Mode','general');Exit=1},
            [pscustomobject]@{Name='duplicate';Tokens=@('-Mode','general','-Mode','general');Exit=1},
            [pscustomobject]@{Name='missing-value';Tokens=@('-Mode');Exit=1},
            [pscustomobject]@{Name='position';Tokens=@('general');Exit=1},
            [pscustomobject]@{Name='missing-mode';Tokens=@('-PesterVersion','6.2.0');Exit=1},
            [pscustomobject]@{Name='invalid-mode';Tokens=@('-Mode','other');Exit=1},
            [pscustomobject]@{Name='invalid-receipt-hash';Tokens=@('-Mode','general','-PesterReceiptSha256',('A'*64));Exit=1},
            [pscustomobject]@{Name='invalid-manifest-hash';Tokens=@('-Mode','general','-PesterManifestSha256','abc');Exit=1},
            [pscustomobject]@{Name='invalid-version';Tokens=@('-Mode','general','-PesterVersion','6.2');Exit=1},
            [pscustomobject]@{Name='pester-missing-receipt';Tokens=@('-Mode','pester','-PesterManifestSha256',$validHash,'-PesterVersion','6.2.0');Exit=1},
            [pscustomobject]@{Name='pester-missing-manifest';Tokens=@('-Mode','pester','-PesterReceiptSha256',$validHash,'-PesterVersion','6.2.0');Exit=1},
            [pscustomobject]@{Name='pester-missing-version';Tokens=@('-Mode','pester','-PesterReceiptSha256',$validHash,'-PesterManifestSha256',$validHash);Exit=1}
        )
        foreach($case in $cases){
            $result=Invoke-ArgumentFixture $case.Tokens
            if($result.ExitCode-ne$case.Exit){throw "$($case.Name) expected $($case.Exit), got $($result.ExitCode): $($result.Error)"}
            $result.ExitCode|Should Be $case.Exit
        }
        $source=Get-Content -Raw -Encoding UTF8 $trusted;$tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $ast.ParamBlock|Should Not BeNullOrEmpty
        $ast.ParamBlock.Attributes.Extent.Text|Should Match 'CmdletBinding\(PositionalBinding=\$false\)'
        @($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})|Should Be @('Mode','PesterReceiptSha256','PesterManifestSha256','PesterVersion')
        @($ast.ScriptRequirements.RequiredModules).Count|Should Be 0
    }

    # Scenario: Adapter validation sees the frozen pwsh runtime, trusted -File script, another script, and mismatched hashes.
    # Purpose: Close the consumer adapter to one exact pwsh -File repository-check command and its two frozen identities.
    It 'UnitT46_allows_only_the_setup_bound_trusted_pwsh_file_check' {
        $root=Join-Path $TestDrive 'adapter-ps1-closure'
        $trustedRoot=Join-Path $root 'runtime'
        $trustedDirectory=Join-Path $trustedRoot 'trusted'
        [void][IO.Directory]::CreateDirectory($trustedDirectory)
        $trusted=Join-Path $trustedDirectory 'Invoke-ConsumerRepositoryCheck.ps1'
        $other=Join-Path $trustedDirectory 'Other.ps1'
        $powerShell=Join-Path $trustedRoot $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        [IO.File]::WriteAllText($trusted,'exit 0',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($other,'exit 0',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($powerShell,'fixture pwsh',[Text.UTF8Encoding]::new($false))
        $hash=(Get-FileHash $trusted -Algorithm SHA256).Hash.ToLowerInvariant()
        $powerShellHash=(Get-FileHash $powerShell -Algorithm SHA256).Hash.ToLowerInvariant()
        $setupPath=Join-Path $root 'source-tools.json'
        Write-FixtureJson $setupPath ([ordered]@{trustedRoot=$trustedRoot;repositoryCheck=$trusted;pesterReceiptSha256=('a'*64)
                pesterManifestSha256=('b'*64);pesterVersion='6.2.0';sourceValidation=[ordered]@{
                    frozenFiles=@([ordered]@{path=$trusted;sha256=$hash},[ordered]@{path=$powerShell;sha256=$powerShellHash})}})
        $gateSetup=Read-GateJson $setupPath 'adapter setup fixture'
        $valid=@(
            [pscustomobject]@{id='repository-general';kind='general';executable=$powerShell;executableSha256=$powerShellHash
                arguments=@('-NoProfile','-NonInteractive','-File',$trusted,'-Mode','general')},
            [pscustomobject]@{id='repository-pester';kind='pester';executable=$powerShell;executableSha256=$powerShellHash
                arguments=@('-NoProfile','-NonInteractive','-File',$trusted,'-Mode','pester','-PesterReceiptSha256',('a'*64),
                    '-PesterManifestSha256',('b'*64),'-PesterVersion','6.2.0')}
        )
        {Assert-GateAdapterExecutableBindings -Checks @($valid) -Setup $gateSetup -PowerShell $powerShell}|Should Not Throw
        $wrongPath=Copy-FixtureValue $valid;$wrongPath[0].arguments[3]=$other
        {Assert-GateAdapterExecutableBindings -Checks @($wrongPath) -Setup $gateSetup -PowerShell $powerShell}|Should Throw 'trusted pwsh -File'
        $wrongHash=Copy-FixtureValue $valid;$wrongHash[0].executableSha256=('0'*64)
        {Assert-GateAdapterExecutableBindings -Checks @($wrongHash) -Setup $gateSetup -PowerShell $powerShell}|Should Throw 'trusted pwsh -File'
        $missingFrozenFiles=Copy-FixtureValue $gateSetup
        $missingFrozenFiles.sourceValidation.PSObject.Properties.Remove('frozenFiles')
        {Assert-GateAdapterExecutableBindings -Checks @($valid) -Setup $missingFrozenFiles -PowerShell $powerShell}|Should Throw 'frozenFiles array'
        $duplicateSetup=Copy-FixtureValue $gateSetup
        $duplicateSetup.sourceValidation.frozenFiles=@($duplicateSetup.sourceValidation.frozenFiles)+@(
            [pscustomobject]@{path=$trusted;sha256=('0'*64)})
        {Assert-GateAdapterExecutableBindings -Checks @($valid) -Setup $duplicateSetup -PowerShell $powerShell}|Should Throw 'exactly once'
    }

    if($IsWindows){
        # Scenario: The resolver runs in its deny-by-default environment on a native Windows host.
        # Purpose: Preserve the Windows system roots required by PowerShellGet without inheriting the full parent environment.
        It 'UnitT47_preserves_required_windows_resolver_environment_roots' {
            $root=Join-Path $TestDrive 'resolver-windows-environment'
            $authority=Join-Path $root 'authority';$install=Join-Path $root 'install';$source=Join-Path $root 'source-tools'
            foreach($directory in @($authority,$install,$source,(Join-Path $authority 'docs/standards'))){[void][IO.Directory]::CreateDirectory($directory)}
            Copy-GatePlatformRuntimeFixture $authority
            [IO.File]::WriteAllText((Join-Path $authority 'docs/standards/validation-toolchain.json'),'{}',[Text.UTF8Encoding]::new($false))
            $resolver=Join-Path $root 'resolver.ps1'
            [IO.File]::WriteAllText($resolver,@'
param([string]$PolicyPath,[string]$ToolName,[switch]$Install,[string]$InstallRoot,[string]$ExpectedGoRuntimeVersion,[string]$RunId,[string]$OutputPath,
    [int]$AcquisitionTimeoutSeconds)
$names=@('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','LOCALAPPDATA','APPDATA')
$values=[ordered]@{};foreach($name in $names){$values[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
[IO.File]::WriteAllText($OutputPath,($values|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
'@,[Text.UTF8Encoding]::new($false))
            $old=$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH;$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$resolver
            Import-Module $script:GateModule -Force
            try{$result=Invoke-GateResolver (Get-Process -Id $PID).Path $authority $install pester ('a'*32) (Join-Path $source 'receipt-pester.json') latest ''}
            finally{$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$old;Restore-GateFixtureModule}
            foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','LOCALAPPDATA','APPDATA')){
                $parent=[Environment]::GetEnvironmentVariable($name,'Process')
                if($null-ne$parent){[string]$result.$name|Should Be $parent}
            }
        }
    }

    # Scenario: Resolver and validator children fail after writing useful stderr, including one credential sentinel.
    # Purpose: Persist bounded UTF-8 diagnostics, redact credentials before create-only writes, and still fail closed.
    It 'UnitT48_preserves_redacted_resolver_and_validator_failure_diagnostics' {
        $root=Join-Path $TestDrive 'process-diagnostics'
        $authority=Join-Path $root 'authority';$install=Join-Path $root 'install';$source=Join-Path $root 'source-tools'
        foreach($directory in @($authority,$install,$source,(Join-Path $authority 'docs/standards'),(Join-Path $authority 'scripts'))){[void][IO.Directory]::CreateDirectory($directory)}
        Copy-GatePlatformRuntimeFixture $authority
        Import-Module $script:GateModule -Force
        [IO.File]::WriteAllText((Join-Path $authority 'docs/standards/validation-toolchain.json'),'{}',[Text.UTF8Encoding]::new($false))
        $resolver=Join-Path $root 'resolver-failure.ps1'
        [IO.File]::WriteAllText($resolver,"[Console]::Out.Write('resolver out'); [Console]::Error.Write('resolver diagnostic'); exit 7",[Text.UTF8Encoding]::new($false))
        $old=$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH;$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$resolver
        try{{Invoke-GateResolver (Get-Process -Id $PID).Path $authority $install pester ('a'*32) (Join-Path $source 'receipt-pester.json') latest ''}|Should Throw 'Resolver failed'}
        finally{$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$old}
        (Get-Content -Raw (Join-Path $source 'diagnostics/resolver-pester.stderr.txt'))|Should Match 'resolver diagnostic'

        $sentinel='resolver-secret-sentinel'
        $sentinelResolver=Join-Path $root 'resolver-sentinel.ps1'
        [IO.File]::WriteAllText($sentinelResolver,"[Console]::Error.Write(`$env:STANDARD_VALIDATION_GITHUB_API_TOKEN); exit 8",[Text.UTF8Encoding]::new($false))
        $sentinelSource=Join-Path $root 'sentinel-source';[void][IO.Directory]::CreateDirectory($sentinelSource)
        $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$sentinelResolver
        try{{Invoke-GateResolver (Get-Process -Id $PID).Path $authority $install pester ('b'*32) (Join-Path $sentinelSource 'receipt-pester.json') latest $sentinel}|Should Throw 'credential sentinel'}
        finally{$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$old}
        $redacted=Get-Content -Raw (Join-Path $sentinelSource 'diagnostics/resolver-pester.stderr.txt')
        $redacted|Should Match '\[REDACTED\]';$redacted|Should Not Match ([regex]::Escape($sentinel))
        {Assert-GateCredentialAbsent $root $sentinel}|Should Not Throw

        $validatorRoot=Join-Path $root 'validator';$trustedRoot=Join-Path $validatorRoot 'runtime';$trustedDirectory=Join-Path $trustedRoot 'trusted'
        $candidate=Join-Path $validatorRoot 'candidate';$work=Join-Path $validatorRoot 'work'
        foreach($directory in @($trustedDirectory,$candidate,$work,(Join-Path $work 'validation-artifacts'))){[void][IO.Directory]::CreateDirectory($directory)}
        $check=Join-Path $trustedDirectory 'Invoke-ConsumerRepositoryCheck.ps1';[IO.File]::WriteAllText($check,'exit 0',[Text.UTF8Encoding]::new($false))
        $checkHash=(Get-FileHash $check -Algorithm SHA256).Hash.ToLowerInvariant()
        $validatorPowerShell=Join-Path $trustedRoot $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        [IO.File]::WriteAllText($validatorPowerShell,'fixture pwsh',[Text.UTF8Encoding]::new($false))
        $validatorPowerShellHash=(Get-FileHash $validatorPowerShell -Algorithm SHA256).Hash.ToLowerInvariant()
        $setup=[ordered]@{trustedRoot=$trustedRoot;repositoryCheck=$check;pesterReceiptSha256=('a'*64);pesterManifestSha256=('b'*64);pesterVersion='6.2.0'
            sourceValidation=[ordered]@{frozenFiles=@([ordered]@{path=$check;sha256=$checkHash},
                    [ordered]@{path=$validatorPowerShell;sha256=$validatorPowerShellHash})}}
        Write-FixtureJson (Join-Path $work 'source-tools.json') $setup
        $runner=Join-Path $authority 'scripts/Invoke-StandardValidation.ps1'
        [IO.File]::WriteAllText($runner,"[Console]::Out.Write('validator out'); [Console]::Error.Write('validator diagnostic'); exit 9",[Text.UTF8Encoding]::new($false))
        $binding=[pscustomobject]@{candidateRevision=('c'*40);baseRevision=('d'*40);canonicalEvent='pull_request';runId=('e'*32);commit=('f'*40)}
        $config=[pscustomobject]@{sourceRepository='https://example.test/fixture.git';activeSkills=@('fixture')}
        try{
            Mock Import-GatePlatformRuntime {[pscustomobject]@{ExportedCommands=@{
                        'Invoke-PlatformPreparationCommand'={
                            [pscustomobject]@{stdout='validator out';stderr='validator diagnostic';exitCode=9}
                        }
                    }}} -ModuleName ConsumerGate
            {Invoke-GateValidation $authority $candidate $work $binding $config $validatorPowerShell}|Should Throw 'Validator failed'
            (Get-Content -Raw (Join-Path $work 'validation-artifacts/validator.stderr.txt'))|Should Match 'validator diagnostic'
        }finally{Restore-GateFixtureModule}
    }

    # Scenario: The resolver fixture starts a long-lived descendant and exceeds a test-shortened owned-process deadline.
    # Purpose: Resolver timeout arguments, diagnostics, fail-closed state, and complete descendant cleanup remain authority-owned.
    It 'UnitT49_bounds_resolver_and_validator_deadlines_and_cleans_the_resolver_tree' {
        $moduleText=Get-Content -Raw -Encoding UTF8 $script:GateModule
        $tokens=$null;$parseErrors=$null
        $moduleAst=[Management.Automation.Language.Parser]::ParseInput($moduleText,[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count|Should Be 0
        $resolverAst=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateResolver'},$true))[0]
        $validatorAst=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateValidation'},$true))[0]
        $gitCaptureAst=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateOwnedGitCapture'},$true))[0]
        $gitBytesAst=@($moduleAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-GateGitBytes'},$true))[0]
        $resolverAst.Extent.Text|Should Match ([regex]::Escape("'-AcquisitionTimeoutSeconds',([string]`$budget.resolverAcquisitionSeconds)"))
        $validatorAst.Extent.Text|Should Match ([regex]::Escape("'-TimeoutSeconds',([string]`$budget.validatorSeconds)"))
        $resolverAst.Extent.Text|Should Match 'Invoke-PlatformPreparationCommand'
        $validatorAst.Extent.Text|Should Match 'Invoke-PlatformPreparationCommand'
        $moduleText|Should Match 'Start-PlatformOwnedProcess'
        $moduleText|Should Match 'Stop-PlatformOwnedProcess'
        $moduleText|Should Not Match '\[Diagnostics\.Process(?:StartInfo)?\]'
        $moduleText|Should Not Match '\.WaitForExit\s*\('
        $moduleText|Should Match "ExportedCommands\['Start-PlatformOwnedProcess'\]"
        $moduleText|Should Match "ExportedCommands\['Stop-PlatformOwnedProcess'\]"
        $moduleText|Should Match "ExportedCommands\['Resolve-PlatformPhysicalPath'\]"
        $gitBytesAst.Extent.Text|Should Match 'Invoke-GateOwnedGitCapture[\s\S]+-ByteExact'
        $closureText=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1')
        $closureText|Should Match "ExportedCommands\['Start-PlatformOwnedProcess'\]"
        $closureText|Should Match "ExportedCommands\['Stop-PlatformOwnedProcess'\]"
        $closureText|Should Match "ExportedCommands\['Resolve-PlatformPhysicalPath'\]"
        $closureText|Should Not Match '\[Diagnostics\.Process(?:StartInfo)?\]'
        $closureText|Should Not Match '\.WaitForExit\s*\('
        $moduleText|Should Match 'GitByteInvoker=\{[\s\S]+Invoke-GateGitBytes'
        $gitCaptureAst.Extent.Text|Should Match '-ExecutablePath\s+\$git'
        $gitCaptureAst.Extent.Text|Should Match "CaptureProfile\s*=\s*'raw-stdout'"
        $gitCaptureAst.Extent.Text|Should Not Match 'Invoke-GateGitByteCapture|Get-Process\s+-Id\s+\$PID|\.bytes'
        $closureTokens=$null;$closureErrors=$null
        $closureAst=[Management.Automation.Language.Parser]::ParseInput($closureText,[ref]$closureTokens,[ref]$closureErrors)
        @($closureErrors).Count|Should Be 0
        $closureCaptureAst=@($closureAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-ClosureOwnedGitBytes'},$true))[0]
        $closureCaptureAst.Extent.Text|Should Match '-ExecutablePath\s+\$git'
        $closureCaptureAst.Extent.Text|Should Match '-CaptureProfile\s+raw-stdout'
        $closureCaptureAst.Extent.Text|Should Not Match 'Invoke-GateGitByteCapture|Get-Process\s+-Id\s+\$PID|\.bytes'

        $root=Join-Path $TestDrive 'resolver-owned-timeout'
        $authority=Join-Path $root 'authority';$install=Join-Path $root 'install';$source=Join-Path $root 'source-tools'
        foreach($directory in @($authority,$install,$source,(Join-Path $authority 'docs/standards'))){[void][IO.Directory]::CreateDirectory($directory)}
        Copy-GatePlatformRuntimeFixture $authority
        [IO.File]::WriteAllText((Join-Path $authority 'docs/standards/validation-toolchain.json'),'{}',[Text.UTF8Encoding]::new($false))
        $childPidPath=Join-Path $root 'descendant.pid'
        $childScript=Join-Path $root 'resolver-descendant.ps1'
        [IO.File]::WriteAllText($childScript,@'
param([string]$PidPath)
[IO.File]::WriteAllText($PidPath,[string]$PID,[Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 30
'@,[Text.UTF8Encoding]::new($false))
        $resolver=Join-Path $root 'resolver-timeout.ps1'
        $escapedChild=$childScript.Replace("'","''");$escapedPid=$childPidPath.Replace("'","''")
        [IO.File]::WriteAllText($resolver,@"
param([string]`$PolicyPath,[string]`$ToolName,[switch]`$Install,[string]`$InstallRoot,[string]`$ExpectedGoRuntimeVersion,
    [string]`$RunId,[string]`$OutputPath,[int]`$AcquisitionTimeoutSeconds)
`$start=[Diagnostics.ProcessStartInfo]::new()
`$start.FileName=(Get-Process -Id `$PID).Path
`$start.UseShellExecute=`$false
`$start.CreateNoWindow=`$true
`$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
foreach(`$argument in @('-NoProfile','-NonInteractive','-File','$escapedChild','$escapedPid')){[void]`$start.ArgumentList.Add(`$argument)}
`$child=[Diagnostics.Process]::Start(`$start)
[Console]::Out.Write('resolver fixture started')
Start-Sleep -Seconds 30
"@,[Text.UTF8Encoding]::new($false))
        $oldResolver=$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH
        $oldTimeout=$env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS
        try{
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$null
            $env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS='1'
            {Get-GateDeadlineBudget}|Should Throw 'requires the resolver fixture seam'
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$resolver
            $env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS='301'
            {Get-GateDeadlineBudget}|Should Throw 'override is invalid'
        }finally{
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$oldResolver
            $env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS=$oldTimeout
        }
        $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$resolver
        $env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS='2'
        Import-Module $script:GateModule -Force
        try{
            $failure=Get-SourceFixtureFailure {Invoke-GateResolver (Get-Process -Id $PID).Path $authority $install pester `
                ('a'*32) (Join-Path $source 'receipt-pester.json') latest ''}
            $failure|Should Match '^FAILED\|Resolver owned process failed.*deadline'
            Test-Path -LiteralPath (Join-Path $source 'diagnostics/resolver-pester.stdout.txt') -PathType Leaf|Should Be $true
            Test-Path -LiteralPath (Join-Path $source 'diagnostics/resolver-pester.stderr.txt') -PathType Leaf|Should Be $true
            (Get-Content -Raw (Join-Path $source 'diagnostics/resolver-pester.stderr.txt'))|Should Match 'deadline'
            Test-Path -LiteralPath $childPidPath -PathType Leaf|Should Be $true
            $childPid=[int]([IO.File]::ReadAllText($childPidPath))
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue)|Should BeNullOrEmpty
        }finally{
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$oldResolver
            $env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS=$oldTimeout
            Restore-GateFixtureModule
        }
    }

    # Scenario: A Git blob contains bytes that are not valid UTF-8 and is read through the production byte capture path.
    # Purpose: Byte-oriented Git output must never be replacement-decoded or otherwise changed by text capture.
    It 'UnitT49a_preserves_invalid_UTF8_blob_bytes_exactly' {
        $root=Join-Path $TestDrive 'git-byte-exact-blob'
        [void][IO.Directory]::CreateDirectory($root)
        [void](Invoke-SourceFixtureGit $root @('init','-q','-b','main'))
        $expected=[byte[]]@(0x00,0x41,0xff,0x80,0xfe,0x0a)
        $oid=Invoke-SourceFixtureGitWithInputBytes $root @('hash-object','-w','--stdin') $expected
        [byte[]]$actual=Invoke-GateGitBytes $root @('cat-file','blob',$oid)
        [Convert]::ToBase64String($actual)|Should BeExactly ([Convert]::ToBase64String($expected))
    }

    # Scenario: Standalone manifest closure launches a Git shim that exceeds a shortened command deadline.
    # Purpose: Non-gate closure callers must fail closed through the same bounded owned-process boundary.
    It 'UnitT49b_bounds_standalone_closure_Git_deadline' {
        $root=Join-Path $TestDrive 'closure-owned-timeout'
        $shimRoot=Join-Path $root 'shim'
        [void][IO.Directory]::CreateDirectory($shimRoot)
        $childPidPath=Join-Path $root 'child.pid'
        $shimPidPath=Join-Path $root 'shim.pid'
        if($IsWindows){
            [void](New-WindowsGitOwnedProcessShim $shimRoot hang $null $shimPidPath $childPidPath)
        }else{
            $childScript=Join-Path $root 'child.ps1'
            [IO.File]::WriteAllText($childScript,"param([string]`$PidPath)`n[IO.File]::WriteAllText(`$PidPath,[string]`$PID,[Text.UTF8Encoding]::new(`$false))`nStart-Sleep -Seconds 30`n",[Text.UTF8Encoding]::new($false))
            $shell=(Get-Process -Id $PID).Path
            $shim=Join-Path $shimRoot 'git'
            $text="#!/bin/sh`n`"$shell`" -NoProfile -NonInteractive -File `"$childScript`" `"$childPidPath`"`n"
            [IO.File]::WriteAllText($shim,$text,[Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($shim,[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite-bor[IO.UnixFileMode]::UserExecute)
        }
        $manifest=Join-Path $root 'manifest.json'
        Write-FixtureJson $manifest ([ordered]@{repositories=@([ordered]@{id='fixture';inventoryTree=('b'*40);files=@()})})
        $oldPath=$env:PATH
        try{
            $env:PATH=$shimRoot+[IO.Path]::PathSeparator+$oldPath
            $failure=Get-SourceFixtureFailure {Get-ConsumerManifestClosure -RepositoryRoot $root -Commit ('a'*40) `
                -Stage inventory -Manifest $manifest -RepositoryId fixture -AuthorityRoot $script:RepositoryRoot `
                -GitCommandTimeoutSeconds 1 -GitReserveSeconds 2}
            $failure|Should Match 'Manifest closure Git command exceeded its bounded deadline'
            Test-Path -LiteralPath $childPidPath -PathType Leaf|Should Be $true
            if($IsWindows){
                $childPid=[int]([IO.File]::ReadAllText($childPidPath))
                (Get-Process -Id $childPid -ErrorAction SilentlyContinue)|Should BeNullOrEmpty
                Test-Path -LiteralPath $shimPidPath -PathType Leaf|Should Be $true
                $shimPid=[int]([IO.File]::ReadAllText($shimPidPath))
                (Get-Process -Id $shimPid -ErrorAction SilentlyContinue)|Should BeNullOrEmpty
            }
        }finally{
            $env:PATH=$oldPath
            foreach($pidPath in @($childPidPath,$shimPidPath)){
                if(Test-Path -LiteralPath $pidPath -PathType Leaf){
                    $ownedPid=[int]([IO.File]::ReadAllText($pidPath))
                    Get-Process -Id $ownedPid -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Scenario: Every consumer owned-process seam reports an unknown exit status after the child has otherwise completed.
    # Purpose: A null or non-integral exit status must never be coerced to zero or accepted as a successful resolver, validator, Git, byte-Git, or standalone closure result.
    It 'UnitT49c_rejects_unknown_owned_process_exit_statuses' {
        $previousLastExitCode=$global:LASTEXITCODE
        $previousConsoleOut=[Console]::Out
        $previousConsoleError=[Console]::Error
        $consoleOut=[IO.StringWriter]::new()
        $consoleError=[IO.StringWriter]::new()
        $root=Join-Path $TestDrive 'unknown-owned-process-exit'
        $authority=Join-Path $root 'authority';$install=Join-Path $root 'install';$source=Join-Path $root 'source'
        foreach($directory in @($authority,$install,$source,(Join-Path $authority 'docs/standards'),(Join-Path $authority 'scripts'))){
            [void][IO.Directory]::CreateDirectory($directory)
        }
        Copy-GatePlatformRuntimeFixture $authority
        [IO.File]::WriteAllText((Join-Path $authority 'docs/standards/validation-toolchain.json'),'{}',[Text.UTF8Encoding]::new($false))
        $resolver=Join-Path $root 'resolver.ps1';[IO.File]::WriteAllText($resolver,'exit 0',[Text.UTF8Encoding]::new($false))
        $oldResolver=$env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH
        Restore-GateFixtureModule
        $gateModule=(Get-Command Invoke-GateResolver -CommandType Function -ErrorAction Stop).Module
        if($gateModule.Name-cne'ConsumerGate'){throw 'The active resolver command is not owned by ConsumerGate.'}
        $previousGatePlatformRuntimeModule=$gateModule.SessionState.PSVariable.GetValue('GatePlatformRuntimeModule')
        $previousGatePlatformRuntimeAuthorityRoot=$gateModule.SessionState.PSVariable.GetValue('GatePlatformRuntimeAuthorityRoot')
        $previousGateGitHooksPath=$gateModule.SessionState.PSVariable.GetValue('GateGitHooksPath')
        $fakeRuntime=New-Module -Name ("ConsumerGateUnknownExitRuntime_{0}" -f [guid]::NewGuid().ToString('N')) -ScriptBlock {
            function Invoke-PlatformPreparationCommand {
                param($Command,$Arguments,$Environment,$WorkingDirectory,$TimeoutMilliseconds,$PreparationReceipt)
                [pscustomobject]@{stdout='';stderr='';exitCode=$null;processOwnership=$null}
            }
            Export-ModuleMember -Function Invoke-PlatformPreparationCommand
        }
        $closureModule=$null;$previousClosureGitRuntime=$null
        try{
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$resolver
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeModule',$fakeRuntime)
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeAuthorityRoot',[IO.Path]::GetFullPath($authority))
            [Console]::SetOut($consoleOut)
            [Console]::SetError($consoleError)
            {Invoke-GateResolver (Get-Process -Id $PID).Path $authority $install pester ('a'*32) `
                    (Join-Path $source 'receipt-pester.json') latest ''}|Should Throw 'Resolver exit status is unknown.'

            $candidate=Join-Path $root 'candidate';$work=Join-Path $root 'work';$trustedRoot=Join-Path $root 'trusted-runtime'
            $trustedDirectory=Join-Path $trustedRoot 'trusted'
            foreach($directory in @($candidate,$work,$trustedDirectory,(Join-Path $work 'validation-artifacts'))){[void][IO.Directory]::CreateDirectory($directory)}
            $check=Join-Path $trustedDirectory 'Invoke-ConsumerRepositoryCheck.ps1';[IO.File]::WriteAllText($check,'exit 0',[Text.UTF8Encoding]::new($false))
            $checkHash=(Get-FileHash $check -Algorithm SHA256).Hash.ToLowerInvariant()
            $validatorPowerShell=Join-Path $trustedRoot $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            [IO.File]::WriteAllText($validatorPowerShell,'fixture pwsh',[Text.UTF8Encoding]::new($false))
            $validatorPowerShellHash=(Get-FileHash $validatorPowerShell -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-FixtureJson (Join-Path $work 'source-tools.json') ([ordered]@{trustedRoot=$trustedRoot;repositoryCheck=$check
                    pesterReceiptSha256=('b'*64);pesterManifestSha256=('c'*64);pesterVersion='6.2.0'
                    sourceValidation=[ordered]@{frozenFiles=@([ordered]@{path=$check;sha256=$checkHash},
                            [ordered]@{path=$validatorPowerShell;sha256=$validatorPowerShellHash})}})
            [IO.File]::WriteAllText((Join-Path $authority 'scripts/Invoke-StandardValidation.ps1'),'exit 0',[Text.UTF8Encoding]::new($false))
            $binding=[pscustomobject]@{candidateRevision=('d'*40);baseRevision=('e'*40);canonicalEvent='pull_request';runId=('f'*32);commit=('1'*40)}
            $config=[pscustomobject]@{sourceRepository='https://example.test/fixture.git';activeSkills=@('fixture')}
            {Invoke-GateValidation $authority $candidate $work $binding $config $validatorPowerShell}|Should Throw 'Validator exit status is unknown.'

        Mock Invoke-GateOwnedGitCapture {[pscustomobject]@{ExitCode=$null;StdoutBytes=[byte[]]::new(0);StderrBytes=[byte[]]::new(0)}} -ModuleName ConsumerGate
        InModuleScope ConsumerGate {$script:GateGitHooksPath='fixture'}
        {Invoke-GateGit $script:RepositoryRoot @('rev-parse','HEAD')}|Should Throw 'git exit status is unknown.'
        {Invoke-GateGitBytes $script:RepositoryRoot @('rev-parse','HEAD')}|Should Throw 'git exit status is unknown.'

        $closureModule=Import-Module (Join-Path $script:RepositoryRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force -PassThru
        $previousClosureGitRuntime=$closureModule.SessionState.PSVariable.GetValue('ClosureGitRuntime')
        Mock Invoke-ClosureOwnedGitBytes {[pscustomobject]@{ExitCode=$null;Bytes=[byte[]]::new(0);Error=''}} -ModuleName ConsumerManifestClosure
        InModuleScope ConsumerManifestClosure {
            $script:ClosureGitRuntime=[pscustomobject]@{}
            {Invoke-ClosureGitBytes -RepositoryRoot $TestDrive -Arguments @('rev-parse','HEAD')}|Should Throw 'git exit status is unknown.'
        }

        }finally{
            [Console]::SetOut($previousConsoleOut)
            [Console]::SetError($previousConsoleError)
            $consoleOut.Dispose()
            $consoleError.Dispose()
            $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=$oldResolver
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeModule',$previousGatePlatformRuntimeModule)
            $gateModule.SessionState.PSVariable.Set('GatePlatformRuntimeAuthorityRoot',$previousGatePlatformRuntimeAuthorityRoot)
            $gateModule.SessionState.PSVariable.Set('GateGitHooksPath',$previousGateGitHooksPath)
            if($null-ne$closureModule){$closureModule.SessionState.PSVariable.Set('ClosureGitRuntime',$previousClosureGitRuntime)}
            if($null-ne$fakeRuntime){Remove-Module -ModuleInfo $fakeRuntime -Force -ErrorAction SilentlyContinue}
            $global:LASTEXITCODE=$previousLastExitCode
        }
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
            Mock Assert-GateExceptionScannerTransitionEvidence {} -ModuleName ConsumerGate
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
        $coreRunId = '1234567890abcdef1234567890abcdef'
        Remove-Variable StandardValidationPlatformBinding -Scope Script -ErrorAction SilentlyContinue
        . (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -CandidateRoot $TestDrive -AdapterPath 'unused' -ArtifactsRoot $TestDrive `
            -SourceRepository 'https://example.test/consumer-check.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40) -DefineFunctionsOnly
        Initialize-StandardValidationPlatformRuntime
        foreach ($scenario in @('success-file','success-runner','tampered','duplicatepath','partial','duplicate','skipped','notrun')) {
            $workRoot = Join-Path $TestDrive "pester-wrapper-$scenario"
            $candidate = Join-Path $workRoot "$coreRunId/candidate"
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
            foreach ($relative in @('bin/runner.ps1','lib/helper.ps1','en-US/about.txt','Dependencies/dependency.ps1')) {
                $path = Join-Path $installRoot $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                [IO.File]::WriteAllText($path,"fixture $relative`n",[Text.UTF8Encoding]::new($false))
            }
            $closure = @('Pester.psd1','Pester.psm1','bin/runner.ps1','lib/helper.ps1','en-US/about.txt',
                'Dependencies/dependency.ps1') | ForEach-Object {
                [ordered]@{ path=$_
                 sha256=(Get-FileHash (Join-Path $installRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            $ordinalClosure=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach($entry in $closure){$ordinalClosure.Add([string]$entry.path,$entry)}
            $closureText = (@($ordinalClosure.Values | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join '')
            $closureSha = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($closureText))
            ).ToLowerInvariant()
            $manifestSha = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $receiptPath = Join-Path $sourceTools 'receipt-pester.json'
            $receiptClosure=if($scenario-eq'duplicatepath'){@($closure)+@($closure[0])}else{@($closure)}
            Write-FixtureJson $receiptPath ([ordered]@{
                    toolName='pester'
                     resolvedVersion='6.2.0'
                    identityKind='approved-payload-and-installed-closure'
                     frozenForRun=$true
                    installRoot=$installRoot
                     modulePath=$manifestPath
                     executableSha256=$manifestSha
                    dependencyClosure=$receiptClosure
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
                $env:STANDARD_VALIDATION_CORE_RUN_ID = $coreRunId
                $env:STANDARD_VALIDATION_CORE_CHECK_ID = 'fixture-pester'
                $env:STANDARD_VALIDATION_CORE_SKILLS = 'fixture'
                Push-Location $candidate
                try {
                    $trustedCheck=Join-Path $runtime 'Invoke-ConsumerRepositoryCheck.ps1'
                    $checkTokens=@('-Mode','pester','-PesterReceiptSha256',$receiptSha,'-PesterManifestSha256',$manifestSha,
                        '-PesterVersion','6.2.0')
                    if($scenario-ceq'success-runner'){
                        $processResult=Invoke-StandardValidationProcess -Command $trustedCheck -Arguments $checkTokens `
                            -WorkingDirectory $candidate -TimeoutSeconds 60 -Environment @{
                                STANDARD_VALIDATION_CORE_RUN_ID=$coreRunId
                                STANDARD_VALIDATION_CORE_CHECK_ID='fixture-pester'
                                STANDARD_VALIDATION_CORE_SKILLS='fixture'
                            }
                        $output=@($processResult.stdout,$processResult.stderr)
                        $exitCode=[int]$processResult.exitCode
                    }else{
                        $output=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $trustedCheck @checkTokens 2>&1)
                        $exitCode = $LASTEXITCODE
                    }
                }
                finally { Pop-Location }
            }
            finally {
                $env:FAKE_PESTER_SCENARIO = $oldScenario
                $env:STANDARD_VALIDATION_CORE_RUN_ID = $oldRunId
                $env:STANDARD_VALIDATION_CORE_CHECK_ID = $oldCheckId
                $env:STANDARD_VALIDATION_CORE_SKILLS = $oldSkills
            }
            if ($scenario -like 'success-*') {
                if($exitCode-ne0){throw "Scenario $scenario expected exit code 0, got $exitCode. output=$($output-join[Environment]::NewLine)"}
                $exitCode | Should Be 0
                ($output -join "`n") | Should Match '"passed":1'
                (Get-Content -Raw (Join-Path $workRoot "$coreRunId/repository-pester-case-inventory-v1.json") | `
                        ConvertFrom-Json).complete | Should Be $true

                $trustedPath=Join-Path $script:RepositoryRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1'
                $trustedText=Get-Content -Raw -LiteralPath $trustedPath
                $tokens=$null;$errors=$null
                $trustedAst=[Management.Automation.Language.Parser]::ParseInput($trustedText,[ref]$tokens,[ref]$errors)
                @($errors).Count|Should Be 0
                $closureFunction=@($trustedAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                            $node.Name-ceq'Assert-PesterClosure'},$true))[0]
                $orderedAssignment=@($closureFunction.Body.FindAll({param($node)
                            $node-is[Management.Automation.Language.AssignmentStatementAst]-and
                            $node.Left.Extent.Text-ceq'$ordered'},$true))
                @($orderedAssignment).Count|Should Be 1
                $replacement='$ordered=@($entries|Sort-Object -Property path)'
                $mutantText=$trustedText.Remove($orderedAssignment[0].Extent.StartOffset,
                    $orderedAssignment[0].Extent.EndOffset-$orderedAssignment[0].Extent.StartOffset).Insert(
                    $orderedAssignment[0].Extent.StartOffset,$replacement)
                [IO.File]::WriteAllText((Join-Path $runtime 'Invoke-ConsumerRepositoryCheck.ps1'),$mutantText,
                    [Text.UTF8Encoding]::new($false))
                Remove-Item -LiteralPath (Join-Path $workRoot "$coreRunId/repository-pester-case-inventory-v1.json")
                try {
                    $env:FAKE_PESTER_SCENARIO = $scenario
                    $env:STANDARD_VALIDATION_CORE_RUN_ID = $coreRunId
                    $env:STANDARD_VALIDATION_CORE_CHECK_ID = 'fixture-pester'
                    $env:STANDARD_VALIDATION_CORE_SKILLS = 'fixture'
                    Push-Location $candidate
                    try {
                        $mutantOutput=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File `
                                (Join-Path $runtime 'Invoke-ConsumerRepositoryCheck.ps1') -Mode pester `
                                -PesterReceiptSha256 $receiptSha -PesterManifestSha256 $manifestSha `
                                -PesterVersion 6.2.0 2>&1)
                        $mutantExitCode=$LASTEXITCODE
                    }finally{Pop-Location}
                }finally{
                    $env:FAKE_PESTER_SCENARIO = $oldScenario
                    $env:STANDARD_VALIDATION_CORE_RUN_ID = $oldRunId
                    $env:STANDARD_VALIDATION_CORE_CHECK_ID = $oldCheckId
                    $env:STANDARD_VALIDATION_CORE_SKILLS = $oldSkills
                }
                $mutantExitCode|Should Be 1
                ($mutantOutput-join"`n")|Should Match 'Verified Pester closure identity changed'
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
            'General repository check points to a deleted legacy path', 'Assert-GateProtectedFilesWithExceptionShrinkOnly',
            'Unexpected workflow', 'Candidate consumer-gate.yml is missing',
            'Removed legacy path is present', 'Repository has advanced'
        )
        foreach ($required in $requiredBarriers) {
            $module | Should Match ([regex]::Escape($required))
        }
    }
}
