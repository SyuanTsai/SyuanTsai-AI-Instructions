[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $EventName = [string]$env:GITHUB_EVENT_NAME,
    [string] $PullRequestHeadSha = [string]$env:PULL_REQUEST_HEAD_SHA,
    [string] $WeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/windows-core-shard-weights.json'),
    [string] $RunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
    [ValidateRange(1, 2147483647)][int] $RunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 }),
    [string] $OutputPath = '',
    [switch] $DefineFunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-WindowsCoreGitBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($Root)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'git did not start.' }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.MemoryStream]::new()
        try { $process.StandardOutput.BaseStream.CopyTo($stream); $bytes = $stream.ToArray() }
        finally { $stream.Dispose() }
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $($process.ExitCode): $errorText"
        }
        return ,$bytes
    }
    finally { $process.Dispose() }
}

function Invoke-WindowsCoreGitText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string[]] $Arguments)
    return [Text.Encoding]::UTF8.GetString((Invoke-WindowsCoreGitBytes -Root $Root -Arguments $Arguments)).Trim()
}

function Split-WindowsCoreNulRecords {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    if ($Bytes.Count -eq 0) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($text[$text.Length - 1] -ne [char]0) { throw 'NUL-delimited git output did not end with NUL.' }
    return [string[]]$text.Substring(0, $text.Length - 1).Split([char]0)
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
    if ($actual.Count -ne 6 -or (($actual | Sort-Object) -join "`n") -cne (($expected | Sort-Object) -join "`n")) {
        throw 'The Windows Core authority test inventory must remain the exact six policy-owned paths.'
    }
    return [string[]]$expected
}

function Test-WindowsCoreDocumentationPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    if ($Path -ceq 'README.md') { return $true }
    if ($Path -cnotmatch '^docs/.+\.md$') { return $false }
    if ($Path -cmatch '^docs/(standards|examples)/') { return $false }
    return $true
}

