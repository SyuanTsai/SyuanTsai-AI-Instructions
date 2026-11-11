[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $WeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/windows-core-shard-weights.json'),
    [string] $RunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
    [ValidateRange(1, 2147483647)][int] $RunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 }),
    [string] $OutputPath = '',
    [switch] $DefineFunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Sort-WindowsCoreOrdinal {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Values)
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Get-WindowsCoreAuthorityTestFiles {
    param([Parameter(Mandatory = $true)][string] $Root)
    . (Join-Path $Root 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
    $actual = @(
        Get-AuthorityTestPaths -Root $Root |
            ForEach-Object { [IO.Path]::GetRelativePath($Root, $_).Replace('\', '/') }
    )
    $expected = @(
        'tests/internal-source-continuation.Tests.ps1',
        'tests/skill-repository-standard.Tests.ps1',
        'tests/skill-repository-workflows.Tests.ps1',
        'tests/standard-authority-entry-preflight.Tests.ps1',
        'tests/standard-entry-point-binding.Tests.ps1',
        'tests/standard-core-pester-adapter.Tests.ps1'
    )
    if ($actual.Count -ne 6 -or ((Sort-WindowsCoreOrdinal ([string[]]$actual)) -join "`n") -cne ((Sort-WindowsCoreOrdinal ([string[]]$expected)) -join "`n")) {
        throw 'The Windows Core authority test inventory must remain the exact six policy-owned paths.'
    }
    return [string[]]$expected
}

function Get-WindowsCoreSelectedTests {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string[]] $AuthorityTestFiles
    )
    $testRoot = Join-Path $Root 'tests'
    $all = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File -Recurse)
    if ($all.Count -eq 0) { throw 'Windows Core test discovery found no tests.' }
    $relativePaths = [string[]]@($all | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') })
    if (@($relativePaths | Select-Object -Unique).Count -ne $relativePaths.Count) { throw 'Windows Core test discovery returned duplicate paths.' }
    $pathsByLeaf = [Collections.Generic.Dictionary[string,Collections.Generic.List[string]]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in $relativePaths) {
        $leaf = [IO.Path]::GetFileName($relativePath)
        if (-not $pathsByLeaf.ContainsKey($leaf)) {
            $pathsByLeaf.Add($leaf, [Collections.Generic.List[string]]::new())
        }
        $pathsByLeaf[$leaf].Add($relativePath)
    }
    $conflictingPaths = [Collections.Generic.List[string]]::new()
    foreach ($entry in $pathsByLeaf.GetEnumerator()) {
        if ($entry.Value.Count -gt 1) {
            foreach ($path in $entry.Value) { $conflictingPaths.Add($path) }
        }
    }
    if ($conflictingPaths.Count -gt 0) {
        $orderedConflicts = Sort-WindowsCoreOrdinal ([string[]]$conflictingPaths.ToArray())
        throw "Windows Core requires every tests/ *.Tests.ps1 leaf name to be case-insensitive unique. Conflicting relative paths: $($orderedConflicts -join ', ')."
    }
    $authoritySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $AuthorityTestFiles) { [void]$authoritySet.Add($path) }
    $nonAuthority = [string[]]@($relativePaths | Where-Object { -not $authoritySet.Contains($_) })
    if ($nonAuthority.Count -ne ($relativePaths.Count - 6)) { throw 'Windows Core exclusion did not remove exactly six authority tests.' }
    $names = [string[]]@($nonAuthority | ForEach-Object { [IO.Path]::GetFileName($_) })
    return [string[]](Sort-WindowsCoreOrdinal $names)
}

function Get-WindowsCoreSkipInventory {
    param([Parameter(Mandatory = $true)][string] $Root)
    $path = Join-Path $Root 'docs/standards/core-test-skip-inventory.json'
    $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    $values = [string[]]@($inventory.platforms.windows.expectedSkippedTests)
    if ($values.Count -ne 5 -or @($values | Select-Object -Unique).Count -ne 5) {
        throw 'Windows Core must retain exactly five unique reviewed skipped tests.'
    }
    foreach ($value in $values) {
        if ($value -notmatch '^[^:/\\]+\.Tests\.ps1::\S.+$') { throw "Invalid Windows Core skip identifier '$value'." }
    }
    return [string[]](Sort-WindowsCoreOrdinal $values)
}

