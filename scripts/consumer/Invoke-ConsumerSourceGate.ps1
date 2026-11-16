# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('consumer-gate-v1')][string]$Interface,
    [Parameter(Mandatory=$true)][ValidateSet('prepare','validate','finalize','aggregate')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$AuthorityBindingPath,
    [Parameter(Mandatory=$true)][string]$BaseRoot,
    [Parameter(Mandatory=$true)][string]$CandidateRoot,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][ValidateSet('windows','linux','macos','aggregate')][string]$Platform,
    [switch]$TransitionFromLegacy
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ConsumerGate.psm1') -Force
$phaseEnvironmentDumpPath=[string]$env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH
if(-not[string]::IsNullOrWhiteSpace($phaseEnvironmentDumpPath)){
    try{
        $phaseEnvironment=[Environment]::GetEnvironmentVariables('Process')
        $sentinelHashPath="$phaseEnvironmentDumpPath.sentinel.sha256"
        $sentinelHash=if(Test-Path -LiteralPath $sentinelHashPath -PathType Leaf){[IO.File]::ReadAllText($sentinelHashPath).Trim()}else{''}
        $phaseTokenNames=@($phaseEnvironment.Keys|ForEach-Object{[string]$_}|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'}|Sort-Object)
        $phaseSentinelNames=@($phaseEnvironment.Keys|ForEach-Object{[string]$_}|Where-Object{
                $value=[string]$phaseEnvironment[$_]
                -not[string]::IsNullOrEmpty($sentinelHash)-and-not[string]::IsNullOrEmpty($value)-and
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()-ceq$sentinelHash
            }|Sort-Object)
        $phaseEnvironmentDump=[ordered]@{phase=$Phase;tokenNames=$phaseTokenNames;sentinelValueNames=$phaseSentinelNames}
        [IO.File]::WriteAllText($phaseEnvironmentDumpPath,($phaseEnvironmentDump|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    }finally{
        $phaseEnvironment=$null;$phaseEnvironmentDump=$null;$phaseTokenNames=$null;$phaseSentinelNames=$null;$sentinelHash=$null;$value=$null
        Remove-Variable phaseEnvironment,phaseEnvironmentDump,phaseTokenNames,phaseSentinelNames,sentinelHash,value -ErrorAction SilentlyContinue
    }
}
try{
    if($Phase-cne'prepare'){
        $credentialNames=@('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')
        if(@($credentialNames|Where-Object{-not[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_,'Process'))}).Count-ne0){
            Throw-GateResult INVALID 'Credential-bearing environment is forbidden outside prepare.'
        }
        $credentialNames=$null
        Remove-Variable credentialNames -ErrorAction SilentlyContinue
    }
    $authorityRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Initialize-GateGitHooks $WorkRoot
    $binding=Read-GateJson $AuthorityBindingPath 'authority binding'
    $binding|Add-Member -NotePropertyName canonicalEvent -NotePropertyValue $(if([string]$binding.triggerEvent-ceq'push'){'push'}else{'pull_request'}) -Force
    $eventRepository=[string]$env:CONSUMER_GATE_EVENT_REPOSITORY
    if([string]::IsNullOrWhiteSpace($eventRepository)){Throw-GateResult INVALID 'Event repository is missing.'}
    if($Phase-ceq'prepare'){
        $validated=Assert-GateConfig $authorityRoot $CandidateRoot $eventRepository
        Assert-GateTransitionInventory $BaseRoot $validated.ManifestEntry ([string]$binding.baseRevision) ([bool]$TransitionFromLegacy)
        Assert-GateProtectedFiles $authorityRoot $BaseRoot $CandidateRoot $validated.ManifestEntry `
            ([string]$binding.baseRevision) ([string]$binding.candidateRevision) ([bool]$TransitionFromLegacy)
        Invoke-GateManifestClosureCheck $authorityRoot $BaseRoot $CandidateRoot $validated.ManifestEntry `
            ([string]$binding.baseRevision) ([string]$binding.candidateRevision) $WorkRoot `
            ([bool]$TransitionFromLegacy)
        Assert-GateExceptionSetUnchanged $CandidateRoot ([string]$binding.baseRevision) ([string]$binding.candidateRevision)
        $token=[string]$env:STANDARD_VALIDATION_GITHUB_API_TOKEN
        [void](Invoke-GateCredentialScopedPreparation $authorityRoot $CandidateRoot $WorkRoot $Platform $binding $eventRepository $token)
    }elseif($Phase-ceq'validate'){
        $validated=Assert-GateConfig $authorityRoot $CandidateRoot $eventRepository
        $runtime=Read-GateJson (Join-Path $WorkRoot 'runtime/consumer-runtime-receipt.json') 'consumer runtime receipt'
        Invoke-GateValidation $authorityRoot $CandidateRoot $WorkRoot $binding $validated.Config ([string]$runtime.executablePath)
    }elseif($Phase-ceq'finalize'){
        Write-GateLegReceipt $authorityRoot $CandidateRoot $WorkRoot $binding $Platform
    }else{Invoke-GateAggregate $WorkRoot $binding}
    exit 0
}catch{
    $message=[string]$_.Exception.Message
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $tokenVariable=Get-Variable token -ErrorAction SilentlyContinue
    if ($null -ne $tokenVariable -and -not [string]::IsNullOrEmpty([string]$tokenVariable.Value)) {
        $message = $message.Replace([string]$tokenVariable.Value, '[REDACTED]')
    }
    if($message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|(.*)$'){[Console]::Error.WriteLine($Matches[2])
    exit @{BLOCKED=10
    FAILED=20
    INVALID=30
    CANCELLED=40}[$Matches[1]]}
    [Console]::Error.WriteLine($message)
    exit 20
}finally{
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
        [Environment]::SetEnvironmentVariable($name,$null,'Process')
    }
    $token=$null
    $tokenVariable=$null
    $message=$null
    $phaseEnvironmentDumpPath=$null
    Remove-Variable token, tokenVariable, message, phaseEnvironmentDumpPath -ErrorAction SilentlyContinue
}
