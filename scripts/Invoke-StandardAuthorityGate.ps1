[CmdletBinding()]
param(
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [System.IO.Path]::GetTempPath() }
    ),

    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AuthorityProperty {
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

function Get-AuthorityRequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "$Context is missing required property '$Name'."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Context is missing required property '$Name'."
    }
    return ,$property.Value
}

function Assert-AuthorityExactString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        throw "$Context must be the exact string '$Expected'."
    }
}

function Assert-AuthorityNonNegativeInteger {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (($Value -isnot [int] -and $Value -isnot [long]) -or [int64]$Value -lt 0) {
        throw "$Context must be a non-negative integer."
    }
}

function Assert-AuthoritySha256 {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase SHA-256 value."
    }
}

function Assert-AuthorityFileIdentity {
    param(
        [Parameter(Mandatory = $true)] $PathValue,
        [Parameter(Mandatory = $true)] $Sha256Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($PathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$PathValue)) {
        throw "$Context path is missing."
    }
    $path = [System.IO.Path]::GetFullPath([string]$PathValue)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Context path is not an installed file: $path"
    }
    Assert-AuthoritySha256 -Value $Sha256Value -Context "$Context receipt hash"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$Sha256Value) {
        throw "$Context changed after resolution. Expected '$Sha256Value', got '$actual'."
    }
    return $path
}

function Assert-AuthorityPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $fullPath.StartsWith($fullRoot, $comparison)) {
        throw "$Context escapes the authority run install root: $fullPath"
    }
}

function Get-AuthorityDirectoryClosureSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $entries = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        $entries += [pscustomobject]@{
            path = $relative
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        }
    }
    if ($entries.Count -eq 0) { throw "Installed authority tool directory is empty: $root" }
    $canonical = ($entries | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-AuthorityJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Context JSON file is missing: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "$Context did not produce parseable JSON: $($_.Exception.Message)"
    }
}

