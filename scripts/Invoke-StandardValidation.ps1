[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $AdapterPath,
    [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
    [string] $OutputPath,
    [Parameter(Mandatory = $true)][string] $SourceRepository,
    [Parameter(Mandatory = $true)][string] $SourceRevision,
    [Parameter(Mandatory = $true)][string] $BaseRevision,
    [ValidateSet('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch')]
    [string] $EventName = 'local',
    [string] $CandidateArchiveSha256,
    [int] $TimeoutSeconds = 300,
    [string] $CancellationPath,
    [string] $TrustedToolRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $DevelopmentHarness,
    [switch] $SemanticTriggered,
    [switch] $SemanticConsent,
    [string] $SemanticProvider,
    [string] $SemanticPurpose,
    [string] $SemanticScope,
    [string] $SemanticEvidencePath,
    [string] $AiReviewEvidencePath,
    [string] $HumanApprovalEvidencePath,
    [string] $PublishInstallEvidencePath,
    [string] $PostInstallEvidencePath,
    [switch] $CompleteLifecycle,
    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StandardValidationStageDefinitions = @(
    [ordered]@{ order = 1; id = 'controlled-acquisition'; condition = 'always' },
    [ordered]@{ order = 2; id = 'integrity-verification'; condition = 'always' },
    [ordered]@{ order = 3; id = 'package-validation'; condition = 'always' },
    [ordered]@{ order = 4; id = 'skillspector-static'; condition = 'always' },
    [ordered]@{ order = 5; id = 'repository-tests'; condition = 'always' },
    [ordered]@{ order = 6; id = 'conditional-semantic-scan'; condition = 'when-triggered' },
    [ordered]@{ order = 7; id = 'ai-review'; condition = 'lifecycle-evidence' },
    [ordered]@{ order = 8; id = 'human-approval'; condition = 'lifecycle-evidence' },
    [ordered]@{ order = 9; id = 'publish-or-install'; condition = 'approved-release-or-authorized-install' },
    [ordered]@{ order = 10; id = 'post-install-verification'; condition = 'after-install' }
)

$script:StandardValidationExitCodes = [ordered]@{
    PASS = 0
    BLOCKED = 10
    FAILED = 20
    INVALID = 30
    CANCELLED = 40
}
$script:StandardValidationLastEvent = $null
$script:StandardValidationAuthorityEvidence = $null
$script:StandardValidationRepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:StandardValidationAuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Get-StandardValidationProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) { return ,$DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ,$DefaultValue }
    return ,$property.Value
}

function Get-StandardValidationRequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "INVALID|$Context is not a JSON object."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "INVALID|$Context is missing required property '$Name'."
    }
    return ,$property.Value
}

function Assert-StandardValidationExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "INVALID|$Context must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "INVALID|$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-StandardValidationSha256 {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "INVALID|$Context must be a lowercase SHA-256 value."
    }
}

function Assert-StandardValidationRevision {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "INVALID|$Context must be a lowercase immutable commit SHA."
    }
}

function Assert-StandardValidationSourceRepository {
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -cnotmatch '^https://[^/?#]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
        throw 'INVALID|SourceRepository must be a canonical HTTPS repository URL.'
    }
}

function Get-StandardValidationFullPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    try { return [System.IO.Path]::GetFullPath($Path) }
    catch { throw "INVALID|$Context is not a valid path: $($_.Exception.Message)" }
}

function Test-StandardValidationPathWithin {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $IncludeRoot
    )

    $fullPath = Get-StandardValidationFullPath -Path $Path -Context 'path'
    $fullRoot = (Get-StandardValidationFullPath -Path $Root -Context 'root').TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else { [System.StringComparison]::Ordinal }
    if ($IncludeRoot -and [string]::Equals($fullPath, $fullRoot, $comparison)) { return $true }
    return $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)
}

function Assert-StandardValidationOutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (Test-StandardValidationPathWithin -Path $Path -Root $Root -IncludeRoot) {
        throw "INVALID|$Context must not be under the candidate root."
    }
}

function Assert-StandardValidationDistinctRoots {
    param(
        [Parameter(Mandatory = $true)][string] $First,
        [Parameter(Mandatory = $true)][string] $Second,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ((Test-StandardValidationPathWithin -Path $First -Root $Second -IncludeRoot) -or
        (Test-StandardValidationPathWithin -Path $Second -Root $First -IncludeRoot)) {
        throw "INVALID|$Context must be outside both candidate and artifact roots."
    }
}

function Get-StandardValidationFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INVALID|$Context file is missing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-StandardValidationTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-StandardValidationJson {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INVALID|$Context JSON file is missing: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch { throw "INVALID|$Context is not parseable JSON: $($_.Exception.Message)" }
}

function Assert-StandardValidationSafeRelativePath {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '\\' -or $Value -match '^[A-Za-z]:' -or $Value.StartsWith('/') -or
        $Value -match '(^|/)\.\.?(/|$)' -or
        $Value -notmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') {
        throw "INVALID|$Context must be a safe repository-relative path."
    }
}

function Assert-StandardValidationNoReparsePoints {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Context)

    $rootItem = Get-Item -LiteralPath $Root -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "INVALID|$Context root must not be a reparse point."
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "INVALID|$Context contains a reparse point: $($item.FullName)"
        }
    }
}

function Get-StandardValidationInventory {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Context)

    Assert-StandardValidationNoReparsePoints -Root $Root -Context $Context
    $fullRoot = (Get-StandardValidationFullPath -Path $Root -Context $Context).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $entries = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($fullRoot.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
        Assert-StandardValidationSafeRelativePath -Value $relative -Context "$Context inventory path"
        $entries += [pscustomobject][ordered]@{
            path = $relative
            sha256 = (Get-StandardValidationFileSha256 -Path $file.FullName -Context $Context)
            length = [int64]$file.Length
        }
    }
    if ($entries.Count -eq 0) { throw "INVALID|$Context must contain at least one file." }
    return ,$entries
}

function Get-StandardValidationInventorySha256 {
    param([Parameter(Mandatory = $true)] $Inventory)

    $ordered = @($Inventory | Sort-Object path)
    $canonical = ($ordered | ForEach-Object { "$($_.path)`t$($_.sha256)`t$($_.length)`n" }) -join ''
    return Get-StandardValidationTextSha256 -Value $canonical
}

function Copy-StandardValidationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force -ErrorAction Stop
    }
}

function Assert-StandardValidationCandidateUnchanged {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedContentSha256,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ExpectedAdapterSha256
    )

    $currentInventory = Get-StandardValidationInventory -Root $CandidateRoot -Context 'candidate revalidation'
    $currentContentSha256 = Get-StandardValidationInventorySha256 -Inventory $currentInventory
    if ($currentContentSha256 -cne $ExpectedContentSha256) {
        throw 'FAILED|Candidate content changed during validation.'
    }
    $currentAdapterSha256 = Get-StandardValidationFileSha256 -Path $AdapterPath -Context 'adapter revalidation'
    if ($currentAdapterSha256 -cne $ExpectedAdapterSha256) {
        throw 'FAILED|Adapter configuration changed during validation.'
    }
}

