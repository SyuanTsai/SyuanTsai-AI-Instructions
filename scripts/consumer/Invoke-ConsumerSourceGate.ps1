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
try{
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
        [void](Invoke-GateCredentialScopedPreparation $WorkRoot $token {
            $runtime=Install-GatePowerShell $authorityRoot $WorkRoot $Platform $token
            $receipt=[ordered]@{schemaVersion=1
            report='consumer-runtime-receipt-v1'
            executablePath=[string]$runtime.executablePath
            executableSha256=[string]$runtime.executableSha256
            version=[string]$runtime.version
            archiveSha256=[string]$runtime.archiveSha256}
            Write-GateJsonCreateOnly (Join-Path $WorkRoot 'runtime/consumer-runtime-receipt.json') $receipt
            [void](New-GateSourceSetup $authorityRoot $CandidateRoot $WorkRoot `
                    ([string]$runtime.executablePath) ([string]$binding.runId) ([string]$binding.commit) `
                    ([string]$binding.candidateRevision) $eventRepository $token)
        })
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
}
