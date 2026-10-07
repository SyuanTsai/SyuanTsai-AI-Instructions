#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceRoot = [string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT,
    [Parameter(Mandatory=$true)][string]$DescriptorPath,
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$SourceRevision,
    [string]$OutputPath,
    [switch]$RequireApproved,
    [switch]$SourceValidationEnvelope
)
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { throw 'SourceRoot is required.' }
if ($SourceValidationEnvelope) {
    if ($env:STANDARD_VALIDATION_STAGE_ID -cne 'package-validation' -or $env:STANDARD_VALIDATION_TOOL_ID -cne 'package-adapter' -or
        [string]$env:STANDARD_VALIDATION_CANDIDATE_ID -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_CANDIDATE_ROOT)) {
        throw 'Source envelope requires the canonical package-adapter supervisor context.'
    }
    $comparison=if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
    if (-not [string]::Equals([IO.Path]::GetFullPath($SourceRoot),[IO.Path]::GetFullPath($env:STANDARD_VALIDATION_CANDIDATE_ROOT),$comparison)) { throw 'Source envelope candidate root mismatch.' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath=Join-Path (Get-Location).Path 'raw-source-report.json' }
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'An explicit standalone report OutputPath is required.' }
Import-Module (Join-Path $PSScriptRoot 'third-party-skill-source.psm1') -Force -ErrorAction Stop
$report=Test-ThirdPartySkillSource -SourceRoot $SourceRoot -DescriptorPath $DescriptorPath -ArchivePath $ArchivePath -SourceRepository $SourceRepository -SourceRevision $SourceRevision -RequireApproved:$RequireApproved
if ($SourceValidationEnvelope) {
    $actual=[string[]]@($report.skills | ForEach-Object {$_.id})
    $expected=[string[]]@(([string]$env:STANDARD_VALIDATION_ACTIVE_SKILLS).Split(';'))
    [Array]::Sort($actual,[StringComparer]::Ordinal);[Array]::Sort($expected,[StringComparer]::Ordinal)
    if ($expected.Count -eq 0 -or ($actual -join "`n") -cne ($expected -join "`n")) { throw 'Source envelope active inventory mismatch.' }
}
$stream=[IO.File]::Open([IO.Path]::GetFullPath($OutputPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 30)+"`n")
    $stream.Write($bytes,0,$bytes.Length)
} finally { $stream.Dispose() }
if ($SourceValidationEnvelope) {
    [ordered]@{
        schemaVersion=1;status='passed';decision='PASS';candidateIdentity=[string]$env:STANDARD_VALIDATION_CANDIDATE_ID
        activeSkills=@($actual);findings=@();adapterStatus='passed';adapterSurfaces=@('third-party-raw-skill')
        semanticRequired=$false;rawSourceEvidence=$report
    } | ConvertTo-Json -Depth 40 -Compress
}
else { $report }