function Sort-WindowsCoreOrdinal {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Values)
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Test-WindowsCoreUnsafeChangedPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('"') -or $Path.Contains("`r") -or $Path.Contains("`n")) { return $true }
    if ($Path.Contains('\') -or $Path.StartsWith('/') -or $Path -match '(^|/)\.\.(/|$)') { return $true }
    return $false
}

function Test-WindowsCoreContentReference {
    param([Parameter(Mandatory = $true)][string] $Content,[Parameter(Mandatory = $true)][string] $RepositoryPath,[switch] $IncludeLeafName)
    $components = [string[]]@($RepositoryPath -split '[\\/]+')
    if ($components.Count -eq 0 -or @($components | Where-Object { $_.Length -eq 0 }).Count -ne 0) {
        throw "Repository reference path cannot be decomposed safely: '$RepositoryPath'."
    }
    $patterns = [Collections.Generic.List[string]]::new()
    $patterns.Add((($components | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]+'))
    if ($IncludeLeafName) { $patterns.Add([regex]::Escape($components[$components.Count - 1])) }
    foreach ($pattern in $patterns) {
        if ([regex]::IsMatch($Content, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $true }
    }
    return $false
}

function Get-WindowsCoreTrackedPaths {
    param([Parameter(Mandatory = $true)][string] $Root)
    return (Split-WindowsCoreNulRecords (Invoke-WindowsCoreGitBytes -Root $Root -Arguments @('ls-files', '-z')))
}

function Get-WindowsCoreChangedEntries {
    param([Parameter(Mandatory = $true)][string] $Root)
    $nameRecords = @(Split-WindowsCoreNulRecords (Invoke-WindowsCoreGitBytes -Root $Root -Arguments @('diff', '--name-status', '--no-renames', '-z', 'HEAD^1', 'HEAD')))
    $rawRecords = @(Split-WindowsCoreNulRecords (Invoke-WindowsCoreGitBytes -Root $Root -Arguments @('diff', '--raw', '--no-renames', '-z', 'HEAD^1', 'HEAD')))
    if (($nameRecords.Count % 2) -ne 0 -or ($rawRecords.Count % 2) -ne 0) { throw 'git diff returned an incomplete record pair.' }
    $modes = @{}
    for ($index = 0; $index -lt $rawRecords.Count; $index += 2) {
        $metadata = $rawRecords[$index]
        $path = $rawRecords[$index + 1]
        if ($metadata -notmatch '^:(?<old>[0-9]{6}) (?<new>[0-9]{6}) [0-9a-f]+ [0-9a-f]+ (?<status>[A-Z])$') {
            throw "git diff --raw returned an unsupported record: '$metadata'."
        }
        if ($modes.ContainsKey($path)) { throw "git diff returned duplicate raw path '$path'." }
        $modes[$path] = [pscustomobject]@{ oldMode = $Matches.old; newMode = $Matches.new; status = $Matches.status }
    }
    $entries = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $nameRecords.Count; $index += 2) {
        $status = $nameRecords[$index]
        $path = $nameRecords[$index + 1]
        if ($status -notmatch '^[A-Z]$' -or -not $modes.ContainsKey($path)) { throw "git diff name/raw records disagree for '$path'." }
        $mode = $modes[$path]
        if ($mode.status -cne $status) { throw "git diff status records disagree for '$path'." }
        $entries.Add([pscustomobject][ordered]@{ path = $path; status = $status; oldMode = $mode.oldMode; newMode = $mode.newMode })
    }
    if ($entries.Count -ne $modes.Count) { throw 'git diff name/raw path counts differ.' }
    return $entries.ToArray()
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
    return $values
}

function Get-WindowsCoreSelectedTests {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][ValidateSet('full','docs')][string] $Mode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ChangedPaths,
        [Parameter(Mandatory = $true)][string[]] $AuthorityTestFiles
    )
    $testRoot = Join-Path $Root 'tests'
    $authorityNames = [string[]]@($AuthorityTestFiles | ForEach-Object { [IO.Path]::GetFileName($_) })
    $all = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File -Recurse)
    if ($all.Count -eq 0) { throw 'Windows Core test discovery found no tests.' }
    $duplicateNames = @($all | Group-Object Name | Where-Object Count -ne 1)
    if ($duplicateNames.Count -ne 0) { throw "Windows Core requires unique test leaf names: $($duplicateNames.Name -join ', ')." }
    $nonAuthority = @($all | Where-Object { $authorityNames -cnotcontains $_.Name })
    if ($nonAuthority.Count -ne ($all.Count - 6)) { throw 'Windows Core exclusion did not remove exactly six authority tests.' }
    if ($Mode -ceq 'full') {
        return [string[]](Sort-WindowsCoreOrdinal ([string[]]$nonAuthority.Name))
    }

    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($required in @('licensing-scope.Tests.ps1', 'ai-instructions-contract.Tests.ps1')) {
        if (@($nonAuthority | Where-Object Name -ceq $required).Count -ne 1) { throw "Required docs-mode test '$required' is missing." }
        [void]$selected.Add($required)
    }
    foreach ($test in $nonAuthority) {
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $test.FullName
        foreach ($path in $ChangedPaths) {
            if (Test-WindowsCoreContentReference -Content $content -RepositoryPath $path -IncludeLeafName) {
                [void]$selected.Add($test.Name)
                break
            }
        }
    }
    $result = [string[]]@($selected)
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
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

function Write-WindowsCoreGitHubOutput {
    param([Parameter(Mandatory = $true)][string] $Name,[Parameter(Mandatory = $true)][string] $Value)
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) { return }
    $delimiter = 'SYP417_' + [Guid]::NewGuid().ToString('N')
    $text = "$Name<<$delimiter`n$Value`n$delimiter`n"
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, $text, [Text.UTF8Encoding]::new($false))
}

