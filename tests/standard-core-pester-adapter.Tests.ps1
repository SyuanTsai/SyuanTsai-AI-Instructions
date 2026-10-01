Describe 'Standard core Pester adapter inventory and execution evidence' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ExecutorPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $script:ReportRunRoot = [Environment]::GetEnvironmentVariable('SYP154_PESTER_P02A_EVIDENCE_ROOT', 'Process')
        if ([string]::IsNullOrWhiteSpace($script:ReportRunRoot)) {
            $script:ReportRunRoot = Join-Path ([IO.Path]::GetTempPath()) ('SYP226-P02A-' + [guid]::NewGuid().ToString('N'))
        }
        $reportRunFull = [IO.Path]::GetFullPath($script:ReportRunRoot)
        if ($reportRunFull.Length -ge 200) { throw 'The P02A report directory is too long for guarded Windows child paths.' }
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
            if ($path.Length -ge 200) { throw 'A P02A fixture directory exceeds the short-path budget.' }
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
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
                $PSVersionTable.PSEdition -cne 'Core' -or
                $PSVersionTable.PSVersion.Major -ne 7) {
                throw 'Pester adapter contract tests require Windows PowerShell 7.'
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
                [int] $ShardPartitionIndex = 0
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
        OuterTimeoutSeconds = [int]60
    }
    if ($config.PSObject.Properties.Name -contains 'SelectedTestFileNames') {
        $parameters.SelectedTestFileNames = [string[]]@($config.SelectedTestFileNames)
    }
    if ($config.PSObject.Properties.Name -contains 'SummaryOutputPath') {
        $parameters.SummaryOutputPath = [string]$config.SummaryOutputPath
    }
    & ([string]$config.ExecutorPath) @parameters
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
            Write-P02AText -Path $wrapperPath -Text $wrapperText
            $config = [ordered]@{
                ExecutorPath = $script:ExecutorPath
                PesterModulePath = $runtime.Manifest
                PesterVersion = $runtime.Version
                TestRoot = $Fixture.TestRoot
                EvidenceRoot = $Fixture.EvidenceRoot
                IsolatedTestFileNames = [string[]]@()
                ShardPartitionCount = [int]$ShardPartitionCount
                ShardPartitionIndex = [int]$ShardPartitionIndex
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
                $rawArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Invocation.WrapperPath, '-ConfigPath', $Invocation.ConfigPath)
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
            $files = @(Get-P02AProcessEvidenceFiles -Fixture $Fixture | Sort-Object Name | Select-Object -First 4)
            if ($files.Count -eq 0) { return '<no child process evidence>' }
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
                        stdoutPath = $stdoutPath
                        stderrPath = $stderrPath
                        stdout = Get-P02AFilePreview -Path $stdoutPath
                        stderr = Get-P02AFilePreview -Path $stderrPath
                    }
                }
                catch {
                    $details += [pscustomobject][ordered]@{ evidencePath = $file.FullName; readError = $_.Exception.Message }
                }
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
                throw "$Message Expected='$expectedText' Actual='$actualText'. Child status, exit, cleanup and raw stream previews: $diagnostics"
            }
        }
        function Assert-P02ARejectedBeforeChild {
            param([Parameter(Mandatory = $true)] $Run, [Parameter(Mandatory = $true)] $Fixture)
            Assert-P02ATrue ($null -ne $Run.ExitCode -and $Run.ExitCode -ne 0) 'Unsafe summary path must return a true nonzero outer exit.'
            $combined = $Run.StdoutText + [Environment]::NewLine + $Run.StderrText
            Assert-P02ATrue ($combined -match 'INVALID\|Pester summary') 'Unsafe summary path must emit the stable ASCII summary error.'
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
    }

    Context 'Path ancestor validation' {
        # Scenario: A real existing test file is reached through a platform-native directory link.
        # Purpose: Reject its reparse parent while accepting an ordinary file and a missing target below a safe directory.
        It 'UnitT30_rejects_reparse_parent_of_existing_file_and_preserves_safe_paths' {
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
    }

    Context 'Actual Pester adapter' {
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