function Assert-StandardValidationCommandSpec {
    param(
        [Parameter(Mandatory = $true)] $Spec,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][bool] $DevelopmentHarness
    )

    Assert-StandardValidationExactPropertySet -Object $Spec -Expected @('command', 'arguments') -Context $Context
    $command = Get-StandardValidationRequiredProperty -Object $Spec -Name 'command' -Context $Context
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$command)) {
        throw "INVALID|$Context command must be a non-empty path."
    }
    $commandPath = Get-StandardValidationFullPath -Path ([string]$command) -Context "$Context command"
    if (-not [System.IO.Path]::IsPathRooted([string]$command)) {
        throw "INVALID|$Context command must be an absolute path resolved by the trusted supervisor."
    }
    if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
        throw "INVALID|$Context command is not an installed file: $commandPath"
    }
    $commandItem = Get-Item -Force -LiteralPath $commandPath -ErrorAction Stop
    if (($commandItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "INVALID|$Context command must not be a reparse point: $commandPath"
    }
    Assert-StandardValidationOutsideRoot -Path $commandPath -Root $CandidateRoot -Context "$Context command"
    $arguments = Get-StandardValidationRequiredProperty -Object $Spec -Name 'arguments' -Context $Context
    if ($arguments -isnot [array]) { throw "INVALID|$Context arguments must be an array." }
    foreach ($argument in @($arguments)) {
        if ($argument -isnot [string]) { throw "INVALID|$Context arguments must contain only strings." }
        if ([string]$argument -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "INVALID|$Context arguments may not contain parent-directory traversal."
        }
        if ([System.IO.Path]::IsPathRooted([string]$argument) -and
            (Test-StandardValidationPathWithin -Path ([string]$argument) -Root $CandidateRoot -IncludeRoot)) {
            throw "INVALID|$Context argument reaches into the candidate root."
        }
    }
    $commandName = [System.IO.Path]::GetFileName($commandPath).ToLowerInvariant()
    if ($commandName -in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe', 'bash', 'bash.exe', 'sh', 'sh.exe', 'cmd', 'cmd.exe')) {
        if (@($arguments | Where-Object { [string]$_ -in @('-Command', '-EncodedCommand', '/c', '-c') }).Count -gt 0) {
            throw "INVALID|$Context may not use an inline command interpreter before the central barriers."
        }
    }
    if (-not $DevelopmentHarness) {
        $allowedRoots = @($TrustedToolRoot, $ArtifactsRoot, $PSScriptRoot, $PSHOME)
        $allowed = $false
        foreach ($allowedRoot in $allowedRoots) {
            if (Test-StandardValidationPathWithin -Path $commandPath -Root $allowedRoot -IncludeRoot) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) { throw "INVALID|$Context command is outside the trusted tool roots." }
    }
    return [pscustomobject][ordered]@{
        command = $commandPath
        arguments = @($arguments | ForEach-Object { [string]$_ })
        commandSha256 = Get-StandardValidationFileSha256 -Path $commandPath -Context "$Context command"
    }
}

function Get-StandardValidationSkillSet {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $SkillsRootRelative,
        [Parameter(Mandatory = $true)] $DeclaredSkills
    )

    Assert-StandardValidationSafeRelativePath -Value $SkillsRootRelative -Context 'adapter skillsRoot'
    if ($DeclaredSkills -isnot [array] -or @($DeclaredSkills).Count -eq 0) {
        throw 'INVALID|adapter activeSkills must be a non-empty array.'
    }
    $declared = @()
    $declaredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($skill in @($DeclaredSkills)) {
        if ($skill -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$skill) -or
            [string]$skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            -not $declaredSet.Add([string]$skill)) {
            throw 'INVALID|adapter activeSkills must contain unique safe Skill IDs.'
        }
        $declared += [string]$skill
    }
    $skillsRoot = Get-StandardValidationFullPath -Path (Join-Path $CandidateRoot $SkillsRootRelative) -Context 'adapter skillsRoot'
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
        throw "INVALID|adapter skillsRoot does not exist: $SkillsRootRelative"
    }
    Assert-StandardValidationNoReparsePoints -Root $skillsRoot -Context 'active Skill root'
    $discovered = @()
    $discoveredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($directory in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | Sort-Object Name)) {
        if (-not $discoveredSet.Add([string]$directory.Name)) {
            throw "INVALID|active Skill IDs are duplicated: $($directory.Name)"
        }
        $skillMd = Join-Path $directory.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
            throw "INVALID|active Skill directory '$($directory.Name)' has no SKILL.md."
        }
        if ([string]$directory.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "INVALID|active Skill directory '$($directory.Name)' has an unsafe ID."
        }
        $discovered += [string]$directory.Name
    }
    $declaredSorted = @($declared | Sort-Object)
    $discoveredSorted = @($discovered | Sort-Object)
    if (($declaredSorted -join "`n") -cne ($discoveredSorted -join "`n")) {
        throw "INVALID|adapter activeSkills does not exactly match the discovered active Skill set. Declared='$($declaredSorted -join ',')' Discovered='$($discoveredSorted -join ',')'."
    }
    $records = @()
    foreach ($skillId in $discoveredSorted) {
        $root = Join-Path $skillsRoot $skillId
        $inventory = Get-StandardValidationInventory -Root $root -Context "Skill '$skillId'"
        $records += [pscustomobject][ordered]@{
            id = $skillId
            root = $root
            inventory = $inventory
            inventorySha256 = Get-StandardValidationInventorySha256 -Inventory $inventory
        }
    }
    return [pscustomobject][ordered]@{
        root = $skillsRoot
        relative = $SkillsRootRelative
        ids = $discoveredSorted
        records = $records
    }
}

