[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $WeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/unix-core-shard-weights.json'),
    [string] $WindowsWeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/windows-core-shard-weights.json'),
    [string] $RunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
    [ValidateRange(1, 2147483647)][int] $RunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 }),
    [string] $OutputDirectory = '',
    [switch] $DefineFunctionsOnly
)

$ErrorActionPreference = 'Stop'

$unixCoreParameters = @{
    RepositoryRoot = $RepositoryRoot
    WeightsPath = $WeightsPath
    RunId = $RunId
    RunAttempt = $RunAttempt
    DefineFunctionsOnly = [bool]$DefineFunctionsOnly
}
. (Join-Path $PSScriptRoot 'Get-WindowsCorePlan.ps1') -DefineFunctionsOnly
$RepositoryRoot = $unixCoreParameters.RepositoryRoot
$WeightsPath = $unixCoreParameters.WeightsPath
$RunId = $unixCoreParameters.RunId
$RunAttempt = $unixCoreParameters.RunAttempt
$DefineFunctionsOnly = $unixCoreParameters.DefineFunctionsOnly

function Sort-UnixCoreOrdinal {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Values)
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Get-UnixCoreSha256 {
    param([Parameter(Mandatory = $true)][string] $Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Read-UnixCoreShardWeights {
    param([Parameter(Mandatory = $true)][string] $Path)

    try { $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Unix Core shard weights are invalid JSON: $($_.Exception.Message)" }
    if ($configuration -isnot [pscustomobject] -or
        ($configuration.schemaVersion -isnot [int] -and $configuration.schemaVersion -isnot [long]) -or
        [int64]$configuration.schemaVersion -ne 1) {
        throw 'Unix Core shard weights require integer schemaVersion 1.'
    }
    if ($configuration.platforms -isnot [pscustomobject]) { throw 'Unix Core shard weights require a platforms object.' }
    $platformNames = [string[]]@($configuration.platforms.PSObject.Properties.Name)
    if ($platformNames.Count -ne 2 -or -not ($platformNames -ccontains 'linux') -or -not ($platformNames -ccontains 'macos')) {
        throw 'Unix Core shard weights must contain exactly the linux and macos platforms.'
    }

    $result = [ordered]@{}
    foreach ($platformId in @('linux','macos')) {
        $platform = $configuration.platforms.$platformId
        if ($platform -isnot [pscustomobject] -or
            ($platform.partitionCount -isnot [int] -and $platform.partitionCount -isnot [long]) -or
            [int64]$platform.partitionCount -lt 1 -or [int64]$platform.partitionCount -gt 12) {
            throw "Unix Core $platformId partitionCount must be an integer from 1 through 12."
        }
        if ($platform.weights -isnot [pscustomobject]) { throw "Unix Core $platformId weights must be an object." }
        $weights = @{}
        foreach ($property in @($platform.weights.PSObject.Properties)) {
            $numeric = $property.Value -is [int] -or $property.Value -is [long] -or
                $property.Value -is [double] -or $property.Value -is [decimal]
            if ($property.Name -notmatch '^[^/\\]+\.Tests\.ps1$' -or -not $numeric) {
                throw "Invalid Unix Core $platformId shard weight '$($property.Name)'."
            }
            $value = [double]$property.Value
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) {
                throw "Invalid Unix Core $platformId shard weight '$($property.Name)'."
            }
            $weights[$property.Name] = $value
        }
        $result[$platformId] = [pscustomobject][ordered]@{
            partitionCount = [int]$platform.partitionCount
            weights = $weights
        }
    }
    return [pscustomobject]$result
}

function New-UnixCoreShards {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('linux','macos')][string] $PlatformId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $SelectedTestFiles,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExpectedSkippedTests,
        [Parameter(Mandatory = $true)][ValidateRange(1,12)][int] $PartitionCount,
        [Parameter(Mandatory = $true)] $Weights
    )

    $weightedItems = @($SelectedTestFiles | ForEach-Object {
        $configured = if ($Weights -is [Collections.IDictionary]) { $Weights.Contains($_) } else { $null -ne $Weights.PSObject.Properties[$_] }
        $value = if ($configured) {
            if ($Weights -is [Collections.IDictionary]) { [double]$Weights[$_] } else { [double]$Weights.$_ }
        } else { [double]1 }
        [pscustomobject]@{ name = [string]$_; weight = $value }
    })
    $items = [Collections.Generic.List[object]]::new()
    foreach ($weight in @($weightedItems.weight | Sort-Object -Descending -Unique)) {
        $names = [string[]]@($weightedItems | Where-Object weight -eq $weight | ForEach-Object name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        foreach ($name in $names) { $items.Add([pscustomobject]@{ name=$name; weight=[double]$weight }) }
    }
    $partitions = @(for ($index = 0; $index -lt $PartitionCount; $index++) {
        [pscustomobject]@{ index=$index; load=[double]0; files=[Collections.Generic.List[string]]::new() }
    })
    foreach ($item in $items) {
        $target = (@($partitions | Sort-Object @{Expression='load';Descending=$false}, @{Expression='index';Descending=$false}))[0]
        $target.files.Add($item.name)
        $target.load += $item.weight
    }

    $shards = [Collections.Generic.List[object]]::new()
    foreach ($partition in $partitions) {
        if ($partition.files.Count -eq 0) { continue }
        $files = Sort-UnixCoreOrdinal ([string[]]$partition.files.ToArray())
        $fileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $files) { [void]$fileSet.Add($file) }
        $skips = [string[]]@(Sort-UnixCoreOrdinal ([string[]]@($ExpectedSkippedTests | Where-Object { $fileSet.Contains(($_ -split '::',2)[0]) })))
        $shards.Add([pscustomobject][ordered]@{
            id = '{0:D2}' -f ($partition.index + 1)
            platform = $PlatformId
            files = [string[]]$files
            expectedSkippedTests = [string[]]$skips
            weight = [Math]::Round([double]$partition.load, 1)
        })
    }
    return $shards.ToArray()
}