function Invoke-AuthorityExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot
    )

    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) {
        throw "$Context executable is missing: $Command"
    }
    $stderrPath = Join-Path $DiagnosticRoot ("stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        $stdout = & $Command @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdoutText = @($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Get-Content -Raw -Encoding UTF8 -LiteralPath $stderrPath
        }
        else { '' }
        if ($exitCode -ne 0) {
            throw "$Context exited with code $exitCode.`nSTDOUT:`n$stdoutText`nSTDERR:`n$stderrText"
        }
        return $stdoutText
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-InstalledAuthorityToolReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $ToolName,
        [Parameter(Mandatory = $true)][string] $ExpectedSource,
        [Parameter(Mandatory = $true)][string] $InstallRoot
    )

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Receipt -Name 'schemaVersion' -Context "$ToolName receipt"
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
        throw "$ToolName receipt has an unsupported schemaVersion."
    }
    if ((Get-AuthorityProperty -Object $Receipt -Name 'toolName') -isnot [string] -or
        [string](Get-AuthorityProperty -Object $Receipt -Name 'toolName') -cne $ToolName) {
        throw "$ToolName receipt has the wrong tool identity."
    }
    if ((Get-AuthorityProperty -Object $Receipt -Name 'source') -isnot [string] -or
        [string](Get-AuthorityProperty -Object $Receipt -Name 'source') -cne $ExpectedSource) {
        throw "$ToolName receipt has an unapproved source."
    }
    Assert-AuthorityExactString -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'channel' -Context "$ToolName receipt") -Expected 'latest-stable' -Context "$ToolName receipt channel"
    if ((Get-AuthorityProperty -Object $Receipt -Name 'frozenForRun') -isnot [bool] -or
        -not [bool](Get-AuthorityProperty -Object $Receipt -Name 'frozenForRun')) {
        throw "$ToolName receipt is not frozen at latest-stable for this run."
    }
    foreach ($name in @('resolvedVersion', 'resolvedIdentity', 'identityKind')) {
        $value = Get-AuthorityProperty -Object $Receipt -Name $name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "$ToolName receipt is missing $name."
        }
    }

    $toolInstallRoot = Get-AuthorityProperty -Object $Receipt -Name 'installRoot'
    if ($toolInstallRoot -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$toolInstallRoot) -or
        -not (Test-Path -LiteralPath ([string]$toolInstallRoot) -PathType Container)) {
        throw "$ToolName receipt is missing its persistent install root."
    }
    Assert-AuthorityPathWithinRoot -Path ([string]$toolInstallRoot) -Root $InstallRoot -Context "$ToolName install root"

    $executablePath = Assert-AuthorityFileIdentity `
        -PathValue (Get-AuthorityProperty -Object $Receipt -Name 'executablePath') `
        -Sha256Value (Get-AuthorityProperty -Object $Receipt -Name 'executableSha256') `
        -Context "$ToolName executable"
    Assert-AuthorityPathWithinRoot -Path $executablePath -Root ([string]$toolInstallRoot) -Context "$ToolName executable"

    Assert-AuthoritySha256 `
        -Value (Get-AuthorityProperty -Object $Receipt -Name 'dependencyClosureSha256') `
        -Context "$ToolName dependency closure"
    $closure = Get-AuthorityProperty -Object $Receipt -Name 'dependencyClosure'
    if ($closure -isnot [array] -or @($closure).Count -le 0) {
        throw "$ToolName receipt does not contain a dependency/install closure."
    }

    return $executablePath
}

function Assert-AuthorityPolicyReceipt {
    param([Parameter(Mandatory = $true)] $Receipt)

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Receipt -Name 'schemaVersion' -Context 'Validation policy receipt'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
        throw 'Canonical validation policy receipt has an unsupported schemaVersion.'
    }
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'policy' -Context 'Validation policy receipt') `
        -Expected 'latest-stable-per-validation-run' `
        -Context 'Validation policy receipt policy'
    $sourceTrust = Get-AuthorityRequiredProperty -Object $Receipt -Name 'sourceTrust' -Context 'Validation policy receipt'
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $sourceTrust -Name 'enforcement' -Context 'Validation policy sourceTrust') `
        -Expected 'exact-approved-source' `
        -Context 'Validation policy sourceTrust enforcement'
    $failClosed = Get-AuthorityRequiredProperty -Object $sourceTrust -Name 'failClosedOnMismatch' -Context 'Validation policy sourceTrust'
    $recordIdentity = Get-AuthorityRequiredProperty -Object $Receipt -Name 'recordResolvedIdentityWhenAvailable' -Context 'Validation policy receipt'
    if ($failClosed -isnot [bool] -or -not [bool]$failClosed -or
        $recordIdentity -isnot [bool] -or -not [bool]$recordIdentity) {
        throw 'Canonical validation policy receipt is incomplete or untrusted.'
    }
}

function Assert-AuthorityPesterResult {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [int] $MinimumTotalCount = 35,
        [int] $PesterMajorVersion = 6
    )

    if ($null -eq $Result) { throw 'Pester did not return a result object.' }
    $total = Get-AuthorityRequiredProperty -Object $Result -Name 'TotalCount' -Context 'Pester result'
    $passed = Get-AuthorityRequiredProperty -Object $Result -Name 'PassedCount' -Context 'Pester result'
    $failed = Get-AuthorityRequiredProperty -Object $Result -Name 'FailedCount' -Context 'Pester result'
    foreach ($entry in @(
        @{ Name='TotalCount'; Value=$total },
        @{ Name='PassedCount'; Value=$passed },
        @{ Name='FailedCount'; Value=$failed }
    )) {
        Assert-AuthorityNonNegativeInteger -Value $entry.Value -Context "Pester $($entry.Name)"
    }
    if ([int64]$total -lt $MinimumTotalCount) {
        throw "Pester discovered only $total authority tests; expected at least $MinimumTotalCount."
    }
    if ([int64]$failed -ne 0 -or [int64]$passed -ne [int64]$total) {
        throw "Pester authority tests did not all pass. Total=$total Passed=$passed Failed=$failed."
    }
    if ($PesterMajorVersion -ge 5) {
        Assert-AuthorityExactString `
            -Value (Get-AuthorityRequiredProperty -Object $Result -Name 'Result' -Context 'Pester result') `
            -Expected 'Passed' `
            -Context 'Pester result status'
    }

    $requiredZeroCounts = if ($PesterMajorVersion -ge 5) {
        @('FailedBlocksCount', 'FailedContainersCount', 'SkippedCount', 'NotRunCount', 'InconclusiveCount')
    }
    else {
        @('SkippedCount', 'PendingCount', 'InconclusiveCount')
    }
    foreach ($name in $requiredZeroCounts) {
        $value = Get-AuthorityRequiredProperty -Object $Result -Name $name -Context 'Pester result'
        Assert-AuthorityNonNegativeInteger -Value $value -Context "Pester $name"
        if ([int64]$value -ne 0) {
            throw "Pester reported $name=$value."
        }
    }

    foreach ($name in @('FailedBlocksCount', 'FailedContainersCount', 'SkippedCount', 'NotRunCount', 'PendingCount', 'InconclusiveCount')) {
        if ($name -in $requiredZeroCounts) { continue }
        $property = $Result.PSObject.Properties[$name]
        if ($null -eq $property) { continue }
        Assert-AuthorityNonNegativeInteger -Value $property.Value -Context "Pester $name"
        if ([int64]$property.Value -ne 0) { throw "Pester reported $name=$($property.Value)." }
    }
    $errorsProperty = $Result.PSObject.Properties['Errors']
    if ($null -ne $errorsProperty) {
        $errors = $errorsProperty.Value
        if ($errors -isnot [array]) { throw 'Pester Errors must be an array when present.' }
        if (@($errors).Count -ne 0) { throw "Pester reported $(@($errors).Count) discovery/container errors." }
    }
}

function Test-AuthorityPathEqual {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else { [System.StringComparison]::Ordinal }
    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left),
        [System.IO.Path]::GetFullPath($Right),
        $comparison
    )
}

function Resolve-AuthorityReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Context must be a non-empty path string."
    }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
            throw "$Context must be a local fixture path."
        }
        $candidate = $uri.LocalPath
    }
    elseif ($candidate -cmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Context must be a local fixture path."
    }
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $FixtureRoot $candidate
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    Assert-AuthorityPathWithinRoot -Path $fullPath -Root $FixtureRoot -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-AuthorityPathEqual -Left $fullPath -Right (Join-Path $FixtureRoot $relativePath)) {
            return $fullPath
        }
    }
    throw "$Context does not identify a file in the controlled fixture inventory: $fullPath"
}

function Assert-AuthoritySkillSpectorReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    $executionSuccessful = Get-AuthorityProperty -Object $Report -Name 'execution_successful'
    $completeness = Get-AuthorityProperty -Object $Report -Name 'analysis_completeness'
    $completenessExecutionSuccessful = Get-AuthorityProperty -Object $completeness -Name 'execution_successful'
    $isComplete = Get-AuthorityProperty -Object $completeness -Name 'is_complete'
    $status = Get-AuthorityProperty -Object $completeness -Name 'status'
    $coveragePercent = Get-AuthorityProperty -Object $completeness -Name 'coverage_percent'
    $coverageIsNumeric = (
        $coveragePercent -is [byte] -or $coveragePercent -is [sbyte] -or
        $coveragePercent -is [int16] -or $coveragePercent -is [uint16] -or
        $coveragePercent -is [int] -or $coveragePercent -is [uint32] -or
        $coveragePercent -is [long] -or $coveragePercent -is [uint64] -or
        $coveragePercent -is [single] -or $coveragePercent -is [double] -or
        $coveragePercent -is [decimal]
    )
    if ($executionSuccessful -isnot [bool] -or -not $executionSuccessful -or
        $completenessExecutionSuccessful -isnot [bool] -or -not $completenessExecutionSuccessful -or
        $isComplete -isnot [bool] -or -not $isComplete -or
        $status -isnot [string] -or $status -cne 'complete' -or
        -not $coverageIsNumeric -or $coveragePercent -ne 100) {
        throw 'SkillSpector static scan was unsuccessful or incomplete.'
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        $items = Get-AuthorityProperty -Object $completeness -Name $name
        if ($items -isnot [array] -or @($items).Count -ne 0) {
            throw "SkillSpector analysis_completeness.$name must be an empty array."
        }
    }
    $issues = Get-AuthorityProperty -Object $Report -Name 'issues'
    $riskAssessment = Get-AuthorityProperty -Object $Report -Name 'risk_assessment'
    $recommendation = Get-AuthorityProperty -Object $riskAssessment -Name 'recommendation'
    if ($issues -isnot [array] -or @($issues).Count -ne 0 -or
        $recommendation -isnot [string] -or $recommendation -cne 'SAFE') {
        throw 'SkillSpector controlled fixture must have an empty issues[] array and a SAFE recommendation.'
    }

    $skill = Get-AuthorityProperty -Object $Report -Name 'skill'
    $skillName = Get-AuthorityProperty -Object $skill -Name 'name'
    $skillSource = Get-AuthorityProperty -Object $skill -Name 'source'
    if ($skillName -isnot [string] -or $skillName -cne $ExpectedSkillId -or
        $skillSource -isnot [string] -or [string]::IsNullOrWhiteSpace($skillSource) -or
        -not (Test-AuthorityPathEqual -Left $skillSource -Right $ExpectedFixtureRoot)) {
        throw 'SkillSpector report is not bound to the controlled fixture identity and source path.'
    }

    $components = Get-AuthorityProperty -Object $Report -Name 'components'
    if ($components -isnot [array] -or @($components).Count -ne $ExpectedInventoryPaths.Count) {
        throw 'SkillSpector components do not match the exact controlled fixture inventory.'
    }
    $observedPaths = @()
    foreach ($component in @($components)) {
        if ($component -isnot [pscustomobject]) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
        $componentPath = Get-AuthorityProperty -Object $component -Name 'path'
        if ($componentPath -isnot [string] -or
            -not ($ExpectedInventoryPaths -ccontains [string]$componentPath) -or
            $observedPaths -ccontains [string]$componentPath) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
        $observedPaths += [string]$componentPath
    }
    foreach ($expectedPath in $ExpectedInventoryPaths) {
        if ($observedPaths -cnotcontains $expectedPath) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
    }
}

function Assert-AuthoritySkillValidatorReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    $skillDirectory = Get-AuthorityProperty -Object $Report -Name 'skill_dir'
    $passed = Get-AuthorityProperty -Object $Report -Name 'passed'
    $errors = Get-AuthorityProperty -Object $Report -Name 'errors'
    $warnings = Get-AuthorityProperty -Object $Report -Name 'warnings'
    $results = Get-AuthorityProperty -Object $Report -Name 'results'
    if ($skillDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($skillDirectory) -or
        -not (Test-AuthorityPathEqual -Left $skillDirectory -Right $ExpectedFixtureRoot) -or
        $passed -isnot [bool] -or -not $passed -or
        ($errors -isnot [int] -and $errors -isnot [long]) -or [int64]$errors -ne 0 -or
        ($warnings -isnot [int] -and $warnings -isnot [long]) -or [int64]$warnings -ne 0 -or
        $results -isnot [array] -or @($results).Count -le 0) {
        throw 'skill-validator did not produce a clean, non-empty package validation report.'
    }
    foreach ($result in @($results)) {
        if ($result -isnot [pscustomobject]) {
            throw 'skill-validator result entries must be structured validation objects.'
        }
        $level = Get-AuthorityProperty -Object $result -Name 'level'
        $category = Get-AuthorityProperty -Object $result -Name 'category'
        $message = Get-AuthorityProperty -Object $result -Name 'message'
        if ($level -isnot [string] -or $level -cnotin @('pass', 'info', 'warning', 'error') -or
            $level -in @('warning', 'error') -or
            $category -isnot [string] -or [string]::IsNullOrWhiteSpace($category) -or
            $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) {
            throw 'skill-validator result entries do not describe a clean controlled fixture.'
        }
        $fileProperty = $result.PSObject.Properties['file']
        if ($null -ne $fileProperty) {
            [void](Resolve-AuthorityReportedFilePath -Value $fileProperty.Value -FixtureRoot $ExpectedFixtureRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-validator result file')
        }
        $lineProperty = $result.PSObject.Properties['line']
        if ($null -ne $lineProperty -and
            (($lineProperty.Value -isnot [int] -and $lineProperty.Value -isnot [long]) -or [int64]$lineProperty.Value -le 0)) {
            throw 'skill-validator result line must be a positive integer when present.'
        }
    }
}

function Assert-AuthoritySkillToolsSarifReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    $version = Get-AuthorityProperty -Object $Report -Name 'version'
    $runs = Get-AuthorityProperty -Object $Report -Name 'runs'
    if ($version -isnot [string] -or $version -cne '2.1.0' -or
        $runs -isnot [array] -or @($runs).Count -ne 1) {
        throw 'skill-tools did not produce a non-empty SARIF 2.1.0 report.'
    }
    foreach ($run in @($runs)) {
        $tool = Get-AuthorityProperty -Object $run -Name 'tool'
        $driver = Get-AuthorityProperty -Object $tool -Name 'driver'
        $driverName = Get-AuthorityProperty -Object $driver -Name 'name'
        $rules = Get-AuthorityProperty -Object $driver -Name 'rules'
        $results = Get-AuthorityProperty -Object $run -Name 'results'
        if ($driverName -isnot [string] -or $driverName -cne 'skill-tools' -or
            $rules -isnot [array] -or @($rules).Count -le 0 -or
            $results -isnot [array] -or @($results).Count -le 0) {
            throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
        }
        $ruleById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($rule in @($rules)) {
            if ($rule -isnot [pscustomobject]) {
                throw 'skill-tools SARIF rule metadata is incomplete or malformed.'
            }
            $ruleId = Get-AuthorityProperty -Object $rule -Name 'id'
            if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or $ruleById.ContainsKey($ruleId)) {
                throw 'skill-tools SARIF rule metadata is incomplete or malformed.'
            }
            $ruleById.Add($ruleId, $rule)
        }
        foreach ($result in @($results)) {
            if ($result -isnot [pscustomobject]) {
                throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
            }
            $ruleId = Get-AuthorityProperty -Object $result -Name 'ruleId'
            if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or -not $ruleById.ContainsKey($ruleId)) {
                throw 'skill-tools SARIF result references an unknown or malformed ruleId.'
            }
            $levelProperty = $result.PSObject.Properties['level']
            if ($null -ne $levelProperty) {
                $effectiveLevel = $levelProperty.Value
            }
            else {
                $defaultConfiguration = Get-AuthorityProperty -Object $ruleById[$ruleId] -Name 'defaultConfiguration'
                if ($defaultConfiguration -isnot [pscustomobject] -or
                    $null -eq $defaultConfiguration.PSObject.Properties['level']) {
                    throw 'skill-tools SARIF result without level requires an exact rule defaultConfiguration.level.'
                }
                $effectiveLevel = $defaultConfiguration.PSObject.Properties['level'].Value
            }
            if ($effectiveLevel -isnot [string] -or
                $effectiveLevel -cnotin @('none', 'note', 'warning', 'error') -or
                $effectiveLevel -ceq 'error') {
                throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
            }
            $message = Get-AuthorityProperty -Object $result -Name 'message'
            $messageText = Get-AuthorityProperty -Object $message -Name 'text'
            $locations = Get-AuthorityProperty -Object $result -Name 'locations'
            if ($messageText -isnot [string] -or [string]::IsNullOrWhiteSpace($messageText) -or
                $locations -isnot [array] -or @($locations).Count -le 0) {
                throw 'skill-tools SARIF result is missing its message or controlled fixture location.'
            }
            foreach ($location in @($locations)) {
                $physicalLocation = Get-AuthorityProperty -Object $location -Name 'physicalLocation'
                $artifactLocation = Get-AuthorityProperty -Object $physicalLocation -Name 'artifactLocation'
                $uri = Get-AuthorityProperty -Object $artifactLocation -Name 'uri'
                [void](Resolve-AuthorityReportedFilePath -Value $uri -FixtureRoot $ExpectedFixtureRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-tools SARIF artifact location')
            }
        }
    }
}

function Get-AuthorityCandidateCommit {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [AllowEmptyString()][string] $ExpectedCommit = [string]$env:GITHUB_SHA
    )

    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $candidateCommit = (& $git.Source -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $candidateCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Authority gate could not bind its candidate commit to checkout HEAD.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit)) {
        if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw 'GITHUB_SHA must be a lowercase full commit SHA when present.'
        }
        if ($ExpectedCommit -cne $candidateCommit) {
            throw "GITHUB_SHA '$ExpectedCommit' does not match checkout HEAD '$candidateCommit'."
        }
    }
    return $candidateCommit
}