function Assert-StandardValidationAdapter {
    param(
        [Parameter(Mandatory = $true)] $Adapter,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][bool] $DevelopmentHarness
    )

    Assert-StandardValidationExactPropertySet -Object $Adapter -Expected @(
        'schemaVersion', 'adapter', 'mode', 'skillsRoot', 'activeSkills',
        'packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'repositoryTests'
    ) -Context 'standard validation adapter'
    if ((Get-StandardValidationRequiredProperty -Object $Adapter -Name 'schemaVersion' -Context 'adapter') -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $Adapter -Name 'adapter' -Context 'adapter') -cne 'standard-validation-adapter-v1') {
        throw 'INVALID|adapter has an unsupported schema identity.'
    }
    $mode = Get-StandardValidationRequiredProperty -Object $Adapter -Name 'mode' -Context 'adapter'
    if ($mode -notin @('production', 'development-harness') -or
        ($DevelopmentHarness -and [string]$mode -cne 'development-harness') -or
        (-not $DevelopmentHarness -and [string]$mode -cne 'production')) {
        throw 'INVALID|adapter mode does not match the selected supervisor mode.'
    }
    $skills = Get-StandardValidationSkillSet `
        -CandidateRoot $CandidateRoot `
        -SkillsRootRelative ([string](Get-StandardValidationRequiredProperty -Object $Adapter -Name 'skillsRoot' -Context 'adapter')) `
        -DeclaredSkills (Get-StandardValidationRequiredProperty -Object $Adapter -Name 'activeSkills' -Context 'adapter')
    $commands = [ordered]@{}
    foreach ($name in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        $commands[$name] = Assert-StandardValidationCommandSpec `
            -Spec (Get-StandardValidationRequiredProperty -Object $Adapter -Name $name -Context "adapter $name") `
            -Context "adapter $name" `
            -CandidateRoot $CandidateRoot `
            -ArtifactsRoot $ArtifactsRoot `
            -TrustedToolRoot $TrustedToolRoot `
            -DevelopmentHarness $DevelopmentHarness
    }
    $repositoryTests = Get-StandardValidationRequiredProperty -Object $Adapter -Name 'repositoryTests' -Context 'adapter repositoryTests'
    if ($repositoryTests -isnot [array] -or @($repositoryTests).Count -eq 0) {
        throw 'INVALID|adapter repositoryTests must contain at least one test dispatch.'
    }
    $testIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $testCommands = @()
    foreach ($test in @($repositoryTests)) {
        Assert-StandardValidationExactPropertySet -Object $test -Expected @('id', 'command', 'arguments') -Context 'adapter repository test'
        $testId = Get-StandardValidationRequiredProperty -Object $test -Name 'id' -Context 'adapter repository test'
        if ($testId -isnot [string] -or [string]$testId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or -not $testIds.Add([string]$testId)) {
            throw 'INVALID|adapter repository test IDs must be unique safe values.'
        }
        $testCommand = Assert-StandardValidationCommandSpec `
            -Spec ([pscustomobject][ordered]@{ command = $test.command; arguments = $test.arguments }) `
            -Context "adapter repository test '$testId'" `
            -CandidateRoot $CandidateRoot `
            -ArtifactsRoot $ArtifactsRoot `
            -TrustedToolRoot $TrustedToolRoot `
            -DevelopmentHarness $DevelopmentHarness
        $testCommands += [pscustomobject][ordered]@{ id = [string]$testId; command = $testCommand }
    }
    return [pscustomobject][ordered]@{
        mode = [string]$mode
        skills = $skills
        commands = $commands
        repositoryTests = $testCommands
    }
}

function New-StandardValidationStages {
    $stages = @()
    foreach ($definition in $script:StandardValidationStageDefinitions) {
        $stages += [pscustomobject][ordered]@{
            order = [int]$definition.order
            id = [string]$definition.id
            condition = [string]$definition.condition
            status = 'not-run'
            startedAt = $null
            endedAt = $null
            reason = $null
            events = @()
        }
    }
    return ,$stages
}

function Get-StandardValidationStage {
    param([Parameter(Mandatory = $true)] $Stages, [Parameter(Mandatory = $true)][string] $Id)
    return @($Stages | Where-Object { [string]$_.id -ceq $Id })[0]
}

function Start-StandardValidationStage {
    param([Parameter(Mandatory = $true)] $Stage)
    $Stage.startedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function Complete-StandardValidationStage {
    param(
        [Parameter(Mandatory = $true)] $Stage,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'blocked', 'cancelled', 'not-run', 'not-applicable')][string] $Status,
        [string] $Reason
    )
    $Stage.status = $Status
    $Stage.reason = $Reason
    $Stage.endedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function ConvertTo-StandardValidationProcessArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $quoted = @()
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]' -and $argument.Length -gt 0) {
            $quoted += $argument
            continue
        }
        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $quoted += ('"' + $escaped + '"')
    }
    return ($quoted -join ' ')
}

function Invoke-StandardValidationProcess {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable] $Environment,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $CancellationPath
    )

    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $status = 'failed'
    $exitCode = -1
    $stdout = ''
    $stderr = ''
    $cleanedUp = $true
    $process = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
            return [pscustomobject][ordered]@{
                startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                status = 'cancelled'; stdout = ''; stderr = 'Cancellation requested before process start.'; cleanedUp = $true
            }
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Command
        $startInfo.Arguments = ConvertTo-StandardValidationProcessArguments -Arguments $Arguments
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($entry in $Environment.GetEnumerator()) {
            $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }
        foreach ($credentialName in @(
            'GITHUB_TOKEN', 'GH_TOKEN', 'JIRA_API_TOKEN', 'NPM_TOKEN', 'NODE_AUTH_TOKEN',
            'PYPI_TOKEN', 'TWINE_PASSWORD', 'AZURE_DEVOPS_EXT_PAT', 'AWS_ACCESS_KEY_ID',
            'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'CODEX_API_KEY'
        )) {
            [void]$startInfo.EnvironmentVariables.Remove($credentialName)
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                return [pscustomobject][ordered]@{
                    startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                    status = 'startup-failed'; stdout = ''; stderr = 'Process.Start returned false.'; cleanedUp = $true
                }
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                status = 'startup-failed'; stdout = ''; stderr = $_.Exception.Message; cleanedUp = $true
            }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
        $terminationStatus = $null
        while (-not $process.HasExited) {
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
                $terminationStatus = 'cancelled'
                try { $process.Kill() } catch { }
                break
            }
            if ((Get-Date) -gt $deadline) {
                $terminationStatus = 'timeout'
                try { $process.Kill() } catch { }
                break
            }
            Start-Sleep -Milliseconds 50
        }
        if ($null -ne $terminationStatus) {
            try { [void]$process.WaitForExit(5000) } catch { }
            if (-not $process.HasExited) {
                $cleanedUp = $false
                try { $process.Kill() } catch { }
                try { [void]$process.WaitForExit(1000) } catch { }
            }
        }
        else { $process.WaitForExit() }
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = '' }
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = '' }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        if (-not $cleanedUp) { $status = 'cleanup-failed' }
        elseif ($null -ne $terminationStatus) { $status = $terminationStatus }
        elseif ($exitCode -eq 0) { $status = 'passed' }
        else { $status = 'failed' }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
    return [pscustomobject][ordered]@{
        startedAt = $startedAt
        endedAt = (Get-Date).ToUniversalTime().ToString('o')
        exitCode = [int]$exitCode
        status = [string]$status
        stdout = [string]$stdout
        stderr = [string]$stderr
        cleanedUp = [bool]$cleanedUp
    }
}

function Write-StandardValidationJsonCreate {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $Value)

    $fullPath = Get-StandardValidationFullPath -Path $Path -Context 'artifact output'
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $json = $Value | ConvertTo-Json -Depth 100
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    return $fullPath
}

function Write-StandardValidationStageReceipt {
    param([Parameter(Mandatory = $true)][string] $RunRoot, [Parameter(Mandatory = $true)] $Stage)

    $stageRoot = Join-Path $RunRoot ([string]$Stage.id)
    [void](New-Item -ItemType Directory -Path $stageRoot -Force)
    [void](Write-StandardValidationJsonCreate -Path (Join-Path $stageRoot 'receipt.json') -Value $Stage)
}

function Get-StandardValidationOutputHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stdout, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stderr)
    return Get-StandardValidationTextSha256 -Value ([string]$Stdout + "`n---stderr---`n" + [string]$Stderr)
}

function Assert-StandardValidationToolEnvelope {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stdout,
        [Parameter(Mandatory = $true)] $ProcessResult,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $SkillId,
        [string] $SkillInventorySha256,
        [string[]] $ExpectedActiveSkills
    )

    if ([string]$ProcessResult.status -ne 'passed') {
        if ([string]$ProcessResult.status -eq 'cancelled') { throw 'CANCELLED|A validation child process was cancelled.' }
        throw "FAILED|$Context process status was '$($ProcessResult.status)'."
    }
    if ([int]$ProcessResult.exitCode -ne 0) { throw "FAILED|$Context returned exit code $($ProcessResult.exitCode)." }
    if ([string]::IsNullOrWhiteSpace($Stdout)) { throw "FAILED|$Context produced no output envelope." }
    try { $envelope = $Stdout.Trim() | ConvertFrom-Json }
    catch { throw "FAILED|$Context produced unparsable output: $($_.Exception.Message)" }
    if ($envelope -is [array] -or $null -eq $envelope) { throw "FAILED|$Context output envelope must be an object." }
    if ((Get-StandardValidationProperty -Object $envelope -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $envelope -Name 'status') -cne 'passed' -or
        [string](Get-StandardValidationProperty -Object $envelope -Name 'decision') -cne 'PASS') {
        throw "FAILED|$Context did not report a passed versioned result."
    }
    if ([string](Get-StandardValidationProperty -Object $envelope -Name 'candidateIdentity') -cne $CandidateId) {
        throw "FAILED|$Context evidence is bound to a different candidate."
    }
    if (-not [string]::IsNullOrWhiteSpace($SkillId) -and
        [string](Get-StandardValidationProperty -Object $envelope -Name 'skillId') -cne $SkillId) {
        throw "FAILED|$Context evidence is missing the expected Skill identity '$SkillId'."
    }
    if (-not [string]::IsNullOrWhiteSpace($SkillInventorySha256) -and
        [string](Get-StandardValidationProperty -Object $envelope -Name 'skillInventorySha256') -cne $SkillInventorySha256) {
        throw "FAILED|$Context evidence is missing the expected Skill inventory identity."
    }
    if ($null -ne $ExpectedActiveSkills) {
        $actualSkills = Get-StandardValidationProperty -Object $envelope -Name 'activeSkills'
        if ($actualSkills -isnot [array] -or (@($actualSkills | Sort-Object) -join "`n") -cne (@($ExpectedActiveSkills | Sort-Object) -join "`n")) {
            throw "FAILED|$Context evidence does not cover the complete active Skill set."
        }
    }
    return ,$envelope
}

function Assert-StandardValidationFindings {
    param([Parameter(Mandatory = $true)] $Envelope, [Parameter(Mandatory = $true)][string] $Context)

    $findings = Get-StandardValidationProperty -Object $Envelope -Name 'findings'
    $requiresHuman = $false
    if ($null -eq $findings) { return $requiresHuman }
    if ($findings -isnot [array]) { throw "FAILED|$Context findings are not an array." }
    foreach ($finding in @($findings)) {
        $severity = [string](Get-StandardValidationProperty -Object $finding -Name 'severity')
        if ($severity -notin @('critical', 'high', 'medium', 'low', 'informational')) {
            throw "FAILED|$Context contains an unknown severity '$severity'."
        }
        if ($severity -in @('critical', 'high')) { throw "FAILED|$Context contains a $severity finding." }
        if ($severity -ceq 'medium') { $requiresHuman = $true }
    }
    return $requiresHuman
}

function Invoke-StandardValidationCommandAndRecord {
    param(
        [Parameter(Mandatory = $true)] $CommandSpec,
        [Parameter(Mandatory = $true)][string] $RunRoot,
        [Parameter(Mandatory = $true)][string] $StageId,
        [Parameter(Mandatory = $true)][string] $ToolId,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [string] $SkillId,
        [string] $SkillInventorySha256,
        [string[]] $ExpectedActiveSkills,
        [Parameter(Mandatory = $true)][string] $SnapshotRoot,
        [Parameter(Mandatory = $true)][string] $SkillsRoot,
        [Parameter(Mandatory = $true)][string] $ActiveSkillsText,
        [Parameter(Mandatory = $true)][string] $OriginalCandidateRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedCandidateContentSha256,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ExpectedAdapterSha256,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $CancellationPath
    )

    $eventId = [guid]::NewGuid().ToString()
    $script:StandardValidationLastEvent = $null
    if ($null -ne $script:StandardValidationAuthorityEvidence) {
        Assert-StandardValidationAuthorityUnchanged -Authority $script:StandardValidationAuthorityEvidence
    }
    $commandSha256Before = Get-StandardValidationFileSha256 -Path ([string]$CommandSpec.command) -Context "$StageId/$ToolId command"
    if ([string]$CommandSpec.commandSha256 -cne $commandSha256Before) {
        throw "FAILED|$StageId/$ToolId command changed after adapter resolution."
    }
    $environment = @{
        STANDARD_VALIDATION_STAGE_ID = $StageId
        STANDARD_VALIDATION_TOOL_ID = $ToolId
        STANDARD_VALIDATION_SKILL_ID = if ([string]::IsNullOrWhiteSpace($SkillId)) { '' } else { $SkillId }
        STANDARD_VALIDATION_CANDIDATE_ID = $CandidateId
        STANDARD_VALIDATION_CANDIDATE_ROOT = $SnapshotRoot
        STANDARD_VALIDATION_SKILLS_ROOT = $SkillsRoot
        STANDARD_VALIDATION_ACTIVE_SKILLS = $ActiveSkillsText
        STANDARD_VALIDATION_SKILL_ROOT = if ([string]::IsNullOrWhiteSpace($SkillId)) { '' } else { Join-Path $SkillsRoot $SkillId }
        STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 = if ([string]::IsNullOrWhiteSpace($SkillInventorySha256)) { '' } else { $SkillInventorySha256 }
        STANDARD_VALIDATION_EVENT_ID = $eventId
    }
    $processResult = Invoke-StandardValidationProcess `
        -Command ([string]$CommandSpec.command) `
        -Arguments @($CommandSpec.arguments) `
        -WorkingDirectory $RunRoot `
        -Environment $environment `
        -TimeoutSeconds $TimeoutSeconds `
        -CancellationPath $CancellationPath
    if ($null -ne $script:StandardValidationAuthorityEvidence) {
        Assert-StandardValidationAuthorityUnchanged -Authority $script:StandardValidationAuthorityEvidence
    }
    $commandSha256After = Get-StandardValidationFileSha256 -Path ([string]$CommandSpec.command) -Context "$StageId/$ToolId command"
    if ($commandSha256After -cne $commandSha256Before) {
        throw "FAILED|$StageId/$ToolId command changed during validation."
    }
    $eventDirectory = Join-Path $RunRoot ([string]$StageId)
    [void](New-Item -ItemType Directory -Path $eventDirectory -Force)
    $rawOutput = [ordered]@{
        schemaVersion = 1
        eventId = $eventId
        stageId = $StageId
        toolId = $ToolId
        skillId = if ([string]::IsNullOrWhiteSpace($SkillId)) { $null } else { $SkillId }
        candidateId = $CandidateId
        process = $processResult
        stdout = [string]$processResult.stdout
        stderr = [string]$processResult.stderr
    }
    $rawOutputPath = Join-Path $eventDirectory ("event-$eventId.json")
    [void](Write-StandardValidationJsonCreate -Path $rawOutputPath -Value $rawOutput)
    $event = [pscustomobject][ordered]@{
        eventId = $eventId
        stageId = $StageId
        toolId = $ToolId
        skillId = if ([string]::IsNullOrWhiteSpace($SkillId)) { $null } else { $SkillId }
        candidateId = $CandidateId
        commandSha256 = $commandSha256Before
        exitCode = [int]$processResult.exitCode
        status = [string]$processResult.status
        outputSha256 = Get-StandardValidationOutputHash -Stdout ([string]$processResult.stdout) -Stderr ([string]$processResult.stderr)
        outputPath = $rawOutputPath
        cleanedUp = [bool]$processResult.cleanedUp
    }
    $script:StandardValidationLastEvent = $event
    if (-not [bool]$processResult.cleanedUp) { throw 'FAILED|Validation child process cleanup failed.' }
    Assert-StandardValidationCandidateUnchanged `
        -CandidateRoot $OriginalCandidateRoot `
        -ExpectedContentSha256 $ExpectedCandidateContentSha256 `
        -AdapterPath $AdapterPath `
        -ExpectedAdapterSha256 $ExpectedAdapterSha256
    $envelope = Assert-StandardValidationToolEnvelope `
        -Stdout ([string]$processResult.stdout) `
        -ProcessResult $processResult `
        -CandidateId $CandidateId `
        -Context "$StageId/$ToolId" `
        -SkillId $SkillId `
        -SkillInventorySha256 $SkillInventorySha256 `
        -ExpectedActiveSkills $ExpectedActiveSkills
    return [pscustomobject][ordered]@{ event = $event; envelope = $envelope }
}

