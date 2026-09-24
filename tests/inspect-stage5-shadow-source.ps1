param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $ExpectedHeadSha,
    [Parameter(Mandatory = $true)][string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ExpectedHeadSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Expected PR head must be a full lowercase Git commit.' }
$candidateRootPath = [IO.Path]::GetFullPath($CandidateRoot)
$gatePath = Join-Path $candidateRootPath 'scripts/Invoke-StandardAuthorityGate.ps1'
if (-not (Test-Path -LiteralPath $gatePath -PathType Leaf)) { throw 'Candidate authority gate is missing.' }
$headBefore = (& git -C $candidateRootPath rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $headBefore -cne $ExpectedHeadSha) { throw 'Candidate checkout does not match the event PR head.' }
$statusBefore = @(& git -C $candidateRootPath status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $statusBefore.Count -ne 0) { throw 'Candidate checkout is not clean before inspection.' }
$gateShaBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $gatePath).Hash.ToLowerInvariant()

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($gatePath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) { throw 'Candidate authority gate does not parse.' }
$functions = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    [string]::Equals($node.Name, 'Invoke-AuthorityLinuxIsolatedPester', [StringComparison]::Ordinal)
}, $true))
$isolatedPesterSource = if ($functions.Count -eq 1) { $functions[0].Extent.Text } else { '' }
$childWritesResult = $isolatedPesterSource.Contains('[IO.File]::WriteAllText([string]$config.resultPath')
$parentReadsResult = $isolatedPesterSource.Contains('Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath')
$parentReturnsChildCounts = $isolatedPesterSource.Contains('$result = $report.result')

$headAfter = (& git -C $candidateRootPath rev-parse --verify 'HEAD^{commit}').Trim()
$statusAfter = @(& git -C $candidateRootPath status --porcelain --untracked-files=all)
$gateShaAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $gatePath).Hash.ToLowerInvariant()
$candidateUnchanged = $LASTEXITCODE -eq 0 -and $headAfter -ceq $ExpectedHeadSha -and
    $statusAfter.Count -eq 0 -and $gateShaAfter -ceq $gateShaBefore
$evidence = [ordered]@{
    schemaVersion = 1
    mode = 'protected-shadow-static-diagnostic'
    authorityPass = $false
    expectedHeadSha = $ExpectedHeadSha
    observedHeadSha = $headAfter
    gateScriptSha256 = $gateShaBefore
    candidateUnchanged = $candidateUnchanged
    powershellVersion = [string]$PSVersionTable.PSVersion
    candidateCodeExecuted = $false
    pesterTestsRun = 0
    childWritesResult = $childWritesResult
    parentReadsResult = $parentReadsResult
    parentReturnsChildCounts = $parentReturnsChildCounts
    protectedSuiteReady = $false
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
Write-Host ($evidence | ConvertTo-Json -Depth 8)
if (-not $candidateUnchanged) { throw 'Candidate identity or filesystem changed during shadow inspection.' }
if ($childWritesResult -and $parentReadsResult -and $parentReturnsChildCounts) {
    throw 'Stage 5 still promotes a candidate-writable result report.'
}
throw 'Stage 5 protected suite/publisher is not ready; shadow remains fail closed.'