function Assert-AuthorityFixtureContract {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    if ($ExpectedSkillId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Authority fixture Skill ID '$ExpectedSkillId' is invalid."
    }
    $skillPath = Join-Path $FixtureRoot 'SKILL.md'
    $metadataPath = Join-Path $FixtureRoot 'agents/openai.yaml'
    foreach ($path in @($skillPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Authority fixture is missing required file: $path"
        }
    }

    $skillText = [IO.File]::ReadAllText($skillPath).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($skillText -notmatch '(?s)^---\n(?<frontmatter>.*?)\n---\n(?<body>.+)$') {
        throw 'Authority fixture SKILL.md must contain closed YAML frontmatter and a non-empty body.'
    }
    $frontmatter = $Matches.frontmatter
    $body = $Matches.body
    $frontmatterValues = @{}
    foreach ($line in $frontmatter.Split("`n")) {
        if ($line -notmatch '^(?<key>[a-z][a-z-]*): (?<value>\S.*)$') {
            throw "Authority fixture SKILL.md has unsupported frontmatter syntax: '$line'."
        }
        $key = [string]$Matches.key
        if ($key -cnotin @('name', 'description') -or $frontmatterValues.ContainsKey($key)) {
            throw "Authority fixture SKILL.md has unsupported or duplicate frontmatter key '$key'."
        }
        $frontmatterValues[$key] = [string]$Matches.value
    }
    if ($frontmatterValues.Count -ne 2 -or
        [string]$frontmatterValues.name -cne $ExpectedSkillId -or
        [string]::IsNullOrWhiteSpace([string]$frontmatterValues.description) -or
        [string]::IsNullOrWhiteSpace($body)) {
        throw 'Authority fixture SKILL.md metadata or body is incomplete.'
    }

    $metadataText = [IO.File]::ReadAllText($metadataPath).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
    $metadataLines = $metadataText.Split("`n")
    if ($metadataLines.Count -ne 4 -or $metadataLines[0] -cne 'interface:') {
        throw 'Authority fixture agents/openai.yaml must contain one interface mapping.'
    }
    $interface = @{}
    foreach ($line in @($metadataLines | Select-Object -Skip 1)) {
        if ($line -notmatch '^  (?<key>[a-z_]+): (?<jsonString>"(?:[^"\\]|\\.)*")$') {
            throw "Authority fixture agents/openai.yaml requires unquoted keys and double-quoted string values: '$line'."
        }
        $key = [string]$Matches.key
        if ($key -cnotin @('display_name', 'short_description', 'default_prompt') -or $interface.ContainsKey($key)) {
            throw "Authority fixture agents/openai.yaml has unsupported or duplicate interface key '$key'."
        }
        try { $interface[$key] = [string]($Matches.jsonString | ConvertFrom-Json) }
        catch { throw "Authority fixture agents/openai.yaml has an invalid quoted string for '$key'." }
    }
    if ($interface.Count -ne 3 -or [string]::IsNullOrWhiteSpace([string]$interface.display_name)) {
        throw 'Authority fixture agents/openai.yaml is missing required interface fields.'
    }
    $shortDescription = [string]$interface.short_description
    if ($shortDescription.Length -lt 25 -or $shortDescription.Length -gt 64) {
        throw 'Authority fixture interface.short_description must contain 25 to 64 characters.'
    }
    $expectedToken = '$' + $ExpectedSkillId
    if ([string]$interface.default_prompt -cnotmatch ("(?<![a-z0-9-]){0}(?![a-z0-9-])" -f [regex]::Escape($expectedToken))) {
        throw "Authority fixture interface.default_prompt must reference exact token '$expectedToken'."
    }
}

if ($DefineFunctionsOnly) { return }

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$resolverPath = Join-Path $PSScriptRoot 'Resolve-StandardValidationTool.ps1'
$pythonClosureHelperPath = Join-Path $PSScriptRoot 'Resolve-PythonWheelClosure.py'
$authorityTestPaths = @(
    (Join-Path $repositoryRoot 'tests/skill-repository-standard.Tests.ps1')
    (Join-Path $repositoryRoot 'tests/skill-repository-workflows.Tests.ps1')
    (Join-Path $repositoryRoot 'tests/standard-validation-resolver-hardening.Tests.ps1')
)
foreach ($requiredPath in @($resolverPath, $pythonClosureHelperPath) + $authorityTestPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Authority gate input is missing: $requiredPath"
    }
}