function Assert-StandardValidationImportedEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedType,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $evidence = Get-StandardValidationJson -Path $Path -Context $Context
    if ($evidence -is [array]) { throw "BLOCKED|$Context must be a JSON object." }
    if ((Get-StandardValidationProperty -Object $evidence -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $evidence -Name 'evidenceType') -cne $ExpectedType -or
        [string](Get-StandardValidationProperty -Object $evidence -Name 'candidateId') -cne $CandidateId) {
        throw "BLOCKED|$Context is not bound to this candidate and evidence type."
    }
    $status = [string](Get-StandardValidationProperty -Object $evidence -Name 'status')
    if ($status -notin @('passed', 'approved', 'authorized')) { throw "BLOCKED|$Context is not a successful evidence result." }
    if ($ExpectedType -ceq 'semantic') {
        if ((Get-StandardValidationProperty -Object $evidence -Name 'consentGranted') -ne $true) {
            throw 'BLOCKED|Semantic evidence does not prove explicit consent.'
        }
        foreach ($name in @('provider', 'purpose', 'scope')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $evidence -Name $name))) {
                throw "BLOCKED|Semantic evidence is missing '$name'."
            }
        }
    }
    if ($ExpectedType -ceq 'human-approval' -and
        ([string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $evidence -Name 'approver')) -or
         [string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $evidence -Name 'approvalTimestamp')))) {
        throw 'BLOCKED|Human approval evidence is missing the approver or approval timestamp.'
    }
    if ($ExpectedType -ceq 'ai-review' -and
        ($null -eq (Get-StandardValidationProperty -Object $evidence -Name 'reviewFindings') -or
         $null -eq (Get-StandardValidationProperty -Object $evidence -Name 'findingDisposition'))) {
        throw 'BLOCKED|AI review evidence is missing review findings or disposition.'
    }
    if ($ExpectedType -ceq 'publish-install' -and
        ((Get-StandardValidationProperty -Object $evidence -Name 'authorization') -ne $true -or
         [string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $evidence -Name 'releaseIdentity')))) {
        throw 'BLOCKED|Publish/install evidence does not prove explicit authorization and release identity.'
    }
    if ($ExpectedType -ceq 'post-install' -and
        ($null -eq (Get-StandardValidationProperty -Object $evidence -Name 'installedInventory') -or
         (Get-StandardValidationProperty -Object $evidence -Name 'postInstallIntegrity') -ne $true)) {
        throw 'BLOCKED|Post-install evidence is missing installed inventory or integrity verification.'
    }
    return ,$evidence
}

