#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('general','pester')][string]$Check,
    [Parameter(Mandatory=$true)][string]$DescriptorPath,
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$SourceRevision,
    [Parameter(Mandatory=$true)][string]$AuthorityRevision,
    [string]$PesterReceiptPath
)
$ErrorActionPreference='Stop'

function New-ThirdPartySourcePesterCase {
    param($Test,[string]$TestRoot,[string[]]$TestFiles)
    if ($Test.ScriptBlock -isnot [scriptblock] -or [string]::IsNullOrWhiteSpace([string]$Test.ExpandedPath)) {throw 'Pester case has no actual source block or expanded identity.'}
    $extent=$Test.ScriptBlock.Ast.Extent
    $root=[IO.Path]::GetFullPath($TestRoot).TrimEnd('/','\')+[IO.Path]::DirectorySeparatorChar
    $file=[IO.Path]::GetFullPath([string]$extent.File)
    $comparison=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if (-not $file.StartsWith($root,$comparison)) {throw 'Pester case originates outside the governed central test root.'}
    $relative=$file.Substring($root.Length).Replace('\','/')
    if ($relative -cnotin $TestFiles -or $extent.StartOffset -lt 0 -or [string]$Test.Result -cnotin @('Passed','Failed','Skipped','Inconclusive','NotRun')) {throw 'Pester case source or result is outside the actual full suite.'}
    $tuple=ConvertTo-Json -InputObject ([object[]]@($relative.ToUpperInvariant(),[int]$extent.StartOffset,[string]$Test.ExpandedPath)) -Depth 3 -Compress
    return [pscustomobject]@{
        identity=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($tuple))
        sourceFile=$relative;sourceStartOffset=[int]$extent.StartOffset;sourceStartLine=[int]$extent.StartLineNumber
        expandedPath=[string]$Test.ExpandedPath;result=[string]$Test.Result;identityError=$null
    }
}

$sourceRoot=(Get-Location).Path
$rawCheckEntryPath=$PSCommandPath
$DescriptorPath=[IO.Path]::GetFullPath($DescriptorPath)
$ArchivePath=[IO.Path]::GetFullPath($ArchivePath)
if (-not [string]::IsNullOrWhiteSpace($PesterReceiptPath)) {$PesterReceiptPath=[IO.Path]::GetFullPath($PesterReceiptPath)}
$runId=[string]$env:STANDARD_VALIDATION_CORE_RUN_ID
$runRoot=Split-Path -Parent $sourceRoot
if ($runId -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName($runRoot) -cne $runId -or
    [string]$env:STANDARD_VALIDATION_CORE_CHECK_ID -cne ('repository-'+$Check)) {throw 'Raw source checks require the canonical run-owned Core check context.'}
$authorityRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Invoke-StandardValidation.ps1') -CandidateRoot $sourceRoot -AdapterPath (Join-Path $runRoot 'source-core-adapter.json') -ArtifactsRoot (Split-Path -Parent (Split-Path -Parent $runRoot)) -SourceRepository $SourceRepository -SourceRevision $SourceRevision -BaseRevision $SourceRevision -AuthorityRevision $AuthorityRevision -RunId $runId -DefineFunctionsOnly
$adapter=(Get-StandardValidationJsonSnapshot -Path (Join-Path $runRoot 'source-core-adapter.json') -Context 'raw source retained adapter').value
if ([string]$adapter.sourceValidation.testOwnership -cne 'central-third-party-raw-skill-v1') {throw 'The raw check entry requires explicit central test ownership.'}
Assert-StandardCoreFrozenFiles -Files @($adapter.sourceValidation.frozenFiles)
foreach($path in @($DescriptorPath,$ArchivePath,$rawCheckEntryPath)) {
    if (@($adapter.sourceValidation.frozenFiles | Where-Object {[string]$_.path -ceq $path}).Count -ne 1) {throw 'Raw check input or entry point is not frozen exactly once.'}
}
if ($Check -ceq 'general') {
    Import-Module (Join-Path $PSScriptRoot 'third-party-skill-source.psm1') -Force
    $report=Test-ThirdPartySkillSource -SourceRoot $sourceRoot -DescriptorPath $DescriptorPath -ArchivePath $ArchivePath -SourceRepository $SourceRepository -SourceRevision $SourceRevision
    [void](Write-StandardCoreCapturedText -Path (Join-Path $runRoot 'repository-general-raw-package.json') -Value ($report | ConvertTo-Json -Depth 40))
    Assert-StandardCoreFrozenFiles -Files @($adapter.sourceValidation.frozenFiles)
    Write-Output 'The complete raw package and original archive projection passed the central general check.'
    return
}

if ([string]::IsNullOrWhiteSpace($PesterReceiptPath) -or @($adapter.sourceValidation.frozenFiles | Where-Object {[string]$_.path -ceq $PesterReceiptPath}).Count -ne 1) {throw 'The source Pester resolver receipt must be frozen.'}
$receipt=(Get-StandardValidationJsonSnapshot -Path $PesterReceiptPath -Context 'raw source Pester receipt').value
$policy=(Get-StandardValidationJsonSnapshot -Path (Join-Path $authorityRoot 'docs/standards/validation-toolchain.json') -Context 'raw source tool policy').value.tools.pester
if ([string]$receipt.toolName -cne 'pester' -or [string]$receipt.source -cne [string]$policy.source -or [string]$receipt.channel -cne 'latest-stable' -or
    [string]$receipt.resolutionRunId -cne $runId -or $receipt.frozenForRun -isnot [bool] -or -not $receipt.frozenForRun -or
    [string]$receipt.resolvedVersion -cne [string]$policy.approvedPayload.version -or [string]$receipt.approvedPayloadSha256 -cne [string]$policy.approvedPayload.sha256 -or
    [string]$receipt.modulePath -cne [string]$receipt.executablePath -or -not (Test-StandardValidationPathWithin -Path $receipt.modulePath -Root $receipt.installRoot) -or
    (Get-StandardValidationFileSha256 -Path $receipt.modulePath -Context 'source Pester manifest') -cne [string]$receipt.executableSha256) {throw 'The source Pester receipt does not bind the approved module and this run.'}
$beforeClosure=Get-StandardValidationDirectoryClosureSha256 -Root $receipt.installRoot -Context 'source Pester installed closure'
if ($beforeClosure -cne [string]$receipt.installedClosureSha256 -or $beforeClosure -cne [string]$receipt.dependencyClosureSha256) {throw 'The source Pester module closure changed.'}
$testFiles=@('third-party-skill-source.Tests.ps1','third-party-source-envelope.Tests.ps1')
$testRoot=Join-Path $authorityRoot 'tests'
$testInventory=@()
foreach ($file in $testFiles) {
    $path=Join-Path $testRoot $file
    $hash=Get-StandardValidationFileSha256 -Path $path -Context 'raw source central test'
    if (@($adapter.sourceValidation.frozenFiles | Where-Object {[string]$_.path -ceq $path -and [string]$_.sha256 -ceq $hash}).Count -ne 1) {throw 'The complete central Pester suite must be frozen.'}
    $testInventory += [pscustomobject]@{path=('tests/'+$file);sha256=$hash}
}
$candidateInventory=Get-StandardValidationInventory -Root $sourceRoot -Context 'raw source Pester candidate snapshot'
$snapshotRows=@($candidateInventory | Sort-Object -Property path -CaseSensitive | ForEach-Object {[pscustomobject]@{path=[string]$_.path;sha256=[string]$_.sha256}})
$snapshotHash=Get-StandardValidationTextSha256 -Value (ConvertTo-Json -InputObject $snapshotRows -Depth 3 -Compress)
Import-Module $receipt.modulePath -Force
$config=New-PesterConfiguration
$config.Run.Path=@($testFiles | ForEach-Object {Join-Path $testRoot $_})
$config.Run.PassThru=$true
$config.Run.RepoRoot=$authorityRoot
if (Test-Path -LiteralPath (Join-Path $authorityRoot 'Pester.BeforeContainer.ps1')) {throw 'The fixed central raw suite does not include a Pester container initialization hook.'}
$config.Output.Verbosity='None'
$result=Invoke-Pester -Configuration $config
$discovery=@($result.Tests | ForEach-Object {New-ThirdPartySourcePesterCase -Test $_ -TestRoot $testRoot -TestFiles $testFiles})
$execution=@($result.Tests | Where-Object {$_.Executed} | ForEach-Object {New-ThirdPartySourcePesterCase -Test $_ -TestRoot $testRoot -TestFiles $testFiles})
$containers=@($result.Containers | ForEach-Object {[IO.Path]::GetFileName([string]$_.Item)})
$afterClosure=Get-StandardValidationDirectoryClosureSha256 -Root $receipt.installRoot -Context 'source Pester installed closure after execution'
Assert-StandardCoreFrozenFiles -Files @($adapter.sourceValidation.frozenFiles)
if ($beforeClosure -cne $afterClosure -or (Get-StandardValidationInventorySha256 -Inventory (Get-StandardValidationInventory -Root $sourceRoot -Context 'Pester snapshot after execution')) -cne (Get-StandardValidationInventorySha256 -Inventory $candidateInventory)) {throw 'Source Pester changed a frozen module or candidate snapshot.'}
$complete=$result.Result -ceq 'Passed' -and $result.TotalCount -gt 0 -and $discovery.Count -eq $result.TotalCount -and $execution.Count -eq $result.TotalCount -and
    $result.PassedCount -eq $result.TotalCount -and $result.FailedBlocksCount -eq 0 -and $result.FailedContainersCount -eq 0 -and
    $result.SkippedCount -eq 0 -and $result.InconclusiveCount -eq 0 -and $result.NotRunCount -eq 0
$errors=@(@($result.FailedBlocks)+@($result.FailedContainers) | ForEach-Object {@($_.ErrorRecord | ForEach-Object {$_.ToString()})})
$cases=[ordered]@{
    schemaVersion=1;report='standard-core-pester-case-inventory-v1';coreRunId=$runId
    candidateSnapshotIdentity=@{coreRunId=$runId;root=$sourceRoot};candidateSnapshotSha256=$snapshotHash
    pesterModule=@{version=[string]$result.Version;manifestPath=[string]$receipt.modulePath;moduleRoot=[string]$receipt.installRoot;lockPath=$PesterReceiptPath;lockSha256=(Get-StandardValidationFileSha256 -Path $PesterReceiptPath -Context 'source Pester receipt');closureSha256Before=$beforeClosure;closureSha256After=$afterClosure}
    runPath='central/tests';runScope='complete-central-raw-skill-suite'
    testSourceIdentity=@{ownership='central-third-party-raw-skill-v1';root=$authorityRoot;authorityRevision=$AuthorityRevision;files=$testInventory}
    testFileInventory=$testFiles;containerFileInventory=$containers;discoveredCaseFileInventory=@($discovery.sourceFile | Sort-Object -Unique)
    caseDiscoveryCount=$discovery.Count;caseExecutionCount=$execution.Count;containerCount=@($result.Containers).Count
    failedBlockCount=[int]$result.FailedBlocksCount;failedContainerCount=[int]$result.FailedContainersCount
    terminalStatus=$(if($complete){'complete'}else{'failed'});complete=[bool]$complete;errors=$errors
    reportedCounts=@{Passed=[int]$result.PassedCount;Failed=[int]$result.FailedCount;Skipped=[int]$result.SkippedCount;Inconclusive=[int]$result.InconclusiveCount;NotRun=[int]$result.NotRunCount}
    shardIdentity='core-full';shardCaseIdentities=@($execution.identity)
    shardUnion=@{discoveryCount=$discovery.Count;executionUnionCount=$execution.Count;complete=[bool]$complete}
    discoveryCases=$discovery;executionCases=$execution
}
[void](Write-StandardCoreCapturedText -Path (Join-Path $runRoot 'repository-pester-case-inventory-v1.json') -Value ($cases | ConvertTo-Json -Depth 30))
[ordered]@{schemaVersion=1;report='standard-core-pester-result-v1';total=[int]$result.TotalCount;passed=[int]$result.PassedCount;failed=[int]$result.FailedCount;skipped=[int]$result.SkippedCount} | ConvertTo-Json -Compress
if (-not $complete) {exit 1}