$artifactsRootPath = [System.IO.Path]::GetFullPath($ArtifactsRoot)
[void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
$artifactsItem = Get-Item -Force -LiteralPath $artifactsRootPath
if (-not $artifactsItem.PSIsContainer -or
    ($artifactsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Authority artifacts root must be a non-reparse directory: $artifactsRootPath"
}

$runId = [guid]::NewGuid().ToString('N')
$runRoot = Join-Path $artifactsRootPath "standard-authority-$runId"
$installRoot = Join-Path $runRoot 'tools'
$fixtureRoot = Join-Path $runRoot 'fixture/standard-validation-fixture'
[void](New-Item -ItemType Directory -Path $installRoot -Force)
[void](New-Item -ItemType Directory -Path $fixtureRoot -Force)

$fixtureText = @'
---
name: standard-validation-fixture
description: Use when verifying that the canonical validation toolchain can inspect a harmless and deterministic Agent Skill package.
---

# Standard Validation Fixture

Use this deterministic fixture to confirm that each approved validation tool can inspect one complete Agent Skill package.

## Procedure

1. Read this file.
2. Confirm that the package metadata is valid.
3. Return a short validation status without changing files.

## Expected result

Report that the fixture is structurally valid and contains no executable content.
'@
$fixturePath = Join-Path $fixtureRoot 'SKILL.md'
[System.IO.File]::WriteAllText($fixturePath, $fixtureText.TrimStart() + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$fixtureSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash.ToLowerInvariant()

$fixtureAgentsRoot = Join-Path $fixtureRoot 'agents'
[void](New-Item -ItemType Directory -Path $fixtureAgentsRoot -Force)
$fixtureMetadataText = @'
interface:
  display_name: "Standard Validation Fixture"
  short_description: "Validate one deterministic canonical Skill package."
  default_prompt: "Use $standard-validation-fixture to verify the canonical validation toolchain."
'@
$fixtureMetadataPath = Join-Path $fixtureAgentsRoot 'openai.yaml'
[System.IO.File]::WriteAllText($fixtureMetadataPath, $fixtureMetadataText.TrimStart() + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Assert-AuthorityFixtureContract -FixtureRoot $fixtureRoot -ExpectedSkillId 'standard-validation-fixture'
$fixtureMetadataSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureMetadataPath).Hash.ToLowerInvariant()
$fixtureFiles = @(
    [pscustomobject][ordered]@{ path = 'SKILL.md'; sha256 = $fixtureSha256 },
    [pscustomobject][ordered]@{ path = 'agents/openai.yaml'; sha256 = $fixtureMetadataSha256 }
)
$fixtureCanonicalInventory = ($fixtureFiles | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
$fixtureInventoryHasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $fixtureInventorySha256 = ([System.BitConverter]::ToString(
        $fixtureInventoryHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fixtureCanonicalInventory))
    ) -replace '-', '').ToLowerInvariant()
}
finally {
    $fixtureInventoryHasher.Dispose()
}

$policyReceiptPath = Join-Path $runRoot 'policy.json'
& $resolverPath -ValidatePolicyOnly -OutputPath $policyReceiptPath | Out-Host
$policyReceipt = Read-AuthorityJson -Path $policyReceiptPath -Context 'Validation policy resolver'
Assert-AuthorityPolicyReceipt -Receipt $policyReceipt

$expectedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}
$receipts = [ordered]@{}
$executablePaths = [ordered]@{}

# Freeze the complete formal toolset before any validator executes.
foreach ($entry in $expectedSources.GetEnumerator()) {
    $receiptPath = Join-Path $runRoot ("receipt-{0}.json" -f $entry.Key)
    & $resolverPath -ToolName $entry.Key -Install -InstallRoot $installRoot -OutputPath $receiptPath | Out-Host
    $receipt = Read-AuthorityJson -Path $receiptPath -Context "$($entry.Key) resolver"
    $executablePaths[$entry.Key] = Assert-InstalledAuthorityToolReceipt `
        -Receipt $receipt -ToolName $entry.Key -ExpectedSource $entry.Value -InstallRoot $installRoot
    $receipts[$entry.Key] = $receipt
    if ($entry.Key -ceq 'skillspector') {
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    }
}

foreach ($entry in $expectedSources.GetEnumerator()) {
    $receipt = $receipts[$entry.Key]
    $expectedClosure = if ($entry.Key -in @('skillspector', 'skill-tools')) {
        Get-AuthorityProperty -Object $receipt -Name 'installedClosureSha256'
    }
    else {
        Get-AuthorityProperty -Object $receipt -Name 'dependencyClosureSha256'
    }
    Assert-AuthoritySha256 -Value $expectedClosure -Context "$($entry.Key) installed closure"
    $actualClosure = Get-AuthorityDirectoryClosureSha256 -Path ([string]$receipt.installRoot)
    if ($actualClosure -cne [string]$expectedClosure) {
        throw "$($entry.Key) installed closure changed after resolution. Expected '$expectedClosure', got '$actualClosure'."
    }
}

$skillSpectorReceipt = $receipts.skillspector
if ($skillSpectorReceipt.pythonPackageIndex -isnot [string] -or
    [string]$skillSpectorReceipt.pythonPackageIndex -cnotmatch '^https://pypi\.org/simple/?$' -or
    $skillSpectorReceipt.installEnvironment -isnot [string] -or
    [string]$skillSpectorReceipt.installEnvironment -cne 'isolated-venv' -or
    $skillSpectorReceipt.interpreterIsolation -isnot [string] -or
    [string]$skillSpectorReceipt.interpreterIsolation -cne 'python-isolated-mode' -or
    $skillSpectorReceipt.credentialIsolation -isnot [string] -or
    [string]$skillSpectorReceipt.credentialIsolation -cne 'github-token-cleared-before-python' -or
    $skillSpectorReceipt.installedMetadataVerification -isnot [string] -or
    [string]$skillSpectorReceipt.installedMetadataVerification -cne 'static-dist-info-metadata' -or
    $skillSpectorReceipt.directReferencesAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.directReferencesAllowed -or
    $skillSpectorReceipt.pipOnlineDependencyTraversalAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.pipOnlineDependencyTraversalAllowed -or
    $skillSpectorReceipt.yankedAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.yankedAllowed -or
    $skillSpectorReceipt.dependencyDiscovery -isnot [string] -or
    [string]$skillSpectorReceipt.dependencyDiscovery -cne 'approved-simple-json-lazy' -or
    $skillSpectorReceipt.requiresPythonPolicy -isnot [string] -or
    [string]$skillSpectorReceipt.requiresPythonPolicy -cne 'simple-json-wheel-metadata-exact-current-interpreter' -or
    $skillSpectorReceipt.dependencyResolver -isnot [string] -or
    [string]$skillSpectorReceipt.dependencyResolver -cne 'pip-offline-backtracking' -or
    $skillSpectorReceipt.offlineResolutionVerified -isnot [bool] -or
    -not [bool]$skillSpectorReceipt.offlineResolutionVerified -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'interpreterIsolation=python-isolated-mode' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'credentialIsolation=github-token-cleared-before-python' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'installedMetadataVerification=static-dist-info-metadata' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'directReferences=blocked' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'pipOnlineDependencyTraversal=disabled' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'dependencyDiscovery=approved-simple-json-lazy' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'requiresPython=simple-json-wheel-metadata-exact-current-interpreter' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'offlineBacktracking=verified' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'offlineResolution=verified' -or
    @($skillSpectorReceipt.dependencyClosure).Count -le 1) {
    throw 'SkillSpector receipt does not bind the approved isolated dependency closure.'
}
Assert-AuthoritySha256 -Value $skillSpectorReceipt.installedClosureSha256 -Context 'SkillSpector installed closure'
$skillSpectorHelper = Assert-AuthorityFileIdentity `
    -PathValue $skillSpectorReceipt.resolverHelperPath `
    -Sha256Value $skillSpectorReceipt.resolverHelperSha256 `
    -Context 'SkillSpector Python wheel closure helper'
if ($skillSpectorHelper -cne [System.IO.Path]::GetFullPath($pythonClosureHelperPath)) {
    throw 'SkillSpector receipt identifies the wrong Python wheel closure helper.'
}
foreach ($name in @('candidateInventorySha256', 'selectionPlanSha256', 'rawSelectionPlanSha256', 'selectedClosureSha256')) {
    Assert-AuthoritySha256 -Value $skillSpectorReceipt.$name -Context "SkillSpector $name"
}
foreach ($name in @('resolutionRounds', 'candidateCount')) {
    Assert-AuthorityNonNegativeInteger -Value $skillSpectorReceipt.$name -Context "SkillSpector $name"
    if ([int64]$skillSpectorReceipt.$name -le 0) { throw "SkillSpector $name must be positive." }
}
if ($skillSpectorReceipt.pipVersion -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$skillSpectorReceipt.pipVersion) -or
    $skillSpectorReceipt.consoleEntryPoint -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$skillSpectorReceipt.consoleEntryPoint)) {
    throw 'SkillSpector receipt is missing pip or console entry-point identity.'
}
foreach ($binding in @(
    "pipVersion=$($skillSpectorReceipt.pipVersion)",
    "resolutionRounds=$($skillSpectorReceipt.resolutionRounds)",
    "candidateCount=$($skillSpectorReceipt.candidateCount)",
    "resolverHelperSha256=$($skillSpectorReceipt.resolverHelperSha256)",
    "candidateInventorySha256=$($skillSpectorReceipt.candidateInventorySha256)",
    "selectionPlanSha256=$($skillSpectorReceipt.selectionPlanSha256)",
    "selectedClosureSha256=$($skillSpectorReceipt.selectedClosureSha256)",
    "consoleEntryPoint=$($skillSpectorReceipt.consoleEntryPoint)"
)) {
    if ([string]$skillSpectorReceipt.resolvedIdentity -cnotlike "*$binding*") {
        throw "SkillSpector resolved identity is missing '$binding'."
    }
}

