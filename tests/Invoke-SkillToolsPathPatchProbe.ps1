[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('leg', 'aggregate')][string] $Mode,
    [ValidateSet('windows', 'linux', 'macos')][string] $Platform,
    [string] $WorkRoot,
    [string] $LegResultsRoot,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Get-ProbeSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Probe file is missing: '$Path'." }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-ProbeJson {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)] $Value)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-ProbeNodeCommand {
    param(
        [Parameter(Mandatory = $true)][string] $NodePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][int[]] $ExpectedExitCodes
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $NodePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start Node command '$NodePath'." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill($true) } catch {}
            throw "Node command timed out: $($Arguments -join ' ')."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($ExpectedExitCodes -notcontains $process.ExitCode) {
            throw "Node command exited $($process.ExitCode), expected '$($ExpectedExitCodes -join ',')'. stderr='$stderr' stdout='$stdout'."
        }
        return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    }
    finally { $process.Dispose() }
}

function ConvertFrom-ProbeJsonStream {
    param([Parameter(Mandatory = $true)][string] $Text)
    $documents = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    while ($index -lt $Text.Length) {
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) { $index++ }
        if ($index -ge $Text.Length) { break }
        if ($Text[$index] -ne '{' -and $Text[$index] -ne '[') { throw "Unexpected non-JSON output at offset $index." }
        $start = $index
        $depth = 0
        $inString = $false
        $escaped = $false
        for (; $index -lt $Text.Length; $index++) {
            $character = $Text[$index]
            if ($inString) {
                if ($escaped) { $escaped = $false; continue }
                if ($character -eq '\') { $escaped = $true; continue }
                if ($character -eq '"') { $inString = $false }
                continue
            }
            if ($character -eq '"') { $inString = $true; continue }
            if ($character -eq '{' -or $character -eq '[') { $depth++ }
            elseif ($character -eq '}' -or $character -eq ']') {
                $depth--
                if ($depth -eq 0) {
                    $json = $Text.Substring($start, $index - $start + 1)
                    $documents.Add(($json | ConvertFrom-Json))
                    $index++
                    break
                }
            }
        }
        if ($depth -ne 0 -or $inString) { throw 'skill-tools emitted an incomplete JSON document.' }
    }
    return $documents.ToArray()
}

function Get-NormalizedDimensions {
    param([Parameter(Mandatory = $true)] $Dimensions)
    $values = @($Dimensions.PSObject.Properties | ForEach-Object {
        [pscustomobject][ordered]@{
            key = [string]$_.Name
            label = [string]$_.Value.label
            score = [int]$_.Value.score
            max = [int]$_.Value.max
            details = [string]$_.Value.details
        }
    })
    return @($values | Sort-Object -Property key)
}

function Get-NormalizedDiagnostics {
    param([Parameter(Mandatory = $true)] $Diagnostics)
    $values = @($Diagnostics | ForEach-Object {
        [pscustomobject][ordered]@{
            ruleId = if ($_.PSObject.Properties['ruleId']) { $_.ruleId } else { $null }
            severity = if ($_.PSObject.Properties['severity']) { $_.severity } else { $null }
            message = if ($_.PSObject.Properties['message']) { $_.message } else { $null }
            line = if ($_.PSObject.Properties['line']) { $_.line } else { $null }
            fix = if ($_.PSObject.Properties['fix']) { $_.fix } else { $null }
        }
    })
    return @($values | Sort-Object -Stable -Property ruleId, line, message)
}