function Assert-StandardValidationContractFiles {
    param([Parameter(Mandatory = $true)][string] $RepositoryRoot)

    $contractPath = Join-Path $RepositoryRoot 'docs/standards/standard-validation-contract-v1.json'
    $contract = Get-StandardValidationJson -Path $contractPath -Context 'central validation contract'
    if ((Get-StandardValidationProperty -Object $contract -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $contract -Name 'contract') -cne 'standard-validation-contract-v1') {
        throw 'INVALID|Central validation contract identity is unsupported.'
    }
    $stages = Get-StandardValidationRequiredProperty -Object $contract -Name 'stages' -Context 'central validation contract'
    if ($stages -isnot [array] -or @($stages).Count -ne 10) { throw 'INVALID|Central validation contract must declare ten stages.' }
    for ($index = 0; $index -lt $script:StandardValidationStageDefinitions.Count; $index++) {
        if ([int]$stages[$index].order -ne [int]$script:StandardValidationStageDefinitions[$index].order -or
            [string]$stages[$index].id -cne [string]$script:StandardValidationStageDefinitions[$index].id) {
            throw 'INVALID|Central validation contract stage order is not canonical.'
        }
    }
    $policyPath = Join-Path $RepositoryRoot 'docs/standards/validation-security-gate.json'
    $policy = Get-StandardValidationJson -Path $policyPath -Context 'canonical validation security gate'
    $authorityGatePath = Join-Path $RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
    if (-not (Test-Path -LiteralPath $authorityGatePath -PathType Leaf)) {
        throw 'INVALID|Canonical authority gate is missing.'
    }
    try {
        . $authorityGatePath -DefineFunctionsOnly
        [void](Assert-AuthorityValidationSecurityGate -Policy $policy)
    }
    catch { throw "INVALID|Canonical validation security gate failed authority validation: $($_.Exception.Message)" }
    $policyIds = @($policy.stages | ForEach-Object { [string]$_.id })
    $contractIds = @($stages | ForEach-Object { [string]$_.id })
    if (($policyIds -join ',') -cne ($contractIds -join ',')) { throw 'INVALID|Validation contract and security policy stage orders diverge.' }
    $resolverPath = Join-Path $RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1'
    $toolchainPath = Join-Path $RepositoryRoot 'docs/standards/validation-toolchain.json'
    foreach ($authorityFile in @($resolverPath, $toolchainPath, $authorityGatePath, (Join-Path $RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'))) {
        if (-not (Test-Path -LiteralPath $authorityFile -PathType Leaf)) {
            throw "INVALID|Central authority file is missing: $authorityFile"
        }
    }
    try {
        $LASTEXITCODE = 0
        $resolverJson = (& $resolverPath -ValidatePolicyOnly 2>&1 | Out-String).Trim()
        if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) { throw "resolver exit code $LASTEXITCODE" }
        $resolverPolicy = $resolverJson | ConvertFrom-Json
    }
    catch { throw "INVALID|Central validation tool policy could not be verified: $($_.Exception.Message)" }
    if ([string]$resolverPolicy.policy -cne 'latest-stable-per-validation-run' -or
        [string]$resolverPolicy.sourceTrust.enforcement -cne 'exact-approved-source' -or
        [bool]$resolverPolicy.sourceTrust.failClosedOnMismatch -ne $true) {
        throw 'INVALID|Central resolver policy is not the approved latest-stable fail-closed policy.'
    }
    $authority = [ordered]@{
        repository = $script:StandardValidationAuthorityRepository
        runnerPath = 'scripts/Invoke-StandardValidation.ps1'
        runnerSha256 = Get-StandardValidationFileSha256 -Path (Join-Path $RepositoryRoot 'scripts/Invoke-StandardValidation.ps1') -Context 'central runner'
        contractPath = 'docs/standards/standard-validation-contract-v1.json'
        contractSha256 = Get-StandardValidationFileSha256 -Path $contractPath -Context 'central validation contract'
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = Get-StandardValidationFileSha256 -Path $policyPath -Context 'canonical validation security gate'
        authorityGatePath = 'scripts/Invoke-StandardAuthorityGate.ps1'
        authorityGateSha256 = Get-StandardValidationFileSha256 -Path $authorityGatePath -Context 'canonical authority gate'
        resolverPath = 'scripts/Resolve-StandardValidationTool.ps1'
        resolverSha256 = Get-StandardValidationFileSha256 -Path $resolverPath -Context 'central tool resolver'
    }
    return [pscustomobject][ordered]@{ contract = $contract; contractPath = $contractPath; policy = $policy; policyPath = $policyPath; authority = $authority }
}

function Assert-StandardValidationAuthorityUnchanged {
    param([Parameter(Mandatory = $true)] $Authority)

    $checks = @(
        [pscustomobject]@{ path = $Authority.runnerPath; sha256 = $Authority.runnerSha256; context = 'central runner' }
        [pscustomobject]@{ path = $Authority.contractPath; sha256 = $Authority.contractSha256; context = 'central validation contract' }
        [pscustomobject]@{ path = $Authority.policyPath; sha256 = $Authority.policySha256; context = 'canonical validation security gate' }
        [pscustomobject]@{ path = $Authority.authorityGatePath; sha256 = $Authority.authorityGateSha256; context = 'canonical authority gate' }
        [pscustomobject]@{ path = $Authority.resolverPath; sha256 = $Authority.resolverSha256; context = 'central tool resolver' }
    )
    foreach ($check in $checks) {
        $path = Join-Path $script:StandardValidationRepositoryRoot ([string]$check.path)
        $actual = Get-StandardValidationFileSha256 -Path $path -Context "$($check.context) revalidation"
        if ($actual -cne [string]$check.sha256) {
            throw "FAILED|$($check.context) changed during validation."
        }
    }
}

function New-StandardValidationCandidateEvidence {
    param(
        [Parameter(Mandatory = $true)][guid] $RunId,
        [Parameter(Mandatory = $true)][string] $State,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][bool] $ReleaseEligible,
        $Candidate,
        $Adapter,
        $Authority,
        [Parameter(Mandatory = $true)] $Stages,
        [string] $FailureState,
        [string] $FailureMessage,
        [string] $ArtifactRoot,
        [string] $LockPath
    )

        $result = [ordered]@{
        schemaVersion = 1
        evidence = 'standard-validation-evidence-v1'
        contract = 'standard-validation-contract-v1'
        runId = $RunId.ToString()
        state = $State
        exitCode = $ExitCode
        releaseEligible = $ReleaseEligible
        candidate = if ($null -eq $Candidate) { [ordered]@{ sourceRepository = 'https://invalid.invalid/invalid/invalid.git'; sourceRevision = ('0' * 40); baseRevision = ('0' * 40); eventName = 'invalid'; candidateId = ('0' * 64); contentSha256 = ('0' * 64); inventory = @([ordered]@{ path = 'unavailable'; sha256 = ('0' * 64); length = 0 }); activeSkills = @('invalid') } } else { $Candidate }
        adapter = if ($null -eq $Adapter) { [ordered]@{ schemaVersion = 1; sha256 = ('0' * 64); mode = 'production'; skillsRoot = 'unavailable'; activeSkills = @('invalid') } } else { $Adapter }
        authority = if ($null -eq $Authority) { [ordered]@{ repository = $script:StandardValidationAuthorityRepository; runnerPath = 'scripts/Invoke-StandardValidation.ps1'; runnerSha256 = ('0' * 64); contractPath = 'docs/standards/standard-validation-contract-v1.json'; contractSha256 = ('0' * 64); policyPath = 'docs/standards/validation-security-gate.json'; policySha256 = ('0' * 64); authorityGatePath = 'scripts/Invoke-StandardAuthorityGate.ps1'; authorityGateSha256 = ('0' * 64); resolverPath = 'scripts/Resolve-StandardValidationTool.ps1'; resolverSha256 = ('0' * 64) } } else { $Authority }
        stages = $Stages
        artifacts = [ordered]@{
            root = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { 'unavailable' } else { $ArtifactRoot }
            lockPath = if ([string]::IsNullOrWhiteSpace($LockPath)) { 'unavailable' } else { $LockPath }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureState)) {
        $result.failure = [ordered]@{ state = $FailureState; message = if ([string]::IsNullOrWhiteSpace($FailureMessage)) { 'Validation did not pass.' } else { $FailureMessage } }
    }
    return [pscustomobject]$result
}