function Get-WindowsCorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Event,
        [string] $ExpectedPullRequestHead,
        [Parameter(Mandatory = $true)][string] $ShardWeightsPath,
        [string] $WorkflowRunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
        [ValidateRange(1, 2147483647)][int] $WorkflowRunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 })
    )
    if ([string]::IsNullOrWhiteSpace($WorkflowRunId)) { throw 'Windows Core workflow run id cannot be empty.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $authority = [string[]](Get-WindowsCoreAuthorityTestFiles -Root $rootPath)
    $mode = 'full'
    $reasons = [Collections.Generic.List[string]]::new()
    $changedPaths = [string[]]@()
    if ($Event -cne 'pull_request') {
        $reasons.Add("event '$Event' requires the full suite")
    }
    else {
        $parents = (Invoke-WindowsCoreGitText -Root $rootPath -Arguments @('rev-list', '--parents', '-n', '1', 'HEAD')) -split ' '
        if ($parents.Count -ne 3) { throw 'Pull-request checkout HEAD must be a merge commit with exactly two parents.' }
        $secondParent = Invoke-WindowsCoreGitText -Root $rootPath -Arguments @('rev-parse', '--verify', 'HEAD^2')
        if ($ExpectedPullRequestHead -notmatch '^[0-9a-fA-F]{40}$' -or -not [string]::Equals($secondParent, $ExpectedPullRequestHead, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Pull-request checkout HEAD^2 does not equal PULL_REQUEST_HEAD_SHA.'
        }
        try {
            $entries = @(Get-WindowsCoreChangedEntries -Root $rootPath)
            $changedPaths = [string[]](Sort-WindowsCoreOrdinal ([string[]]$entries.path))
            $fullReasons = [Collections.Generic.List[string]]::new()
            foreach ($entry in $entries) {
                if ($entry.status -cnotin @('A','M','D')) { $fullReasons.Add("unsupported change status $($entry.status): $($entry.path)") }
                if (($entry.oldMode -cne '000000' -and $entry.oldMode -cne '100644') -or ($entry.newMode -cne '000000' -and $entry.newMode -cne '100644')) {
                    $fullReasons.Add("non-regular file mode: $($entry.path)")
                }
                if (Test-WindowsCoreUnsafeChangedPath -Path $entry.path) { $fullReasons.Add("unsafe changed path: $($entry.path)") }
                elseif (-not (Test-WindowsCoreDocumentationPath -Path $entry.path)) { $fullReasons.Add("non-documentation path: $($entry.path)") }
            }
            if ($fullReasons.Count -eq 0) {
                $alwaysRunReferences = @(
                    'licensing-scope.json', # licensing-scope.Tests.ps1 always runs in docs mode.
                    'scripts/Invoke-StandardAuthorityGate.ps1', # The authority job always covers this entry point.
                    'scripts/Get-WindowsCorePlan.ps1', # Every lane runs this planner, so its allowlist literals cannot self-escalate documentation.
                    'docs/standards/validation-security-gate.json', # The authority job always validates this policy.
                    'docs/standards/schemas/validation-security-gate-v1.schema.json', # The authority job always validates this schema.
                    'scripts/test-syp101-production-smoke.ps1' # Windows Install Smoke owns this production smoke script.
                )
                $pesterTestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($testFile in @(Get-ChildItem -LiteralPath (Join-Path $rootPath 'tests') -Filter '*.Tests.ps1' -File -Recurse -ErrorAction Stop)) {
                    [void]$pesterTestPaths.Add([IO.Path]::GetRelativePath($rootPath, $testFile.FullName).Replace('\', '/'))
                }
                foreach ($trackedPath in @(Get-WindowsCoreTrackedPaths -Root $rootPath)) {
                    if (Test-WindowsCoreDocumentationPath -Path $trackedPath) { continue }
                    if ($pesterTestPaths.Contains($trackedPath.Replace('\', '/'))) { continue }
                    if ($alwaysRunReferences -ccontains $trackedPath) { continue }
                    $fullPath = Join-Path $rootPath $trackedPath
                    try { $trackedItem = Get-Item -Force -LiteralPath $fullPath -ErrorAction Stop }
                    catch {
                        $fullReasons.Add("tracked referrer '$trackedPath' could not be inspected as a regular file: $($_.Exception.Message)")
                        continue
                    }
                    if ($trackedItem.PSIsContainer -or ($trackedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $fullReasons.Add("tracked referrer '$trackedPath' is not a regular non-reparse file")
                        continue
                    }
                    try { $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $trackedItem.FullName -ErrorAction Stop }
                    catch {
                        $fullReasons.Add("tracked referrer '$trackedPath' could not be read: $($_.Exception.Message)")
                        continue
                    }
                    foreach ($changedPath in $changedPaths) {
                        if (Test-WindowsCoreContentReference -Content $content -RepositoryPath $changedPath) {
                            $fullReasons.Add("tracked source '$trackedPath' references '$changedPath'")
                        }
                    }
                }
            }
            if ($fullReasons.Count -eq 0) { $mode = 'docs'; $reasons.Add('all changed paths are unreferenced documentation') }
            else { foreach ($reason in $fullReasons) { $reasons.Add($reason) } }
        }
        catch {
            $mode = 'full'
            $reasons.Add("change discovery failed closed: $($_.Exception.Message)")
            $changedPaths = [string[]]@()
        }
    }
    $selected = [string[]](Get-WindowsCoreSelectedTests -Root $rootPath -Mode $mode -ChangedPaths $changedPaths -AuthorityTestFiles $authority)
    $allSkips = [string[]](Get-WindowsCoreSkipInventory -Root $rootPath)
    $selectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $selected) { [void]$selectedSet.Add($file) }
    $expectedSkips = [string[]]@(Sort-WindowsCoreOrdinal ([string[]]@($allSkips | Where-Object { $selectedSet.Contains(($_ -split '::', 2)[0]) })))
    if ($mode -ceq 'full' -and $expectedSkips.Count -ne 5) { throw 'Full Windows Core plan must retain exactly five reviewed skipped tests.' }
    $shards = @(New-WindowsCoreShards -SelectedTestFiles $selected -ExpectedSkippedTests $expectedSkips -ConfigurationPath $ShardWeightsPath)
    if ($shards.Count -eq 0) { throw 'Windows Core plan cannot contain zero shards.' }
    $plan = [pscustomobject][ordered]@{
        authorityTestFiles = $authority
        changedPaths = $changedPaths
        expectedSkippedTests = $expectedSkips
        mode = $mode
        partitionCount = [int]8
        reasons = [string[]]$reasons.ToArray()
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
    return [pscustomobject][ordered]@{
        Plan = $plan
        CanonicalJson = $json
        PlanSha256 = Get-WindowsCoreSha256 -Text $json
        MatrixJson = ConvertTo-Json -InputObject $matrix -Depth 6 -Compress
    }
}

if (-not $DefineFunctionsOnly) {
    $result = Get-WindowsCorePlan -Root $RepositoryRoot -Event $EventName -ExpectedPullRequestHead $PullRequestHeadSha -ShardWeightsPath $WeightsPath -WorkflowRunId $RunId -WorkflowRunAttempt $RunAttempt
    $destination = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path ([IO.Path]::GetTempPath()) 'windows-core-plan.json' }
        else { Join-Path $env:RUNNER_TEMP 'windows-core/plan.json' }
    } else { [IO.Path]::GetFullPath($OutputPath) }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::WriteAllText($destination, $result.CanonicalJson + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($destination)) 'plan.sha256'), $result.PlanSha256 + "`n", [Text.UTF8Encoding]::new($false))
    Write-WindowsCoreGitHubOutput -Name mode -Value $result.Plan.mode
    Write-WindowsCoreGitHubOutput -Name matrix -Value $result.MatrixJson
    Write-WindowsCoreGitHubOutput -Name planSha256 -Value $result.PlanSha256
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summary = "### Windows Core plan`n`n- Mode: ``$($result.Plan.mode)```n- Shards: $($result.Plan.shards.Count)`n- Tests: $($result.Plan.selectedTestFiles.Count)`n- SHA-256: ``$($result.PlanSha256)```n- Reasons: $($result.Plan.reasons -join '; ')`n"
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary, [Text.UTF8Encoding]::new($false))
    }
    Write-Output $result.CanonicalJson
}
