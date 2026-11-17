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
$runRoot=Join-Path $ArtifactsRoot "runs/$RunId"
$candidateSnapshot=Join-Path $runRoot 'candidate'
[void][IO.Directory]::CreateDirectory($candidateSnapshot)
$casePath=Join-Path $runRoot 'repository-pester-case-inventory-v1.json'
$caseInventory=[ordered]@{
    schemaVersion=1
    report='standard-core-pester-case-inventory-v1'
    coreRunId=$RunId
    candidateSnapshotIdentity=[ordered]@{coreRunId=$RunId;root=$candidateSnapshot}
    candidateSnapshotSha256=('1'*64)
    pesterModule=[ordered]@{version='6.2.0';manifestPath='fixture/Pester.psd1';moduleRoot='fixture'
        lockPath='fixture/receipt-pester.json';lockSha256=('2'*64);closureSha256Before=('3'*64);closureSha256After=('3'*64)}
    runPath='tests'
    runScope='complete-unfiltered-tests-tree'
    testFileInventory=@('tests/fixture.Tests.ps1')
    containerFileInventory=@('tests/fixture.Tests.ps1')
    discoveredCaseFileInventory=@('tests/fixture.Tests.ps1')
    caseDiscoveryCount=[long]1
    caseExecutionCount=[long]1
    containerCount=1
    failedBlockCount=0
    failedContainerCount=0
    terminalStatus='complete'
    reportedCounts=[ordered]@{Passed=1;Failed=0;Skipped=0;Inconclusive=0;NotRun=0}
    shardIdentity='core-full'
    shardCaseIdentities=@('fixture/passes')
    shardUnion=[ordered]@{discoveryCount=1;executionUnionCount=1;complete=$true}
    discoveryCases=@([ordered]@{identity='fixture/passes'})
    executionCases=@([ordered]@{identity='fixture/passes'})
    complete=$true
    errors=@()
}
[IO.File]::WriteAllText($casePath,($caseInventory|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$caseSha=(Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash.ToLowerInvariant()
$report=[ordered]@{state='PASS';releaseEligible=$false;sourceValidation=[ordered]@{
        pesterCaseInventory=[ordered]@{path=$casePath;sha256=$caseSha}}}
[IO.File]::WriteAllText($OutputPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
exit 0
