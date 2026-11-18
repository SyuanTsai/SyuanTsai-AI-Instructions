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
    [string]$LegReceiptsRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:ProbeAuthorityRepository='https://example.test/consumer-transition-authority.git'
$script:ProbeConsumerRepository='https://example.test/example/consumer-transition-fixture.git'
$script:OfficialAuthorityRepository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Invoke-ProbeGit([string]$Root,[string[]]$Arguments,[int[]]$AllowedExitCodes=@(0)) {
    $output=@(& git -c core.autocrlf=false -c core.eol=lf -c core.filemode=false -C $Root @Arguments 2>&1)
    $exitCode=$LASTEXITCODE
    if($exitCode-notin$AllowedExitCodes){throw "Probe git failed ($exitCode): $($output-join' ')"}
    [pscustomobject]@{ExitCode=$exitCode;Output=$output}
}
function Get-ProbeGitScalar([string]$Root,[string[]]$Arguments) {
    ([string](Invoke-ProbeGit $Root $Arguments).Output[0]).Trim()
}
function Write-ProbeUtf8([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Write-ProbeJson([string]$Path,$Value) {
    Write-ProbeUtf8 $Path (($Value|ConvertTo-Json -Depth 100)+"`n")
}
function ConvertTo-ProbeAbsoluteFileUrl([string]$FullPath) {
    if([string]::IsNullOrWhiteSpace($FullPath)){throw 'Probe authority path must not be empty.'}
    $isUnixAbsolute=$FullPath.StartsWith('/',[StringComparison]::Ordinal)
    $isWindowsAbsolute=$FullPath-match'^[A-Za-z]:[\\/]'
    $isUncAbsolute=$FullPath-match'^[\\/]{2}[^\\/]'
    if(-not($isUnixAbsolute-or$isWindowsAbsolute-or$isUncAbsolute)){
        throw 'Probe authority path must be absolute.'
    }
    $builder=[UriBuilder]::new()
    $builder.Scheme=[Uri]::UriSchemeFile
    $builder.Host=''
    $builder.Path=$FullPath
    $builder.Uri.AbsoluteUri
}
function ConvertTo-ProbeFileUrl([string]$Path) {
    ConvertTo-ProbeAbsoluteFileUrl ([IO.Path]::GetFullPath($Path))
}
function Assert-ProbeFileUrl([string]$Url,[string]$ExpectedPath) {
    if([string]::IsNullOrWhiteSpace($Url)){throw 'Probe authority file URL must not be empty.'}
    $uri=$null
    if(-not[Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri)-or-not$uri.IsAbsoluteUri){
        throw 'Probe authority file URL must be absolute.'
    }
    if($uri.Scheme-cne[Uri]::UriSchemeFile){throw 'Probe authority URL must use the file scheme.'}
    if($uri.LocalPath-cne$ExpectedPath){throw 'Probe authority file URL path round-trip failed.'}
}
function Protect-ProbeDiagnosticValue([string]$Value) {
    if($null-eq$Value){return $null}
    $protected=$Value
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
        $secret=[Environment]::GetEnvironmentVariable($name,'Process')
        if(-not[string]::IsNullOrEmpty($secret)){$protected=$protected.Replace($secret,'[REDACTED]',[StringComparison]::Ordinal)}
    }
    $protected=[regex]::Replace($protected,'(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@','$1[REDACTED]@')
    $protected=[regex]::Replace($protected,'(?i)(^|[.=])[^/\s@]+@(?=[^/\s]+:)','$1[REDACTED]@')
    [regex]::Replace($protected,'([?#]).*$','$1[REDACTED]')
}
function Get-ProbeInsteadOfSummary([ValidateSet('--system','--global')][string]$Scope) {
    $keys=@(& git config $Scope --name-only --get-regexp '^url\..*\.insteadof$' 2>$null)
    $exitCode=$LASTEXITCODE
    [ordered]@{
        status=if($exitCode-eq0){'present'}elseif($exitCode-eq1){'absent'}else{'query-failed'}
        exitCode=$exitCode
        exists=if($exitCode-in@(0,1)){$exitCode-eq0}else{$null}
        keys=@($keys|ForEach-Object{Protect-ProbeDiagnosticValue ([string]$_).Trim()}|Where-Object{$_})
    }
}
function Write-ProbeAuthorityUrlDiagnostics([string]$ExpectedUrl,[string]$GateRoot) {
    try{
        $gitRoot=Join-Path $GateRoot 'authority-git'
        $actualOutput=@();$actualExitCode=$null
        if(Test-Path -LiteralPath $gitRoot -PathType Container){
            $actualOutput=@(& git -c 'protocol.file.allow=always' -c 'credential.helper=' -C $gitRoot `
                -c "remote.origin.url=$ExpectedUrl" ls-remote --get-url origin 2>$null)
            $actualExitCode=$LASTEXITCODE
        }
        $versionOutput=@(& git --version 2>$null);$versionExitCode=$LASTEXITCODE
        $diagnostic=[ordered]@{
            kind='consumer-transition-probe-authority-url'
            expectedUrl=Protect-ProbeDiagnosticValue $ExpectedUrl
            actualUrl=if($actualOutput.Count-gt0){Protect-ProbeDiagnosticValue ([string]$actualOutput[0]).Trim()}else{$null}
            actualUrlExitCode=$actualExitCode
            actualUrlLineCount=$actualOutput.Count
            gitVersion=if($versionExitCode-eq0-and$versionOutput.Count-gt0){Protect-ProbeDiagnosticValue ([string]$versionOutput[0]).Trim()}else{$null}
            systemInsteadOf=Get-ProbeInsteadOfSummary '--system'
            globalInsteadOf=Get-ProbeInsteadOfSummary '--global'
        }
        [Console]::Error.WriteLine(($diagnostic|ConvertTo-Json -Depth 8 -Compress))
    }catch{
        [Console]::Error.WriteLine('{"kind":"consumer-transition-probe-authority-url","diagnosticStatus":"failed"}')
    }
}
function Copy-ProbeFile([string]$Source,[string]$Destination) {
    $item=Get-Item -LiteralPath $Source -Force
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){
        throw "Probe source must be a physical file: $Source"
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    [IO.File]::Copy($item.FullName,$Destination,$false)
}
function Set-ProbeGitIdentity([string]$Root) {
    [void](Invoke-ProbeGit $Root @('config','user.name','Consumer Transition Probe'))
    [void](Invoke-ProbeGit $Root @('config','user.email','probe@example.test'))
}
function Complete-ProbeCommit([string]$Root,[string]$Message) {
    [void](Invoke-ProbeGit $Root @('add','--all'))
    $files=@((Invoke-ProbeGit $Root @('ls-files')).Output|ForEach-Object{[string]$_}|Where-Object{$_})
    for($index=0;$index-lt$files.Count;$index+=100){
        $last=[Math]::Min($files.Count-1,$index+99)
        [void](Invoke-ProbeGit $Root (@('update-index','--chmod=-x','--')+$files[$index..$last]))
    }
    [void](Invoke-ProbeGit $Root @('commit','--quiet','-m',$Message))
    Get-ProbeGitScalar $Root @('rev-parse','HEAD^{commit}')
}
function New-ProbeConsumerBase([string]$Root,[string]$FixtureRoot) {
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-ProbeGit $Root @('init','--quiet','-b','main'))
    Set-ProbeGitIdentity $Root
    [void](Invoke-ProbeGit $Root @('remote','add','origin',$script:ProbeConsumerRepository))
    Copy-ProbeFile (Join-Path $FixtureRoot 'base/scripts/Legacy.ps1') (Join-Path $Root 'scripts/Legacy.ps1')
    $commit=Complete-ProbeCommit $Root 'consumer transition probe base'
    [pscustomobject]@{Commit=$commit;Tree=Get-ProbeGitScalar $Root @('rev-parse',"$commit^{tree}")}
}
function New-ProbeAuthority([string]$RepositoryRoot,[string]$Root,[string]$BaseCommit,[string]$BaseTree) {
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-ProbeGit $Root @('init','--quiet','-b','main'))
    Set-ProbeGitIdentity $Root
    $paths=@((Invoke-ProbeGit $RepositoryRoot @('ls-files','--cached','--others','--exclude-standard')).Output|
        ForEach-Object{[string]$_}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    foreach($relative in $paths){Copy-ProbeFile (Join-Path $RepositoryRoot $relative) (Join-Path $Root $relative)}

    $bootstrapPath=Join-Path $Root 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
    $bootstrap=Get-Content -Raw -Encoding UTF8 $bootstrapPath
    $bootstrap=$bootstrap.Replace($script:OfficialAuthorityRepository,$script:ProbeAuthorityRepository)
    $bootstrap=$bootstrap.Replace(
        'New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit)',
        "New-PinnedAuthority `$WorkRoot ([string]`$pin.Value.commit) ([Environment]::GetEnvironmentVariable('CONSUMER_TRANSITION_PROBE_AUTHORITY_URL','Process')) -AllowFileProtocol")
    $anchor='    Assert-AuthorityTree $gitRoot $authorityRoot $Commit'
    $replacement=$anchor+"`n    [void](Invoke-PinnedGit `$gitRoot @('remote','set-url','origin','$($script:OfficialAuthorityRepository)') -AllowFileProtocol)"
    if(-not$bootstrap.Contains($anchor,[StringComparison]::Ordinal)){throw 'Probe bootstrap projection anchor is missing.'}
    $bootstrap=$bootstrap.Replace($anchor,$replacement)
    Write-ProbeUtf8 $bootstrapPath $bootstrap

    $manifestPath=Join-Path $Root 'consumer/legacy-migration.json'
    $manifest=Get-Content -Raw -Encoding UTF8 $manifestPath|ConvertFrom-Json -Depth 100
    $entry=@($manifest.repositories|Where-Object id -eq 'skill-general')
    if($entry.Count-ne1){throw 'Probe manifest has no unique skill-general entry.'}
    $entry=$entry[0]
    $entry.repository=$script:ProbeConsumerRepository
    $entry.status='ready';$entry.inventoryCommit=$BaseCommit;$entry.inventoryTree=$BaseTree
    $entry.requiredRepositoryChecks=@(
        [pscustomobject][ordered]@{id='repository-general';kind='general';path='scripts/Test-FixtureRepository.ps1'},
        [pscustomobject][ordered]@{id='repository-pester';kind='pester';path='tests'})
    $entry.files=@([pscustomobject][ordered]@{path='scripts/Legacy.ps1';disposition='delete';reason='Replaced by the consumer transition fixture check.'})
    foreach($name in @('additionalScope','prerequisites','literalReferenceExemptions')){$entry.PSObject.Properties.Remove($name)}
    Write-ProbeJson $manifestPath $manifest
    [void](Invoke-ProbeGit $Root @('remote','add','origin',$script:OfficialAuthorityRepository))
    Complete-ProbeCommit $Root 'consumer transition probe authority projection'
}
function Complete-ProbeCandidate([string]$Root,[string]$FixtureRoot,[string]$AuthorityCommit) {
    [void](Invoke-ProbeGit $Root @('checkout','--quiet','-b','probe-topic'))
    [IO.File]::Delete((Join-Path $Root 'scripts/Legacy.ps1'))
    foreach($relative in @('skills/fixture/SKILL.md','scripts/Test-FixtureRepository.ps1')){
        Copy-ProbeFile (Join-Path $FixtureRoot "candidate/$relative") (Join-Path $Root $relative)
    }
    Copy-ProbeFile (Join-Path $FixtureRoot 'candidate/tests/Fixture.Tests.ps1.template') (Join-Path $Root 'tests/Fixture.Tests.ps1')
    foreach($directory in @('config','.github/workflows')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $directory))}
    Copy-ProbeFile (Join-Path $script:ProbeAuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') `
        (Join-Path $Root 'scripts/Invoke-PinnedAuthority.ps1')
    foreach($name in @('consumer-gate.yml','consumer-gate-transition.yml')){
        Copy-ProbeFile (Join-Path $script:ProbeAuthorityRoot "consumer/workflows/$name") (Join-Path $Root ".github/workflows/$name")
    }
    Write-ProbeJson (Join-Path $Root 'config/authority-pin.json') ([ordered]@{
            schemaVersion=1;repository=$script:ProbeAuthorityRepository;commit=$AuthorityCommit})
    Write-ProbeJson (Join-Path $Root 'config/consumer-gate.json') ([ordered]@{
            schemaVersion=1;repositoryId='skill-general';sourceRepository=$script:ProbeConsumerRepository;activeSkills=@('fixture')
            repositoryChecks=@(
                [ordered]@{id='repository-general';kind='general';path='scripts/Test-FixtureRepository.ps1'},
                [ordered]@{id='repository-pester';kind='pester';path='tests'})})
    $head=Complete-ProbeCommit $Root 'consumer transition probe candidate'
    [void](Invoke-ProbeGit $Root @('checkout','--quiet','main'))
    [void](Invoke-ProbeGit $Root @('merge','--quiet','--no-ff','probe-topic','-m','consumer transition probe merge'))
    [pscustomobject]@{Head=$head;Candidate=Get-ProbeGitScalar $Root @('rev-parse','HEAD^{commit}')}
}
function Invoke-ProbeBootstrap([string]$Bootstrap,[string]$Phase,[string]$GateRoot,[string]$BaseRoot,[string]$CandidateRoot,
    [string]$BaseRevision,[string]$CandidateRevision,[string]$HeadRevision,[string]$PlatformValue,[switch]$Transition) {
    $arguments=@('-NoProfile','-NonInteractive','-File',$Bootstrap,'-Phase',$Phase,'-BaseRoot',$BaseRoot,'-CandidateRoot',$CandidateRoot,
        '-WorkRoot',$GateRoot,'-TriggerEvent','pull_request','-BaseRevision',$BaseRevision,'-CandidateRevision',$CandidateRevision,
        '-HeadRevision',$HeadRevision,'-WorkflowRunId',$WorkflowRunId,'-WorkflowRunAttempt',$WorkflowRunAttempt,'-Platform',$PlatformValue)
    if($Transition){$arguments+='-TransitionFromLegacy'}
    & (Get-Process -Id $PID).Path @arguments
    if($LASTEXITCODE-ne0){
        $exitCode=$LASTEXITCODE
        if($Phase-ceq'prepare'){Write-ProbeAuthorityUrlDiagnostics `
                ([Environment]::GetEnvironmentVariable('CONSUMER_TRANSITION_PROBE_AUTHORITY_URL','Process')) $GateRoot}
        throw "Consumer transition probe phase '$Phase' failed with exit code $exitCode."
    }
}

$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $WorkRoot){throw 'Probe WorkRoot must not already exist.'}
[void][IO.Directory]::CreateDirectory($WorkRoot)
$fixtureRoot=Join-Path $RepositoryRoot 'tests/fixtures/consumer-transition-probe'
$consumerRoot=Join-Path $WorkRoot 'consumer-source'
$authorityRoot=Join-Path $WorkRoot 'authority-source'
$baseRoot=Join-Path $WorkRoot 'base'
$gateRoot=Join-Path $WorkRoot 'gate'
$fixedDate='2026-01-01T00:00:00Z'
$savedEnvironment=@{}
foreach($name in @('GIT_AUTHOR_DATE','GIT_COMMITTER_DATE','RUNNER_TEMP','CONSUMER_TRANSITION_PROBE_AUTHORITY_URL',
        'CONSUMER_GATE_TEST_TEMP_ROOT','CONSUMER_GATE_EVENT_REPOSITORY','STANDARD_GO_RUNTIME_VERSION','STANDARD_VALIDATION_GITHUB_API_TOKEN')){
    $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
try{
    $env:GIT_AUTHOR_DATE=$fixedDate;$env:GIT_COMMITTER_DATE=$fixedDate
    $base=New-ProbeConsumerBase $consumerRoot $fixtureRoot
    $script:ProbeAuthorityRoot=$authorityRoot
    $authorityCommit=New-ProbeAuthority $RepositoryRoot $authorityRoot $base.Commit $base.Tree
    $candidate=Complete-ProbeCandidate $consumerRoot $fixtureRoot $authorityCommit
    [void](Invoke-ProbeGit $consumerRoot @('worktree','add','--quiet','--detach',$baseRoot,$base.Commit))
    $authorityFileUrl=ConvertTo-ProbeFileUrl $authorityRoot
    Assert-ProbeFileUrl $authorityFileUrl $authorityRoot
    $env:CONSUMER_TRANSITION_PROBE_AUTHORITY_URL=$authorityFileUrl
    $env:RUNNER_TEMP=$WorkRoot;$env:CONSUMER_GATE_TEST_TEMP_ROOT=$WorkRoot
    $env:CONSUMER_GATE_EVENT_REPOSITORY=$script:ProbeConsumerRepository
    if($Mode-ceq'leg'-and[string]::IsNullOrWhiteSpace($env:STANDARD_GO_RUNTIME_VERSION)){
        $goVersion=([string](& go version))-replace'^go version go([^ ]+).+$','$1'
        $env:STANDARD_GO_RUNTIME_VERSION=$goVersion.Trim()
    }
    $gitCommand=Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $summary=[ordered]@{platform=$Platform;os=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        powershell=[string]$PSVersionTable.PSVersion;gitExecutable=[IO.Path]::GetFileName($gitCommand.Source)
        programFilesPresent=(-not[string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('ProgramFiles','Process')))
        localAppDataPresent=(-not[string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')))
        tempClass=if($IsWindows){'windows-runner-temp'}else{'unix-runner-temp'}}
    [Console]::Out.WriteLine(($summary|ConvertTo-Json -Compress))
    $bootstrap=Join-Path $consumerRoot 'scripts/Invoke-PinnedAuthority.ps1'
    if($Mode-ceq'leg'){
        Invoke-ProbeBootstrap $bootstrap prepare $gateRoot $baseRoot $consumerRoot $base.Commit $candidate.Candidate $candidate.Head $Platform -Transition
        [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')
        Invoke-ProbeBootstrap $bootstrap validate $gateRoot $baseRoot $consumerRoot $base.Commit $candidate.Candidate $candidate.Head $Platform -Transition
        Invoke-ProbeBootstrap $bootstrap finalize $gateRoot $baseRoot $consumerRoot $base.Commit $candidate.Candidate $candidate.Head $Platform -Transition
        [Console]::Out.WriteLine("Consumer transition probe leg passed: $Platform")
    }else{
        if([string]::IsNullOrWhiteSpace($LegReceiptsRoot)-or-not(Test-Path -LiteralPath $LegReceiptsRoot -PathType Container)){
            throw 'Aggregate mode requires LegReceiptsRoot.'
        }
        $receiptRoot=Join-Path $gateRoot 'receipts';[void][IO.Directory]::CreateDirectory($receiptRoot)
        $receipts=@(Get-ChildItem -LiteralPath $LegReceiptsRoot -Recurse -File -Filter 'leg-*.json')
        if($receipts.Count-ne3){throw 'Aggregate probe requires exactly three leg receipts.'}
        foreach($receipt in $receipts){Copy-ProbeFile $receipt.FullName (Join-Path $receiptRoot $receipt.Name)}
        Invoke-ProbeBootstrap $bootstrap aggregate $gateRoot $baseRoot $consumerRoot $base.Commit $candidate.Candidate $candidate.Head aggregate -Transition
        [Console]::Out.WriteLine('Consumer transition probe aggregate passed.')
    }
}finally{
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
    $savedEnvironment.Clear()
}