function Clear-ProbeInheritedEnvironment {
    $cleared = New-Object 'System.Collections.Generic.List[string]'
    $variables = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    $names = @($variables.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    foreach ($name in $names) {
        $value = [string]$variables[$name]
        $isNpmOverride = $name -match '^NPM_CONFIG_'
        $isPreservedRegistry = $name -ieq 'NPM_CONFIG_REGISTRY' -and $value -ceq 'https://registry.npmjs.org/'
        $shouldClear = ($isNpmOverride -and -not $isPreservedRegistry) -or
            $name -match '^NODE_' -or
            $name -ieq 'SSL_CERT_FILE' -or
            $name -ieq 'SSL_CERT_DIR'
        if (-not $shouldClear) { continue }
        Remove-Item -LiteralPath "Env:$name" -Force
        $cleared.Add($name)
    }
    return $cleared.ToArray()
}

function Invoke-Leg {
    if ([string]::IsNullOrWhiteSpace($Platform)) { throw 'Leg mode requires -Platform.' }
    if ([string]::IsNullOrWhiteSpace($WorkRoot)) { throw 'Leg mode requires -WorkRoot.' }
    $root = [IO.Path]::GetFullPath($WorkRoot)
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $installRoot = Join-Path $root 'install'
    $receiptPath = Join-Path $root 'skill-tools-receipt.json'
    $resolverPath = Join-Path $RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1'
    $clearedInheritedEnvironment = @(Clear-ProbeInheritedEnvironment)
    & $resolverPath -ToolName skill-tools -Install -InstallRoot $installRoot -OutputPath $receiptPath | Out-Null
    if (-not $?) { throw 'skill-tools resolver invocation failed.' }
    $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json

    $coreRoot = Join-Path ([string]$receipt.installRoot) 'node_modules/@skill-tools/core'
    $corePackage = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $coreRoot 'package.json') | ConvertFrom-Json
    $expectedHashes = [ordered]@{
        'dist/index.js' = '4c2449953f3622df3e41f6a6e93d2e2c045d35ffe5ec62c5174f21a6fbb9e518'
        'dist/index.cjs' = 'bc0fa565f0150af06a6d0c7dd9848b9e14ca70307e2f15b2f37fa6d15be7e403'
    }
    $observedHashes = [ordered]@{}
    foreach ($entry in $expectedHashes.GetEnumerator()) {
        $observed = Get-ProbeSha256 -Path (Join-Path $coreRoot ([string]$entry.Key))
        if ($observed -cne [string]$entry.Value) { throw "Patched core hash mismatch for '$($entry.Key)': '$observed'." }
        $observedHashes[[string]$entry.Key] = $observed
    }

    $presentPath = Join-Path $RepositoryRoot 'tests/fixtures/skill-tools-path-patch/reference-present'
    $missingPath = Join-Path $RepositoryRoot 'tests/fixtures/skill-tools-path-patch/reference-missing'
    $scoreCommand = Invoke-ProbeNodeCommand -NodePath ([string]$receipt.nodePath) -Arguments @(
        [string]$receipt.entryPointPath, 'score', $presentPath, '--format', 'json'
    ) -ExpectedExitCodes @(0)
    $scoreDocuments = @(ConvertFrom-ProbeJsonStream -Text $scoreCommand.stdout)
    if ($scoreDocuments.Count -ne 1) { throw "Expected one score JSON document; found $($scoreDocuments.Count)." }
    $dimensions = @(Get-NormalizedDimensions -Dimensions $scoreDocuments[0].dimensions)
    $progressive = @($dimensions | Where-Object { $_.label -ceq 'Progressive Disclosure' })
    if ($progressive.Count -ne 1 -or $progressive[0].score -ne 15 -or $progressive[0].max -ne 15) {
        throw 'reference-present did not receive Progressive Disclosure 15/15.'
    }

    $checkCommand = Invoke-ProbeNodeCommand -NodePath ([string]$receipt.nodePath) -Arguments @(
        [string]$receipt.entryPointPath, 'check', $missingPath, '--format', 'json'
    ) -ExpectedExitCodes @(1)
    $checkDocuments = @(ConvertFrom-ProbeJsonStream -Text $checkCommand.stdout)
    if ($checkDocuments.Count -ne 1) { throw "Expected one validation JSON document; found $($checkDocuments.Count)." }
    $validationResults = @($checkDocuments[0])
    if ($validationResults.Count -ne 1 -or [bool]$validationResults[0].valid) { throw 'reference-missing was not reported invalid.' }
    $referenceDiagnostics = @($validationResults[0].diagnostics | Where-Object { [string]$_.ruleId -ceq 'file-reference-exists' })
    if ($referenceDiagnostics.Count -eq 0) { throw 'reference-missing did not report file-reference-exists.' }

    $result = [pscustomobject][ordered]@{
        schemaVersion = 1
        platform = $Platform
        skillToolsVersion = [string]$receipt.resolvedVersion
        coreVersion = [string]$corePackage.version
        patchedHashes = $observedHashes
        clearedInheritedEnvironment = $clearedInheritedEnvironment
        score = [pscustomobject][ordered]@{
            total = [int]$scoreDocuments[0].score
            dimensions = $dimensions
        }
        check = [pscustomobject][ordered]@{
            exitCode = [int]$checkCommand.exitCode
            valid = [bool]$validationResults[0].valid
            diagnostics = @($validationResults[0].diagnostics)
            hasFileReferenceExists = $true
        }
    }
    $outputPath = Join-Path $root "skill-tools-path-patch-$Platform.json"
    Write-ProbeJson -Path $outputPath -Value $result
    Write-Output $outputPath
}

