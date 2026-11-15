# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][ValidateSet('success','http-error','timeout','cancellation','redirect-success','redirect-unapproved','redirect-limit')][string]$Outcome,
    [Parameter(Mandatory)][string]$Sentinel,
    [ValidateSet('none','summary','artifact','receipt','stdout','stderr')][string]$LeakSurface='none'
)
$ErrorActionPreference='Stop'
function Invoke-FixtureGit([string]$Root,[string[]]$Arguments){
    $output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1)
    if($LASTEXITCODE-ne0){throw "fixture git failed: $($output -join ' ')"}
    @($output)
}
function Get-FixtureGitScalar([string]$Root,[string[]]$Arguments){
    ([string]@(Invoke-FixtureGit $Root $Arguments)[0]).Trim()
}
function Write-FixtureJson([string]$Path,$Value){
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
}
$authority=Join-Path $FixtureRoot 'authority'
$candidate=Join-Path $FixtureRoot 'candidate'
foreach($directory in @(
        (Join-Path $authority 'consumer/bootstrap'),(Join-Path $authority 'consumer/workflows'),
        (Join-Path $authority 'scripts/consumer'),(Join-Path $authority 'scripts'),
        (Join-Path $authority 'docs/standards'),(Join-Path $candidate 'config'),
        (Join-Path $candidate 'skills/general'),(Join-Path $candidate 'scripts'),
        (Join-Path $candidate '.github/workflows'),(Join-Path $candidate 'tests')
    )){[void][IO.Directory]::CreateDirectory($directory)}
foreach($path in @(
        'consumer/bootstrap/Invoke-PinnedAuthority.ps1','consumer/workflows/consumer-gate.yml',
        'consumer/workflows/consumer-gate-transition.yml','scripts/consumer/ConsumerGate.psm1',
        'scripts/consumer/Invoke-ConsumerSourceGate.ps1','scripts/consumer/Invoke-ConsumerValidationChild.ps1',
        'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1','scripts/Invoke-StandardValidation.ps1',
        'scripts/Validate-UpstreamAdapter.ps1','docs/standards/upstream-adapter.json',
        'docs/standards/validation-toolchain.json'
    )){
    $destination=Join-Path $authority $path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $path) -Destination $destination
}
$manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json -Depth 100
$general=@($manifest.repositories|Where-Object id -eq 'skill-general')[0]
$general.repository='https://example.test/fixture.git'
Write-FixtureJson (Join-Path $authority 'consumer/legacy-migration.json') $manifest
Copy-Item (Join-Path $authority 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') (Join-Path $candidate 'scripts/Invoke-PinnedAuthority.ps1')
Copy-Item (Join-Path $authority 'consumer/workflows/consumer-gate.yml') (Join-Path $candidate '.github/workflows/consumer-gate.yml')
$skillText=@'
---
name: general
description: fixture
---
'@
[IO.File]::WriteAllText((Join-Path $candidate 'skills/general/SKILL.md'),$skillText,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $candidate 'scripts/Test-SkillGeneral.ps1'),'exit 0',[Text.UTF8Encoding]::new($false))
Write-FixtureJson (Join-Path $candidate 'config/consumer-gate.json') ([ordered]@{
        schemaVersion=1;repositoryId='skill-general';sourceRepository='https://example.test/fixture.git'
        activeSkills=@('general');repositoryChecks=@(
            [ordered]@{id='repository-general';kind='general';path='scripts/Test-SkillGeneral.ps1'},
            [ordered]@{id='repository-pester';kind='pester';path='tests'}
        )
    })
[void](Invoke-FixtureGit $candidate @('init','-q','-b','main'))
[void](Invoke-FixtureGit $candidate @('config','user.name','Fixture'))
[void](Invoke-FixtureGit $candidate @('config','user.email','fixture@example.test'))
[void](Invoke-FixtureGit $candidate @('add','.'))
[void](Invoke-FixtureGit $candidate @('commit','-q','-m','base'))
$baseRevision=Get-FixtureGitScalar $candidate @('rev-parse','HEAD')
[IO.File]::WriteAllText((Join-Path $candidate 'candidate.txt'),'candidate',[Text.UTF8Encoding]::new($false))
[void](Invoke-FixtureGit $candidate @('add','.'))
[void](Invoke-FixtureGit $candidate @('commit','-q','-m','candidate'))
$candidateRevision=Get-FixtureGitScalar $candidate @('rev-parse','HEAD')
$work=Join-Path $FixtureRoot 'work'
[void][IO.Directory]::CreateDirectory($work)
$platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
$binding=[ordered]@{schemaVersion=1;scope='platform';interface='consumer-gate-v1'
    repository='https://example.test/fixture.git';commit=('a'*40);aiiMainTip=('b'*40);treeSha=('c'*40)
    baseRevision=$baseRevision;candidateRevision=$candidateRevision;headRevision=$candidateRevision
    triggerEvent='pull_request_target';runId=('d'*32);platform=$platform;pinSha256=('e'*64);bootstrapSha256=('f'*64)}
