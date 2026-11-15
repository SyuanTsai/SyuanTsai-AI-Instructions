# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param(
    [switch]$DefineFunctionsOnly,[string]$CandidateRoot,[string]$AdapterPath,[string]$ArtifactsRoot,
    [string]$OutputPath,[string]$SourceRepository,[string]$SourceRevision,[string]$BaseRevision,
    [string]$EventName,[string]$RunId,[string]$AuthorityRevision,[string]$TrustedToolRoot,
    [switch]$SourceValidation,[int]$TimeoutSeconds
)
function Assert-StandardCoreSourceCheckReport {
    param($Report,$ExpectedSourceRevision,$ExpectedBaseRevision,$ExpectedAuthorityRevision,$ExpectedEventName,
        $ArtifactsRoot,$OutputPath,$ProcessExitCode,$ValidationSecurityPolicy)
    if($ProcessExitCode-ne0){throw 'fixture source report process exit code changed.'}
}
if($DefineFunctionsOnly){return}
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($ArtifactsRoot)
$casePath=Join-Path $ArtifactsRoot 'repository-pester-case-inventory-v1.json'
$caseInventory=[ordered]@{sha256=('a'*64);caseDiscoveryCount=[long]1;caseExecutionCount=[long]1
    testFileInventory=@('tests/fixture.Tests.ps1');containerFileInventory=@('tests/fixture.Tests.ps1')
    discoveredCaseFileInventory=@('tests/fixture.Tests.ps1')}
[IO.File]::WriteAllText($casePath,($caseInventory|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$caseSha=(Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash.ToLowerInvariant()
$report=[ordered]@{state='PASS';releaseEligible=$false;sourceValidation=[ordered]@{
        pesterCaseInventory=[ordered]@{path=$casePath;sha256=$caseSha}}}
[IO.File]::WriteAllText($OutputPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
exit 0