$skillValidatorReceipt = $receipts.'skill-validator'
if ($skillValidatorReceipt.proxy -isnot [string] -or [string]$skillValidatorReceipt.proxy -cne 'https://proxy.golang.org' -or
    $skillValidatorReceipt.checksumDatabase -isnot [string] -or [string]$skillValidatorReceipt.checksumDatabase -cne 'sum.golang.org' -or
    $skillValidatorReceipt.moduleCacheIsolation -isnot [string] -or [string]$skillValidatorReceipt.moduleCacheIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.buildCacheIsolation -isnot [string] -or [string]$skillValidatorReceipt.buildCacheIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.temporaryDirectoryIsolation -isnot [string] -or [string]$skillValidatorReceipt.temporaryDirectoryIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.binaryInstallIsolation -isnot [string] -or [string]$skillValidatorReceipt.binaryInstallIsolation -cne 'run-owned') {
    throw 'skill-validator receipt does not bind the approved Go distribution isolation.'
}

$skillToolsReceipt = $receipts.'skill-tools'
if ($skillToolsReceipt.registry -isnot [string] -or
    [string]$skillToolsReceipt.registry -cnotmatch '^https://registry\.npmjs\.org/?$' -or
    $skillToolsReceipt.executableVerified -isnot [bool] -or -not [bool]$skillToolsReceipt.executableVerified) {
    throw 'skill-tools receipt does not bind the approved npm registry and entry point.'
}
Assert-AuthoritySha256 -Value $skillToolsReceipt.packageLockSha256 -Context 'skill-tools package lock'
$skillToolsEntryPoint = Assert-AuthorityFileIdentity `
    -PathValue $skillToolsReceipt.entryPointPath `
    -Sha256Value $skillToolsReceipt.entryPointSha256 `
    -Context 'skill-tools package entry point'
$skillToolsNode = Assert-AuthorityFileIdentity `
    -PathValue $skillToolsReceipt.nodePath `
    -Sha256Value $skillToolsReceipt.nodeSha256 `
    -Context 'skill-tools Node runtime'
Assert-AuthorityPathWithinRoot -Path $skillToolsEntryPoint -Root ([string]$skillToolsReceipt.installRoot) -Context 'skill-tools package entry point'