function Assert-UnixCoreShardCoverage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $SelectedTestFiles,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Shards,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExpectedSkippedTests
    )

    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $SelectedTestFiles) {
        if (-not $selected.Add($file)) { throw "Unix Core selected test inventory contains duplicate '$file'." }
    }
    $expectedSkips = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skip in $ExpectedSkippedTests) {
        if (-not $expectedSkips.Add($skip)) { throw "Unix Core expected skip inventory contains duplicate '$skip'." }
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $fileOwners = @{}
    $skipOwners = @{}
    foreach ($shard in $Shards) {
        if (-not $ids.Add([string]$shard.id)) { throw "Unix Core shard id '$($shard.id)' is duplicated." }
        $shardFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in @($shard.files)) {
            if (-not $selected.Contains([string]$file)) { throw "Unix Core shard contains extra file '$file'." }
            if (-not $shardFiles.Add([string]$file)) { throw "Unix Core shard contains duplicate file '$file'." }
            if (-not $fileOwners.ContainsKey([string]$file)) { $fileOwners[[string]$file] = 0 }
            $fileOwners[[string]$file]++
        }
        foreach ($skip in @($shard.expectedSkippedTests)) {
            if ($null -eq $skip) { continue }
            if (-not $expectedSkips.Contains([string]$skip)) { throw "Unix Core shard contains extra skip '$skip'." }
            $skipFile = ([string]$skip -split '::',2)[0]
            if (-not $shardFiles.Contains($skipFile)) { throw "Unix Core skip '$skip' is not in the shard that owns its file." }
            if (-not $skipOwners.ContainsKey([string]$skip)) { $skipOwners[[string]$skip] = 0 }
            $skipOwners[[string]$skip]++
        }
    }
    foreach ($file in $SelectedTestFiles) {
        if (-not $fileOwners.ContainsKey($file) -or $fileOwners[$file] -ne 1) { throw "Unix Core file '$file' must appear in exactly one shard." }
    }
    foreach ($skip in $ExpectedSkippedTests) {
        if (-not $skipOwners.ContainsKey($skip) -or $skipOwners[$skip] -ne 1) { throw "Unix Core skip '$skip' must appear in exactly one shard." }
    }
}

