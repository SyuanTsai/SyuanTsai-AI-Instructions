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
$baseRoot=Join-Path $FixtureRoot 'base'
$candidateRoot=Join-Path $FixtureRoot 'candidate'
$runnerWorkBoundary=$null
$workRoot=if(-not[string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
    $runnerWorkBoundary=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
    Join-Path $runnerWorkBoundary ('cbc-'+[guid]::NewGuid().ToString('N').Substring(0,12))
}else{Join-Path $FixtureRoot 'work'}
$platform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
$authorityRoot=Join-Path $FixtureRoot 'authority'
foreach($path in @($baseRoot,$candidateRoot,$workRoot,(Join-Path $authorityRoot 'consumer'),(Join-Path $authorityRoot 'scripts/consumer'))){
    [void][IO.Directory]::CreateDirectory($path)
}
$runtimeManifest=Import-PowerShellDataFile (Join-Path $RepositoryRoot 'scripts/platform-runtime.psd1')
foreach($relative in @('platform-runtime.psd1')+@($runtimeManifest.FileList)|Select-Object -Unique){
    $destination=Join-Path (Join-Path $authorityRoot 'scripts') $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath (Join-Path (Join-Path $RepositoryRoot 'scripts') $relative) -Destination $destination
}
foreach($relative in @('ConsumerBootstrapSupervisor.psm1','ConsumerGate.psm1')){
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot "scripts/consumer/$relative") `
        -Destination (Join-Path $authorityRoot "scripts/consumer/$relative")
}
$interfacePath=Join-Path $authorityRoot 'consumer/consumer-gate-interface.json'
$contract=[ordered]@{schemaVersion=1;supportedInterfaces=@('consumer-gate-v1');currentInterface='consumer-gate-v1';retiredInterfaces=@()
    phaseEnvironment=[ordered]@{prepare=@('STANDARD_VALIDATION_GITHUB_API_TOKEN');validate=@();finalize=@();aggregate=@()}
    requiredContexts=@('repository-contract','skill-validator','skill-tools')
    canonicalEventMap=[ordered]@{pull_request_target='pull_request';push='push';'pull_request(transition)'='pull_request'}}
[IO.File]::WriteAllText($interfacePath,($contract|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$gatePath=Join-Path $authorityRoot 'scripts/consumer/Invoke-ConsumerSourceGate.ps1'
$gate=@'
param($Interface,$Phase,$AuthorityBindingPath,$BaseRoot,$CandidateRoot,$WorkRoot,$Platform,[switch]$TransitionFromLegacy)
exit 0
'@
[IO.File]::WriteAllText($gatePath,$gate,[Text.UTF8Encoding]::new($false))
$bindingPath=Join-Path $FixtureRoot 'binding.json'
[IO.File]::WriteAllText($bindingPath,'{}',[Text.UTF8Encoding]::new($false))
$env:STANDARD_VALIDATION_GITHUB_API_TOKEN=$Sentinel
try{
    $supervisor=Import-Module (Join-Path $authorityRoot 'scripts/consumer/ConsumerBootstrapSupervisor.psm1') -Force -PassThru
    $code=& $supervisor.ExportedCommands['Invoke-ConsumerGateProcess'] -AuthorityRoot $authorityRoot `
        -Executable (Get-Process -Id $PID).Path -GatePath $gatePath -InterfacePath $interfacePath -CurrentPhase prepare `
        -BindingPath $bindingPath -BaseRoot $baseRoot -CandidateRoot $candidateRoot -WorkRoot $workRoot -Platform $platform `
        -Token $Sentinel -DeadlineOverrideSeconds 5
    if($code-ne0){throw "Supervisor cleanup fixture returned $code."}
    $formalOutput=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $bootstrap 2>&1)
    if($LASTEXITCODE-ne30){throw "Bootstrap formal cleanup fixture returned $LASTEXITCODE`: $($formalOutput-join' | ')"}
}finally{
    Remove-Item Env:STANDARD_VALIDATION_GITHUB_API_TOKEN -ErrorAction SilentlyContinue
    if($null-ne$runnerWorkBoundary-and(Test-Path -LiteralPath $workRoot)){
        $workFull=[IO.Path]::GetFullPath($workRoot)
        $boundaryFull=$runnerWorkBoundary.TrimEnd([IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not$workFull.StartsWith($boundaryFull,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Bootstrap cleanup fixture WorkRoot escaped its cleanup boundary.'
        }
        Remove-Item -LiteralPath $workFull -Recurse -Force
    }
}