$bindingPath=Join-Path $work 'authority-binding.json'
Write-FixtureJson $bindingPath $binding
$assetBytes=[Text.UTF8Encoding]::new($false).GetBytes('fixture archive')
$assetSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
$assetName="PowerShell-7.99.1-win-$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()).zip"
if($platform-eq'linux'){$assetName="powershell-7.99.1-linux-$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()).tar.gz"}
if($platform-eq'macos'){$assetName="powershell-7.99.1-osx-$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()).tar.gz"}
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$probe.Start()
$port=([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
$ready=Join-Path $FixtureRoot 'http.ready'
$headerLog=Join-Path $FixtureRoot 'http-headers.jsonl'
$httpFixture=Join-Path $RepositoryRoot 'tests/fixtures/consumer-gate-http-fixture.ps1'
$serverStart=[Diagnostics.ProcessStartInfo]::new()
$serverStart.FileName=(Get-Process -Id $PID).Path
$serverStart.UseShellExecute=$false
foreach($argument in @('-NoProfile','-NonInteractive','-File',$httpFixture,'-Port',[string]$port,'-Mode',$Outcome,
        '-ReadyPath',$ready,'-AssetName',$assetName,'-AssetSha256',$assetSha,'-Sentinel',$Sentinel,'-HeaderLogPath',$headerLog)){
    [void]$serverStart.ArgumentList.Add($argument)
}
$server=[Diagnostics.Process]::new()
$server.StartInfo=$serverStart
[void]$server.Start()
$deadline=[DateTime]::UtcNow.AddSeconds(5)
while(-not(Test-Path -LiteralPath $ready)-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 25}
if(-not(Test-Path -LiteralPath $ready)){throw 'HTTP fixture did not start.'}
$cancelPath=Join-Path $FixtureRoot 'cancel.signal'
$canceller=$null
if($Outcome-eq'cancellation'){
    $cancelStart=[Diagnostics.ProcessStartInfo]::new()
    $cancelStart.FileName=(Get-Process -Id $PID).Path
    $cancelStart.UseShellExecute=$false
    $command="Start-Sleep -Milliseconds 350; [IO.File]::WriteAllText('$($cancelPath.Replace("'","''"))','cancel')"
    foreach($argument in @('-NoProfile','-NonInteractive','-Command',$command)){[void]$cancelStart.ArgumentList.Add($argument)}
    $canceller=[Diagnostics.Process]::new()
    $canceller.StartInfo=$cancelStart
    [void]$canceller.Start()
}
$summary=Join-Path $FixtureRoot 'summary.txt'
$artifactRoot=Join-Path $FixtureRoot 'artifacts'
[void][IO.Directory]::CreateDirectory($artifactRoot)
$resolverSource=Join-Path $RepositoryRoot 'tests/fixtures/consumer-gate-resolver-fixture.ps1'
$resolverPath=$resolverSource
if($LeakSurface-in@('stdout','stderr')){
    $resolverPath=Join-Path $FixtureRoot 'resolver-output-leak.ps1'
    $streamStatement=if($LeakSurface-eq'stdout'){'[Console]::Out.Write($env:STANDARD_VALIDATION_GITHUB_API_TOKEN)'}else{
        '[Console]::Error.Write($env:STANDARD_VALIDATION_GITHUB_API_TOKEN)'}
    [IO.File]::WriteAllText($resolverPath,(Get-Content -Raw -LiteralPath $resolverSource)+[Environment]::NewLine+$streamStatement,
        [Text.UTF8Encoding]::new($false))
}
if($LeakSurface-eq'summary'){[IO.File]::WriteAllText($summary,$Sentinel,[Text.UTF8Encoding]::new($false))}
if($LeakSurface-eq'artifact'){[IO.File]::WriteAllText((Join-Path $artifactRoot 'artifact.txt'),$Sentinel,[Text.UTF8Encoding]::new($false))}
if($LeakSurface-eq'receipt'){[IO.File]::WriteAllText((Join-Path $work 'fixture-receipt.json'),$Sentinel,[Text.UTF8Encoding]::new($false))}
$runtimeSource=Join-Path $FixtureRoot 'runtime-source'
[void][IO.Directory]::CreateDirectory($runtimeSource)
foreach($file in @(Get-ChildItem -LiteralPath $PSHOME -File -Force)){
    $target=Join-Path $runtimeSource $file.Name
    try{[void](New-Item -ItemType HardLink -Path $target -Target $file.FullName -ErrorAction Stop)}
    catch{[IO.File]::Copy($file.FullName,$target,$false)}
}
$eventLog=Join-Path $work 'events.log'
[void][IO.Directory]::CreateDirectory((Join-Path $work 'source-tools'))
$sentinelHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Sentinel))).ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $work 'source-tools/credential-sentinel.sha256'),$sentinelHash,[Text.UTF8Encoding]::new($false))
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=(Get-Process -Id $PID).Path
$start.UseShellExecute=$false
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
foreach($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $authority 'scripts/consumer/Invoke-ConsumerSourceGate.ps1'),
        '-Interface','consumer-gate-v1','-Phase','prepare','-AuthorityBindingPath',$bindingPath,
        '-BaseRoot',$candidate,'-CandidateRoot',$candidate,'-WorkRoot',$work,'-Platform',$platform)){
    [void]$start.ArgumentList.Add($argument)
}
$start.Environment['CONSUMER_GATE_EVENT_REPOSITORY']='https://example.test/fixture.git'
$start.Environment['STANDARD_VALIDATION_GITHUB_API_TOKEN']=$Sentinel
$start.Environment['GITHUB_TOKEN']=$Sentinel
$start.Environment['GH_TOKEN']=$Sentinel
$start.Environment['CONSUMER_GATE_POWERSHELL_METADATA_URI']="http://127.0.0.1:$port/metadata"
$start.Environment['CONSUMER_GATE_RUNTIME_SOURCE_ROOT']=$runtimeSource
$start.Environment['CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH']=[IO.Path]::GetFileName((Get-Process -Id $PID).Path)
$start.Environment['CONSUMER_GATE_RESOLVER_SCRIPT_PATH']=$resolverPath
$start.Environment['CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS']=if($Outcome-eq'timeout'){'1'}else{'10'}
$start.Environment['CONSUMER_GATE_ACQUISITION_CANCEL_PATH']=$cancelPath
$start.Environment['CONSUMER_GATE_EVENT_LOG_PATH']=$eventLog
$start.Environment['GITHUB_STEP_SUMMARY']=$summary
$start.Environment['CONSUMER_GATE_ARTIFACT_PATHS']=$artifactRoot
$process=[Diagnostics.Process]::new()
try{
    $process.StartInfo=$start
    [void]$process.Start()
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout=$stdoutTask.GetAwaiter().GetResult()
    $stderr=$stderrTask.GetAwaiter().GetResult()
    $surfaceLeaks=[Collections.Generic.List[string]]::new()
    foreach($surface in @($work,$artifactRoot,$summary)){
        if(-not(Test-Path -LiteralPath $surface)){continue}
        $item=Get-Item -LiteralPath $surface
        $files=if($item.PSIsContainer){@(Get-ChildItem -LiteralPath $surface -Recurse -File)}else{@($item)}
        foreach($file in $files){
            $content=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
            if($content.Contains($Sentinel,[StringComparison]::Ordinal)){$surfaceLeaks.Add($file.FullName)}
        }
    }
    $resolverDumps=@()
    foreach($tool in @('pester','skill-validator','skill-tools','skillspector')){
        $path=Join-Path $work "source-tools/environment-$tool.json"
        if(Test-Path -LiteralPath $path){$resolverDumps+=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}
    }
    $events=@(if(Test-Path -LiteralPath $eventLog){Get-Content -LiteralPath $eventLog})
    $result=[ordered]@{exitCode=$process.ExitCode;stdout=$stdout;stderr=$stderr
        outputContainsSentinel=(($stdout+$stderr).Contains($Sentinel,[StringComparison]::Ordinal))
        surfaceLeaks=@($surfaceLeaks);resolverDumps=@($resolverDumps)
        events=$events}
    [Console]::Out.WriteLine(($result|ConvertTo-Json -Depth 20 -Compress))
}finally{
    $process.Dispose()
    if($null-ne$canceller){[void]$canceller.WaitForExit(3000);$canceller.Dispose()}
    if(-not$server.WaitForExit(3000)){$server.Kill($true);$server.WaitForExit()}
    $server.Dispose()
}
