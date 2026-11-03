Describe 'Standard core Pester adapter inventory and execution evidence' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ExecutorPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $script:ReportRunRoot = [Environment]::GetEnvironmentVariable('SYP154_PESTER_P02A_EVIDENCE_ROOT', 'Process')
        if ([string]::IsNullOrWhiteSpace($script:ReportRunRoot)) {
            $anchor = if ($IsMacOS) { '/private/tmp' } else { [IO.Path]::GetTempPath() }
            $script:ReportRunRoot = Join-Path $anchor ('SYP226-P02A-' + [guid]::NewGuid().ToString('N'))
        }
        $reportRunFull = [IO.Path]::GetFullPath($script:ReportRunRoot)
        if ($IsWindows -and $reportRunFull.Length -ge 200) { throw 'The P02A report directory is too long for guarded Windows child paths.' }
        if (-not (Test-Path -LiteralPath $reportRunFull -PathType Container)) { [void](New-Item -ItemType Directory -Path $reportRunFull -Force) }
        $script:ReportRunRoot = $reportRunFull

        function Assert-P02ATrue {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }
        function Assert-P02AEqual {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -cne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }
        function Assert-P02AProperties {
            param($Object, [string[]] $ExpectedNames, [string] $Message)
            $actualNames = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
            $expectedSorted = @($ExpectedNames | Sort-Object)
            if (($actualNames -join '|') -cne ($expectedSorted -join '|')) {
                throw "$Message Expected='$($expectedSorted -join ',')' Actual='$($actualNames -join ',')'."
            }
        }
        function Assert-P02AInteger {
            param($Value, [string] $Name)
            if ($Value -isnot [int] -and $Value -isnot [long]) {
                $typeName = if ($null -eq $Value) { 'null' } else { $Value.GetType().FullName }
                throw "$Name must be serialized as an integer; got '$typeName'."
            }
        }
        function Get-P02AFileSha256 {
            param([string] $Path)

            $algorithm = [Security.Cryptography.SHA256]::Create()
            $stream = $null
            try {
                $stream = [IO.File]::OpenRead($Path)
                $hashBytes = $algorithm.ComputeHash($stream)
                return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
                $algorithm.Dispose()
            }
        }
        function Write-P02AText {
            param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
            $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
            [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $Text, [Text.UTF8Encoding]::new($false))
        }
        function Get-P02AExecutorFunction {
            param([Parameter(Mandatory = $true)][string] $Name)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ExecutorPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) { throw "Could not parse the Pester shard executor: $($parseErrors[0].Message)" }
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                Where-Object { $_.Name -ceq $Name })
            if ($functions.Count -ne 1) { throw "Expected exactly one executor function named '$Name'; found $($functions.Count)." }
            return [scriptblock]::Create($functions[0].Extent.Text)
        }
        function New-P02AChildDirectory {
            $path = Join-Path $script:ReportRunRoot ('f' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $path -Force)
            if ($IsWindows -and $path.Length -ge 200) { throw 'A P02A fixture directory exceeds the short-path budget.' }
            return $path
        }
        function New-P02AFixture {
            $root = New-P02AChildDirectory
            $testRoot = Join-Path $root 'tests'
            $evidenceRoot = Join-Path $root 'e'
            [void](New-Item -ItemType Directory -Path $testRoot -Force)
            [void](New-Item -ItemType Directory -Path $evidenceRoot -Force)
            return [pscustomobject]@{
                Root = $root
                TestRoot = $testRoot
                EvidenceRoot = $evidenceRoot
                SummaryPath = Join-Path $evidenceRoot 'summary.json'
                SelectedWitness = Join-Path $root 'selected.txt'
                UnselectedWitness = Join-Path $root 'unselected.txt'
                AlphaWitness = Join-Path $root 'alpha.txt'
                BetaWitness = Join-Path $root 'beta.txt'
            }
        }
        function Write-P02ASelectedFixture {
            param([Parameter(Mandatory = $true)] $Fixture)
            $selected = @'
Describe 'selected P02A fixture' {
    It 'writes its witness and passes' {
        [IO.File]::WriteAllText([string]$env:SYP154_PESTER_P02A_SELECTED_WITNESS, 'selected')
        1 | Should Be 1
    }
}
'@
            $unselected = @'
Describe 'unselected P02A fixture' {
    It 'writes its witness and fails if it runs' {
        [IO.File]::WriteAllText([string]$env:SYP154_PESTER_P02A_UNSELECTED_WITNESS, 'unselected')
        1 | Should Be 2
    }
}
'@
            Write-P02AText -Path (Join-Path $Fixture.TestRoot 'selected.Tests.ps1') -Text $selected
            Write-P02AText -Path (Join-Path $Fixture.TestRoot 'unselected.Tests.ps1') -Text $unselected
        }
        function Get-P02ARuntimeConfiguration {
            $pesterModule = Get-Module -Name Pester
            if ($null -eq $pesterModule) { throw 'The Pester module must already be loaded by the exact-path test driver.' }
            $manifest = [Environment]::GetEnvironmentVariable('SYP226_PESTER_P02A_SAFE_MANIFEST', 'Process')
            if ([string]::IsNullOrWhiteSpace($manifest)) {
                $manifest = Join-Path $pesterModule.ModuleBase 'Pester.psd1'
            }
            $version = $pesterModule.Version.ToString()
            if ($PSVersionTable.PSEdition -cne 'Core' -or
                $PSVersionTable.PSVersion.Major -ne 7) {
                throw 'Pester adapter contract tests require PowerShell 7 Core.'
            }
            $hostExe = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "The approved Pester manifest is missing: $manifest" }
            if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) { throw "The current PowerShell executable is missing: $hostExe" }
            return [pscustomobject]@{ Manifest = $manifest; Version = $version; HostExe = $hostExe }
        }
        function New-P02AAdapterInvocation {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [string[]] $SelectedNames = @(),
                [bool] $IncludeSelection = $true,
                [string] $SummaryOutputPath,
                [bool] $IncludeSummary = $true,
                [int] $ShardPartitionCount = 1,
                [int] $ShardPartitionIndex = 0,
                [int] $OuterTimeoutSeconds = 60,
                [int] $CancelAfterMilliseconds = 0,
                [string] $IsolationRequirement = 'cooperative'
            )
            $runtime = Get-P02ARuntimeConfiguration
            $wrapperPath = Join-Path $Fixture.Root 'invoke-adapter.ps1'
            $configPath = Join-Path $Fixture.Root 'adapter-arguments.json'
            $runtimePath = Join-Path $Fixture.Root 'executor-runtime.json'
            $stdoutPath = Join-Path $Fixture.Root 'outer.stdout.bin'
            $stderrPath = Join-Path $Fixture.Root 'outer.stderr.bin'
            $wrapperText = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ConfigPath)