function Invoke-StandardValidationRun {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [string] $OutputPath,
        [Parameter(Mandatory = $true)][string] $SourceRepository,
        [Parameter(Mandatory = $true)][string] $SourceRevision,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $EventName,
        [string] $CandidateArchiveSha256,
        [int] $TimeoutSeconds = 300,
        [string] $CancellationPath,
        [string] $TrustedToolRoot,
        [bool] $DevelopmentHarness = $false,
        [bool] $SemanticTriggered = $false,
        [bool] $SemanticConsent = $false,
        [string] $SemanticProvider,
        [string] $SemanticPurpose,
        [string] $SemanticScope,
        [string] $SemanticEvidencePath,
        [string] $AiReviewEvidencePath,
        [string] $HumanApprovalEvidencePath,
        [string] $PublishInstallEvidencePath,
        [string] $PostInstallEvidencePath,
        [bool] $CompleteLifecycle = $false
    )

    $script:StandardValidationAuthorityEvidence = $null
    $script:StandardValidationLastEvent = $null
    $runId = [guid]::NewGuid()
    $stages = New-StandardValidationStages
    $state = 'FAILED'
    $failureState = 'FAILED'
    $failureMessage = 'Validation did not complete.'
    $releaseEligible = $false
    $candidateEvidence = $null
    $adapterEvidence = $null
    $runRoot = $null
    $lockPath = $null
    $lockCreated = $false
    $finalWritten = $false
    $artifactRootFull = $null
    $outputFull = $null
    $originalCandidateRoot = $null
    $adapterFull = $null
    $expectedCandidateContentSha256 = $null
    $expectedAdapterSha256 = $null
    $candidateInventory = $null
    $adapter = $null
    $adapterResult = $null
    $contractResult = $null
    $authorityEvidence = $null
    $requiresHumanReview = $false

    try {
        if ($TimeoutSeconds -lt 1) { throw 'INVALID|TimeoutSeconds must be at least one second.' }
        Assert-StandardValidationSourceRepository -Value $SourceRepository
        Assert-StandardValidationRevision -Value $SourceRevision -Context 'SourceRevision'
        Assert-StandardValidationRevision -Value $BaseRevision -Context 'BaseRevision'
        if (-not [string]::IsNullOrWhiteSpace($CandidateArchiveSha256)) {
            Assert-StandardValidationSha256 -Value $CandidateArchiveSha256 -Context 'CandidateArchiveSha256'
        }
        if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) { $TrustedToolRoot = Split-Path -Parent $PSScriptRoot }
        $originalCandidateRoot = Get-StandardValidationFullPath -Path $CandidateRoot -Context 'CandidateRoot'
        $adapterFull = Get-StandardValidationFullPath -Path $AdapterPath -Context 'AdapterPath'
        $artifactRootFull = Get-StandardValidationFullPath -Path $ArtifactsRoot -Context 'ArtifactsRoot'
        if (-not (Test-Path -LiteralPath $originalCandidateRoot -PathType Container)) { throw 'INVALID|CandidateRoot is not a directory.' }
        if (-not (Test-Path -LiteralPath $adapterFull -PathType Leaf)) { throw 'INVALID|AdapterPath is not a file.' }
        Assert-StandardValidationDistinctRoots -First $originalCandidateRoot -Second $artifactRootFull -Context 'CandidateRoot and ArtifactsRoot'
        Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $originalCandidateRoot -Context 'AdapterPath'
        Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $artifactRootFull -Context 'AdapterPath'
        Assert-StandardValidationNoReparsePoints -Root $adapterFull -Context 'adapter'
        Assert-StandardValidationOutsideRoot -Path $artifactRootFull -Root (Split-Path -Parent $PSScriptRoot) -Context 'ArtifactsRoot'
        [void](New-Item -ItemType Directory -Path $artifactRootFull -Force)
        Assert-StandardValidationNoReparsePoints -Root $artifactRootFull -Context 'ArtifactsRoot'
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $artifactRootFull 'standard-validation-evidence.json' }
        $outputFull = Get-StandardValidationFullPath -Path $OutputPath -Context 'OutputPath'
        if (-not (Test-StandardValidationPathWithin -Path $outputFull -Root $artifactRootFull -IncludeRoot)) {
            throw 'INVALID|OutputPath must be under ArtifactsRoot.'
        }
        if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
            throw 'INVALID|OutputPath already exists; evidence is create-only and cannot be overwritten.'
        }
        $contractResult = Assert-StandardValidationContractFiles -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
        $authorityEvidence = $contractResult.authority
        $script:StandardValidationAuthorityEvidence = $authorityEvidence
        $adapter = Get-StandardValidationJson -Path $adapterFull -Context 'standard validation adapter'
        $adapterResult = Assert-StandardValidationAdapter `
            -Adapter $adapter `
            -CandidateRoot $originalCandidateRoot `
            -ArtifactsRoot $artifactRootFull `
            -TrustedToolRoot (Get-StandardValidationFullPath -Path $TrustedToolRoot -Context 'TrustedToolRoot') `
            -DevelopmentHarness $DevelopmentHarness
        $candidateInventory = Get-StandardValidationInventory -Root $originalCandidateRoot -Context 'candidate'
        $expectedCandidateContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateInventory
        $expectedAdapterSha256 = Get-StandardValidationFileSha256 -Path $adapterFull -Context 'adapter'
        $candidateId = Get-StandardValidationTextSha256 -Value (
            "$SourceRepository`n$SourceRevision`n$BaseRevision`n$EventName`n$expectedCandidateContentSha256`n$expectedAdapterSha256`n$CandidateArchiveSha256"
        )
        $candidateEvidence = [ordered]@{
            sourceRepository = $SourceRepository
            sourceRevision = $SourceRevision
            baseRevision = $BaseRevision
            eventName = $EventName
            candidateId = $candidateId
            contentSha256 = $expectedCandidateContentSha256
            inventory = $candidateInventory
            activeSkills = @($adapterResult.skills.ids)
        }
        $adapterEvidence = [ordered]@{
            schemaVersion = 1
            sha256 = $expectedAdapterSha256
            mode = $adapterResult.mode
            skillsRoot = $adapterResult.skills.relative
            activeSkills = @($adapterResult.skills.ids)
        }
        $executionKey = Get-StandardValidationTextSha256 -Value "$SourceRepository`n$SourceRevision`n$BaseRevision`n$EventName`n$candidateId"
        $lockDirectory = Join-Path $artifactRootFull 'locks'
        [void](New-Item -ItemType Directory -Path $lockDirectory -Force)
        $lockPath = Join-Path $lockDirectory "$executionKey.lock"
        try {
            $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $lockBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(([ordered]@{ runId = $runId.ToString(); candidateId = $candidateId; eventName = $EventName } | ConvertTo-Json -Compress) + [Environment]::NewLine)
                $lockStream.Write($lockBytes, 0, $lockBytes.Length); $lockStream.Flush()
            }
            finally { $lockStream.Dispose() }
            $lockCreated = $true
        }
        catch [System.IO.IOException] { throw 'INVALID|A canonical execution already exists for this event and candidate.' }
        $runRoot = Join-Path (Join-Path $artifactRootFull 'runs') $executionKey
        [void](New-Item -ItemType Directory -Path $runRoot -Force)
        $snapshotRoot = Join-Path $runRoot 'candidate-snapshot'
        Copy-StandardValidationSnapshot -Source $originalCandidateRoot -Destination $snapshotRoot
        $snapshotInventory = Get-StandardValidationInventory -Root $snapshotRoot -Context 'candidate snapshot'
        if ((Get-StandardValidationInventorySha256 -Inventory $snapshotInventory) -cne $expectedCandidateContentSha256) {
            throw 'FAILED|Candidate snapshot identity does not match the source candidate.'
        }
        $activeSkillsText = (@($adapterResult.skills.ids | Sort-Object) -join ';')
        $snapshotSkillsRoot = Join-Path $snapshotRoot $adapterResult.skills.relative

        $stage = Get-StandardValidationStage -Stages $stages -Id 'controlled-acquisition'
        Start-StandardValidationStage -Stage $stage
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'integrity-verification'
        Start-StandardValidationStage -Stage $stage
        Assert-StandardValidationCandidateUnchanged -CandidateRoot $originalCandidateRoot -ExpectedContentSha256 $expectedCandidateContentSha256 -AdapterPath $adapterFull -ExpectedAdapterSha256 $expectedAdapterSha256
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'package-validation'
        Start-StandardValidationStage -Stage $stage
        $invocation = Invoke-StandardValidationCommandAndRecord `
            -CommandSpec $adapterResult.commands.packageAdapter `
            -RunRoot $runRoot `
            -StageId $stage.id `
            -ToolId 'package-adapter' `
            -CandidateId $candidateId `
            -ExpectedActiveSkills $adapterResult.skills.ids `
            -SnapshotRoot $snapshotRoot `
            -SkillsRoot $snapshotSkillsRoot `
            -ActiveSkillsText $activeSkillsText `
            -OriginalCandidateRoot $originalCandidateRoot `
            -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
            -AdapterPath $adapterFull `
            -ExpectedAdapterSha256 $expectedAdapterSha256 `
            -TimeoutSeconds $TimeoutSeconds `
            -CancellationPath $CancellationPath
        $stage.events += $invocation.event
        $requiresHumanReview = [bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context 'package adapter')
        foreach ($skill in @($adapterResult.skills.records)) {
            foreach ($toolName in @('skillValidator', 'skillTools')) {
                $toolId = if ($toolName -ceq 'skillValidator') { 'skill-validator' } else { 'skill-tools' }
                $invocation = Invoke-StandardValidationCommandAndRecord `
                    -CommandSpec $adapterResult.commands[$toolName] `
                    -RunRoot $runRoot `
                    -StageId $stage.id `
                    -ToolId $toolId `
                    -CandidateId $candidateId `
                    -SkillId $skill.id `
                    -SkillInventorySha256 $skill.inventorySha256 `
                    -SnapshotRoot $snapshotRoot `
                    -SkillsRoot $snapshotSkillsRoot `
                    -ActiveSkillsText $activeSkillsText `
                    -OriginalCandidateRoot $originalCandidateRoot `
                    -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
                    -AdapterPath $adapterFull `
                    -ExpectedAdapterSha256 $expectedAdapterSha256 `
                    -TimeoutSeconds $TimeoutSeconds `
                    -CancellationPath $CancellationPath
                $stage.events += $invocation.event
                if ([bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context "$toolName/$($skill.id)")) { $requiresHumanReview = $true }
            }
        }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'skillspector-static'
        Start-StandardValidationStage -Stage $stage
        $invocation = Invoke-StandardValidationCommandAndRecord `
            -CommandSpec $adapterResult.commands.staticAnalyzer `
            -RunRoot $runRoot `
            -StageId $stage.id `
            -ToolId 'staticAnalyzer' `
            -CandidateId $candidateId `
            -ExpectedActiveSkills $adapterResult.skills.ids `
            -SnapshotRoot $snapshotRoot `
            -SkillsRoot $snapshotSkillsRoot `
            -ActiveSkillsText $activeSkillsText `
            -OriginalCandidateRoot $originalCandidateRoot `
            -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
            -AdapterPath $adapterFull `
            -ExpectedAdapterSha256 $expectedAdapterSha256 `
            -TimeoutSeconds $TimeoutSeconds `
            -CancellationPath $CancellationPath
        $stage.events += $invocation.event
        if ([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'scannerIdentity') -ne 'development-fixture-static-analyzer' -and
            [string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'scannerIdentity'))) {
            throw 'FAILED|Static evidence is missing scanner identity.'
        }
        if ([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'analyzerCompleteness') -cne 'complete') {
            throw 'FAILED|Static analyzer coverage is incomplete.'
        }
        $staticSkills = Get-StandardValidationProperty -Object $invocation.envelope -Name 'activeSkills'
        if ($staticSkills -isnot [array] -or (@($staticSkills | Sort-Object) -join "`n") -cne (@($adapterResult.skills.ids | Sort-Object) -join "`n")) {
            throw 'FAILED|Static analyzer did not cover every active Skill.'
        }
        if ([bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context 'Static analyzer')) { $requiresHumanReview = $true }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'repository-tests'
        Start-StandardValidationStage -Stage $stage
        foreach ($test in @($adapterResult.repositoryTests)) {
            $invocation = Invoke-StandardValidationCommandAndRecord `
                -CommandSpec $test.command `
                -RunRoot $runRoot `
                -StageId $stage.id `
                -ToolId $test.id `
                -CandidateId $candidateId `
                -SnapshotRoot $snapshotRoot `
                -SkillsRoot $snapshotSkillsRoot `
                -ActiveSkillsText $activeSkillsText `
                -OriginalCandidateRoot $originalCandidateRoot `
                -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
                -AdapterPath $adapterFull `
                -ExpectedAdapterSha256 $expectedAdapterSha256 `
                -TimeoutSeconds $TimeoutSeconds `
                -CancellationPath $CancellationPath
            $stage.events += $invocation.event
        }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'conditional-semantic-scan'
        if (-not $SemanticTriggered) {
            Complete-StandardValidationStage -Stage $stage -Status 'not-applicable' -Reason 'Semantic trigger was not present.'
        }
        elseif (-not $SemanticConsent) {
            Start-StandardValidationStage -Stage $stage
            Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Explicit semantic provider, scope, purpose, and consent are required.'
            Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
            throw 'BLOCKED|Semantic scan was triggered without explicit consent.'
        }
        else {
            Start-StandardValidationStage -Stage $stage
            if ([string]::IsNullOrWhiteSpace($SemanticProvider) -or [string]::IsNullOrWhiteSpace($SemanticPurpose) -or [string]::IsNullOrWhiteSpace($SemanticScope)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Semantic consent is missing provider, scope, or purpose.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw 'BLOCKED|Semantic consent metadata is incomplete.'
            }
            if ([string]::IsNullOrWhiteSpace($SemanticEvidencePath)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Semantic consent has no candidate-bound evidence file.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw 'BLOCKED|Semantic consent requires candidate-bound semantic evidence.'
            }
            $semanticFullPath = Get-StandardValidationFullPath -Path $SemanticEvidencePath -Context 'semantic evidence'
            Assert-StandardValidationOutsideRoot -Path $semanticFullPath -Root $originalCandidateRoot -Context 'semantic evidence'
            Assert-StandardValidationOutsideRoot -Path $semanticFullPath -Root $artifactRootFull -Context 'semantic evidence'
            $semantic = Assert-StandardValidationImportedEvidence -Path $semanticFullPath -ExpectedType 'semantic' -CandidateId $candidateId -Context 'semantic evidence'
            if ([string]$semantic.provider -cne $SemanticProvider -or [string]$semantic.purpose -cne $SemanticPurpose -or [string]$semantic.scope -cne $SemanticScope) {
                throw 'BLOCKED|Semantic evidence consent metadata does not match the invocation.'
            }
            $stage.events += [pscustomobject][ordered]@{ eventId = [guid]::NewGuid().ToString(); stageId = $stage.id; toolId = 'imported-semantic-evidence'; skillId = $null; candidateId = $candidateId; commandSha256 = Get-StandardValidationFileSha256 -Path $semanticFullPath -Context 'semantic evidence'; exitCode = 0; status = 'passed'; outputSha256 = Get-StandardValidationFileSha256 -Path $semanticFullPath -Context 'semantic evidence'; outputPath = $semanticFullPath; cleanedUp = $true }
            if ([bool](Assert-StandardValidationFindings -Envelope $semantic -Context 'semantic evidence')) { $requiresHumanReview = $true }
            Complete-StandardValidationStage -Stage $stage -Status passed
        }
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        foreach ($later in @(
            [pscustomobject]@{ id = 'ai-review'; type = 'ai-review'; path = $AiReviewEvidencePath },
            [pscustomobject]@{ id = 'human-approval'; type = 'human-approval'; path = $HumanApprovalEvidencePath },
            [pscustomobject]@{ id = 'publish-or-install'; type = 'publish-install'; path = $PublishInstallEvidencePath },
            [pscustomobject]@{ id = 'post-install-verification'; type = 'post-install'; path = $PostInstallEvidencePath }
        )) {
            $stage = Get-StandardValidationStage -Stages $stages -Id $later.id
            if (-not $CompleteLifecycle) {
                Complete-StandardValidationStage -Stage $stage -Status 'not-applicable' -Reason 'Validation-only run does not perform release lifecycle stages.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                continue
            }
            Start-StandardValidationStage -Stage $stage
            if ([string]::IsNullOrWhiteSpace([string]$later.path)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Required lifecycle evidence is missing.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw "BLOCKED|$($later.id) requires structured candidate-bound evidence."
            }
            $laterEvidencePath = Get-StandardValidationFullPath -Path ([string]$later.path) -Context "$($later.id) evidence"
            Assert-StandardValidationOutsideRoot -Path $laterEvidencePath -Root $originalCandidateRoot -Context "$($later.id) evidence"
            Assert-StandardValidationOutsideRoot -Path $laterEvidencePath -Root $artifactRootFull -Context "$($later.id) evidence"
            $imported = Assert-StandardValidationImportedEvidence -Path $laterEvidencePath -ExpectedType ([string]$later.type) -CandidateId $candidateId -Context "$($later.id) evidence"
            $stage.events += [pscustomobject][ordered]@{ eventId = [guid]::NewGuid().ToString(); stageId = $stage.id; toolId = "imported-$($later.type)"; skillId = $null; candidateId = $candidateId; commandSha256 = Get-StandardValidationFileSha256 -Path $laterEvidencePath -Context "$($later.id) evidence"; exitCode = 0; status = 'passed'; outputSha256 = Get-StandardValidationFileSha256 -Path $laterEvidencePath -Context "$($later.id) evidence"; outputPath = $laterEvidencePath; cleanedUp = $true }
            Complete-StandardValidationStage -Stage $stage -Status passed
            Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
        }
        if ($requiresHumanReview -and -not $CompleteLifecycle) {
            throw 'BLOCKED|A medium-severity finding requires human review before release.'
        }
        if ($CompleteLifecycle -and -not $DevelopmentHarness) { $releaseEligible = $true }
        Assert-StandardValidationAuthorityUnchanged -Authority $authorityEvidence
        $state = 'PASS'
        $failureState = $null
        $failureMessage = $null
    }
    catch {
        $rawMessage = [string]$_.Exception.Message
        $separator = $rawMessage.IndexOf('|')
        if ($separator -gt 0) {
            $candidateState = $rawMessage.Substring(0, $separator)
            if ($script:StandardValidationExitCodes.Contains($candidateState)) {
                $failureState = $candidateState
                $failureMessage = $rawMessage.Substring($separator + 1)
            }
            else { $failureState = 'FAILED'; $failureMessage = $rawMessage }
        }
        else { $failureState = 'FAILED'; $failureMessage = $rawMessage }
        $state = $failureState
        $releaseEligible = $false
        $failedStage = @($stages | Where-Object { $_.status -eq 'not-run' -and $null -ne $_.startedAt } | Select-Object -Last 1)
        if ($failedStage.Count -eq 1) {
            $status = if ($failureState -ceq 'BLOCKED') { 'blocked' } elseif ($failureState -ceq 'CANCELLED') { 'cancelled' } else { 'failed' }
            if ($null -ne $script:StandardValidationLastEvent -and
                @($failedStage[0].events | Where-Object { [string]$_.eventId -ceq [string]$script:StandardValidationLastEvent.eventId }).Count -eq 0) {
                $failedStage[0].events += $script:StandardValidationLastEvent
            }
            Complete-StandardValidationStage -Stage $failedStage[0] -Status $status -Reason $failureMessage
        }
        if ($failureState -ceq 'BLOCKED') {
            foreach ($remainingStage in @($stages | Where-Object { $_.status -eq 'not-run' })) {
                Complete-StandardValidationStage -Stage $remainingStage -Status 'not-applicable' -Reason 'A prior required consent, approval, or barrier was blocked.'
            }
        }
    }
    finally {
        $exitCode = [int]$script:StandardValidationExitCodes[$state]
        $finalEvidence = New-StandardValidationCandidateEvidence `
            -RunId $runId `
            -State $state `
            -ExitCode $exitCode `
            -ReleaseEligible $releaseEligible `
            -Candidate $candidateEvidence `
            -Adapter $adapterEvidence `
            -Authority $authorityEvidence `
            -Stages $stages `
            -FailureState $failureState `
            -FailureMessage $failureMessage `
            -ArtifactRoot $artifactRootFull `
            -LockPath $lockPath
        if ($null -ne $outputFull -and -not $finalWritten -and -not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
            try {
                [void](Write-StandardValidationJsonCreate -Path $outputFull -Value $finalEvidence)
                $finalWritten = $true
            }
            catch {
                if ($state -eq 'PASS') {
                    $state = 'FAILED'
                    $failureState = 'FAILED'
                    $failureMessage = "Final evidence write failed: $($_.Exception.Message)"
                    $finalEvidence = New-StandardValidationCandidateEvidence `
                        -RunId $runId `
                        -State $state `
                        -ExitCode ([int]$script:StandardValidationExitCodes[$state]) `
                        -ReleaseEligible $false `
                        -Candidate $candidateEvidence `
                        -Adapter $adapterEvidence `
                        -Authority $authorityEvidence `
                        -Stages $stages `
                        -FailureState $failureState `
                        -FailureMessage $failureMessage `
                        -ArtifactRoot $artifactRootFull `
                        -LockPath $lockPath
                }
            }
        }
    }
    return $finalEvidence
}

if ($DefineFunctionsOnly) { return }

$result = Invoke-StandardValidationRun `
    -CandidateRoot $CandidateRoot `
    -AdapterPath $AdapterPath `
    -ArtifactsRoot $ArtifactsRoot `
    -OutputPath $OutputPath `
    -SourceRepository $SourceRepository `
    -SourceRevision $SourceRevision `
    -BaseRevision $BaseRevision `
    -EventName $EventName `
    -CandidateArchiveSha256 $CandidateArchiveSha256 `
    -TimeoutSeconds $TimeoutSeconds `
    -CancellationPath $CancellationPath `
    -TrustedToolRoot $TrustedToolRoot `
    -DevelopmentHarness ([bool]$DevelopmentHarness) `
    -SemanticTriggered ([bool]$SemanticTriggered) `
    -SemanticConsent ([bool]$SemanticConsent) `
    -SemanticProvider $SemanticProvider `
    -SemanticPurpose $SemanticPurpose `
    -SemanticScope $SemanticScope `
    -SemanticEvidencePath $SemanticEvidencePath `
    -AiReviewEvidencePath $AiReviewEvidencePath `
    -HumanApprovalEvidencePath $HumanApprovalEvidencePath `
    -PublishInstallEvidencePath $PublishInstallEvidencePath `
    -PostInstallEvidencePath $PostInstallEvidencePath `
    -CompleteLifecycle ([bool]$CompleteLifecycle)
$result | ConvertTo-Json -Depth 100
exit ([int]$result.exitCode)