function New-WindowsCoreShards {
    param(
        [Parameter(Mandatory = $true)][string[]] $SelectedTestFiles,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExpectedSkippedTests,
        [Parameter(Mandatory = $true)][string] $ConfigurationPath
    )
    $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigurationPath | ConvertFrom-Json
    if ([int]$configuration.schemaVersion -ne 1) { throw 'Windows Core shard weights require schemaVersion 1.' }
    $partitionCount = [int]$configuration.partitionCount
    if ($partitionCount -ne 8) { throw 'Windows Core must use exactly eight configured partitions.' }
    $weights = @{}
    foreach ($property in @($configuration.weights.PSObject.Properties)) {
        $value = [double]$property.Value
        if ($property.Name -notmatch '^[^/\\]+\.Tests\.ps1$' -or $value -le 0) { throw "Invalid Windows Core shard weight '$($property.Name)'." }
        $weights[$property.Name] = $value
    }
    $weightedItems = @($SelectedTestFiles | ForEach-Object {
        [pscustomobject]@{ name = $_; weight = $(if ($weights.ContainsKey($_)) { [double]$weights[$_] } else { [double]1 }) }
    })
    $items = [Collections.Generic.List[object]]::new()
    foreach ($weight in @($weightedItems.weight | Sort-Object -Descending -Unique)) {
        $names = [string[]]@($weightedItems | Where-Object weight -eq $weight | ForEach-Object name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        foreach ($name in $names) { $items.Add([pscustomobject]@{ name = $name; weight = [double]$weight }) }
    }
    $partitions = @(for ($index = 0; $index -lt $partitionCount; $index++) {
        [pscustomobject]@{ index = $index; load = [double]0; files = [Collections.Generic.List[string]]::new() }
    })
    foreach ($item in $items) {
        $target = (@($partitions | Sort-Object @{ Expression = 'load'; Descending = $false }, @{ Expression = 'index'; Descending = $false }))[0]
        $target.files.Add($item.name)
        $target.load += $item.weight
    }
    $shards = [Collections.Generic.List[object]]::new()
    foreach ($partition in $partitions) {
        if ($partition.files.Count -eq 0) { continue }
        $files = [string[]]$partition.files.ToArray()
        [Array]::Sort($files, [StringComparer]::Ordinal)
        $fileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $files) { [void]$fileSet.Add($file) }
        $skips = [string[]]@(Sort-WindowsCoreOrdinal ([string[]]@($ExpectedSkippedTests | Where-Object { $fileSet.Contains(($_ -split '::', 2)[0]) })))
        $shards.Add([pscustomobject][ordered]@{
            expectedSkippedTests = $skips
            files = $files
            id = '{0:D2}' -f ($partition.index + 1)
        })
    }
    return $shards.ToArray()
}

function ConvertTo-WindowsCoreCanonicalJson {
    param([Parameter(Mandatory = $true)] $Plan)
    return (ConvertTo-Json -InputObject $Plan -Depth 12 -Compress)
}

function Get-WindowsCoreSha256 {
    param([Parameter(Mandatory = $true)][string] $Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Assert-WindowsCoreMatrix {
    param(
        [Parameter(Mandatory = $true)][string] $MatrixJson,
        [Parameter(Mandatory = $true)][object[]] $ExpectedShards
    )
    try { $matrix = $MatrixJson | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Windows Core matrix is invalid JSON: $($_.Exception.Message)" }
    $include = @($matrix.include)
    if ($include.Count -eq 0 -or $include.Count -ne $ExpectedShards.Count -or $include.Count -gt 8) {
        throw "Windows Core matrix must contain exactly $($ExpectedShards.Count) unique planned shards."
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $include) {
        if ([string]$entry.id -notmatch '^[0-9]{2}$' -or -not $ids.Add([string]$entry.id)) { throw "Windows Core matrix contains an invalid or duplicate shard id '$($entry.id)'." }
        foreach ($property in @('filesBase64','skipsBase64')) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.$property)) { throw "Windows Core matrix shard '$($entry.id)' has an empty $property payload." }
        }
    }
    $expectedIds = [string[]]@($ExpectedShards | ForEach-Object id)
    if (((Sort-WindowsCoreOrdinal ([string[]]$ids)) -join "`n") -cne ((Sort-WindowsCoreOrdinal $expectedIds) -join "`n")) {
        throw 'Windows Core matrix shard ids differ from the planned shard ids.'
    }
}

