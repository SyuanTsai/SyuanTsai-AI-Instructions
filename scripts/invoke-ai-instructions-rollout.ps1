[CmdletBinding()]
param(
    [string[]] $SearchRoots,
    [string] $BootstrapPath,
    [string[]] $ExcludedRepositoryPaths=@(),
    [string[]] $AuthorityRepositoryUrls,
    [string[]] $OfficialFeloSkillRoots,
    [string] $ReportPath,
    [string] $GitExecutable='git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ai-instructions-rollout.psm1') -Force
if ([string]::IsNullOrWhiteSpace($BootstrapPath)) {
    $BootstrapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap-ai-instructions.ps1'
}
$arguments = @{
    SearchRoots=$SearchRoots
    BootstrapPath=$BootstrapPath
    ExcludedRepositoryPaths=$ExcludedRepositoryPaths
    OfficialFeloSkillRoots=$OfficialFeloSkillRoots
    ReportPath=$ReportPath
    GitExecutable=$GitExecutable
}
if ($null -ne $AuthorityRepositoryUrls) { $arguments.AuthorityRepositoryUrls=$AuthorityRepositoryUrls }
$result = Invoke-AiInstructionsRollout @arguments
$result | ConvertTo-Json -Depth 12
if (@($result.Failed).Count -gt 0) { throw "AI instruction rollout completed with $(@($result.Failed).Count) failed repository result(s)." }