$ErrorActionPreference = 'Stop'
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $runtime = [ordered]@{
        pid = [int]$PID
        osPlatform = [string][Environment]::OSVersion.Platform
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
    }
    [IO.File]::WriteAllText([string]$config.RuntimeEvidencePath, ($runtime | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $parameters = @{
        PesterModulePath = [string]$config.PesterModulePath
        PesterVersion = [string]$config.PesterVersion
        TestRoot = [string]$config.TestRoot
        EvidenceRoot = [string]$config.EvidenceRoot
        IsolatedTestFileNames = [string[]]@($config.IsolatedTestFileNames)
        BulkShardSize = [int]1
        ShardPartitionCount = [int]$config.ShardPartitionCount
        ShardPartitionIndex = [int]$config.ShardPartitionIndex
        OuterTimeoutSeconds = [int]$config.OuterTimeoutSeconds
        IsolationRequirement = [string]$config.IsolationRequirement
    }
    if ($config.PSObject.Properties.Name -contains 'SelectedTestFileNames') {
        $parameters.SelectedTestFileNames = [string[]]@($config.SelectedTestFileNames)
    }
    if ($config.PSObject.Properties.Name -contains 'SummaryOutputPath') {
        $parameters.SummaryOutputPath = [string]$config.SummaryOutputPath
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        if ($config.PSObject.Properties.Name -contains 'InjectedEnvironment') {
            foreach ($property in $config.InjectedEnvironment.PSObject.Properties) { [Environment]::SetEnvironmentVariable($property.Name,[string]$property.Value,'Process') }
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            # Injected markers must not revoke the explicit supervisor launch policy
            # before the copied executor can build its own child allowlist.
            [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference','Bypass','Process')
        }
        if ($config.CancelAfterMilliseconds -gt 0) { $cancellation.CancelAfter([int]$config.CancelAfterMilliseconds) }
        $parameters.CancellationToken = $cancellation.Token
        & ([string]$config.ExecutorPath) @parameters
    } finally { $cancellation.Dispose() }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
            Write-P02AText -Path $wrapperPath -Text $wrapperText
            # Copied entry points carry exactly their bound closure; no ambient repository fallback.
            $scripts = Join-Path $Fixture.Root 's'
            [void](New-Item -ItemType Directory -Path $scripts)
            $sourceScripts = Split-Path -Parent $script:ExecutorPath
            $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $sourceScripts 'platform-runtime.psd1')
            foreach ($relative in @('Invoke-PesterShardProcess.ps1') + @($manifest.FileList)) {
                $target = Join-Path $scripts $relative
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
                Copy-Item -LiteralPath (Join-Path $sourceScripts $relative) -Destination $target
            }
            $config = [ordered]@{
                ExecutorPath = Join-Path $scripts 'Invoke-PesterShardProcess.ps1'
                PesterModulePath = $runtime.Manifest
                PesterVersion = $runtime.Version
                TestRoot = $Fixture.TestRoot
                EvidenceRoot = $Fixture.EvidenceRoot
                IsolatedTestFileNames = [string[]]@()
                ShardPartitionCount = [int]$ShardPartitionCount
                ShardPartitionIndex = [int]$ShardPartitionIndex
                OuterTimeoutSeconds = $OuterTimeoutSeconds
                CancelAfterMilliseconds = $CancelAfterMilliseconds
                IsolationRequirement = $IsolationRequirement
                RuntimeEvidencePath = $runtimePath
            }
            if ($IncludeSelection) {
                $config['SelectedTestFileNames'] = [string[]]@($SelectedNames)
                $config['IsolatedTestFileNames'] = [string[]]@($SelectedNames)
            }
            if ($IncludeSummary) {
                if ([string]::IsNullOrWhiteSpace($SummaryOutputPath)) { $SummaryOutputPath = $Fixture.SummaryPath }
                $config['SummaryOutputPath'] = $SummaryOutputPath
            }
            Write-P02AText -Path $configPath -Text ($config | ConvertTo-Json -Depth 8)
            return [pscustomobject]@{
                Runtime = $runtime
                WrapperPath = $wrapperPath
                ConfigPath = $configPath
                RuntimePath = $runtimePath
                StdoutPath = $stdoutPath
                StderrPath = $stderrPath
                SummaryPath = if ($IncludeSummary) { [string]$config['SummaryOutputPath'] } else { $null }
            }
        }
        function Quote-P02AProcessArgument {
            param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
            if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append([char]34)
            $slashCount = 0
            foreach ($character in $Value.ToCharArray()) {
                if ($character -eq [char]92) { $slashCount++; continue }
                if ($character -eq [char]34) {
                    for ($index = 0; $index -lt (($slashCount * 2) + 1); $index++) { [void]$builder.Append([char]92) }
                    [void]$builder.Append([char]34)
                    $slashCount = 0
                    continue
                }
                for ($index = 0; $index -lt $slashCount; $index++) { [void]$builder.Append([char]92) }
                $slashCount = 0
                [void]$builder.Append($character)
            }
            for ($index = 0; $index -lt ($slashCount * 2); $index++) { [void]$builder.Append([char]92) }
            [void]$builder.Append([char]34)
            return $builder.ToString()
        }
        function Invoke-P02AHiddenAdapter {
            param([Parameter(Mandatory = $true)] $Invocation, [Parameter(Mandatory = $true)] $Fixture)
            $environmentNames = @(
                'SYP154_PESTER_P02A_SELECTED_WITNESS',
                'SYP154_PESTER_P02A_UNSELECTED_WITNESS',
                'SYP154_PESTER_P02A_ALPHA_WITNESS',
                'SYP154_PESTER_P02A_BETA_WITNESS',
                'SYP154_PESTER_P02A_RUNTIME_PATH'
            )
            $oldEnvironment = @{}
            foreach ($name in $environmentNames) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
            [Environment]::SetEnvironmentVariable('SYP154_PESTER_P02A_SELECTED_WITNESS', $Fixture.SelectedWitness, 'Process')
            [Environment]::SetEnvironmentVariable('SYP154_PESTER_P02A_UNSELECTED_WITNESS', $Fixture.UnselectedWitness, 'Process')
            [Environment]::SetEnvironmentVariable('SYP154_PESTER_P02A_ALPHA_WITNESS', $Fixture.AlphaWitness, 'Process')
            [Environment]::SetEnvironmentVariable('SYP154_PESTER_P02A_BETA_WITNESS', $Fixture.BetaWitness, 'Process')
            [Environment]::SetEnvironmentVariable('SYP154_PESTER_P02A_RUNTIME_PATH', $Invocation.RuntimePath, 'Process')
            $process = $null
            $processHandle = $null
            $processId = $null
            $processStartTimeUtc = $null
            $exitCode = $null
            $timedOut = $false
            try {
                $rawArguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    $rawArguments += @('-ExecutionPolicy', 'Bypass')
                }
                $rawArguments += @('-File', $Invocation.WrapperPath, '-ConfigPath', $Invocation.ConfigPath)
                $argumentLine = [string]::Join(' ', @($rawArguments | ForEach-Object { Quote-P02AProcessArgument -Value ([string]$_) }))
                $startParameters = @{
                    FilePath = $Invocation.Runtime.HostExe
                    ArgumentList = $argumentLine
                    WorkingDirectory = $script:RepositoryRoot
                    PassThru = $true
                    RedirectStandardOutput = $Invocation.StdoutPath
                    RedirectStandardError = $Invocation.StderrPath
                    ErrorAction = 'Stop'
                }
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    $startParameters.WindowStyle = 'Hidden'
                }
                $process = Start-Process @startParameters
                $processHandle = $process.Handle
                $processId = [int]$process.Id
                $processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                if (-not $process.WaitForExit(90000)) {
                    $timedOut = $true
                    $process.Kill()
                    $process.WaitForExit()
                }
                if ($process.HasExited) {
                    $process.Refresh()
                    $rawExitCode = $process.ExitCode
                    if ($null -eq $rawExitCode) {
                        throw [InvalidOperationException]::new("Hidden adapter process $processId exited without an available exit code.")
                    }
                    $exitCode = [int]$rawExitCode
                }
            }
            finally {
                try {
                    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process') }
                }
                finally {
                    if ($null -ne $process) { $process.Dispose() }
                }
            }
            $stdoutText = if (Test-Path -LiteralPath $Invocation.StdoutPath -PathType Leaf) {
                [IO.File]::ReadAllText($Invocation.StdoutPath, [Text.Encoding]::UTF8)
            } else { '' }
            $stderrText = if (Test-Path -LiteralPath $Invocation.StderrPath -PathType Leaf) {
                [IO.File]::ReadAllText($Invocation.StderrPath, [Text.Encoding]::UTF8)
            } else { '' }
            return [pscustomobject]@{
                ProcessId = $processId
                ProcessStartTimeUtc = $processStartTimeUtc
                ExitCode = $exitCode
                TimedOut = $timedOut
                WindowStyle = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Hidden' } else { 'Default' }
                StdoutPath = $Invocation.StdoutPath
                StderrPath = $Invocation.StderrPath
                StdoutText = $stdoutText
                StderrText = $stderrText
                SummaryPath = $Invocation.SummaryPath
                Runtime = $Invocation.Runtime
            }
        }
        function Get-P02AProcessEvidenceFiles {
            param([Parameter(Mandatory = $true)] $Fixture)
            return @(Get-ChildItem -LiteralPath $Fixture.EvidenceRoot -Filter 'pester-shard-*.process.json' -File)
        }
        function Get-P02AFilePreview {
            param([string] $Path)
            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
            $stream = $null
            try {
                $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                $maximumBytes = 768
                if ($stream.Length -le ($maximumBytes * 2)) {
                    $buffer = [Array]::CreateInstance([byte], [int]$stream.Length)
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                }
                $prefixBuffer = [Array]::CreateInstance([byte], $maximumBytes)
                $prefixRead = $stream.Read($prefixBuffer, 0, $prefixBuffer.Length)
                [void]$stream.Seek(-$maximumBytes, [IO.SeekOrigin]::End)
                $tailBuffer = [Array]::CreateInstance([byte], $maximumBytes)
                $tailRead = $stream.Read($tailBuffer, 0, $tailBuffer.Length)
                $prefix = [Text.Encoding]::UTF8.GetString($prefixBuffer, 0, $prefixRead)
                $tail = [Text.Encoding]::UTF8.GetString($tailBuffer, 0, $tailRead)
                return $prefix + [Environment]::NewLine + '<truncated middle>' + [Environment]::NewLine + $tail
            }
            catch {
                return '<read failed: ' + $_.Exception.Message + '>'
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
        function Get-P02AChildProcessDiagnostics {
            param([Parameter(Mandatory = $true)] $Fixture)
            foreach ($name in @('Remove-PesterShardTerminalControlSequences','ConvertTo-PesterShardSanitizedDiagnosticText')) {
                . (Get-P02AExecutorFunction $name)
            }
            $files = @(Get-P02AProcessEvidenceFiles -Fixture $Fixture | Sort-Object Name | Select-Object -First 4)
            $details = @()
            foreach ($file in $files) {
                try {
                    $evidence = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $stdoutPath = if ($evidence.PSObject.Properties.Name -contains 'stdoutPath') { [string]$evidence.stdoutPath } else { '' }
                    $stderrPath = if ($evidence.PSObject.Properties.Name -contains 'stderrPath') { [string]$evidence.stderrPath } else { '' }
                    $cleanup = if ($evidence.PSObject.Properties.Name -contains 'cleanup') { $evidence.cleanup } else { $null }
                    $failureSummary = if ($evidence.PSObject.Properties.Name -contains 'failureSummary') { [string]$evidence.failureSummary } else { '' }
                    $details += [pscustomobject][ordered]@{
                        evidencePath = $file.FullName
                        status = if ($evidence.PSObject.Properties.Name -contains 'status') { $evidence.status } else { $null }
                        exitCode = if ($evidence.PSObject.Properties.Name -contains 'exitCode') { $evidence.exitCode } else { $null }
                        cleanup = $cleanup
                        cleanedUp = if ($evidence.PSObject.Properties.Name -contains 'cleanedUp') { $evidence.cleanedUp } else { $null }
                        outputQuotaExceeded = if ($evidence.PSObject.Properties.Name -contains 'outputQuotaExceeded') { $evidence.outputQuotaExceeded } else { $null }
                        failureSummary = $failureSummary
                        error = ConvertTo-PesterShardSanitizedDiagnosticText ([string]$evidence.error)
                        stdoutPath = $stdoutPath
                        stderrPath = $stderrPath
                        stdout = ConvertTo-PesterShardSanitizedDiagnosticText (Get-P02AFilePreview -Path $stdoutPath)
                        stderr = ConvertTo-PesterShardSanitizedDiagnosticText (Get-P02AFilePreview -Path $stderrPath)
                    }
                }
                catch {
                    $details += [pscustomobject][ordered]@{ evidencePath = $file.FullName; readError = $_.Exception.Message }
                }
            }
            $details += [pscustomobject][ordered]@{
                source = 'supervisor'
                message = if ($files.Count -eq 0) { '<no child process evidence>' } else { 'outer adapter streams' }
                stdout = ConvertTo-PesterShardSanitizedDiagnosticText (Get-P02AFilePreview (Join-Path $Fixture.Root 'outer.stdout.bin'))
                stderr = ConvertTo-PesterShardSanitizedDiagnosticText (Get-P02AFilePreview (Join-Path $Fixture.Root 'outer.stderr.bin'))
            }
            $json = ConvertTo-Json -InputObject $details -Depth 8 -Compress
            if ($json.Length -gt 14000) { return $json.Substring(0, 14000) + '<truncated>' }
            return $json
        }
        function Assert-P02AExpectedWithChildDiagnostics {
            param($Actual, $Expected, [Parameter(Mandatory = $true)] $Fixture, [string] $Message)
            if ($Actual -cne $Expected) {
                $actualText = if ($null -eq $Actual) { '<null>' } else { [string]$Actual }
                $expectedText = if ($null -eq $Expected) { '<null>' } else { [string]$Expected }
                $diagnostics = Get-P02AChildProcessDiagnostics -Fixture $Fixture
                throw "$Message Expected='$expectedText' Actual='$actualText'. Child status, error, cleanup and sanitized stream previews: $diagnostics"
            }
        }
        function Assert-P02ARejectedBeforeChild {
            param([Parameter(Mandatory = $true)] $Run, [Parameter(Mandatory = $true)] $Fixture, [string]$ExpectedErrorPattern='INVALID\|Pester summary')
            Assert-P02ATrue ($null -ne $Run.ExitCode -and $Run.ExitCode -ne 0) 'Unsafe summary path must return a true nonzero outer exit.'
            $combined = $Run.StdoutText + [Environment]::NewLine + $Run.StderrText
            Assert-P02ATrue ($combined -match $ExpectedErrorPattern) "Preflight must emit the expected error: $ExpectedErrorPattern"
            Assert-P02ATrue (-not (Test-Path -LiteralPath $Fixture.SelectedWitness -PathType Leaf)) 'Summary path rejection must happen before the selected test executes.'
            $processEvidenceFiles = @(Get-P02AProcessEvidenceFiles -Fixture $Fixture)
            Assert-P02AEqual $processEvidenceFiles.Count 0 'Summary path rejection must happen before a shard process starts.'
        }
    }

    Context 'Pure test-file selection' {
        # Scenario: A discovered inventory contains files in an order different from the requested subset.
        # Purpose: Keep exact selection stable, preserve a one-item array, and retain full discovery for an empty selection.
        It 'UnitT10_selects_exact_discovered_names_in_stable_order' {
            $selectorScript = Get-P02AExecutorFunction -Name 'Select-PesterShardTestPaths'
            . $selectorScript
            $inventoryRoot = Join-Path ([IO.Path]::GetTempPath()) 'standard-pester-selection-inventory'
            $allPaths = @(
                (Join-Path $inventoryRoot 'zeta.Tests.ps1')
                (Join-Path $inventoryRoot 'alpha.Tests.ps1')
                (Join-Path $inventoryRoot 'mu.Tests.ps1')
            )
            $oneSelected = Select-PesterShardTestPaths -AllTestPaths $allPaths -SelectedTestFileNames @('mu.Tests.ps1')
            Assert-P02ATrue ($oneSelected -is [array]) 'A one-file selection must remain a string array.'
            Assert-P02AEqual $oneSelected.Count 1 'A one-file selection must return exactly one path.'
            Assert-P02AEqual $oneSelected[0] (Join-Path $inventoryRoot 'mu.Tests.ps1') 'A selected name must resolve to its discovered full path.'
            $fullInventory = Select-PesterShardTestPaths -AllTestPaths $allPaths -SelectedTestFileNames @()
            Assert-P02ATrue ($fullInventory -is [array]) 'Full discovery must remain an array.'
            $expected = [string[]]@($allPaths)
            [Array]::Sort($expected, [StringComparer]::Ordinal)
            Assert-P02AEqual ($fullInventory -join '|') ($expected -join '|') 'Empty selection must preserve the stable full inventory.'
        }

        # Scenario: Selection includes malformed, unsafe, repeated, missing, or case-ambiguous names.
        # Purpose: Reject caller-controlled paths and ambiguous inventory before planning any shard.
        It 'UnitT20_rejects_duplicate_missing_and_unsafe_names' {
            $selectorScript = Get-P02AExecutorFunction -Name 'Select-PesterShardTestPaths'
            . $selectorScript
            $selectionInventoryRoot = Join-Path ([IO.Path]::GetTempPath()) 'standard-pester-invalid-selection-inventory'
            $inventory = @(
                (Join-Path $selectionInventoryRoot 'alpha.Tests.ps1')
                (Join-Path $selectionInventoryRoot 'beta.Tests.ps1')
            )
            $invalidCases = @(
                [pscustomobject]@{ Name = 'blank'; Paths = $inventory; Selected = @('') }
                [pscustomobject]@{ Name = 'whitespace'; Paths = $inventory; Selected = @('  ') }
                [pscustomobject]@{ Name = 'missing'; Paths = $inventory; Selected = @('missing.Tests.ps1') }
                [pscustomobject]@{ Name = 'duplicate'; Paths = $inventory; Selected = @('alpha.Tests.ps1', 'alpha.Tests.ps1') }
                [pscustomobject]@{ Name = 'relative traversal'; Paths = $inventory; Selected = @('..\alpha.Tests.ps1') }
                [pscustomobject]@{ Name = 'absolute path'; Paths = $inventory; Selected = @((Join-Path $selectionInventoryRoot 'alpha.Tests.ps1')) }
                [pscustomobject]@{ Name = 'UNC path'; Paths = $inventory; Selected = @('\\server\alpha.Tests.ps1') }
                [pscustomobject]@{ Name = 'forward slash'; Paths = $inventory; Selected = @('nested/alpha.Tests.ps1') }
                [pscustomobject]@{ Name = 'backslash'; Paths = $inventory; Selected = @('nested\alpha.Tests.ps1') }
                [pscustomobject]@{ Name = 'unsafe character'; Paths = $inventory; Selected = @('bad?.Tests.ps1') }
                [pscustomobject]@{ Name = 'control character'; Paths = $inventory; Selected = @(('bad' + [char]0 + '.Tests.ps1')) }
                [pscustomobject]@{ Name = 'case ambiguity'; Paths = @((Join-Path $selectionInventoryRoot 'alpha.Tests.ps1'), (Join-Path $selectionInventoryRoot 'Alpha.Tests.ps1')); Selected = @('alpha.Tests.ps1') }
            )
            foreach ($case in $invalidCases) {
                $threw = $false
                try { $null = Select-PesterShardTestPaths -AllTestPaths $case.Paths -SelectedTestFileNames $case.Selected }
                catch {
                    $threw = $true
                    if ($_.Exception.Message -notmatch '^INVALID\|Pester selection') {
                        throw "Case '$($case.Name)' was rejected without the stable selection error: $($_.Exception.Message)"
                    }
                }
                if (-not $threw) { throw "Case '$($case.Name)' must be rejected." }
            }
        }

        # Scenario: PowerShell cmdlets add path/JSON values to the allowlisted child environment.
        # Purpose: Match P3's CLR IDictionary boundary, which rejects PSObject-wrapped strings.
        It 'UnitT25_environment_values_are_native_strings_at_the_P3_boundary' {
            . (Get-P02AExecutorFunction 'Get-PesterShardChildEnvironment')
            if ($null -eq ('P02AEnvironmentContract' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Collections;
public static class P02AEnvironmentContract {
    public static string InvalidEntry(IDictionary environment) {
        foreach (DictionaryEntry entry in environment) {
            if (!(entry.Key is string) || !(entry.Value is string))
                return entry.Key + ": expected CLR string";
        }
        return "";
    }
}
'@
            }
            $environment=Get-PesterShardChildEnvironment
            [P02AEnvironmentContract]::InvalidEntry($environment) | Should Be ''
            $environment['SYP154_PESTER_SHARD_PATHS']=ConvertTo-Json -InputObject @('selected.Tests.ps1') -Compress
            $environment['SYP154_PESTER_RESULT_PATH']=Join-Path $script:ReportRunRoot 'result.json'
            [P02AEnvironmentContract]::InvalidEntry($environment) | Should Be ''
            $environment['SYP154_PESTER_SHARD_PATHS'] | Should Be '["selected.Tests.ps1"]'
        }
    }

    Context 'Path ancestor validation' {
        # Scenario: A real existing test file is reached through a platform-native directory link.
        # Purpose: Reject its reparse parent while accepting an ordinary file and a missing target below a safe directory.
        It 'UnitT30_rejects_reparse_parent_of_existing_file_and_preserves_safe_paths' {
            . (Get-P02AExecutorFunction 'Resolve-PesterShardFileSystemPath')
            $reparseCheckScript = Get-P02AExecutorFunction -Name 'Test-PesterShardReparseItem'
            . $reparseCheckScript
            $pathGuardScript = Get-P02AExecutorFunction -Name 'Assert-PesterShardPathAncestorsNoReparse'
            . $pathGuardScript

            $fixture = New-P02AFixture
            $targetDirectory = Join-Path $fixture.Root 'junction-target'
            [void](New-Item -ItemType Directory -Path $targetDirectory -Force)
            $safeFile = Join-Path $targetDirectory 'existing.txt'
            [IO.File]::WriteAllText($safeFile, 'existing')
            $junctionPath = Join-Path $fixture.Root 'junction-parent'
            try {
                $linkItemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
                [void](New-Item -ItemType $linkItemType -Path $junctionPath -Target $targetDirectory -ErrorAction Stop)
                $junctionItem = Get-Item -Force -LiteralPath $junctionPath
                Assert-P02ATrue (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'The controlled parent must be a real reparse point.'
                $linkedFile = Join-Path $junctionPath 'existing.txt'
                $linkedFileItem = Get-Item -Force -LiteralPath $linkedFile
                Assert-P02ATrue ($linkedFileItem -is [IO.FileInfo]) 'The linked child must be an existing FileInfo leaf.'

                $rejected = $false
                try {
                    Assert-PesterShardPathAncestorsNoReparse -Path $linkedFile -Context 'existing file regression'
                }
                catch {
                    if ($_.Exception.Message -notmatch 'symlinked or reparse-point ancestor') { throw }
                    $rejected = $true
                }
                Assert-P02ATrue $rejected 'An existing file below a reparse directory must be rejected.'

                $null = Assert-PesterShardPathAncestorsNoReparse -Path $safeFile -Context 'safe existing file'
                $safeDirectory = Join-Path $fixture.Root 'safe-existing-directory'
                [void](New-Item -ItemType Directory -Path $safeDirectory -Force)
                $absentTarget = Join-Path (Join-Path $safeDirectory 'not-yet') 'child.txt'
                Assert-P02ATrue (-not (Test-Path -LiteralPath $absentTarget)) 'The absent target fixture must remain absent.'
                $null = Assert-PesterShardPathAncestorsNoReparse -Path $absentTarget -Context 'safe absent target'
            }
            finally {
                if (Test-Path -LiteralPath $junctionPath) {
                    [IO.Directory]::Delete($junctionPath, $false)
                }
            }
        }

        # Scenario: PowerShell's current location differs from the process working directory.
        # Purpose: Resolve relative inputs and summary containment against the caller's filesystem location.
        It 'UnitT35_resolves_relative_inputs_from_PowerShell_location' {
            foreach ($name in @('Resolve-PesterShardFileSystemPath','Test-PesterShardReparseItem','Assert-PesterShardPathAncestorsNoReparse','Resolve-PesterShardSummaryOutputPath')) {
                . (Get-P02AExecutorFunction $name)
            }
            $fixture=New-P02AFixture
            $processDirectory=[Environment]::CurrentDirectory
            Push-Location -LiteralPath $fixture.Root
            try {
                [Environment]::CurrentDirectory | Should Be $processDirectory
                Resolve-PesterShardFileSystemPath './tests' | Should Be $fixture.TestRoot
                Resolve-PesterShardSummaryOutputPath './e/summary.json' './e' './tests' | Should Be $fixture.SummaryPath
                { Resolve-PesterShardFileSystemPath 'Env:PATH' } | Should Throw 'filesystem'
            } finally { Pop-Location }
        }

        # Scenario: A startup exception wraps another exception containing sensitive diagnostic data.
        # Purpose: Preserve exception types and inner causes while bounding and sanitizing output.
        It 'UnitT37_formats_bounded_sanitized_exception_chains' {
            foreach ($name in @('Remove-PesterShardTerminalControlSequences','ConvertTo-PesterShardSanitizedDiagnosticText','Format-PesterShardException')) {
                . (Get-P02AExecutorFunction $name)
            }
            $inner=[IO.IOException]::new("missing-working-directory`nsecret=diagnostic-sentinel")
            $failure=[InvalidOperationException]::new('start rejected',$inner)
            $text=Format-PesterShardException $failure
            $text | Should Match 'System.InvalidOperationException: start rejected'
            $text | Should Match 'System.IO.IOException: missing-working-directory'
            $text | Should Not Match 'diagnostic-sentinel'
            $text.Length | Should BeLessThan 4097
            (Format-PesterShardException ([Exception]::new(('x' * 10000)))).Length | Should BeLessThan 4097
            Format-PesterShardException ([Exception]::new(('x' * 10000),$inner)) | Should Match 'System.IO.IOException: missing-working-directory'
        }

        # Scenario: A probe fails before it can write a process receipt, but supervisor stderr has a cause.
        # Purpose: Keep early failures diagnosable without exposing sensitive stderr content.
        It 'UnitT39_reports_supervisor_failure_without_child_evidence' {
            $fixture=New-P02AFixture
            Write-P02AText (Join-Path $fixture.Root 'outer.stderr.bin') "Environment must contain explicit string values.`nsecret=diagnostic-sentinel"
            $text=Get-P02AChildProcessDiagnostics $fixture
            $diagnostics=$text | ConvertFrom-Json
            $diagnostics[0].message | Should Be '<no child process evidence>'
            $diagnostics[0].stderr | Should Match 'Environment must contain explicit string values'
            $text | Should Not Match 'diagnostic-sentinel'
        }
    }

    Context 'Quota diagnostics' {
        # Scenario: Quota termination leaves a full-size capture containing untrusted output.
        # Purpose: Return a bounded owner diagnostic promptly while preserving the raw evidence bytes.
        It 'UnitT10_reports_quota_without_reprocessing_full_captures' {
            foreach ($name in @('Get-PesterShardFailureSummary','Read-PesterShardOutputPrefix','Read-PesterShardOutputTail','ConvertFrom-PesterShardCliXmlDiagnostic','ConvertTo-PesterShardSanitizedDiagnosticText','Remove-PesterShardTerminalControlSequences')) {
                . (Get-P02AExecutorFunction $name)
            }
            $fixture=New-P02AFixture
            $path=Join-Path $fixture.EvidenceRoot 'quota.log'
            $payload='secret=quota-diagnostic-sentinel' + ('x' * 1048544)
            Write-P02AText $path $payload
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $summary=Get-PesterShardFailureSummary -Paths @($path) -OutputQuotaExceeded
            $clock.Stop()
            $summary | Should Be 'Pester shard output exceeded the per-stream character limit; raw captures retained.'
            $clock.Elapsed.TotalSeconds | Should BeLessThan 5
            [IO.File]::ReadAllText($path) | Should Be $payload
        }
    }

    Context 'Actual Pester adapter' {
        # Scenario: A copied executor has a missing dependency or a self-rehashed candidate module.
        # Purpose: Reject incomplete closure and candidate self-authorization before importing or starting tests.
        It 'InterT05_rejects_missing_and_self_authorized_runtime_closures' {
            foreach ($mode in @('missing','self-authorized')) {
                $fixture=New-P02AFixture; Write-P02ASelectedFixture $fixture
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1')
                $scripts=Join-Path $fixture.Root 's'
                if ($mode -eq 'missing') { Remove-Item -LiteralPath (Join-Path $scripts 'platform/UnixProcess.cs') }
                else {
                    $module=Join-Path $scripts 'platform-runtime.psm1'
                    Write-P02AText $module "throw 'candidate module executed'"
                    $hash=(Get-FileHash -LiteralPath $module -Algorithm SHA256).Hash.ToLowerInvariant()
                    $manifest=Join-Path $scripts 'platform-runtime.psd1'
                    $text=[IO.File]::ReadAllText($manifest)
                    $text=[regex]::Replace($text,"(Path = 'platform-runtime.psm1'; Sha256 = ')[a-f0-9]{64}",('${1}'+$hash))
                    Write-P02AText $manifest $text
                }
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                Assert-P02ARejectedBeforeChild $run $fixture -ExpectedErrorPattern 'INVALID\|'
                ($run.StderrText -match 'candidate module executed') | Should Be $false
            }
        }

        # Scenario: The caller selects a duplicate, missing or unsafe name in a real invocation.
        # Purpose: Confirm selection rejection precedes launch, with no selected-test witness.
        It 'InterT07_rejects_invalid_selection_before_launch' {
            foreach ($names in @(@('selected.Tests.ps1','selected.Tests.ps1'),@('missing.Tests.ps1'),@('../selected.Tests.ps1'))) {
                $fixture=New-P02AFixture; Write-P02ASelectedFixture $fixture
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames $names
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                Assert-P02ARejectedBeforeChild $run $fixture -ExpectedErrorPattern 'INVALID\|Pester selection'
            }
        }

        # Scenario: A real P2 directory open fails before the child can start.
        # Purpose: Retain a sanitized cause in process evidence, the thrown error, and adapter diagnostics.
        It 'InterT08_reports_start_failure_before_child_launch' {
            $fixture=New-P02AFixture
            $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1')
            $probe=@'
param([string]$ConfigPath)
$ErrorActionPreference='Stop'
try {
    $config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($config.ExecutorPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Executor parse failed.' }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
    }
    $guards=[Collections.Generic.List[IDisposable]]::new()
    try {
        Import-PesterShardRuntime (Split-Path -Parent $config.ExecutorPath) $guards
        $script:PesterShardChildOutputQuotaCharacters=1048576
        $script:PesterShardCapabilities=$null
        Invoke-PesterShardProcess -Paths @() -ModulePath $config.PesterModulePath -Version $config.PesterVersion -ChildPowerShell ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -EncodedChildScript '' -ResultPath (Join-Path $config.EvidenceRoot 'result.json') -ProcessEvidencePath (Join-Path $config.EvidenceRoot 'pester-shard-start-failure.process.json') -StdoutPath (Join-Path $config.EvidenceRoot 'out') -StderrPath (Join-Path $config.EvidenceRoot 'err') -TimeoutSeconds 30 -WorkingDirectory (Join-Path $config.EvidenceRoot 'missing-working-directory') -Environment (Get-PesterShardChildEnvironment)
    } finally { for ($i=$guards.Count-1;$i -ge 0;$i--) { $guards[$i].Dispose() } }
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
            Write-P02AText $invocation.WrapperPath $probe
            $run=Invoke-P02AHiddenAdapter $invocation $fixture
            $run.TimedOut | Should Be $false
            $run.ExitCode | Should Not Be 0
            $files=@(Get-P02AProcessEvidenceFiles $fixture)
            $files.Count | Should Be 1
            $evidence=Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
            $evidence.status | Should Be 'start-failed'
            $evidence.processStarted | Should Be $false
            $evidence.error | Should Not BeNullOrEmpty
            $evidence.error | Should Match 'open-working-directory.*Exception'
            $evidence.error.Length | Should BeLessThan 4097
            $run.StderrText | Should Match ([regex]::Escape($evidence.error))
            $diagnostics=Get-P02AChildProcessDiagnostics $fixture | ConvertFrom-Json
            $diagnostics[0].error | Should Be $evidence.error
            Test-Path -LiteralPath $fixture.SummaryPath | Should Be $false
        }

        if ($IsWindows) {
            # Scenario: An unsigned child script is blocked by a real process-scoped Restricted policy.
            # Purpose: Require the Windows launcher to explicitly override policy without changing registry policy.
            It 'InterT09_windows_child_explicitly_bypasses_restricted_policy' {
                $fixture=New-P02AFixture
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1')
                $probe=@'
param([string]$ConfigPath)
$ErrorActionPreference='Stop'
try {
    $config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($config.ExecutorPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Executor parse failed.' }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
    }
    $guards=[Collections.Generic.List[IDisposable]]::new()
    $baseline=$null
    try {
        Import-PesterShardRuntime (Split-Path -Parent $config.ExecutorPath) $guards
        $script:PesterShardChildOutputQuotaCharacters=1048576
        $script:PesterShardCapabilities=$null
        $root=Split-Path -Parent $ConfigPath
        $result=Join-Path $root 'policy-result.json'
        $child=Join-Path $root 'unsigned-child.ps1'
        $body="[IO.File]::WriteAllText('"+$result.Replace("'","''")+"', ('{`"policy`":`"'+(Get-ExecutionPolicy)+'`"}'))"
        [IO.File]::WriteAllText($child,$body,[Text.UTF8Encoding]::new($false))
        $environment=Get-PesterShardChildEnvironment
        $environment['PSExecutionPolicyPreference']='Restricted'
        $directory=Open-PesterShardDirectory $root; $guards.Add($directory)
        $executable=Open-PesterShardInput ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) $guards
        # EncodedCommand can run under Restricted; set the process policy explicitly so an outer Bypass or portable-host configuration cannot define this baseline.
        # Do not load Security cmdlets here: Restricted can reject their module type data before the unsigned child is invoked.
        $command="`$ErrorActionPreference='Stop'; [Console]::Out.WriteLine(('processPolicy='+`$env:PSExecutionPolicyPreference)); try { & '"+$child.Replace("'","''")+"'; exit 99 } catch { if (`$_.Exception -is [Management.Automation.PSSecurityException]) { exit 17 }; throw }"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $baselineOut=Join-Path $root 'baseline.out'
        $baselineErr=Join-Path $root 'baseline.err'
        $cleanup=$null
        $baselineError=''
        try {
            $baseline=Start-PlatformOwnedProcess -ExecutableLease $executable -WorkingDirectoryLease $directory -Environment $environment -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Restricted','-EncodedCommand',$encoded) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(30)) -StdoutPath $baselineOut -StderrPath $baselineErr -OutputLimitCharacters 1048576
            [void]$baseline.WaitForExit([TimeSpan]::FromSeconds(30))
            $cleanup=Stop-PlatformOwnedProcess -Lease $baseline -ExpectedStartIdentity $baseline.StartIdentity -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(5))
        } catch {
            $baselineError=Format-PesterShardException $_.Exception
        }
        $resultExists=Test-Path -LiteralPath $result
        $cleanedUp=$null -ne $cleanup -and [bool]$cleanup.CleanedUp
        $baselineExitCode=if ($null -eq $baseline -or $null -eq $baseline.ExitCode) { $null } else { $baseline.ExitCode }
        if (-not [string]::IsNullOrEmpty($baselineError) -or -not $cleanedUp -or $baselineExitCode -ne 17 -or $resultExists) {
            $stdoutPrefix=ConvertTo-PesterShardSanitizedDiagnosticText (ConvertFrom-PesterShardCliXmlDiagnostic (Read-PesterShardOutputPrefix -Path $baselineOut -MaxChars 1024))
            $stderrPrefix=ConvertTo-PesterShardSanitizedDiagnosticText (ConvertFrom-PesterShardCliXmlDiagnostic (Read-PesterShardOutputPrefix -Path $baselineErr -MaxChars 1024))
            if ($stdoutPrefix.Length -gt 1024) { $stdoutPrefix=$stdoutPrefix.Substring(0,1024) }
            if ($stderrPrefix.Length -gt 1024) { $stderrPrefix=$stderrPrefix.Substring(0,1024) }
            $stdoutPrefix=if ([string]::IsNullOrWhiteSpace($stdoutPrefix)) { '<empty>' } else { $stdoutPrefix.Replace("`r",' ').Replace("`n",' | ') }
            $stderrPrefix=if ([string]::IsNullOrWhiteSpace($stderrPrefix)) { '<empty>' } else { $stderrPrefix.Replace("`r",' ').Replace("`n",' | ') }
            $exitCodeText=if ($null -eq $baselineExitCode) { '<null>' } else { [string]$baselineExitCode }
            $cleanedUpText=if ($null -eq $cleanup) { '<null>' } else { [string]$cleanup.CleanedUp }
            $errorText=if ([string]::IsNullOrEmpty($baselineError)) { '<none>' } else { $baselineError }
            throw "Restricted baseline did not block the unsigned script with confirmed cleanup. error=$errorText; exitCode=$exitCodeText; cleanup.cleanedUp=$cleanedUpText; resultExists=$resultExists; baseline.out.prefix=$stdoutPrefix; baseline.err.prefix=$stderrPrefix"
        }
        $baseline.Dispose(); $baseline=$null
        $receipt=Invoke-PesterShardProcess -Paths @($child) -ModulePath $config.PesterModulePath -Version $config.PesterVersion -ChildPowerShell ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ChildScriptPath $child -ResultPath $result -ProcessEvidencePath (Join-Path $config.EvidenceRoot 'pester-shard-policy.process.json') -StdoutPath (Join-Path $root 'policy.out') -StderrPath (Join-Path $root 'policy.err') -TimeoutSeconds 30 -WorkingDirectory $root -Environment $environment
        if ($receipt.status -cne 'completed' -or $receipt.exitCode -ne 0 -or -not $receipt.cleanedUp) { throw 'Explicit Windows policy launch did not complete.' }
        if ((Get-Content -LiteralPath $result -Raw | ConvertFrom-Json).policy -cne 'Bypass') { throw 'Child did not receive explicit Bypass policy.' }
    } finally {
        if ($null -ne $baseline) {
            Stop-PlatformOwnedProcess -Lease $baseline -ExpectedStartIdentity $baseline.StartIdentity -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(5)) | Out-Null
            $baseline.Dispose()
        }
        for ($i=$guards.Count-1;$i -ge 0;$i--) { $guards[$i].Dispose() }
    }
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }
'@
                Write-P02AText $invocation.WrapperPath $probe
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                Assert-P02AExpectedWithChildDiagnostics $run.ExitCode 0 $fixture 'Restricted baseline and explicit Bypass child must pass.'
            }
        }

        # Scenario: One selected file passes while an unselected file would create a witness and fail.
        # Purpose: Prove the real executor runs only the requested file and writes truthful typed completion evidence.
        It 'InterT10_executes_only_selected_files_and_writes_typed_summary' {
            $fixture = New-P02AFixture
            Write-P02ASelectedFixture -Fixture $fixture
            $selectedPath = Join-Path $fixture.TestRoot 'selected.Tests.ps1'
            $invocation = New-P02AAdapterInvocation -Fixture $fixture -SelectedNames @('selected.Tests.ps1')
            $run = Invoke-P02AHiddenAdapter -Invocation $invocation -Fixture $fixture
            Assert-P02ATrue (-not $run.TimedOut) 'The hidden adapter process must finish within its bounded timeout.'
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                Assert-P02AEqual $run.WindowStyle 'Hidden' 'The adapter process must run hidden on Windows.'
            }
            Assert-P02AExpectedWithChildDiagnostics -Actual $run.ExitCode -Expected 0 -Fixture $fixture -Message 'A successful selected adapter run must exit zero.'
            Assert-P02ATrue (Test-Path -LiteralPath $fixture.SelectedWitness -PathType Leaf) 'The selected fixture must produce its witness.'
            Assert-P02ATrue (-not (Test-Path -LiteralPath $fixture.UnselectedWitness -PathType Leaf)) 'The unselected fixture must not execute.'
            Assert-P02ATrue (Test-Path -LiteralPath $run.SummaryPath -PathType Leaf) 'A successful run must create its summary.'

            $summaryBytes = [IO.File]::ReadAllBytes($run.SummaryPath)
            Assert-P02ATrue ($summaryBytes.Length -gt 3) 'The summary must contain JSON bytes.'
            Assert-P02ATrue (-not ($summaryBytes[0] -eq 239 -and $summaryBytes[1] -eq 187 -and $summaryBytes[2] -eq 191)) 'The summary must be UTF-8 without a BOM.'
            $summary = [Text.Encoding]::UTF8.GetString($summaryBytes) | ConvertFrom-Json
            Assert-P02AProperties $summary @('schemaVersion', 'type', 'executed', 'status', 'runtime', 'pesterVersion', 'pesterModuleSha256', 'executorSha256', 'testFiles', 'counts', 'shards') 'The summary must have the exact version 1 property set.'
            Assert-P02AInteger $summary.schemaVersion 'schemaVersion'
            Assert-P02AEqual $summary.schemaVersion 1 'The summary schema version must be 1.'
            Assert-P02AEqual $summary.type 'standard-pester-execution-summary' 'The summary must use the typed adapter type.'
            Assert-P02ATrue ($summary.executed -is [bool] -and $summary.executed) 'The summary must say that execution occurred.'
            Assert-P02AEqual $summary.status 'completed' 'The summary must say completed only after a successful run.'
            Assert-P02AProperties $summary.runtime @('osPlatform', 'psEdition', 'psVersion') 'Runtime must contain only observed executor details.'
            $runtime = Get-Content -LiteralPath $invocation.RuntimePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AEqual $summary.runtime.osPlatform $runtime.osPlatform 'The summary platform must match the actual executor.'
            Assert-P02AEqual $summary.runtime.psEdition $runtime.psEdition 'The summary edition must match the actual executor.'
            Assert-P02AEqual $summary.runtime.psVersion $runtime.psVersion 'The summary version must match the actual executor.'
            Assert-P02AEqual $summary.pesterVersion $invocation.Runtime.Version 'The summary must use the loaded Pester version.'
            $manifestSha = Get-P02AFileSha256 -Path $invocation.Runtime.Manifest
            Assert-P02AEqual $summary.pesterModuleSha256 $manifestSha 'The summary must hash the actual Pester manifest bytes.'
            $executorSha = Get-P02AFileSha256 -Path $script:ExecutorPath
            Assert-P02AEqual $summary.executorSha256 $executorSha 'The summary must hash the executor that actually ran.'
            Assert-P02AEqual @($summary.testFiles).Count 1 'The summary inventory must contain the selected file only.'
            Assert-P02AEqual $summary.testFiles[0] $selectedPath 'The summary inventory must use the selected full path.'
            Assert-P02AProperties $summary.counts @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount') 'Counts must have the exact typed field set.'
            foreach ($countName in @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount')) {
                Assert-P02AInteger $summary.counts.$countName $countName
            }
            Assert-P02AEqual $summary.counts.TotalCount 1 'The selected fixture must report one test.'
            Assert-P02AEqual $summary.counts.PassedCount 1 'The selected fixture must report one pass.'
            Assert-P02AEqual $summary.counts.FailedCount 0 'The selected fixture must report no failures.'
            Assert-P02AEqual $summary.counts.SkippedCount 0 'The selected fixture must report no skips.'
            Assert-P02AEqual $summary.counts.PendingCount 0 'The selected fixture must report no pending tests.'
            Assert-P02AEqual $summary.counts.InconclusiveCount 0 'The selected fixture must report no inconclusive tests.'

            Assert-P02AEqual @($summary.shards).Count 1 'The summary must include one actual shard.'
            $shard = @($summary.shards)[0]
            Assert-P02AProperties $shard @('name', 'paths', 'processEvidencePath', 'resultPath', 'exitCode', 'status', 'cleanedUp', 'outputQuotaExceeded') 'Each shard must have the exact process summary fields.'
            Assert-P02AEqual $shard.name 'selected' 'The shard name must come from the actual selected file.'
            Assert-P02AEqual @($shard.paths).Count 1 'The shard path list must contain one file.'
            Assert-P02AEqual $shard.paths[0] $selectedPath 'The shard path must match the actual selected file.'
            Assert-P02AEqual $shard.exitCode 0 'The shard process must exit zero.'
            Assert-P02ATrue ($shard.cleanedUp -is [bool] -and $shard.cleanedUp) 'The shard summary must report successful cleanup.'
            Assert-P02ATrue ($shard.outputQuotaExceeded -is [bool] -and -not $shard.outputQuotaExceeded) 'The shard must remain within the output quota.'
            Assert-P02ATrue (Test-Path -LiteralPath $shard.processEvidencePath -PathType Leaf) 'The summary must link to actual process evidence.'
            Assert-P02ATrue (Test-Path -LiteralPath $shard.resultPath -PathType Leaf) 'The summary must link to actual Pester result evidence.'
            $processEvidence = Get-Content -LiteralPath $shard.processEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AEqual $processEvidence.status 'completed' 'Process evidence must say completed.'
            Assert-P02AEqual $processEvidence.exitCode 0 'Process evidence must record the true successful child exit.'
            Assert-P02ATrue ($processEvidence.cleanup.cleanedUp -is [bool] -and $processEvidence.cleanup.cleanedUp) 'Process evidence must confirm owned process cleanup.'
            Assert-P02AEqual $processEvidence.outputQuotaExceeded $false 'Process evidence must confirm no output quota overrun.'
            Assert-P02ATrue ($run.StdoutText -match 'Aggregate - Total: 1 Passed: 1 Failed: 0') 'The adapter must preserve the existing aggregate stdout.'
        }

        # Scenario: The adapter is invoked after Push-Location with default ./tests and relative evidence/module inputs.
        # Purpose: Resolve all caller paths at the PowerShell location rather than the unchanged process cwd.
        It 'InterT12_resolves_default_tests_and_relative_inputs_after_location_change' {
            $fixture=New-P02AFixture; Write-P02ASelectedFixture $fixture
            $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1')
            $moduleRoot=Join-Path $fixture.Root 'Pester'
            Copy-Item -LiteralPath (Split-Path -Parent $invocation.Runtime.Manifest) -Destination $moduleRoot -Recurse -Force
            $config=Get-Content -LiteralPath $invocation.ConfigPath -Raw | ConvertFrom-Json
            $config.PesterModulePath='./Pester/Pester.psd1'
            $config.EvidenceRoot='./e'
            $config.SummaryOutputPath='./e/summary.json'
            Write-P02AText $invocation.ConfigPath ($config | ConvertTo-Json -Depth 8)
            $wrapper=[IO.File]::ReadAllText($invocation.WrapperPath)
            $invoke='& ([string]$config.ExecutorPath) @parameters'
            $replacement=@'
$parameters.Remove('TestRoot')
$processDirectory=[Environment]::CurrentDirectory
Push-Location -LiteralPath (Split-Path -Parent $ConfigPath)
try {
    if ([Environment]::CurrentDirectory -cne $processDirectory) { throw 'Fixture unexpectedly changed process cwd.' }
    & ([string]$config.ExecutorPath) @parameters
} finally { Pop-Location }
'@
            Write-P02AText $invocation.WrapperPath ($wrapper.Replace($invoke,$replacement))
            $run=Invoke-P02AHiddenAdapter $invocation $fixture
            Assert-P02AExpectedWithChildDiagnostics $run.ExitCode 0 $fixture 'Relative inputs must resolve at the caller location.'
            $summary=Get-Content -LiteralPath $fixture.SummaryPath -Raw | ConvertFrom-Json
            $summary.testFiles[0] | Should Be (Join-Path $fixture.TestRoot 'selected.Tests.ps1')
            $summary.counts.PassedCount | Should Be 1
            Test-Path -LiteralPath $fixture.SelectedWitness | Should Be $true
            Test-Path -LiteralPath $fixture.UnselectedWitness | Should Be $false
        }

        # Scenario: A real selected test fails or a discovered file contains no test cases.
        # Purpose: Keep true process failures and empty inventories from producing a completed machine summary.
        It 'InterT20_rejects_failed_and_empty_runs_without_completed_summary' {
            $failedFixture = New-P02AFixture
            $failedText = @'
Describe 'failed P02A fixture' {
    It 'fails with a real assertion' {
        1 | Should Be 2
    }
}
'@
            Write-P02AText -Path (Join-Path $failedFixture.TestRoot 'failure.Tests.ps1') -Text $failedText
            $failedInvocation = New-P02AAdapterInvocation -Fixture $failedFixture -SelectedNames @('failure.Tests.ps1')
            $failedRun = Invoke-P02AHiddenAdapter -Invocation $failedInvocation -Fixture $failedFixture
            Assert-P02ATrue (-not $failedRun.TimedOut) 'The failed Pester child must finish within its bounded timeout.'
            Assert-P02ATrue ($failedRun.ExitCode -ne 0) 'A real failed Pester test must cause a true nonzero outer exit.'
            Assert-P02ATrue (-not (Test-Path -LiteralPath $failedRun.SummaryPath -PathType Leaf)) 'A failed run must not write a completed summary.'
            $failedEvidenceFiles = @(Get-P02AProcessEvidenceFiles -Fixture $failedFixture)
            Assert-P02AEqual $failedEvidenceFiles.Count 1 'A failed run must leave one real process evidence record.'
            $failedEvidence = Get-Content -LiteralPath $failedEvidenceFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AExpectedWithChildDiagnostics -Actual $failedEvidence.status -Expected 'failed' -Fixture $failedFixture -Message 'The failure case must retain the child process failure status.'
            Assert-P02AExpectedWithChildDiagnostics -Actual $failedEvidence.exitCode -Expected 2 -Fixture $failedFixture -Message 'The failed Pester child must retain its actual nonzero exit.'
            Assert-P02ATrue ($failedEvidence.cleanup.cleanedUp -is [bool] -and $failedEvidence.cleanup.cleanedUp) 'The failed child must be cleaned up.'
            $failedResult = Get-Content -LiteralPath $failedEvidence.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AEqual $failedResult.FailedCount 1 'The real Pester result must identify one failed test.'

            $emptyFixture = New-P02AFixture
            $emptyText = @'
Describe 'empty P02A fixture' {
}
'@
            Write-P02AText -Path (Join-Path $emptyFixture.TestRoot 'empty.Tests.ps1') -Text $emptyText
            $emptyInvocation = New-P02AAdapterInvocation -Fixture $emptyFixture -SelectedNames @('empty.Tests.ps1')
            $emptyRun = Invoke-P02AHiddenAdapter -Invocation $emptyInvocation -Fixture $emptyFixture
            Assert-P02ATrue (-not $emptyRun.TimedOut) 'The empty Pester child must finish within its bounded timeout.'
            Assert-P02ATrue ($emptyRun.ExitCode -ne 0) 'A zero-test run must return a true nonzero outer exit.'
            Assert-P02ATrue ($emptyRun.StderrText -match 'at least one discovered test') 'The empty result must retain the precise empty-run error.'
            Assert-P02ATrue (-not (Test-Path -LiteralPath $emptyRun.SummaryPath -PathType Leaf)) 'A zero-test run must not write a completed summary.'
            $emptyEvidenceFiles = @(Get-P02AProcessEvidenceFiles -Fixture $emptyFixture)
            Assert-P02AEqual $emptyEvidenceFiles.Count 1 'The empty run must leave one real process evidence record.'
            $emptyEvidence = Get-Content -LiteralPath $emptyEvidenceFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AExpectedWithChildDiagnostics -Actual $emptyEvidence.exitCode -Expected 0 -Fixture $emptyFixture -Message 'The empty Pester process must preserve its true zero child exit.'
            Assert-P02ATrue ($emptyEvidence.cleanup.cleanedUp -is [bool] -and $emptyEvidence.cleanup.cleanedUp) 'The empty child must be cleaned up.'
            $emptyResult = Get-Content -LiteralPath $emptyEvidence.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-P02AEqual $emptyResult.TotalCount 0 'The actual Pester result must identify an empty test inventory.'
        }

        # Scenario: Summary output points to an existing file, outside EvidenceRoot, or inside TestRoot.
        # Purpose: Reject unsafe summary destinations before the executor starts any Pester child and preserve private bytes.
        It 'InterT30_rejects_existing_and_outside_summary_paths_before_execution' {
            $existingFixture = New-P02AFixture
            Write-P02ASelectedFixture -Fixture $existingFixture
            $existingPath = Join-Path $existingFixture.EvidenceRoot 'existing.json'
            $sentinelBytes = [byte[]]@(0, 1, 2, 127, 255)
            [IO.File]::WriteAllBytes($existingPath, $sentinelBytes)
            $existingInvocation = New-P02AAdapterInvocation -Fixture $existingFixture -SelectedNames @('selected.Tests.ps1') -SummaryOutputPath $existingPath
            $existingRun = Invoke-P02AHiddenAdapter -Invocation $existingInvocation -Fixture $existingFixture
            Assert-P02ARejectedBeforeChild -Run $existingRun -Fixture $existingFixture
            Assert-P02AEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($existingPath))) ([Convert]::ToBase64String($sentinelBytes)) 'An existing summary file must remain byte-for-byte unchanged.'

            $outsideFixture = New-P02AFixture
            Write-P02ASelectedFixture -Fixture $outsideFixture
            $outsidePath = Join-Path $outsideFixture.Root 'outside.json'
            $outsideInvocation = New-P02AAdapterInvocation -Fixture $outsideFixture -SelectedNames @('selected.Tests.ps1') -SummaryOutputPath $outsidePath
            $outsideRun = Invoke-P02AHiddenAdapter -Invocation $outsideInvocation -Fixture $outsideFixture
            Assert-P02ARejectedBeforeChild -Run $outsideRun -Fixture $outsideFixture
            Assert-P02ATrue (-not (Test-Path -LiteralPath $outsidePath -PathType Leaf)) 'An outside summary path must not be created.'

            $insideFixture = New-P02AFixture
            Write-P02ASelectedFixture -Fixture $insideFixture
            $insidePath = Join-Path $insideFixture.TestRoot 'forbidden-summary.json'
            $insideInvocation = New-P02AAdapterInvocation -Fixture $insideFixture -SelectedNames @('selected.Tests.ps1') -SummaryOutputPath $insidePath
            $insideRun = Invoke-P02AHiddenAdapter -Invocation $insideInvocation -Fixture $insideFixture
            Assert-P02ARejectedBeforeChild -Run $insideRun -Fixture $insideFixture
            Assert-P02ATrue (-not (Test-Path -LiteralPath $insidePath -PathType Leaf)) 'A summary path inside TestRoot must not be created.'

            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                $unsafeFixture = New-P02AFixture
                Write-P02ASelectedFixture -Fixture $unsafeFixture
                $unsafePath = Join-Path $unsafeFixture.EvidenceRoot 'invalid:name.json'
                $unsafeInvocation = New-P02AAdapterInvocation -Fixture $unsafeFixture -SelectedNames @('selected.Tests.ps1') -SummaryOutputPath $unsafePath
                $unsafeRun = Invoke-P02AHiddenAdapter -Invocation $unsafeInvocation -Fixture $unsafeFixture
                Assert-P02ARejectedBeforeChild -Run $unsafeRun -Fixture $unsafeFixture
                $unsafeOutput = $unsafeRun.StdoutText + [Environment]::NewLine + $unsafeRun.StderrText
                Assert-P02ATrue ($unsafeOutput -match 'invalid Windows filename characters') 'Windows ADS and invalid basename characters must be rejected explicitly.'
                Assert-P02ATrue (-not (Test-Path -LiteralPath $unsafePath)) 'An invalid Windows summary basename must not create a file or stream.'
            }
        }

        # Scenario: The caller omits SelectedTestFileNames while two actual test files exist in TestRoot.
        # Purpose: Preserve complete discovery and current aggregate output for every existing workflow invocation.
        It 'InterT40_preserves_default_full_discovery_without_selection' {
            $fixture = New-P02AFixture
            $alphaText = @'
Describe 'default alpha P02A fixture' {
    It 'passes' {
        1 | Should Be 1
    }
}
'@
            $betaText = @'
Describe 'default beta P02A fixture' {
    It 'passes' {
        2 | Should Be 2
    }
}
'@
            Write-P02AText -Path (Join-Path $fixture.TestRoot 'alpha.Tests.ps1') -Text $alphaText
            Write-P02AText -Path (Join-Path $fixture.TestRoot 'beta.Tests.ps1') -Text $betaText
            $invocation = New-P02AAdapterInvocation -Fixture $fixture -IncludeSelection $false
            $run = Invoke-P02AHiddenAdapter -Invocation $invocation -Fixture $fixture
            Assert-P02ATrue (-not $run.TimedOut) 'The default-discovery adapter must finish within its bounded timeout.'
            Assert-P02AExpectedWithChildDiagnostics -Actual $run.ExitCode -Expected 0 -Fixture $fixture -Message 'Default discovery must still exit zero.'
            Assert-P02ATrue (Test-Path -LiteralPath $run.SummaryPath -PathType Leaf) 'Default discovery must produce its requested optional summary.'
            $summary = Get-Content -LiteralPath $run.SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $expectedPaths = [string[]]@(
                (Join-Path $fixture.TestRoot 'alpha.Tests.ps1')
                (Join-Path $fixture.TestRoot 'beta.Tests.ps1')
            )
            [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
            Assert-P02AEqual @($summary.testFiles).Count 2 'Default discovery must report both actual files.'
            Assert-P02AEqual ($summary.testFiles -join '|') ($expectedPaths -join '|') 'Default discovery must report the complete stable inventory.'
            Assert-P02AEqual $summary.counts.TotalCount 2 'Default discovery must preserve its actual aggregate total.'
            Assert-P02AEqual $summary.counts.PassedCount 2 'Both default fixture tests must pass.'
            Assert-P02ATrue ($run.StdoutText -match 'Aggregate - Total: 2 Passed: 2 Failed: 0') 'Default discovery must preserve aggregate stdout.'
        }

        # Scenario: Real pending/inconclusive tests or an invalid count envelope reach the adapter.
        # Purpose: Preserve failure diagnostics while refusing a completed summary for non-pass outcomes.
        It 'InterT42_rejects_pending_inconclusive_and_malformed_counts' {
            foreach ($mode in @('pending','inconclusive','counts')) {
                $fixture=New-P02AFixture
                $body = if ($mode -eq 'pending') { "Describe 'pending' { It 'pending' -Pending { } }" }
                    elseif ($mode -eq 'inconclusive') { "Describe 'inconclusive' { It 'inconclusive' { Set-TestInconclusive 'fixture' } }" }
                    else { "Describe 'unused' { It 'unused' { 1 | Should Be 1 } }" }
                Write-P02AText (Join-Path $fixture.TestRoot 'result.Tests.ps1') $body
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('result.Tests.ps1')
                if ($mode -eq 'counts') {
                    $moduleRoot=Join-Path $fixture.Root 'Pester'
                    Write-P02AText (Join-Path $moduleRoot 'Pester.psd1') "@{RootModule='Pester.psm1';ModuleVersion='4.10.1';FunctionsToExport=@('Invoke-Pester')}"
                    Write-P02AText (Join-Path $moduleRoot 'Pester.psm1') 'function Invoke-Pester { param($Script,[switch]$PassThru); [pscustomobject]@{TotalCount="1";PassedCount=1;FailedCount=0;SkippedCount=0;PendingCount=0;InconclusiveCount=0;TestResult=@()} }; Export-ModuleMember Invoke-Pester'
                    $config=Get-Content -LiteralPath $invocation.ConfigPath -Raw | ConvertFrom-Json
                    $config.PesterModulePath=Join-Path $moduleRoot 'Pester.psd1'
                    Write-P02AText $invocation.ConfigPath ($config | ConvertTo-Json -Depth 8)
                }
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                $run.TimedOut | Should Be $false
                $run.ExitCode | Should Not Be 0
                Test-Path -LiteralPath $run.SummaryPath | Should Be $false
                @(Get-ChildItem -LiteralPath $fixture.EvidenceRoot -Filter '*.cases.json').Count | Should Be 1
                if ($mode -eq 'counts') { $run.StderrText | Should Match 'non-integer TotalCount' }
            }
        }

        # Scenario: Recursive workflow discovery includes a nested test with a unique basename.
        # Purpose: Ensure the shard selection cannot silently omit a workflow-discovered file.
        It 'InterT44_selects_nested_discovery_and_rejects_duplicate_basenames' {
            $fixture=New-P02AFixture
            Write-P02AText (Join-Path $fixture.TestRoot 'nested/deep.Tests.ps1') "Describe 'deep' { It 'passes' { 1 | Should Be 1 } }"
            $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('deep.Tests.ps1')
            $run=Invoke-P02AHiddenAdapter $invocation $fixture
            Assert-P02AExpectedWithChildDiagnostics $run.ExitCode 0 $fixture 'Nested fixture must execute.'
            $summary=Get-Content -LiteralPath $run.SummaryPath -Raw | ConvertFrom-Json
            $summary.testFiles[0] | Should Be (Join-Path $fixture.TestRoot 'nested/deep.Tests.ps1')
            $duplicate=New-P02AFixture
            foreach ($relative in @('a/deep.Tests.ps1','b/deep.Tests.ps1')) { Write-P02AText (Join-Path $duplicate.TestRoot $relative) "throw 'must not execute'" }
            $invocation=New-P02AAdapterInvocation $duplicate -SelectedNames @('deep.Tests.ps1')
            $run=Invoke-P02AHiddenAdapter $invocation $duplicate
            Assert-P02ARejectedBeforeChild $run $duplicate -ExpectedErrorPattern 'INVALID\|Pester selection'
        }

        # Scenario: A live test overruns its deadline or the supervisor cancels its token.
        # Purpose: Exercise real P3 termination rather than child-controlled cancellation markers.
        It 'InterT46_bounds_timeout_and_supervisor_cancellation' {
            foreach ($mode in @('deadline','cancelled')) {
                $fixture=New-P02AFixture
                Write-P02AText (Join-Path $fixture.TestRoot 'wait.Tests.ps1') "Describe 'wait' { It 'waits' { Start-Sleep -Seconds 90 } }"
                $timeout=if ($mode -eq 'deadline') { 10 } else { 60 }
                $cancel=if ($mode -eq 'cancelled') { 30000 } else { 0 }
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('wait.Tests.ps1') -OuterTimeoutSeconds $timeout -CancelAfterMilliseconds $cancel
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                $run.TimedOut | Should Be $false
                $run.ExitCode | Should Not Be 0
                Test-Path -LiteralPath $run.SummaryPath | Should Be $false
                $evidence=Get-Content -LiteralPath (@(Get-P02AProcessEvidenceFiles $fixture)[0].FullName) -Raw | ConvertFrom-Json
                $evidence.status | Should Be $(if ($mode -eq 'deadline') {'timed-out'} else {'cancelled'})
                $evidence.processStarted | Should Be $true
                $evidence.cleanup.cleanedUp | Should Be $true
                $evidence.cleanup.CaptureReadersStopped | Should Be $true
                $evidence.cleanup.CaptureResourcesClosed | Should Be $true
            }
        }

        # Scenario: Either child output stream exceeds the owner's independent quota before a 30-second sleep.
        # Purpose: Require cleanup and adapter completion within 25 seconds of the flood, without a completed summary.
        It 'InterT48_rejects_stdout_and_stderr_quota_overflow' {
            foreach ($stream in @('Out','Error')) {
                $fixture=New-P02AFixture
                $body=if ($stream -ceq 'Out') {
@'
Describe 'quota' { It 'floods stdout' {
    [IO.File]::WriteAllText($env:SYP154_PESTER_P02A_SELECTED_WITNESS,[DateTimeOffset]::UtcNow.ToString('o'))
    [Console]::Out.Write(('x' * 1100000))
    Start-Sleep 30
} }
'@
                } else {
@'
Describe 'quota' { It 'floods stderr' {
    [IO.File]::WriteAllText($env:SYP154_PESTER_P02A_SELECTED_WITNESS,[DateTimeOffset]::UtcNow.ToString('o'))
    [Console]::Error.Write(('x' * 1100000))
    Start-Sleep 30
} }
'@
                }
                Write-P02AText (Join-Path $fixture.TestRoot 'quota.Tests.ps1') $body
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('quota.Tests.ps1')
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                $finishedAt=[DateTimeOffset]::UtcNow
                $run.TimedOut | Should Be $false
                $run.ExitCode | Should Not Be 0
                $floodStarted=[DateTimeOffset]::Parse([IO.File]::ReadAllText($fixture.SelectedWitness))
                ($finishedAt-$floodStarted).TotalSeconds | Should BeLessThan 25
                Test-Path -LiteralPath $run.SummaryPath | Should Be $false
                $evidence=Get-Content -LiteralPath (@(Get-P02AProcessEvidenceFiles $fixture)[0].FullName) -Raw | ConvertFrom-Json
                $evidence.status | Should Be 'output-quota-exceeded'
                $evidence.outputQuotaExceeded | Should Be $true
                $evidence.cleanup.cleanedUp | Should Be $true
                $evidence.cleanup.CaptureReadersStopped | Should Be $true
                $evidence.cleanup.CaptureResourcesClosed | Should Be $true
                @($evidence.cleanup.RemainingPids).Count | Should Be 0
                $evidence.failureSummary | Should Be 'Pester shard output exceeded the per-stream character limit; raw captures retained.'
                $run.StdoutText.Length | Should BeLessThan 8192
            }
        }

        # Scenario: The supervisor inherits secret-like sentinels and runtime injection variables.
        # Purpose: Verify an actual child receives only the explicit environment allowlist.
        It 'InterT49_excludes_inherited_secrets_and_runtime_injection' {
            $fixture=New-P02AFixture
            $names=@('SYP154_PESTER_SECRET_TOKEN','PRIVATE_SENTINEL','DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','LD_PRELOAD','DYLD_INSERT_LIBRARIES','PSExecutionPolicyPreference')
            # Windows CLI sets this variable to the explicit policy; it must never retain the inherited sentinel.
            $body="Describe 'environment' { It 'does not inherit injection' { foreach (`$name in @('"+($names -join "','")+"')) { if (`$IsWindows -and `$name -ceq 'PSExecutionPolicyPreference') { [Environment]::GetEnvironmentVariable(`$name) | Should Be 'Bypass' } else { [Environment]::GetEnvironmentVariable(`$name) | Should BeNullOrEmpty } } } }"
            Write-P02AText (Join-Path $fixture.TestRoot 'environment.Tests.ps1') $body
            $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('environment.Tests.ps1')
            $config=Get-Content -LiteralPath $invocation.ConfigPath -Raw | ConvertFrom-Json
            $injection=@{}; foreach ($name in $names) { $injection[$name]='p51-sentinel-must-not-reach-child' }
            $config | Add-Member NoteProperty InjectedEnvironment ([pscustomobject]$injection)
            Write-P02AText $invocation.ConfigPath ($config | ConvertTo-Json -Depth 8)
            $run=Invoke-P02AHiddenAdapter $invocation $fixture
            Assert-P02AExpectedWithChildDiagnostics $run.ExitCode 0 $fixture 'Environment allowlist fixture must pass.'
        }

        # Scenario: Test or evidence ancestry uses a native link, or a selected file has a second hard link.
        # Purpose: Exercise P2 on the host and preserve an outside sentinel before any test executes.
        It 'InterT60_rejects_linked_inputs_and_evidence_ancestors' {
            foreach ($mode in @('test-parent','evidence-parent','hard-link')) {
                $fixture=New-P02AFixture; Write-P02ASelectedFixture $fixture
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1')
                $sentinel=Join-Path $fixture.Root 'outside.txt'; Write-P02AText $sentinel 'outside-preserved'
                $config=Get-Content -LiteralPath $invocation.ConfigPath -Raw | ConvertFrom-Json
                if ($mode -eq 'hard-link') {
                    Remove-Item -LiteralPath (Join-Path $fixture.TestRoot 'selected.Tests.ps1')
                    New-Item -ItemType HardLink -Path (Join-Path $fixture.TestRoot 'selected.Tests.ps1') -Target $sentinel | Out-Null
                } else {
                    $link=Join-Path $fixture.Root 'linked'
                    $target=if ($mode -eq 'test-parent') { $fixture.TestRoot } else { $fixture.EvidenceRoot }
                    $kind=if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
                    New-Item -ItemType $kind -Path $link -Target $target | Out-Null
                    if ($mode -eq 'test-parent') { $config.TestRoot=$link }
                    else { $config.EvidenceRoot=$link; $config.SummaryOutputPath=Join-Path $link 'summary.json' }
                    Write-P02AText $invocation.ConfigPath ($config | ConvertTo-Json -Depth 8)
                }
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                Assert-P02ARejectedBeforeChild $run $fixture -ExpectedErrorPattern 'exactly one link|reparse|symlink|errno (20|40|62)'
                [IO.File]::ReadAllText($sentinel) | Should Be 'outside-preserved'
            }
        }

        # Scenario: The Pester root exits after creating a grandchild that retains inherited output handles.
        # Purpose: Require owner cleanup of descendants rather than treating root HasExited as cleanup.
        It 'InterT70_cleans_grandchildren_after_root_exit' {
            $fixture=New-P02AFixture
            $body=@'
Describe 'grandchild' {
    It 'leaves a live descendant for the owner' {
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        foreach ($argument in @('-NoProfile','-NonInteractive','-Command','Start-Sleep 90')) { $start.ArgumentList.Add($argument) }
        $child=[Diagnostics.Process]::Start($start)
        try { [IO.File]::WriteAllText($env:SYP154_PESTER_P02A_SELECTED_WITNESS,([pscustomobject]@{pid=$child.Id;start=$child.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json)) }
        finally { $child.Dispose() }
        1 | Should Be 1
    }
}
'@
            Write-P02AText (Join-Path $fixture.TestRoot 'grandchild.Tests.ps1') $body
            $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('grandchild.Tests.ps1')
            $run=Invoke-P02AHiddenAdapter $invocation $fixture
            Assert-P02AExpectedWithChildDiagnostics $run.ExitCode 0 $fixture 'Owner must stop the grandchild and complete capture.'
            $evidence=Get-Content -LiteralPath (@(Get-P02AProcessEvidenceFiles $fixture)[0].FullName) -Raw | ConvertFrom-Json
            $evidence.cleanup.cleanedUp | Should Be $true
            @($evidence.cleanup.RemainingPids).Count | Should Be 0
            $identity=Get-Content -LiteralPath $fixture.SelectedWitness -Raw | ConvertFrom-Json
            $child=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
            if ($null -ne $child) {
                try { ($child.StartTime.ToUniversalTime().ToString('o') -ceq $identity.start -and -not $child.HasExited) | Should Be $false }
                finally { $child.Dispose() }
            }
            if ($IsMacOS) { @($evidence.cleanup.Limitations) | Should Contain 'macos-process-group-cannot-detect-setsid-escape' }
        }

        if ($IsLinux -or $IsMacOS) {
            # Scenario: A caller requires stronger isolation than the native Unix cooperative boundary.
            # Purpose: Fail before the Pester child starts and retain the actual platform limitation.
            It 'InterT80_refuses_unsatisfied_strong_unix_isolation' {
                $fixture=New-P02AFixture; Write-P02ASelectedFixture $fixture
                $invocation=New-P02AAdapterInvocation $fixture -SelectedNames @('selected.Tests.ps1') -IsolationRequirement strong
                $run=Invoke-P02AHiddenAdapter $invocation $fixture
                $run.ExitCode | Should Not Be 0
                Test-Path -LiteralPath $fixture.SelectedWitness | Should Be $false
                Test-Path -LiteralPath $run.SummaryPath | Should Be $false
                $evidence=Get-Content -LiteralPath (@(Get-P02AProcessEvidenceFiles $fixture)[0].FullName) -Raw | ConvertFrom-Json
                $evidence.processStarted | Should Be $false
                $evidence.error | Should Match 'strong-process-isolation'
            }
        }

        # Scenario: Two passing files are partitioned into two bulk shards and only partition 1 executes.
        # Purpose: Report exactly the paths in completed shards, excluding the unexecuted alpha shard.
        It 'InterT50_partition_summary_lists_only_executed_files' {
            $fixture = New-P02AFixture
            $alphaText = @'
Describe 'partition alpha P02A fixture' {
    It 'writes its witness and passes' {
        [IO.File]::WriteAllText([string]$env:SYP154_PESTER_P02A_ALPHA_WITNESS, 'alpha')
        1 | Should Be 1
    }
}
'@
            $betaText = @'
Describe 'partition beta P02A fixture' {
    It 'writes its witness and passes' {
        [IO.File]::WriteAllText([string]$env:SYP154_PESTER_P02A_BETA_WITNESS, 'beta')
        2 | Should Be 2
    }
}
'@
            Write-P02AText -Path (Join-Path $fixture.TestRoot 'alpha.Tests.ps1') -Text $alphaText
            Write-P02AText -Path (Join-Path $fixture.TestRoot 'beta.Tests.ps1') -Text $betaText
            $invocation = New-P02AAdapterInvocation -Fixture $fixture -IncludeSelection $false -ShardPartitionCount 2 -ShardPartitionIndex 1
            $run = Invoke-P02AHiddenAdapter -Invocation $invocation -Fixture $fixture
            Assert-P02ATrue (-not $run.TimedOut) 'The partitioned adapter must finish within its bounded timeout.'
            Assert-P02AExpectedWithChildDiagnostics -Actual $run.ExitCode -Expected 0 -Fixture $fixture -Message 'The selected partition must exit zero.'
            Assert-P02ATrue (-not (Test-Path -LiteralPath $fixture.AlphaWitness -PathType Leaf)) 'The alpha partition witness must remain absent.'
            Assert-P02ATrue (Test-Path -LiteralPath $fixture.BetaWitness -PathType Leaf) 'The beta partition witness must be written.'
            Assert-P02ATrue (Test-Path -LiteralPath $run.SummaryPath -PathType Leaf) 'A successful partition must write its summary.'

            $summary = Get-Content -LiteralPath $run.SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $betaPath = Join-Path $fixture.TestRoot 'beta.Tests.ps1'
            Assert-P02AEqual $summary.counts.TotalCount 1 'The partition summary must count only its executed test.'
            Assert-P02AEqual $summary.counts.PassedCount 1 'The executed beta test must pass.'
            Assert-P02AEqual $summary.counts.FailedCount 0 'The executed partition must have no failed tests.'
            Assert-P02AEqual @($summary.testFiles).Count 1 'The summary inventory must exclude unexecuted files.'
            Assert-P02AEqual $summary.testFiles[0] $betaPath 'The summary must list only the executed beta path.'
            Assert-P02AEqual @($summary.shards).Count 1 'The selected partition must report its single actual shard.'
            $shardPaths = [string[]]@($summary.shards | ForEach-Object { $_.paths })
            [Array]::Sort($shardPaths, [StringComparer]::Ordinal)
            Assert-P02AEqual ($shardPaths -join '|') ($summary.testFiles -join '|') 'Summary inventory must equal the sorted union of actual shard paths.'
            Assert-P02AEqual $summary.shards[0].name 'bulk-002-beta' 'The executed partition must be the beta shard.'
            Assert-P02AEqual $summary.shards[0].exitCode 0 'The actual beta shard must exit zero.'
            Assert-P02ATrue ($summary.shards[0].cleanedUp -is [bool] -and $summary.shards[0].cleanedUp) 'The actual beta shard must be cleaned up.'
            Assert-P02ATrue ($run.StdoutText -match 'Aggregate - Total: 1 Passed: 1 Failed: 0') 'Aggregate output must report only the executed partition.'
        }
    }
}