function Write-WindowsCoreGitHubOutput {
    param([Parameter(Mandatory = $true)][string] $Name,[Parameter(Mandatory = $true)][string] $Value)
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) { return }
    $delimiter = 'SYP417_' + [Guid]::NewGuid().ToString('N')
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name<<$delimiter`n$Value`n$delimiter`n", [Text.UTF8Encoding]::new($false))
}

function Get-WindowsCorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ShardWeightsPath,
        [string] $WorkflowRunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
        [ValidateRange(1, 2147483647)][int] $WorkflowRunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 })
    )
    if ([string]::IsNullOrWhiteSpace($WorkflowRunId)) { throw 'Windows Core workflow run id cannot be empty.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $authority = [string[]](Get-WindowsCoreAuthorityTestFiles -Root $rootPath)
    $selected = [string[]](Get-WindowsCoreSelectedTests -Root $rootPath -AuthorityTestFiles $authority)
    $expectedSkips = [string[]](Get-WindowsCoreSkipInventory -Root $rootPath)
    $selectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $selected) { [void]$selectedSet.Add($file) }
    foreach ($identifier in $expectedSkips) {
        if (-not $selectedSet.Contains(($identifier -split '::', 2)[0])) { throw "Reviewed skip is outside the full selected test inventory: '$identifier'." }
    }
    $shards = @(New-WindowsCoreShards -SelectedTestFiles $selected -ExpectedSkippedTests $expectedSkips -ConfigurationPath $ShardWeightsPath)
    if ($shards.Count -eq 0) { throw 'Windows Core plan cannot contain zero shards.' }
    $plan = [pscustomobject][ordered]@{
        authorityTestFiles = $authority
        expectedSkippedTests = $expectedSkips
        partitionCount = [int]8
        runAttempt = [int]$WorkflowRunAttempt
        runId = [string]$WorkflowRunId
        selectedTestFiles = $selected
        shards = $shards
    }
    $json = ConvertTo-WindowsCoreCanonicalJson -Plan $plan
    $matrix = [pscustomobject][ordered]@{ include = [object[]]@($shards | ForEach-Object {
        [pscustomobject][ordered]@{
            id = $_.id
            filesBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject ([string[]]$_.files) -Compress)))
            skipsBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject ([string[]]$_.expectedSkippedTests) -Compress)))
        }
    }) }
    $matrixJson = ConvertTo-Json -InputObject $matrix -Depth 6 -Compress
    Assert-WindowsCoreMatrix -MatrixJson $matrixJson -ExpectedShards $shards
    return [pscustomobject][ordered]@{
        Plan = $plan
        CanonicalJson = $json
        PlanSha256 = Get-WindowsCoreSha256 -Text $json
        MatrixJson = $matrixJson
    }
}

if (-not $DefineFunctionsOnly) {
    $result = Get-WindowsCorePlan -Root $RepositoryRoot -ShardWeightsPath $WeightsPath -WorkflowRunId $RunId -WorkflowRunAttempt $RunAttempt
    $destination = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path ([IO.Path]::GetTempPath()) 'windows-core-plan.json' }
        else { Join-Path $env:RUNNER_TEMP 'windows-core/plan.json' }
    } else { [IO.Path]::GetFullPath($OutputPath) }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::WriteAllText($destination, $result.CanonicalJson + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($destination)) 'plan.sha256'), $result.PlanSha256 + "`n", [Text.UTF8Encoding]::new($false))
    Write-WindowsCoreGitHubOutput -Name matrix -Value $result.MatrixJson
    Write-WindowsCoreGitHubOutput -Name planSha256 -Value $result.PlanSha256
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summary = "### Windows Core plan`n`n- Shards: $($result.Plan.shards.Count)`n- Tests: $($result.Plan.selectedTestFiles.Count)`n- SHA-256: ``$($result.PlanSha256)```n"
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary, [Text.UTF8Encoding]::new($false))
    }
    Write-Output $result.CanonicalJson
}
