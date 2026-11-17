# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][string]$Sentinel
)
$ErrorActionPreference='Stop'
$bootstrap=Join-Path $RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
. $bootstrap -DefineFunctionsOnly
$script:BaseRoot=Join-Path $FixtureRoot 'base'
$script:CandidateRoot=Join-Path $FixtureRoot 'candidate'
$runnerWorkBoundary=$null
$script:WorkRoot=if(-not[string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
    $runnerWorkBoundary=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
    Join-Path $runnerWorkBoundary ('cbc-'+[guid]::NewGuid().ToString('N').Substring(0,12))
}else{Join-Path $FixtureRoot 'work'}
$script:Platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
$script:TransitionFromLegacy=$false
foreach($path in @($script:BaseRoot,$script:CandidateRoot,$script:WorkRoot)){[void][IO.Directory]::CreateDirectory($path)}
$interfacePath=Join-Path $FixtureRoot 'consumer-gate-interface.json'
$contract=[ordered]@{schemaVersion=1;supportedInterfaces=@('consumer-gate-v1');currentInterface='consumer-gate-v1';retiredInterfaces=@()
    phaseEnvironment=[ordered]@{prepare=@('STANDARD_VALIDATION_GITHUB_API_TOKEN');validate=@();finalize=@();aggregate=@()}
    requiredContexts=@('repository-contract','skill-validator','skill-tools')
    canonicalEventMap=[ordered]@{pull_request_target='pull_request';push='push';'pull_request(transition)'='pull_request'}}
[IO.File]::WriteAllText($interfacePath,($contract|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$gatePath=Join-Path $FixtureRoot 'gate.ps1'
$gate=@'
param($Interface,$Phase,$AuthorityBindingPath,$BaseRoot,$CandidateRoot,$WorkRoot,$Platform,[switch]$TransitionFromLegacy)
exit 0
'@
[IO.File]::WriteAllText($gatePath,$gate,[Text.UTF8Encoding]::new($false))
$bindingPath=Join-Path $FixtureRoot 'binding.json'
[IO.File]::WriteAllText($bindingPath,'{}',[Text.UTF8Encoding]::new($false))
$env:STANDARD_VALIDATION_GITHUB_API_TOKEN=$Sentinel
try{
    $code=Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $gatePath $interfacePath prepare $bindingPath $Sentinel
    if($code-ne0){throw "Bootstrap cleanup fixture returned $code."}
    $formalOutput=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $bootstrap 2>&1)
    if($LASTEXITCODE-ne30){throw "Bootstrap formal cleanup fixture returned $LASTEXITCODE`: $($formalOutput-join' | ')"}
}finally{
    Remove-Item Env:STANDARD_VALIDATION_GITHUB_API_TOKEN -ErrorAction SilentlyContinue
    if($null-ne$runnerWorkBoundary-and(Test-Path -LiteralPath $script:WorkRoot)){
        $workFull=[IO.Path]::GetFullPath($script:WorkRoot)
        $boundaryFull=$runnerWorkBoundary.TrimEnd([IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not$workFull.StartsWith($boundaryFull,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Bootstrap cleanup fixture WorkRoot escaped its cleanup boundary.'
        }
        Remove-Item -LiteralPath $workFull -Recurse -Force
    }
}
