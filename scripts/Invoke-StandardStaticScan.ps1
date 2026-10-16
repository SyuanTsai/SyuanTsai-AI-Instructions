# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ToolReceiptPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedToolReceiptSha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedResolutionRunId,
    [Parameter(Mandatory=$true)][string]$SkillRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceRevision,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$CandidateIdentity,
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [Parameter(Mandatory=$true)][string]$EvidencePath,
    [ValidateRange(1,600)][int]$ScanTimeoutSeconds=300
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$staticTimeout=$ScanTimeoutSeconds
$authorityRoot=Split-Path -Parent $PSScriptRoot

function Assert-StaticPhysicalPath([string]$Path,[switch]$MayNotExist) {
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while(-not [string]::IsNullOrWhiteSpace($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Static parser input/output has a linked ancestor.'}
        } elseif(-not $MayNotExist -and $cursor -ceq $full) {throw 'Static parser input does not exist.'}
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -ceq $cursor){break}
        $cursor=$parent
    }
    return $full
}
function Static-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Read-StaticFrozenReceipt([string]$Path,[string]$ExpectedSha256) {
    # Hash and parse the same immutable byte snapshot, rather than reopening
    # a path after a separate file-hash check.
    $snapshot=[IO.File]::ReadAllBytes($Path)
    $snapshotHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($snapshot)).ToLowerInvariant()
    if($snapshotHash -cne $ExpectedSha256){throw 'Frozen scanner receipt digest differs.'}
    $decoder=[Text.UTF8Encoding]::new($false,$true)
    return ($decoder.GetString($snapshot).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
}