function Get-UnixCorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ShardWeightsPath,
        [Parameter(Mandatory = $true)][string] $WindowsShardWeightsPath,
        [string] $WorkflowRunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
        [ValidateRange(1,2147483647)][int] $WorkflowRunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 })
    )

    if ([string]::IsNullOrWhiteSpace($WorkflowRunId)) { throw 'Unix Core workflow run id cannot be empty.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $windowsPlan = Get-WindowsCorePlan -Root $rootPath -ShardWeightsPath $WindowsShardWeightsPath `
        -WorkflowRunId $WorkflowRunId -WorkflowRunAttempt $WorkflowRunAttempt
    $selectedFiles = [string[]]@($windowsPlan.Plan.selectedTestFiles)
    $selectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $selectedFiles) { [void]$selectedSet.Add($file) }
    $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $rootPath 'docs/standards/core-test-skip-inventory.json') | ConvertFrom-Json
    $weights = Read-UnixCoreShardWeights -Path $ShardWeightsPath
    $platforms = @(
        [pscustomobject][ordered]@{ id='linux'; display='Linux'; runner='ubuntu-latest'; asset='powershell-7.6.6-linux-x64.tar.gz'; sha256='DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC'; partitionCount=[int]$weights.linux.partitionCount },
        [pscustomobject][ordered]@{ id='macos'; display='macOS'; runner='macos-latest'; asset='powershell-7.6.6-osx-arm64.tar.gz'; sha256='6DF833D094EBAC1C1A74340D7B3437F4AAF5E03CE640484A1C4359F3CE8B3DB1'; partitionCount=[int]$weights.macos.partitionCount }
    )
    $allShards = [Collections.Generic.List[object]]::new()
    foreach ($platform in $platforms) {
        $expectedSkips = [string[]]@($inventory.platforms.($platform.id).expectedSkippedTests)
        if (@($expectedSkips | Select-Object -Unique).Count -ne $expectedSkips.Count) { throw "Unix Core $($platform.id) skip inventory contains duplicates." }
        foreach ($skip in $expectedSkips) {
            if ($skip -notmatch '^[^:/\\]+\.Tests\.ps1::\S.+$') { throw "Invalid Unix Core skip identifier '$skip'." }
            if (-not $selectedSet.Contains(($skip -split '::',2)[0])) { throw "Unix Core skip is outside the retained plan: '$skip'." }
        }
        $configuration = $weights.($platform.id)
        $shards = @(New-UnixCoreShards -PlatformId $platform.id -SelectedTestFiles $selectedFiles `
            -ExpectedSkippedTests $expectedSkips -PartitionCount $configuration.partitionCount -Weights $configuration.weights)
        Assert-UnixCoreShardCoverage -SelectedTestFiles $selectedFiles -Shards $shards -ExpectedSkippedTests $expectedSkips
        foreach ($shard in $shards) { $allShards.Add($shard) }
    }
    if ($allShards.Count -lt 2 -or $allShards.Count -gt 256) { throw "Unix Core matrix entry count must be from 2 through 256; got $($allShards.Count)." }

    $plan = [pscustomobject][ordered]@{
        schemaVersion = 2
        runId = [string]$WorkflowRunId
        runAttempt = [int]$WorkflowRunAttempt
        windowsPlanSha256 = [string]$windowsPlan.PlanSha256
        authorityTestFiles = [string[]]$windowsPlan.Plan.authorityTestFiles
        selectedTestFiles = $selectedFiles
        platforms = [object[]]$platforms
        shards = [object[]]$allShards.ToArray()
    }
    $canonicalJson = ConvertTo-Json -InputObject $plan -Depth 12 -Compress
    $platformById = @{}
    foreach ($platform in $platforms) { $platformById[$platform.id] = $platform }
    $include = [object[]]@($allShards | ForEach-Object {
        $platform = $platformById[$_.platform]
        $filesJson = ConvertTo-Json -InputObject ([string[]]$_.files) -Compress
        $skipsJson = ConvertTo-Json -InputObject ([string[]]@($_.expectedSkippedTests)) -Compress
        [pscustomobject][ordered]@{
            platform = $_.platform; display = $platform.display; runner = $platform.runner
            asset = $platform.asset; sha256 = $platform.sha256; shard = $_.id
            filesBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($filesJson))
            skipsBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($skipsJson))
        }
    })
    $matrixJson = ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ include=$include }) -Depth 8 -Compress
    return [pscustomobject][ordered]@{
        Plan = $plan
        CanonicalJson = $canonicalJson
        PlanSha256 = Get-UnixCoreSha256 -Text $canonicalJson
        MatrixJson = $matrixJson
    }
}

if (-not $DefineFunctionsOnly) {
    $result = Get-UnixCorePlan -Root $RepositoryRoot -ShardWeightsPath $WeightsPath -WindowsShardWeightsPath $WindowsWeightsPath `
        -WorkflowRunId $RunId -WorkflowRunAttempt $RunAttempt
    $destination = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $base = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
        Join-Path $base 'unix-core-plan'
    } else { [IO.Path]::GetFullPath($OutputDirectory) }
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $destination 'plan.json'), $result.CanonicalJson + "`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $destination 'plan.sha256'), $result.PlanSha256 + "`n", $utf8)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        $delimiter = 'SYP574_' + [Guid]::NewGuid().ToString('N')
        $output = "matrix<<$delimiter`n$($result.MatrixJson)`n$delimiter`nplanSha256=$($result.PlanSha256)`nplanRunAttempt=$($result.Plan.runAttempt)`n"
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, $output, $utf8)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summary = "### Unix Core plan`n"
        foreach ($platform in @('linux','macos')) {
            $shards = @($result.Plan.shards | Where-Object platform -ceq $platform)
            $summary += "`n#### $platform ($($shards.Count) shards)`n`n| Shard | Files | Weight |`n| --- | ---: | ---: |`n"
            foreach ($shard in $shards) { $summary += "| $($shard.id) | $(@($shard.files).Count) | $($shard.weight) |`n" }
        }
        $summary += "`n- SHA-256: ``$($result.PlanSha256)```n"
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary, $utf8)
    }
    Write-Output $result.CanonicalJson
}
