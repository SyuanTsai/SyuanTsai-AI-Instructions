# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('leg','aggregate')][string]$Mode,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][ValidateSet('windows','linux','macos','aggregate')][string]$Platform,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string]$WorkflowRunId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$WorkflowRunAttempt,
    [string]$LegReceiptsRoot,
    [switch]$FixtureOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$requestedMode=$Mode;$requestedPlatform=$Platform
. (Join-Path $PSScriptRoot 'Invoke-ConsumerTransitionProbe.ps1') -Mode leg -RepositoryRoot $RepositoryRoot `
    -WorkRoot $WorkRoot -Platform windows -WorkflowRunId $WorkflowRunId -WorkflowRunAttempt $WorkflowRunAttempt -DefineFunctionsOnly
$Mode=$requestedMode;$Platform=$requestedPlatform
Remove-Variable requestedMode,requestedPlatform

$script:ProbeAuthorityRepository='https://example.test/consumer-repin-authority.git'
$script:ProbeConsumerRepository='https://example.test/example/consumer-repin-fixture.git'
$script:OfficialAuthorityRepository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:OldAuthorityRevision='7338a3f6d8e2d25849b79627fb9a2cbd21ebd123'

function ConvertTo-RepinBootstrapProjection([string]$Text){
    $text=$Text
    if(-not$text.Contains($script:OfficialAuthorityRepository,[StringComparison]::Ordinal)){
        throw 'Re-pin bootstrap has no official authority URL anchor.'
    }
    $text=$text.Replace($script:OfficialAuthorityRepository,$script:ProbeAuthorityRepository)
    $call='New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit)'
    $replacement="New-PinnedAuthority `$WorkRoot ([string]`$pin.Value.commit) ([Environment]::GetEnvironmentVariable('CONSUMER_REPIN_PROBE_AUTHORITY_URL','Process')) -AllowFileProtocol"
    if(-not$text.Contains($call,[StringComparison]::Ordinal)){throw 'Re-pin bootstrap acquisition anchor is missing.'}
    $text=$text.Replace($call,$replacement)
    $anchor='    Assert-AuthorityTree $gitRoot $authorityRoot $Commit'
    $originReset=$anchor+"`n    [void](Invoke-PinnedGit `$gitRoot @('remote','set-url','origin','$($script:OfficialAuthorityRepository)') -AllowFileProtocol)"
    if(-not$text.Contains($anchor,[StringComparison]::Ordinal)){throw 'Re-pin bootstrap tree-verification anchor is missing.'}
    $text.Replace($anchor,$originReset)
}
function Set-RepinBootstrapProjection([string]$Path){
    Write-ProbeUtf8 $Path (ConvertTo-RepinBootstrapProjection (Get-Content -Raw -Encoding UTF8 $Path))
}
function Replace-RepinFile([string]$Source,[string]$Destination){
    if(Test-Path -LiteralPath $Destination -PathType Leaf){[IO.File]::Delete($Destination)}
    Copy-ProbeFile $Source $Destination
}
function Test-RepinBytesEqual([byte[]]$Left,[byte[]]$Right){
    $Left.Length-eq$Right.Length-and
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Left))-ceq
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Right))
}
function Get-RepinRepositoryChecks {
    @(
        [pscustomobject][ordered]@{id='repository-general';kind='general';path='scripts/Test-FixtureRepository.ps1'},
        [pscustomobject][ordered]@{id='repository-pester';kind='pester';path='tests'}
    )
}
function Copy-RepinCurrentAuthority([string]$SourceRoot,[string]$DestinationRoot){
    [void](Invoke-ProbeGit $DestinationRoot @('rm','-r','--quiet','--ignore-unmatch','.'))
    $paths=@((Invoke-ProbeGit $SourceRoot @('ls-files','--cached','--others','--exclude-standard')).Output|
        ForEach-Object{[string]$_}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    foreach($relative in $paths){Copy-ProbeFile (Join-Path $SourceRoot $relative) (Join-Path $DestinationRoot $relative)}
}
function New-RepinAuthority([string]$SourceRoot,[string]$Root){
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-ProbeGit $Root @('init','--quiet','-b','main'));Set-ProbeGitIdentity $Root
    [void](Invoke-ProbeGit $SourceRoot @('cat-file','-e',"$($script:OldAuthorityRevision)^{commit}"))
    $sourceCommonDirectory=Get-ProbeGitScalar $SourceRoot @('rev-parse','--path-format=absolute','--git-common-dir')
    $sourceObjectDirectory=Join-Path $sourceCommonDirectory 'objects'
    if(-not(Test-Path -LiteralPath $sourceObjectDirectory -PathType Container)){
        throw 'Re-pin source Git object directory is missing.'
    }
    Write-ProbeUtf8 (Join-Path $Root '.git/objects/info/alternates') ([IO.Path]::GetFullPath($sourceObjectDirectory)+"`n")
    [void](Invoke-ProbeGit $Root @('update-ref','refs/heads/main',$script:OldAuthorityRevision))
    [void](Invoke-ProbeGit $Root @('reset','--hard','--quiet',$script:OldAuthorityRevision))
    $oldCommit=Get-ProbeGitScalar $Root @('rev-parse','HEAD^{commit}')
    if($oldCommit-cne$script:OldAuthorityRevision){throw 'Re-pin old authority revision mismatch.'}
    $oldTree=Get-ProbeGitScalar $Root @('rev-parse','HEAD^{tree}')
    $sourceOldTree=Get-ProbeGitScalar $SourceRoot @('rev-parse',"$($script:OldAuthorityRevision)^{tree}")
    if($oldTree-cne$sourceOldTree){throw 'Re-pin old authority tree is not the exact 7338a3f tree.'}
    $oldBootstrap=Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
    $oldWorkflow=Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'consumer/workflows/consumer-gate.yml')

    Copy-RepinCurrentAuthority $SourceRoot $Root
    Set-RepinBootstrapProjection (Join-Path $Root 'consumer/bootstrap/Invoke-PinnedAuthority.ps1')
    $manifestPath=Join-Path $Root 'consumer/legacy-migration.json'
    $manifest=Get-Content -Raw -Encoding UTF8 $manifestPath|ConvertFrom-Json -Depth 100
    $entry=@($manifest.repositories|Where-Object id -eq 'skill-general')
    if($entry.Count-ne1){throw 'Re-pin authority has no unique skill-general manifest entry.'}
    $entry=$entry[0]
    $entry.repository=$script:ProbeConsumerRepository
    $entry.status='ready'
    $entry.requiredRepositoryChecks=@(Get-RepinRepositoryChecks)
    $entry.files=@([pscustomobject][ordered]@{
            path='scripts/Legacy.ps1';disposition='delete';reason='Replaced by the consumer transition fixture check.'})
    foreach($name in @('additionalScope','prerequisites','literalReferenceExemptions')){$entry.PSObject.Properties.Remove($name)}
    Write-ProbeJson $manifestPath $manifest
    $newCommit=Complete-ProbeCommit $Root 'consumer re-pin probe authority'
    [pscustomobject]@{OldCommit=$oldCommit;OldTree=$oldTree;NewCommit=$newCommit;OldBootstrap=$oldBootstrap
        OldBootstrapProjected=ConvertTo-RepinBootstrapProjection $oldBootstrap;OldWorkflow=$oldWorkflow}
}
function New-RepinConsumer([string]$Root,[string]$FixtureRoot,$Authority){
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-ProbeGit $Root @('init','--quiet','-b','main'));Set-ProbeGitIdentity $Root
    [void](Invoke-ProbeGit $Root @('remote','add','origin',$script:ProbeConsumerRepository))
    foreach($relative in @('skills/fixture/SKILL.md','scripts/Test-FixtureRepository.ps1')){
        Copy-ProbeFile (Join-Path $FixtureRoot "candidate/$relative") (Join-Path $Root $relative)
    }
    Copy-ProbeFile (Join-Path $FixtureRoot 'candidate/tests/Fixture.Tests.ps1.template') (Join-Path $Root 'tests/Fixture.Tests.ps1')
    foreach($directory in @('config','.github/workflows')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $directory))}
    Write-ProbeUtf8 (Join-Path $Root 'scripts/Invoke-PinnedAuthority.ps1') $Authority.OldBootstrapProjected
    Write-ProbeUtf8 (Join-Path $Root '.github/workflows/consumer-gate.yml') $Authority.OldWorkflow
    Write-ProbeJson (Join-Path $Root 'config/authority-pin.json') ([ordered]@{
            schemaVersion=1;repository=$script:ProbeAuthorityRepository;commit=$Authority.OldCommit})
    Write-ProbeJson (Join-Path $Root 'config/consumer-gate.json') ([ordered]@{
            schemaVersion=1;repositoryId='skill-general';sourceRepository=$script:ProbeConsumerRepository;activeSkills=@('fixture')
            repositoryChecks=@(Get-RepinRepositoryChecks)})
    $base=Complete-ProbeCommit $Root 'consumer re-pin probe base'
    [void](Invoke-ProbeGit $Root @('checkout','--quiet','-b','repin-topic'))
    Replace-RepinFile (Join-Path $script:ProbeAuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') `
        (Join-Path $Root 'scripts/Invoke-PinnedAuthority.ps1')
    Replace-RepinFile (Join-Path $script:ProbeAuthorityRoot 'consumer/workflows/consumer-gate.yml') `
        (Join-Path $Root '.github/workflows/consumer-gate.yml')
    Write-ProbeJson (Join-Path $Root 'config/authority-pin.json') ([ordered]@{
            schemaVersion=1;repository=$script:ProbeAuthorityRepository;commit=$Authority.NewCommit})
    $head=Complete-ProbeCommit $Root 'consumer re-pin probe candidate'
    [void](Invoke-ProbeGit $Root @('checkout','--quiet','main'))
    [void](Invoke-ProbeGit $Root @('merge','--quiet','--no-ff','repin-topic','-m','consumer re-pin probe merge'))
    [pscustomobject]@{Base=$base;Head=$head;Candidate=Get-ProbeGitScalar $Root @('rev-parse','HEAD^{commit}')}
}
function Invoke-RepinBootstrap([string]$Bootstrap,[string]$Phase,[string]$GateRoot,[string]$BaseRoot,[string]$CandidateRoot,$Revision,
    [string]$PlatformValue,[int[]]$AllowedExitCodes=@(0)){
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Bootstrap -Phase $Phase -BaseRoot $BaseRoot `
        -CandidateRoot $CandidateRoot -WorkRoot $GateRoot -TriggerEvent pull_request_target -BaseRevision $Revision.Base `
        -CandidateRevision $Revision.Candidate -HeadRevision $Revision.Head -WorkflowRunId $WorkflowRunId `
        -WorkflowRunAttempt $WorkflowRunAttempt -Platform $PlatformValue
    $exitCode=$LASTEXITCODE
    if($exitCode-notin$AllowedExitCodes){throw "Consumer re-pin probe phase '$Phase' failed with exit code $exitCode."}
    $exitCode
}
function Get-RepinOutputExcerpt([string]$Output,[int]$Limit=4096){
    if($null-eq$Output-or$Output.Length-le$Limit){return $Output}
    $marker="`n... output truncated ...`n";$half=[int][Math]::Floor(($Limit-$marker.Length)/2)
    $Output.Substring(0,$half)+$marker+$Output.Substring($Output.Length-$half)
}
function Invoke-RepinBootstrapCaptured([string]$Bootstrap,[string]$Phase,[string]$GateRoot,[string]$BaseRoot,
    [string]$CandidateRoot,$Revision,[string]$PlatformValue){
    $captureRoot=Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($GateRoot))) ".repin-bootstrap-capture-$([guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($captureRoot)
    $stdoutPath=Join-Path $captureRoot 'bootstrap.stdout';$stderrPath=Join-Path $captureRoot 'bootstrap.stderr'
    try{
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Bootstrap -Phase $Phase -BaseRoot $BaseRoot `
            -CandidateRoot $CandidateRoot -WorkRoot $GateRoot -TriggerEvent pull_request_target -BaseRevision $Revision.Base `
            -CandidateRevision $Revision.Candidate -HeadRevision $Revision.Head -WorkflowRunId $WorkflowRunId `
            -WorkflowRunAttempt $WorkflowRunAttempt -Platform $PlatformValue 1> $stdoutPath 2> $stderrPath
        $exitCode=$LASTEXITCODE
        $stdout=[IO.File]::ReadAllText($stdoutPath,[Text.UTF8Encoding]::new($false,$true))
        $stderr=[IO.File]::ReadAllText($stderrPath,[Text.UTF8Encoding]::new($false,$true))
        [Console]::Out.Write($stdout);[Console]::Error.Write($stderr)
        $sections=[Collections.Generic.List[string]]::new()
        $sections.Add("=== bootstrap stdout ===`n$stdout");$sections.Add("=== bootstrap stderr ===`n$stderr")
        $diagnosticRoot=Join-Path $GateRoot 'bootstrap-supervisor-diagnostics'
        if(Test-Path -LiteralPath $diagnosticRoot -PathType Container){
            foreach($path in @(Get-ChildItem -LiteralPath $diagnosticRoot -File -Filter '*.txt'|Sort-Object Name)){
                $content=[IO.File]::ReadAllText($path.FullName,[Text.UTF8Encoding]::new($false,$true))
                $sections.Add("=== diagnostic $($path.Name) ===`n$content")
            }
        }
        [pscustomobject]@{ExitCode=$exitCode;Output=$sections-join"`n"}
    }finally{
        if([IO.Directory]::Exists($captureRoot)){[IO.Directory]::Delete($captureRoot,$true)}
    }
}
function Assert-RepinNegativeBootstrapResult($Result){
    $expected='Candidate bootstrap differs from both authority template and base.'
    if([int]$Result.ExitCode-ne20-or-not([string]$Result.Output).Contains($expected,[StringComparison]::Ordinal)){
        $excerpt=Get-RepinOutputExcerpt ([string]$Result.Output)
        throw "Consumer re-pin negative bootstrap returned exit code $($Result.ExitCode); expected 20 with '$expected'.`nCaptured output (truncated):`n$excerpt"
    }
}
function New-RepinNegativeCandidate([string]$ConsumerRoot,$Revision){
    [void](Invoke-ProbeGit $ConsumerRoot @('checkout','--quiet','-b','negative-topic',$Revision.Base))
    Replace-RepinFile (Join-Path $script:ProbeAuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') `
        (Join-Path $ConsumerRoot 'scripts/Invoke-PinnedAuthority.ps1')
    [IO.File]::AppendAllText((Join-Path $ConsumerRoot 'scripts/Invoke-PinnedAuthority.ps1'),"`n# unauthorized bootstrap drift`n",
        [Text.UTF8Encoding]::new($false))
    Replace-RepinFile (Join-Path $script:ProbeAuthorityRoot 'consumer/workflows/consumer-gate.yml') `
        (Join-Path $ConsumerRoot '.github/workflows/consumer-gate.yml')
    Write-ProbeJson (Join-Path $ConsumerRoot 'config/authority-pin.json') ([ordered]@{
            schemaVersion=1;repository=$script:ProbeAuthorityRepository;commit=$script:ProbeAuthorityCommit})
    $head=Complete-ProbeCommit $ConsumerRoot 'consumer re-pin negative candidate'
    [void](Invoke-ProbeGit $ConsumerRoot @('checkout','--quiet','-B','negative-main',$Revision.Base))
    [void](Invoke-ProbeGit $ConsumerRoot @('merge','--quiet','--no-ff','negative-topic','-m','consumer re-pin negative merge'))
    [pscustomobject]@{Base=$Revision.Base;Head=$head;Candidate=Get-ProbeGitScalar $ConsumerRoot @('rev-parse','HEAD^{commit}')}
}
function Invoke-RepinNegativeCandidate([string]$ConsumerRoot,[string]$BaseRoot,[string]$Bootstrap,$Revision){
    $negative=New-RepinNegativeCandidate $ConsumerRoot $Revision
    $negativeGate=Join-Path (Split-Path -Parent $ConsumerRoot) 'negative-gate'
    $result=Invoke-RepinBootstrapCaptured $Bootstrap prepare $negativeGate $BaseRoot $ConsumerRoot $negative $Platform
    Assert-RepinNegativeBootstrapResult $result
}
function Assert-RepinFixture([string]$BaseRoot,[string]$ConsumerRoot,$Authority,$Revision){
    $baseBootstrap=[IO.File]::ReadAllBytes((Join-Path $BaseRoot 'scripts/Invoke-PinnedAuthority.ps1'))
    $oldTemplate=[Text.UTF8Encoding]::new($false).GetBytes([string]$Authority.OldBootstrapProjected)
    if(-not(Test-RepinBytesEqual $baseBootstrap $oldTemplate)){throw 'Re-pin base bootstrap differs from the projected 7338a3f template.'}
    $candidateBootstrap=[IO.File]::ReadAllBytes((Join-Path $ConsumerRoot 'scripts/Invoke-PinnedAuthority.ps1'))
    $newTemplate=[IO.File]::ReadAllBytes((Join-Path $script:ProbeAuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'))
    if(-not(Test-RepinBytesEqual $candidateBootstrap $newTemplate)){throw 'Re-pin candidate bootstrap differs from the new authority template.'}
    $basePin=Get-Content -Raw -Encoding UTF8 (Join-Path $BaseRoot 'config/authority-pin.json')|ConvertFrom-Json
    $candidatePin=Get-Content -Raw -Encoding UTF8 (Join-Path $ConsumerRoot 'config/authority-pin.json')|ConvertFrom-Json
    if([string]$basePin.commit-cne[string]$Authority.OldCommit-or[string]$candidatePin.commit-cne[string]$Authority.NewCommit){
        throw 'Re-pin base and candidate pins do not bind the old and new authority commits.'
    }
    $expectedChanges=@('.github/workflows/consumer-gate.yml','config/authority-pin.json','scripts/Invoke-PinnedAuthority.ps1')
    $actualChanges=@((Invoke-ProbeGit $ConsumerRoot @('diff','--name-only',$Revision.Base,$Revision.Head)).Output|
        ForEach-Object{[string]$_}|Where-Object{$_}|Sort-Object)
    if(($actualChanges-join"`n")-cne($expectedChanges-join"`n")){
        throw "Re-pin candidate changed an unexpected path set: $($actualChanges-join', ')"
    }
    foreach($root in @($BaseRoot,$ConsumerRoot)){
        $workflows=@((Invoke-ProbeGit $root @('ls-files','--','.github/workflows')).Output|
            ForEach-Object{[string]$_}|Where-Object{$_})
        if($workflows.Count-ne1-or$workflows[0]-cne'.github/workflows/consumer-gate.yml'){
            throw 'Re-pin fixture must contain only the post-transition consumer workflow.'
        }
        $config=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'config/consumer-gate.json')|ConvertFrom-Json -Depth 100
        $skills=@((Invoke-ProbeGit $root @('ls-files','--','skills/*/SKILL.md')).Output|
            ForEach-Object{[string]$_}|Where-Object{$_}|ForEach-Object{($_-split'/')[1]}|Sort-Object)
        if((@([string[]]$config.activeSkills|Sort-Object)-join"`n")-cne($skills-join"`n")){
            throw 'Re-pin activeSkills differs from the tracked Skill inventory.'
        }
    }
    $parents=@((Invoke-ProbeGit $ConsumerRoot @('rev-list','--parents','-n','1',$Revision.Candidate)).Output[0]-split' ')
    if($parents.Count-ne3-or$parents[0]-cne$Revision.Candidate-or$parents[1]-cne$Revision.Base-or$parents[2]-cne$Revision.Head){
        throw 'Re-pin candidate merge parents are invalid.'
    }
}

$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot);$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $WorkRoot){throw 'Re-pin probe WorkRoot must not already exist.'}
[void][IO.Directory]::CreateDirectory($WorkRoot)
$fixtureRoot=Join-Path $RepositoryRoot 'tests/fixtures/consumer-transition-probe'
$consumerRoot=Join-Path $WorkRoot 'consumer-source';$authorityRoot=Join-Path $WorkRoot 'authority-source'
$baseRoot=Join-Path $WorkRoot 'base';$gateRoot=Join-Path $WorkRoot 'gate';$fixedDate='2026-01-01T00:00:00Z'
$savedEnvironment=@{}
foreach($name in @('GIT_AUTHOR_DATE','GIT_COMMITTER_DATE','RUNNER_TEMP','CONSUMER_REPIN_PROBE_AUTHORITY_URL',
        'CONSUMER_GATE_TEST_TEMP_ROOT','CONSUMER_GATE_EVENT_REPOSITORY','STANDARD_GO_RUNTIME_VERSION','STANDARD_VALIDATION_GITHUB_API_TOKEN')){
    $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
try{
    $env:GIT_AUTHOR_DATE=$fixedDate;$env:GIT_COMMITTER_DATE=$fixedDate
    $script:ProbeAuthorityRoot=$authorityRoot;$authority=New-RepinAuthority $RepositoryRoot $authorityRoot
    $script:ProbeAuthorityCommit=$authority.NewCommit
    $revision=New-RepinConsumer $consumerRoot $fixtureRoot $authority
    [void](Invoke-ProbeGit $consumerRoot @('worktree','add','--quiet','--detach',$baseRoot,$revision.Base))
    Assert-RepinFixture $baseRoot $consumerRoot $authority $revision
    if($FixtureOnly){
        $positiveBootstrap=[IO.File]::ReadAllBytes((Join-Path $consumerRoot 'scripts/Invoke-PinnedAuthority.ps1'))
        $negative=New-RepinNegativeCandidate $consumerRoot $revision
        $negativeBootstrap=[IO.File]::ReadAllBytes((Join-Path $consumerRoot 'scripts/Invoke-PinnedAuthority.ps1'))
        $baseBootstrap=[IO.File]::ReadAllBytes((Join-Path $baseRoot 'scripts/Invoke-PinnedAuthority.ps1'))
        if((Test-RepinBytesEqual $negativeBootstrap $baseBootstrap)-or(Test-RepinBytesEqual $negativeBootstrap $positiveBootstrap)){
            throw 'Re-pin negative bootstrap must differ from both approved templates.'
        }
        [Console]::Out.WriteLine(([ordered]@{result='PASS';oldCommit=$authority.OldCommit;newCommit=$authority.NewCommit
            base=$revision.Base;head=$revision.Head;candidate=$revision.Candidate;negativeCandidate=$negative.Candidate}|ConvertTo-Json -Compress))
        return
    }
    $authorityFileUrl=ConvertTo-ProbeFileUrl $authorityRoot;Assert-ProbeFileUrl $authorityFileUrl $authorityRoot
    $env:CONSUMER_REPIN_PROBE_AUTHORITY_URL=$authorityFileUrl;$env:RUNNER_TEMP=$WorkRoot;$env:CONSUMER_GATE_TEST_TEMP_ROOT=$WorkRoot
    $env:CONSUMER_GATE_EVENT_REPOSITORY=$script:ProbeConsumerRepository
    if($Mode-ceq'leg'-and[string]::IsNullOrWhiteSpace($env:STANDARD_GO_RUNTIME_VERSION)){
        $env:STANDARD_GO_RUNTIME_VERSION=(([string](& go version))-replace'^go version go([^ ]+).+$','$1').Trim()
    }
    $bootstrap=Join-Path $baseRoot 'scripts/Invoke-PinnedAuthority.ps1'
    if($Mode-ceq'leg'){
        [void](Invoke-RepinBootstrap $bootstrap prepare $gateRoot $baseRoot $consumerRoot $revision $Platform)
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')
        [void](Invoke-RepinBootstrap $bootstrap validate $gateRoot $baseRoot $consumerRoot $revision $Platform)
        [void](Invoke-RepinBootstrap $bootstrap finalize $gateRoot $baseRoot $consumerRoot $revision $Platform)
        Invoke-RepinNegativeCandidate $consumerRoot $baseRoot $bootstrap $revision
        $global:LASTEXITCODE=0
        [Console]::Out.WriteLine("Consumer re-pin probe leg passed with old bootstrap 7338a3f: $Platform")
    }else{
        if([string]::IsNullOrWhiteSpace($LegReceiptsRoot)-or-not(Test-Path -LiteralPath $LegReceiptsRoot -PathType Container)){
            throw 'Aggregate mode requires LegReceiptsRoot.'
        }
        $receiptRoot=Join-Path $gateRoot 'receipts';[void][IO.Directory]::CreateDirectory($receiptRoot)
        $receipts=@(Get-ChildItem -LiteralPath $LegReceiptsRoot -Recurse -File -Filter 'leg-*.json')
        if($receipts.Count-ne3){throw 'Re-pin aggregate requires exactly three leg receipts.'}
        foreach($receipt in $receipts){Copy-ProbeFile $receipt.FullName (Join-Path $receiptRoot $receipt.Name)}
        [void](Invoke-RepinBootstrap $bootstrap aggregate $gateRoot $baseRoot $consumerRoot $revision aggregate)
        [Console]::Out.WriteLine('Consumer re-pin probe aggregate passed with old bootstrap 7338a3f.')
    }
    $global:LASTEXITCODE=0
    exit 0
}finally{
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
    $savedEnvironment.Clear()
}