function Assert-StaticOutputLocation([string]$Output,[string[]]$ForbiddenRoots) {
    $full=[IO.Path]::GetFullPath($Output)
    foreach($root in $ForbiddenRoots){
        $rootFull=[IO.Path]::GetFullPath($root).TrimEnd([char[]]@('/','\'))
        $prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
        if([string]::Equals($full,$rootFull,[StringComparison]::OrdinalIgnoreCase) -or
           $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Static output is inside the bound candidate or frozen tooling.'
        }
    }
}

function Assert-StaticCoverageDelta($Original,$Corrected,$ProfileExecution) {
    $expected=@($ProfileExecution.candidateInventory | ForEach-Object {[string]$_.path} | Sort-Object)
    foreach($report in @($Original,$Corrected)){
        $components=Get-StandardValidationProperty -Object $report -Name 'components'
        if($components -isnot [array]){throw 'Scanner component inventory is not an explicit array.'}
        $paths=@($components | ForEach-Object {[string](Get-StandardValidationProperty -Object $_ -Name 'path')} | Sort-Object)
        if(($paths -join "`n") -cne ($expected -join "`n")){throw 'Scanner component inventory differs from the exact frozen Skill.'}
    }
    $completeness=Get-StandardValidationProperty -Object $Original -Name 'analysis_completeness'
    $exceptions=Get-StandardValidationProperty -Object $completeness -Name 'ledger_exceptions'
    if($exceptions -isnot [array]){throw 'Original scanner ledger exceptions are missing.'}
    foreach($exception in $exceptions){
        $analyzers=Get-StandardValidationProperty -Object $exception -Name 'analyzers'
        $target=[string](Get-StandardValidationProperty -Object $exception -Name 'path')
        $covered=@($ProfileExecution.correctedComponents | Where-Object {
            $_.partialAfterActualParserRun -is [bool] -and -not $_.partialAfterActualParserRun -and $_.candidatePaths -ccontains $target
        })
        $fatal=Get-StandardValidationProperty -Object $exception -Name 'fatal'
        if([string](Get-StandardValidationProperty -Object $exception -Name 'phase') -cne 'static' -or
           [string](Get-StandardValidationProperty -Object $exception -Name 'outcome') -cne 'partial' -or
           $fatal -isnot [bool] -or $fatal -or
           [string](Get-StandardValidationProperty -Object $exception -Name 'reason_code') -cne 'static_parse_limit' -or
           $analyzers -isnot [array] -or $analyzers.Count -ne 1 -or $analyzers[0] -cne 'static_patterns_tool_misuse' -or
           $covered.Count -ne 1){throw 'A native scanner exception lacks exact actual parser coverage.'}
    }
}
function Convert-StaticFindingComparisonKey($Issue) {
    # Official Finding._new_finding_id uses uuid4 for each graph run. Preserve
    # that raw ID in both reports; compare all other fields as an exact multiset.
    $runId=Get-StandardValidationProperty -Object $Issue -Name 'finding_id'
    $fingerprint=Get-StandardValidationProperty -Object $Issue -Name 'match_fingerprint'
    if($runId -isnot [string] -or $runId -cnotmatch '^finding-[0-9a-f]{32}$' -or
       $fingerprint -isnot [string] -or [string]::IsNullOrWhiteSpace($fingerprint)){
        throw 'Native finding lacks the supported run identity and stable fingerprint.'
    }
    $comparable=[ordered]@{}
    if($Issue -is [Collections.IDictionary]){
        foreach($name in $Issue.Keys){if([string]$name -cne 'finding_id'){$comparable[[string]$name]=$Issue[$name]}}
    }else{
        foreach($property in $Issue.PSObject.Properties){if($property.Name -cne 'finding_id'){$comparable[$property.Name]=$property.Value}}
    }
    return Convert-StandardValidationValueToCanonicalJson -Value $comparable -Context 'stable native static finding'
}

function Assert-StaticPreservedFindings($Original,$Corrected,$ProfileExecution) {
    $newIssues=Get-StandardValidationProperty -Object $Corrected -Name 'issues'
    $oldIssues=Get-StandardValidationProperty -Object $Original -Name 'issues'
    if($newIssues -isnot [array] -or $oldIssues -isnot [array]){throw 'Static finding collections are not explicit arrays.'}
    $newKeys=@($newIssues | ForEach-Object {Convert-StaticFindingComparisonKey -Issue $_})
    $newCounts=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach($newKey in $newKeys){if($newCounts.ContainsKey($newKey)){$newCounts[$newKey]++}else{$newCounts[$newKey]=1}}
    foreach($issue in $oldIssues){
        $key=Convert-StaticFindingComparisonKey -Issue $issue
        if($newCounts.ContainsKey($key) -and $newCounts[$key] -gt 0){$newCounts[$key]--;continue}
        $evidence=Get-StandardValidationProperty -Object $issue -Name 'evidence'
        $target=Get-StandardValidationProperty -Object $evidence -Name 'target_path'
        $reasons=Get-StandardValidationProperty -Object $evidence -Name 'reasons'
        $derived=[string](Get-StandardValidationProperty -Object $issue -Name 'id') -ceq 'AE1' -and
            [string](Get-StandardValidationProperty -Object $issue -Name 'pattern') -ceq 'Incomplete referenced artifact analysis' -and
            [string](Get-StandardValidationProperty -Object $evidence -Name 'target_disposition') -ceq 'partial' -and
            $reasons -is [array] -and $reasons.Count -gt 0
        foreach($reason in @($reasons)){
            $analyzers=Get-StandardValidationProperty -Object $reason -Name 'analyzers'
            if([string](Get-StandardValidationProperty -Object $reason -Name 'reason_code') -cne 'static_parse_limit' -or
               [string](Get-StandardValidationProperty -Object $reason -Name 'phase') -cne 'static' -or
               $analyzers -isnot [array] -or $analyzers.Count -ne 1 -or $analyzers[0] -cne 'static_patterns_tool_misuse'){$derived=$false}
        }
        $originalCompleteness=Get-StandardValidationProperty -Object $Original -Name 'analysis_completeness'
        $exceptions=Get-StandardValidationProperty -Object $originalCompleteness -Name 'ledger_exceptions'
        $matching=@($exceptions | Where-Object {
            [string](Get-StandardValidationProperty -Object $_ -Name 'path') -ceq [string]$target -and
            [string](Get-StandardValidationProperty -Object $_ -Name 'reason_code') -ceq 'static_parse_limit'
        })
        $completed=@((Get-StandardValidationProperty -Object $ProfileExecution -Name 'correctedComponents') | Where-Object {
            $partial=Get-StandardValidationProperty -Object $_ -Name 'partialAfterActualParserRun'
            $paths=Get-StandardValidationProperty -Object $_ -Name 'candidatePaths'
            $partial -is [bool] -and -not $partial -and $paths -is [array] -and $paths -ccontains [string]$target
        })
        if(-not $derived -or $matching.Count -eq 0 -or $completed.Count -ne 1){throw 'Corrected graph lost an original non-derived or still-uncovered finding.'}
    }
}
try {
    if($env:STANDARD_VALIDATION_CANDIDATE_ID -cne $CandidateIdentity -or
       [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_CANDIDATE_ROOT)) {
        throw 'Static parser bridge requires the existing candidate-bound source child.'
    }
    $receiptFull=Assert-StaticPhysicalPath $ToolReceiptPath
    $skillFull=Assert-StaticPhysicalPath $SkillRoot
    if(-not(Test-Path -LiteralPath $skillFull -PathType Container)){throw 'Skill root is not a directory.'}
    $candidateFull=Assert-StaticPhysicalPath $env:STANDARD_VALIDATION_CANDIDATE_ROOT
    $candidatePrefix=$candidateFull.TrimEnd([char[]]@('/','\'))+[IO.Path]::DirectorySeparatorChar
    if(-not $skillFull.StartsWith($candidatePrefix,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Static Skill root is outside the bound source candidate.'
    }
    $frozenAuthority=[ordered]@{}
    foreach($relative in @(
        'scripts/Invoke-StandardStaticScan.ps1','scripts/standard_static_powershell.py',
        'scripts/Get-StandardPowerShellSyntaxProof.ps1','scripts/Resolve-StandardValidationTool.ps1',
        'scripts/Invoke-StandardValidation.ps1','docs/standards/static-parser-host-ownership.json',
        'docs/standards/schemas/static-parser-host-ownership-v1.schema.json',
        'docs/standards/schemas/static-parser-profile-execution-v1.schema.json')){
        $frozenPath=Assert-StaticPhysicalPath (Join-Path $authorityRoot $relative)
        $frozenAuthority[$relative]=Static-Hash $frozenPath
    }
    $receipt=Read-StaticFrozenReceipt -Path $receiptFull -ExpectedSha256 $ExpectedToolReceiptSha256
    if($receipt.toolName -cne 'skillspector' -or $receipt.source -cne 'NVIDIA/SkillSpector' -or
       $receipt.channel -cne 'latest-stable' -or $receipt.resolvedVersion -cne '2.12.0' -or
       $receipt.frozenForRun -isnot [bool] -or -not $receipt.frozenForRun -or
       $receipt.resolutionRunId -cne $ExpectedResolutionRunId -or
       $receipt.identityKind -cne 'release-commit-asset-metadata-dependency-closure-and-executable' -or
       $receipt.offlineResolutionVerified -isnot [bool] -or -not $receipt.offlineResolutionVerified -or
       $receipt.consoleEntryPoint -cne 'skillspector.cli:app' -or
       $receipt.installedClosureSha256 -cnotmatch '^[0-9a-f]{64}$') {throw 'Scanner receipt has no supported frozen parser profile.'}
    $installFull=Assert-StaticPhysicalPath ([string]$receipt.installRoot)
    $scannerFull=Assert-StaticPhysicalPath ([string]$receipt.executablePath)
    $venv=Join-Path $installFull 'venv'
    $python=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Join-Path $venv 'Scripts/python.exe'}else{Join-Path $venv 'bin/python'}
    $python=Assert-StaticPhysicalPath $python
    $expectedScanner=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Join-Path $venv 'Scripts/skillspector.exe'}else{Join-Path $venv 'bin/skillspector'}
    if(-not [string]::Equals($scannerFull,[IO.Path]::GetFullPath($expectedScanner),[StringComparison]::OrdinalIgnoreCase) -or
       (Static-Hash $scannerFull) -cne [string]$receipt.executableSha256){throw 'Scanner executable differs from its frozen receipt.'}
    $reportFull=Assert-StaticPhysicalPath $ReportPath -MayNotExist
    $evidenceFull=Assert-StaticPhysicalPath $EvidencePath -MayNotExist
    $originalReport=$reportFull+'.original.json'
    $profileRecord=$evidenceFull+'.profile.json'
    if(@($reportFull,$evidenceFull,$originalReport,$profileRecord | Sort-Object -Unique).Count -ne 4){throw 'Static report/evidence paths collide.'}
    foreach($output in @($reportFull,$evidenceFull,$originalReport,$profileRecord)){
        [void](Assert-StaticPhysicalPath $output -MayNotExist)
        if(Test-Path -LiteralPath $output){throw 'Static report/evidence output must be new.'}
        if(-not(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($output)) -PathType Container)){throw 'Static output parent must already exist.'}
        Assert-StaticOutputLocation -Output $output -ForbiddenRoots @($candidateFull,$installFull,$authorityRoot)
    }
    $working=[IO.Path]::GetDirectoryName($reportFull)
    foreach($output in @($evidenceFull,$originalReport,$profileRecord)){
        if(-not [string]::Equals([IO.Path]::GetDirectoryName($output),$working,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Static report and evidence must share one owned artifact directory.'
        }
    }
    # Reuse the exact resolver closure and owned-process implementations.
    # Expected receipt identity comes from the existing trusted parent toolchain;
    # this entry point and its unsigned sidecar are not an independent authority.
    . (Join-Path $PSScriptRoot 'Resolve-StandardValidationTool.ps1') -ValidatePolicyOnly | Out-Null
    $before=Get-DirectoryClosureIdentity -Path $installFull
    if($before.sha256 -cne [string]$receipt.installedClosureSha256){throw 'Installed scanner closure differs before execution.'}
    . (Join-Path $PSScriptRoot 'Invoke-StandardValidation.ps1') -DefineFunctionsOnly -CandidateRoot $skillFull -AdapterPath 'unused' -ArtifactsRoot ([IO.Path]::GetDirectoryName($reportFull)) -SourceRepository 'https://example.test/parser/functions-only.git' -SourceRevision $SourceRevision -BaseRevision $SourceRevision
    $profilePath=Join-Path $authorityRoot 'docs/standards/static-parser-host-ownership.json'
    $schemaPath=Join-Path $authorityRoot 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json'
    if(-not((Get-Content -LiteralPath $profilePath -Raw) | Test-Json -SchemaFile $schemaPath)){throw 'Central parser policy is invalid.'}
    $pwsh=(Get-Process -Id $PID).Path
    if($PSVersionTable.PSVersion.ToString() -cne '7.6.6'){throw 'Native parser runtime has no reviewed grammar profile.'}
    $pwshHash=Static-Hash $pwsh
    $pythonHash=Static-Hash $python
    $working=[IO.Path]::GetDirectoryName($reportFull)
    # The shared process owner clears and rebuilds its own environment.
    $environment=@{STANDARD_VALIDATION_CANDIDATE_ID=$CandidateIdentity;STANDARD_VALIDATION_CANDIDATE_ROOT=$candidateFull}
    $nativeArguments=@('-I','-B','-c','from skillspector.cli import app; app()','scan',$skillFull,'--no-llm','--format','json','--output',$originalReport)
    $original=Invoke-StandardValidationProcess -Command $python -Arguments $nativeArguments -WorkingDirectory $working -Environment $environment -TimeoutSeconds $staticTimeout
    if($original.status -cne 'passed' -or $original.exitCode -ne 0 -or -not $original.cleanedUp -or -not(Test-Path -LiteralPath $originalReport -PathType Leaf)){throw 'Official native scanner baseline failed or omitted cleanup/report.'}
    $bridgePath=Join-Path $PSScriptRoot 'standard_static_powershell.py'
    $bridgeArguments=@('-I','-B',$bridgePath,'--pwsh',$pwsh,'--pwsh-sha256',$pwshHash,'--skill-root',$skillFull,'--report-path',$reportFull,'--evidence-path',$profileRecord,'--source-revision',$SourceRevision,'--candidate-identity',$CandidateIdentity)
    $corrected=Invoke-StandardValidationProcess -Command $python -Arguments $bridgeArguments -WorkingDirectory $working -Environment $environment -TimeoutSeconds $staticTimeout
    foreach($relative in $frozenAuthority.Keys){
        $frozenPath=Assert-StaticPhysicalPath (Join-Path $authorityRoot $relative)
        if((Static-Hash $frozenPath) -cne $frozenAuthority[$relative]){throw 'Central static parser authority changed during analysis.'}
    }
    $after=Get-DirectoryClosureIdentity -Path $installFull
    if($after.sha256 -cne $before.sha256 -or (Static-Hash $receiptFull) -cne $ExpectedToolReceiptSha256 -or
       (Static-Hash $python) -cne $pythonHash -or (Static-Hash $pwsh) -cne $pwshHash){throw 'Frozen tool/receipt/runtime changed during static analysis.'}
    if($corrected.status -cne 'passed' -or $corrected.exitCode -ne 0 -or -not $corrected.cleanedUp -or
       -not(Test-Path -LiteralPath $reportFull -PathType Leaf) -or -not(Test-Path -LiteralPath $profileRecord -PathType Leaf)){throw 'Corrected scanner graph failed or omitted cleanup/evidence.'}
    $executionSchema=Join-Path $authorityRoot 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json'
    if(-not((Get-Content -LiteralPath $profileRecord -Raw) | Test-Json -SchemaFile $executionSchema)){throw 'Profile execution record violates its strict schema.'}
    $profileExecution=Get-Content -LiteralPath $profileRecord -Raw | ConvertFrom-Json
    if($profileExecution.sourceRevision -cne $SourceRevision -or $profileExecution.candidateIdentity -cne $CandidateIdentity -or
       $profileExecution.correctedReportSha256 -cne (Static-Hash $reportFull)){throw 'Profile execution identity differs from this source child.'}
    $result=Get-Content -LiteralPath $reportFull -Raw | ConvertFrom-Json
    $originalNative=Get-Content -LiteralPath $originalReport -Raw | ConvertFrom-Json
    Assert-StaticCoverageDelta -Original $originalNative -Corrected $result -ProfileExecution $profileExecution
    Assert-StaticPreservedFindings -Original $originalNative -Corrected $result -ProfileExecution $profileExecution
    $record=[ordered]@{
        schemaVersion=1;profile='powershell-native-command-ownership-v1';signed=$false;authorizationGranted=$false
        applicabilityStatus='not-verified';executionProvenanceStatus='not-verified';authorizedOperations=@();releaseEligible=$false
        sourceRevision=$SourceRevision;candidateIdentity=$CandidateIdentity;resolverReceiptSha256=$ExpectedToolReceiptSha256
        resolutionRunId=$ExpectedResolutionRunId;installedClosureSha256=[string]$before.sha256;authorityFiles=$frozenAuthority
        pythonPath=$python;pythonSha256=$pythonHash;nativeParserRuntimePath=$pwsh;nativeParserRuntimeSha256=$pwshHash
        centralPolicySha256=(Static-Hash $profilePath);bridgeSha256=(Static-Hash $bridgePath)
        nativeParserSha256=(Static-Hash (Join-Path $PSScriptRoot 'Get-StandardPowerShellSyntaxProof.ps1'))
        originalReportPath=$originalReport;originalReportSha256=(Static-Hash $originalReport)
        correctedReportPath=$reportFull;correctedReportSha256=(Static-Hash $reportFull)
        profileExecutionPath=$profileRecord;profileExecutionSha256=(Static-Hash $profileRecord)
        originalProcess=$original;correctedProcess=$corrected
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 12)+"`n")
    $stream=[IO.File]::Open($evidenceFull,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
    if($result.execution_successful -isnot [bool] -or -not $result.execution_successful -or
       $result.analysis_completeness.is_complete -isnot [bool] -or -not $result.analysis_completeness.is_complete -or
       $result.analysis_completeness.status -cne 'complete'){throw 'Actual corrected graph still has incomplete coverage.'}
    [pscustomobject]@{status='completed';reportPath=$reportFull;evidencePath=$evidenceFull;profile='powershell-native-command-ownership-v1';applicabilityStatus='not-verified';executionProvenanceStatus='not-verified';authorizationGranted=$false;authorizedOperations=@();releaseEligible=$false} | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{status='failed';applicabilityStatus='not-verified';executionProvenanceStatus='not-verified';authorizationGranted=$false;authorizedOperations=@();releaseEligible=$false} | ConvertTo-Json -Compress
    [Console]::Error.WriteLine('Central static scan failed closed: '+$_.Exception.Message)
    exit 20
}