$pesterReceipt = $receipts.pester
$pesterModulePath = Assert-AuthorityFileIdentity `
    -PathValue $pesterReceipt.modulePath `
    -Sha256Value $pesterReceipt.executableSha256 `
    -Context 'Pester module'
if ([System.IO.Path]::GetFullPath([string]$pesterReceipt.modulePath) -cne
    [System.IO.Path]::GetFullPath([string]$pesterReceipt.executablePath)) {
    throw 'Pester receipt modulePath and executablePath must identify the same frozen module manifest.'
}

$skillSpectorReportPath = Join-Path $runRoot 'skillspector-report.json'
[void](Invoke-AuthorityExternalCommand `
    -Command $executablePaths.skillspector `
    -Arguments @('scan', $fixtureRoot, '--no-llm', '--format', 'json', '--output', $skillSpectorReportPath) `
    -Context 'SkillSpector static scan' `
    -DiagnosticRoot $runRoot)
$skillSpectorReport = Read-AuthorityJson -Path $skillSpectorReportPath -Context 'SkillSpector static scan'
Assert-AuthoritySkillSpectorReport `
    -Report $skillSpectorReport `
    -ExpectedFixtureRoot $fixtureRoot `
    -ExpectedSkillId 'standard-validation-fixture' `
    -ExpectedInventoryPaths @($fixtureFiles.path)

$skillValidatorOutput = Invoke-AuthorityExternalCommand `
    -Command $executablePaths.'skill-validator' `
    -Arguments @('-o', 'json', 'validate', 'structure', $fixtureRoot) `
    -Context 'skill-validator package validation' `
    -DiagnosticRoot $runRoot
$skillValidatorOutputPath = Join-Path $runRoot 'skill-validator-report.json'
[System.IO.File]::WriteAllText($skillValidatorOutputPath, $skillValidatorOutput + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$skillValidatorReport = Read-AuthorityJson -Path $skillValidatorOutputPath -Context 'skill-validator package validation'
Assert-AuthoritySkillValidatorReport `
    -Report $skillValidatorReport `
    -ExpectedFixtureRoot $fixtureRoot `
    -ExpectedInventoryPaths @($fixtureFiles.path)

$skillToolsOutput = Invoke-AuthorityExternalCommand `
    -Command $skillToolsNode `
    -Arguments @($skillToolsEntryPoint, 'check', $fixtureRoot, '--format', 'sarif', '--fail-on', 'error', '--min-score', '0') `
    -Context 'skill-tools combined check' `
    -DiagnosticRoot $runRoot
$skillToolsOutputPath = Join-Path $runRoot 'skill-tools-report.sarif.json'
[System.IO.File]::WriteAllText($skillToolsOutputPath, $skillToolsOutput + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$skillToolsReport = Read-AuthorityJson -Path $skillToolsOutputPath -Context 'skill-tools combined check'
Assert-AuthoritySkillToolsSarifReport `
    -Report $skillToolsReport `
    -ExpectedFixtureRoot $fixtureRoot `
    -ExpectedInventoryPaths @($fixtureFiles.path)

Import-Module $pesterModulePath -Force -ErrorAction Stop
$pesterModuleRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $pesterModulePath))
$loadedPester = Get-Module Pester | Where-Object {
    [string]::Equals([System.IO.Path]::GetFullPath([string]$_.ModuleBase), $pesterModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)
} | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne [string]$pesterReceipt.resolvedVersion) {
    throw 'The exact frozen Pester module was not imported.'
}
$authorityResult = Invoke-Pester -Path $authorityTestPaths -PassThru
Assert-AuthorityPesterResult `
    -Result $authorityResult `
    -MinimumTotalCount 45 `
    -PesterMajorVersion ([version]$pesterReceipt.resolvedVersion).Major

$candidateCommit = Get-AuthorityCandidateCommit -RepositoryRoot $repositoryRoot

$summary = [ordered]@{
    schemaVersion = 1
    runId = $runId
    candidateCommit = $candidateCommit
    fixture = [ordered]@{
        id = 'standard-validation-fixture'
        inventorySha256 = $fixtureInventorySha256
        files = $fixtureFiles
    }
    tools = @($expectedSources.Keys | ForEach-Object {
        $receipt = $receipts[$_]
        [ordered]@{
            toolName = $_
            source = [string]$receipt.source
            version = [string]$receipt.resolvedVersion
            resolvedIdentity = [string]$receipt.resolvedIdentity
        }
    })
    stages = @(
        [ordered]@{ name='skillspector-static'; result='passed'; exitCode=0; mode='static-no-llm'; report='skillspector-report.json' },
        [ordered]@{ name='skill-validator-package'; result='passed'; exitCode=0; mode='structure-json'; report='skill-validator-report.json' },
        [ordered]@{ name='skill-tools-check'; result='passed'; exitCode=0; mode='sarif-error'; report='skill-tools-report.sarif.json' },
        [ordered]@{
            name='pester-authority'; result='passed'; exitCode=0; mode='authority-inventory'; total=[int]$authorityResult.TotalCount
            passed=[int]$authorityResult.PassedCount; failed=[int]$authorityResult.FailedCount
        }
    )
}
$summaryPath = Join-Path $runRoot 'authority-gate-summary.json'
$summaryJson = $summary | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($summaryPath, $summaryJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Write-Host "Standard authority gate passed. Evidence: $summaryPath"
$summaryJson
