[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [Parameter(Mandatory = $true)][string] $LockPath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $SelectedSkillIds,
    [Parameter(Mandatory = $true)][hashtable] $SourceArchivePaths,
    [Parameter(Mandatory = $true)][string] $InstructionSourceArchivePath,
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $TargetRoot,
    [string] $ConfigurationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-routing.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-acquisition.psm1') -Force
Import-Module (Join-Path $scriptRoot 'skills-source-composition.psm1') -Force

$catalog = Test-SkillsCatalogDocument -CatalogPath $CatalogPath
try {
    $lock = Get-Content -Raw -Encoding UTF8 -LiteralPath ([System.IO.Path]::GetFullPath($LockPath)) | ConvertFrom-Json
}
catch {
    throw "Skills Catalog lock is not valid JSON: $LockPath. $($_.Exception.Message)"
}

$instructionArchive = [System.IO.Path]::GetFullPath($InstructionSourceArchivePath)
if (-not (Test-Path -LiteralPath $instructionArchive -PathType Leaf)) {
    throw "Instruction source archive does not exist: $instructionArchive"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\\', '/'))
$workingRoot = Join-Path $tempRoot ('syp79-multisource-' + [Guid]::NewGuid().ToString('N'))
$instructionExtract = Join-Path $workingRoot 'instruction-source'
$sourceStaging = Join-Path $workingRoot 'skill-sources'
$composedParent = Join-Path $workingRoot 'composed'
$composedRoot = Join-Path $composedParent 'repository'
$composedArchive = Join-Path $workingRoot 'composed-source.zip'

try {
    New-Item -ItemType Directory -Path $workingRoot, $instructionExtract, $composedParent | Out-Null

    # All selected Skill routing and source archive validation completes before the legacy bootstrap is invoked.
    $plan = Resolve-SkillsSourcePlan -Catalog $catalog -Lock $lock -SkillIds $SelectedSkillIds
    $resolved = Expand-ValidatedSkillsSourceArchives `
        -Plan $plan `
        -SourceArchivePaths $SourceArchivePaths `
        -WorkingRoot $sourceStaging

    Expand-Archive -LiteralPath $instructionArchive -DestinationPath $instructionExtract
    $instructionRoots = @(Get-ChildItem -LiteralPath $instructionExtract -Directory)
    if ($instructionRoots.Count -ne 1) {
        throw "Instruction source archive must contain exactly one repository root; found $($instructionRoots.Count)."
    }

    $composition = New-ComposedBootstrapSource `
        -InstructionSourceRoot $instructionRoots[0].FullName `
        -ResolvedSkills $resolved.Skills `
        -DestinationRoot $composedRoot

    Compress-Archive -LiteralPath $composedRoot -DestinationPath $composedArchive -CompressionLevel Optimal

    $legacyBootstrap = Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1'
    $arguments = @{
        SourceRepository = $SourceRepository
        SourceRef = $SourceRef
        SourceArchivePath = $composedArchive
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
        $arguments.TargetRoot = $TargetRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigurationPath)) {
        $arguments.ConfigurationPath = $ConfigurationPath
    }

    & $legacyBootstrap @arguments
}
finally {
    $resolvedWorkingRoot = [System.IO.Path]::GetFullPath($workingRoot)
    $expectedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe multi-source temporary cleanup path: $resolvedWorkingRoot"
    }
    Remove-Item -LiteralPath $resolvedWorkingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