function Invoke-Aggregate {
    if ([string]::IsNullOrWhiteSpace($LegResultsRoot)) { throw 'Aggregate mode requires -LegResultsRoot.' }
    $paths = @(Get-ChildItem -LiteralPath $LegResultsRoot -File -Recurse -Filter 'skill-tools-path-patch-*.json')
    if ($paths.Count -ne 3) { throw "Expected exactly three leg result files; found $($paths.Count)." }
    $results = @($paths | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json })
    $expectedPlatforms = @('linux', 'macos', 'windows')
    $actualPlatforms = @($results.platform | Sort-Object)
    if (($actualPlatforms -join '|') -cne ($expectedPlatforms -join '|')) { throw "Leg platforms differ: '$($actualPlatforms -join ',')'." }

    $baseline = @($results | Where-Object { $_.platform -ceq 'windows' })[0]
    $differences = New-Object 'System.Collections.Generic.List[string]'
    $baselineDimensions = $baseline.score.dimensions | ConvertTo-Json -Depth 10 -Compress
    $baselineDiagnostics = Get-NormalizedDiagnostics -Diagnostics $baseline.check.diagnostics | ConvertTo-Json -Depth 10 -Compress
    foreach ($result in $results) {
        if ([string]$result.skillToolsVersion -cne [string]$baseline.skillToolsVersion) { $differences.Add("$($result.platform): skill-tools version differs.") }
        if ([string]$result.coreVersion -cne [string]$baseline.coreVersion) { $differences.Add("$($result.platform): core version differs.") }
        if ([int]$result.score.total -ne [int]$baseline.score.total) { $differences.Add("$($result.platform): total score differs.") }
        if (($result.score.dimensions | ConvertTo-Json -Depth 10 -Compress) -cne $baselineDimensions) { $differences.Add("$($result.platform): dimension scores differ.") }
        $progressive = @($result.score.dimensions | Where-Object { $_.label -ceq 'Progressive Disclosure' })
        if ($progressive.Count -ne 1 -or [int]$progressive[0].score -ne 15 -or [int]$progressive[0].max -ne 15) { $differences.Add("$($result.platform): Progressive Disclosure is not 15/15.") }
        if ([int]$result.check.exitCode -ne [int]$baseline.check.exitCode) { $differences.Add("$($result.platform): check exit code differs.") }
        if ([bool]$result.check.valid -ne [bool]$baseline.check.valid) { $differences.Add("$($result.platform): check validity differs.") }
        if ((Get-NormalizedDiagnostics -Diagnostics $result.check.diagnostics | ConvertTo-Json -Depth 10 -Compress) -cne $baselineDiagnostics) { $differences.Add("$($result.platform): check diagnostics differ.") }
        if ([bool]$result.check.valid -or -not [bool]$result.check.hasFileReferenceExists) { $differences.Add("$($result.platform): missing reference check is invalid.") }
    }
    if ($differences.Count -gt 0) { throw "Cross-platform skill-tools patch probe failed:`n$($differences -join "`n")" }
    Write-Output 'skill-tools path patch probe: PASS'
}

if ($Mode -ceq 'leg') { Invoke-Leg } else { Invoke-Aggregate }
