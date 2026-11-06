[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][ValidateSet('4.10.1')][string] $PesterVersion,
    [ValidateRange(-1, 2147483647)][int] $ExpectedTotalCount = -1,
    [ValidateRange(-1, 2147483647)][int] $ExpectedSkippedCount = -1,
    [AllowEmptyCollection()][string[]] $ExpectedSkippedTests,
    [string[]] $IsolatedTestFileNames = @(
        'standard-validation-runner.Tests.ps1',
        'syp101-production-smoke-contract.Tests.ps1'
    ),
    [ValidateRange(1, 1024)][int] $BulkShardSize = 1,
    [int] $OuterTimeoutSeconds = 1800,
    [ValidateRange(1, 16)][int] $ShardPartitionCount = 1,
    [ValidateRange(0, 15)][int] $ShardPartitionIndex = 0,
    [ValidateRange(0, 1024)][int] $ExpectedFullShardCount = 0,
    [string] $CancellationPath,
    [string] $TestRoot = './tests',
    [string] $EvidenceRoot,
    [AllowEmptyCollection()][string[]] $SelectedTestFileNames = @(),
    [string] $SummaryOutputPath = '',
    [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None,
    [ValidateSet('cooperative','strong')][string] $IsolationRequirement = 'cooperative'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.Major -ne 7) {
    throw [PlatformNotSupportedException]::new('INVALID|Pester shard executor requires PowerShell 7 Core on Windows, Linux or macOS.')
}
if ([Environment]::Version.Major -lt 8) {
    throw [PlatformNotSupportedException]::new('INVALID|The shared platform runtime requires .NET 8 or newer.')
}
if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
    throw 'INVALID|Pester shard executor does not accept a caller-visible CancellationPath; use the supervisor-only cancellation token.'
}
$script:PesterShardChildOutputQuotaCharacters = 1048576
$compareExpectedSkippedTests = $PSBoundParameters.ContainsKey('ExpectedSkippedTests')

function Assert-PesterShardExpectedSkippedTests {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Expected,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $CaseEvidence
    )

    $expectedValues = [Collections.Generic.List[string]]::new()
    $expectedSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identifier in @($Expected)) {
        if ([string]::IsNullOrWhiteSpace($identifier) -or $identifier -notmatch '^[^:/\\]+\.Tests\.ps1::\S.+$') {
            throw "INVALID|Expected skipped test identifier is invalid: '$identifier'."
        }
        if (-not $expectedSeen.Add($identifier)) { throw "INVALID|Expected skipped test inventory contains a duplicate: '$identifier'." }
        $expectedValues.Add($identifier)
    }

    $actualValues = [Collections.Generic.List[string]]::new()
    $actualSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($document in @($CaseEvidence)) {
        foreach ($case in @($document.cases)) {
            if ([string]$case.result -cne 'Skipped') { continue }
            $fileName = [IO.Path]::GetFileName([string]$case.path)
            $testName = [string]$case.name
            if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($testName)) {
                throw 'INVALID|Skipped Pester case evidence must include both path and name.'
            }
            $identifier = "${fileName}::$testName"
            if (-not $actualSeen.Add($identifier)) { throw "INVALID|Pester case evidence contains a duplicate skipped test: '$identifier'." }
            $actualValues.Add($identifier)
        }
    }

    $missing = @($expectedValues | Where-Object { -not $actualSeen.Contains($_) } | Sort-Object)
    $unexpected = @($actualValues | Where-Object { -not $expectedSeen.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        $missingText = if ($missing.Count -eq 0) { '<none>' } else { $missing -join ', ' }
        $unexpectedText = if ($unexpected.Count -eq 0) { '<none>' } else { $unexpected -join ', ' }
        throw "Pester skipped test inventory mismatch. Missing: $missingText. Unexpected: $unexpectedText."
    }
}

function Get-PesterShardCanonicalHash {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) { throw 'INVALID|Runtime closure must be UTF-8 without BOM.' }
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($utf8.GetString($Bytes).Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Import-PesterShardRuntime {
    param([string]$Root, [Collections.Generic.List[IDisposable]]$Guards)
    # Trust anchor belongs to this reviewed entry point, never to a candidate manifest.
    $manifestSha256 = '60fdd12c6c815f6bf79ac9f79e53143a393cdb1a85928f2fcefe9d44ee2e4b4e'
    $manifestPath = Join-Path $Root 'platform-runtime.psd1'
    Assert-PesterShardPathAncestorsNoReparse $manifestPath 'runtime manifest'
    if ((Get-PesterShardCanonicalHash ([IO.File]::ReadAllBytes($manifestPath))) -cne $manifestSha256) { throw 'INVALID|Untrusted platform runtime manifest.' }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $entries = @([pscustomobject]@{Path='platform-runtime.psd1';Sha256=$manifestSha256}) + @($manifest.PrivateData.PlatformRuntime.Inventory)
    $declared = [string[]]@($entries | ForEach-Object Path)
    foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $Root 'platform') -Recurse -Force)) {
        Assert-PesterShardPathAncestorsNoReparse $item.FullName 'runtime closure'
    }
    $actual = [string[]]@(Get-ChildItem -LiteralPath (Join-Path $Root 'platform') -Recurse -File -Force | ForEach-Object { 'platform/' + $_.FullName.Substring((Join-Path $Root 'platform').Length+1).Replace('\','/') })
    if ((@($actual | Sort-Object) -join '|') -cne (@($declared | Where-Object { $_.StartsWith('platform/') } | Sort-Object) -join '|')) { throw 'INVALID|Platform closure inventory differs.' }
    foreach ($entry in $entries) {
        $filePath = Join-Path $Root $entry.Path
        Assert-PesterShardPathAncestorsNoReparse $filePath 'runtime closure'
        if ((Get-PesterShardCanonicalHash ([IO.File]::ReadAllBytes($filePath))) -cne $entry.Sha256) { throw "INVALID|Platform closure hash mismatch: $($entry.Path)" }
    }
    # Compile only the now verified native closure. P2 protects and rehashes every
    # file before importing executable PowerShell; no ambient module lookup.
    if ($null -ne ('SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative' -as [type])) {
        throw [IO.InvalidDataException]::new('INVALID|Preloaded native runtime has no entry-point provenance; use a fresh shard supervisor.')
    }
    # A1 boundary: Add-Type reopens these verified paths. A same-account concurrent
    # malicious writer can replace source between hashing and this read; external
    # isolation is required. The later P2 recheck does not close that interval.
    Add-Type -LiteralPath @($entries | Where-Object { $_.Path.EndsWith('.cs') } | ForEach-Object { Join-Path $Root $_.Path }) -ErrorAction Stop
    $runtimeRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($manifestPath))
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild]::Seal(
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild]::ComputeSourceFingerprint($runtimeRoot))
    $platform = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    foreach ($entry in $entries) {
        $filePath = [IO.Path]::GetFullPath((Join-Path $Root $entry.Path))
        $parentPath = [IO.Path]::GetDirectoryName($filePath)
        if ($platform -ceq 'windows') {
            $parent = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($parentPath)
            $Guards.Add($parent)
            $file = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($parent,[IO.Path]::GetFileName($filePath),'Read','OpenExisting')
        } else {
            $parent = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectory('/', $parentPath.TrimStart('/'), $false)
            $Guards.Add($parent)
            $file = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($parent,[IO.Path]::GetFileName($filePath),'Read','OpenExisting')
        }
        $Guards.Add($file)
        if ((Get-PesterShardCanonicalHash ($file.ReadAllBytes(16777216))) -cne $entry.Sha256) { throw 'INVALID|Platform closure changed before import.' }
    }
    Import-Module -Name $manifestPath -Force -Global -ErrorAction Stop
}

function Resolve-PesterShardFileSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $provider = $null; $drive = $null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if ($provider.Name -cne 'FileSystem') { throw 'INVALID|Pester shard inputs require filesystem paths.' }
    return $full
}

function Open-PesterShardDirectory {
    param([string]$Path,[switch]$Create)
    $full = (Resolve-PesterShardFileSystemPath $Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $anchor = [IO.Path]::GetPathRoot($full)
    Open-PlatformDirectory -Root $anchor -RelativePath $full.Substring($anchor.Length) -CreatePrivate:$Create
}

function Open-PesterShardInput {
    param([string]$Path, [Collections.Generic.List[IDisposable]]$Guards)
    $Path = Resolve-PesterShardFileSystemPath $Path
    $parent = Open-PesterShardDirectory ([IO.Path]::GetDirectoryName($Path))
    $Guards.Add($parent)
    $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($Path)) -Access Read -CreateMode OpenExisting
    $Guards.Add($file)
    Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink | Out-Null
    return $file
}

function Assert-PesterShardModuleManifest {
    param([string]$Path,[string]$Version)
    $Path = Resolve-PesterShardFileSystemPath $Path
    $manifest = Import-PowerShellDataFile -LiteralPath $Path
    if ([string]$manifest.ModuleVersion -cne $Version) { throw 'INVALID|Pester module version mismatch.' }
    if (@($manifest['RequiredModules']).Count -gt 0 -and $null -ne $manifest['RequiredModules']) { throw 'INVALID|Ambient Pester module dependencies are not allowed.' }
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $entryPoints = @($manifest['RootModule'],$manifest['ModuleToProcess']) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    if (@($entryPoints).Count -ne 1) { throw 'INVALID|Pester manifest must declare one local entry point.' }
    foreach ($field in @('RootModule','ModuleToProcess','NestedModules','RequiredAssemblies','ScriptsToProcess','TypesToProcess','FormatsToProcess')) {
        foreach ($relative in @($manifest[$field])) {
            if ($null -eq $relative -or $relative -ceq '') { continue }
            if ($relative -isnot [string] -or [IO.Path]::IsPathRooted($relative) -or $relative -match '[*?]') { throw 'INVALID|Pester dependencies must be explicit local files.' }
            $full = [IO.Path]::GetFullPath((Join-Path $root $relative.Replace('\',[IO.Path]::DirectorySeparatorChar)))
            if (-not $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison) -or -not [IO.File]::Exists($full)) { throw 'INVALID|Pester dependency escapes or is missing from the protected closure.' }
        }
    }
    return $manifest
}

function Write-PesterShardJson {
    param([string]$Path,$Value)
    Write-PesterShardBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 16 -Compress)))
}

function Write-PesterShardBytes {
    param([string]$Path,[byte[]]$Bytes)
    $Path = Resolve-PesterShardFileSystemPath $Path
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [IO.Path]::GetFullPath($Path).Length -ge 240) {
        throw 'INVALID|Windows shard artifact paths must be fewer than 240 characters.'
    }
    $parent = Open-PesterShardDirectory ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    try {
        $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($Path)) -Access ReadWrite -CreateMode CreateNew
        try { $file.WriteNewBytes($Bytes) }
        finally { $file.Dispose() }
    } finally { $parent.Dispose() }
    # Partial files are retained on failure. P7 publication/removal is not used.
}

function Read-PesterShardJson {
    param([string]$Path)
    $guards = [Collections.Generic.List[IDisposable]]::new()
    try { $file = Open-PesterShardInput $Path $guards; return [Text.UTF8Encoding]::new($false,$true).GetString($file.ReadAllBytes(1048576)) | ConvertFrom-Json }
    finally { for ($i=$guards.Count-1;$i -ge 0;$i--) { $guards[$i].Dispose() } }
}

function Get-PesterShardChildEnvironment {
    # Explicit allowlist: no prefix wildcards, runtime injection, or inherited PSModulePath.
    # Cmdlet output (Join-Path/ConvertTo-Json) can retain a PSObject wrapper in a
    # hashtable. P3's native IDictionary contract requires actual CLR strings,
    # including values the supervisor adds after this function returns.
    $comparer = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $values = [Collections.Generic.Dictionary[string,string]]::new($comparer)
    foreach ($name in @('PATH','PATHEXT','COMSPEC','SYSTEMROOT','WINDIR','TEMP','TMP','TMPDIR','HOME','USERPROFILE','APPDATA','LOCALAPPDATA','LANG','LC_ALL','NUMBER_OF_PROCESSORS',
        'SYP154_PESTER_P02A_SELECTED_WITNESS','SYP154_PESTER_P02A_UNSELECTED_WITNESS','SYP154_PESTER_P02A_ALPHA_WITNESS','SYP154_PESTER_P02A_BETA_WITNESS','SYP154_PESTER_P02A_RUNTIME_PATH','SYP154_PESTER_P02A_EVIDENCE_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name,'Process')
        if ($null -ne $value) { $values[$name] = $value }
    }
    $values['PSModulePath'] = Join-Path $PSHOME 'Modules'
    return $values
}

function ConvertTo-PesterShardProcessState {
    param($Cleanup,[AllowNull()]$ExitCode,[string]$TerminationReason,[bool]$OutputLimitExceeded,[bool]$NaturalExit,[bool]$SupervisorCancelled)
    if ($null -eq $Cleanup -or -not $Cleanup.CleanedUp -or -not $Cleanup.CaptureReadersStopped -or -not $Cleanup.CaptureResourcesClosed -or
        -not [string]::IsNullOrEmpty($Cleanup.Uncertainty) -or @($Cleanup.RemainingPids).Count -ne 0) { return 'cleanup-failed' }
    if ($OutputLimitExceeded -or $TerminationReason -ceq 'output-limit') { return 'output-quota-exceeded' }
    if ($TerminationReason -ceq 'deadline') { return 'timed-out' }
    if ($SupervisorCancelled -or ($TerminationReason -ceq 'cancelled' -and -not $NaturalExit)) { return 'cancelled' }
    if ($TerminationReason -cin @('capture-failure','supervisor-failure')) { return $TerminationReason }
    if ($TerminationReason -cnotin @('','cancelled')) { return 'supervisor-failure' }
    if (-not $NaturalExit -or $null -eq $ExitCode) { return 'failed' }
    if ($ExitCode -ne 0) { return 'failed' }
    return 'completed'
}

function Get-PesterShardStartupCleanupEvidence {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    $cleanup = $null
    $cleanupFailed = $false
    $cause = $Exception
    while ($null -ne $cause) {
        if ($cause.Data.Contains('StartupCleanupReceipt')) {
            $cleanup = $cause.Data['StartupCleanupReceipt']
            if ($null -eq $cleanup -or -not $cleanup.CleanedUp) { $cleanupFailed = $true }
        }
        foreach ($key in @('StartupCaptureCleanupUncertainty','StartupCleanupUncertainty')) {
            if ($cause.Data.Contains($key)) { $cleanupFailed = $true }
        }
        foreach ($key in @('StartupRootExitConfirmed','StartupCleanupConfirmed')) {
            if ($cause.Data.Contains($key) -and $cause.Data[$key] -ne $true) { $cleanupFailed = $true }
        }
        $cause = $cause.InnerException
    }
    [pscustomobject][ordered]@{ cleanup=$cleanup; cleanupFailed=$cleanupFailed }
}

function Format-PesterShardException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    $parts = [Collections.Generic.List[string]]::new()
    $cause = $Exception
    while ($null -ne $cause -and $parts.Count -lt 8) {
        $message = [string]$cause.Message
        if ($message.Length -gt 8192) { $message = $message.Substring(0,8192) }
        $message = ConvertTo-PesterShardSanitizedDiagnosticText $message
        $part = $cause.GetType().FullName + ': ' + $message
        # Reserve room for inner causes even if an outer exception repeats a large message.
        if ($part.Length -gt 480) { $part = $part.Substring(0,480) + '...' }
        $parts.Add($part)
        $cause = $cause.InnerException
    }
    $text = $parts.ToArray() -join ' -> '
    return $text.Substring(0,[Math]::Min(4096,$text.Length))
}

function Invoke-PesterShardProcess {
    [CmdletBinding()]
    param([string[]]$Paths,[string]$ModulePath,[string]$Version,[string]$ChildPowerShell,[string]$EncodedChildScript,[string]$ChildScriptPath,
        [string]$ResultPath,[string]$ProcessEvidencePath,[string]$StdoutPath,[string]$StderrPath,[int]$TimeoutSeconds,
        [string]$WorkingDirectory,[Collections.IDictionary]$Environment,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [ValidateSet('cooperative','strong')][string]$IsolationRequirement = 'cooperative')
    $guards = [Collections.Generic.List[IDisposable]]::new()
    $lease = $null; $cleanup = $null; $status = 'not-started'; $exitCode = $null
    $naturalExit = $false; $cancelled = $false; $quota = $false; $reason = ''; $failure = ''; $processId = $null; $identity = $null
    $phase = 'validate-inputs'
    try {
        if ($TimeoutSeconds -le 0) { throw 'INVALID|Shard deadline must be positive.' }
        foreach ($path in @($Paths)+@($ModulePath,$ChildPowerShell,$ResultPath,$ProcessEvidencePath,$StdoutPath,$StderrPath,$WorkingDirectory)) {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $path.Length -ge 240) { throw 'INVALID|Windows shard paths must be fewer than 240 characters.' }
        }
        $phase = 'open-working-directory'
        $directory = Open-PesterShardDirectory $WorkingDirectory; $guards.Add($directory)
        $phase = 'open-executable'
        $executable = Open-PesterShardInput $ChildPowerShell $guards
        $phase = 'open-test-and-module-inputs'
        foreach ($path in @($Paths)+@($ModulePath)) { Open-PesterShardInput $path $guards | Out-Null }
        $arguments = @('-NoLogo','-NoProfile','-NonInteractive')
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $arguments += @('-ExecutionPolicy','Bypass')
        }
        if (-not [string]::IsNullOrEmpty($ChildScriptPath)) {
            $phase = 'open-child-script'
            Open-PesterShardInput $ChildScriptPath $guards | Out-Null
            $arguments += @('-File',$ChildScriptPath)
        } else { $arguments += @('-EncodedCommand',$EncodedChildScript) }
        if ($CancellationToken.IsCancellationRequested) { $cancelled=$true; $status='cancelled' }
        else {
            $phase = 'start-owned-process'
            $lease = Start-PlatformOwnedProcess -ExecutableLease $executable -ArgumentList $arguments `
                -Environment $Environment -WorkingDirectoryLease $directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)) `
                -IsolationRequirement $IsolationRequirement -StdoutPath $StdoutPath -StderrPath $StderrPath -OutputLimitCharacters $script:PesterShardChildOutputQuotaCharacters
            $processId=$lease.Pid; $identity=$lease.StartIdentity
            while (-not $lease.HasExited -and $null -eq $lease.Cleanup) {
                if ($CancellationToken.IsCancellationRequested) { $cancelled=$true; break }
                [void]$lease.WaitForExit([TimeSpan]::FromMilliseconds(50))
            }
            $naturalExit = $lease.HasExited -and [string]::IsNullOrEmpty($lease.TerminationReason) -and -not $cancelled
        }
    } catch {
        $status='start-failed'; $failure=$phase + ': ' + (Format-PesterShardException $_.Exception)
        $startupEvidence=Get-PesterShardStartupCleanupEvidence -Exception $_.Exception
        $cleanup=$startupEvidence.cleanup
        if ($startupEvidence.cleanupFailed) { $status='cleanup-failed' }
    } finally {
        if ($null -ne $lease) {
            try {
                $cleanup=Stop-PlatformOwnedProcess -Lease $lease -ExpectedStartIdentity $identity -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(5))
                $exitCode=$lease.ExitCode; $quota=$lease.OutputLimitExceeded; $reason=[string]$lease.TerminationReason
                $status=ConvertTo-PesterShardProcessState $cleanup $exitCode $reason $quota $naturalExit $cancelled
            } catch { $status='cleanup-failed'; $failure += ' stop-owned-process: ' + (Format-PesterShardException $_.Exception) }
            try { $lease.Dispose() } catch { $status='cleanup-failed'; $failure += ' dispose-process-lease: ' + (Format-PesterShardException $_.Exception) }
        }
        for ($i=$guards.Count-1;$i -ge 0;$i--) {
            try { $guards[$i].Dispose() }
            catch { $status='cleanup-failed'; $failure += ' dispose-input-lease: ' + (Format-PesterShardException $_.Exception) }
        }
        if ($status -ceq 'cleanup-failed' -and [string]::IsNullOrWhiteSpace($failure)) {
            $failure = 'Process cleanup unconfirmed: ' + (ConvertTo-PesterShardSanitizedDiagnosticText ([string]$cleanup.Uncertainty))
            $failure += '; cleanedUp=' + $cleanup.CleanedUp + '; captureReadersStopped=' + $cleanup.CaptureReadersStopped + '; captureResourcesClosed=' + $cleanup.CaptureResourcesClosed
        }
        if ($failure.Length -gt 4096) { $failure=$failure.Substring(0,4096) }
        $diagnostic = [ordered]@{
            schemaVersion=1; status=$status; exitCode=$exitCode; resultPath=$ResultPath; stdoutPath=$StdoutPath; stderrPath=$StderrPath
            processStarted=($null -ne $processId); rootProcessId=$processId; startIdentity=$identity
            outputQuotaExceeded=$quota; terminationReason=$reason; cleanup=$cleanup
            failureSummary=Get-PesterShardFailureSummary -Paths @($StderrPath,$StdoutPath) -OutputQuotaExceeded:$quota; error=$failure
            platformReceipt=$script:PesterShardCapabilities; artifactsRetained=$true
            caseDiagnosticsPath=($ResultPath+'.cases.json'); childScriptPath=$ChildScriptPath
        }
        Write-PesterShardJson $ProcessEvidencePath $diagnostic
    }
    if ($quota) {
        # Report promptly after the owner's cleanup attempt. The raw captures
        # remain available without sanitizing/replaying a full quota of output.
        Write-Host $diagnostic.failureSummary
    } else {
        foreach ($path in @($StdoutPath,$StderrPath)) {
            $text=Read-PesterShardOutputPrefix $path $script:PesterShardChildOutputQuotaCharacters
            if (-not [string]::IsNullOrEmpty($text)) { Write-Host (ConvertTo-PesterShardSanitizedDiagnosticText (ConvertFrom-PesterShardCliXmlDiagnostic $text)) }
        }
    }
    if ($status -cnotin @('completed','failed') -or $null -eq $cleanup -or -not $cleanup.CleanedUp) { throw "Pester shard process ended with status '$status'; evidence='$ProcessEvidencePath'. $failure" }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) { throw "Pester shard exited without a result file; evidence='$ProcessEvidencePath'." }
    [pscustomobject]@{ resultPath=$ResultPath; processEvidencePath=$ProcessEvidencePath; status=$status; exitCode=$exitCode; cleanedUp=$cleanup.CleanedUp; outputQuotaExceeded=$quota }
}

function Test-PesterShardReparseItem {
    param([Parameter(Mandatory = $true)] $Item)

    $isReparse = (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    $isHardLink = ($Item.PSObject.Properties.Name -contains 'LinkType' -and
        [string]$Item.LinkType -match '(?i)^HardLink$')
    # Hard links are not reparse traversal. The P2 file lease separately rejects
    # multiple links before an executable, module, test or evidence file is used.
    if (-not $isReparse -and -not $isHardLink -and $Item.PSObject.Properties.Name -contains 'LinkType' -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.LinkType) -and
        [string]$Item.LinkType -notmatch '(?i)^HardLink$') {
        $isReparse = $true
    }
    if (-not $isReparse -and -not $isHardLink -and $Item.PSObject.Properties.Name -contains 'Target' -and
        $null -ne $Item.Target -and -not [string]::IsNullOrWhiteSpace(([string](@($Item.Target) -join '|')))) {
        $isReparse = $true
    }
    return [bool]$isReparse
}

function Assert-PesterShardPathAncestorsNoReparse {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = Resolve-PesterShardFileSystemPath $Path
    $existingPath = $fullPath
    while (-not (Test-Path -LiteralPath $existingPath)) {
        $parent = [IO.Path]::GetDirectoryName($existingPath)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $existingPath) { break }
        $existingPath = $parent
    }
    if (-not (Test-Path -LiteralPath $existingPath)) {
        throw "Preflight $Context has no existing ancestor: $fullPath"
    }

    $item = Get-Item -Force -LiteralPath $existingPath -ErrorAction Stop
    while ($null -ne $item) {
        if (Test-PesterShardReparseItem -Item $item) {
            throw "Preflight $Context contains a symlinked or reparse-point ancestor: $($item.FullName)"
        }
        $parent = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
        if ($null -eq $parent -or $parent.FullName -ceq $item.FullName) { break }
        $item = $parent
    }
}

function Get-PesterShardFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

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

function Read-PesterShardOutputPrefix {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $MaxChars = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    $builder = New-Object System.Text.StringBuilder
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::UTF8), $true
        $buffer = New-Object char[] 4096
        $remaining = [Math]::Max(0, $MaxChars)
        while ($remaining -gt 0) {
            $read = $reader.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { break }
            [void]$builder.Append($buffer, 0, $read)
            $remaining -= $read
        }
        return $builder.ToString()
    }
    catch {
        return "<output-read-error: $($_.Exception.Message)>"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-PesterShardOutputTail {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $MaxBytes = 65536,
        [int] $MaxChars = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    if ($MaxBytes -lt 1 -or $MaxChars -lt 1) { return '' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $start = [Math]::Max([int64]0, $stream.Length - [int64]$MaxBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $requested = [int]($stream.Length - $start)
        $buffer = New-Object byte[] $requested
        $total = 0
        while ($total -lt $requested) {
            $read = $stream.Read($buffer, $total, $requested - $total)
            if ($read -le 0) { break }
            $total += $read
        }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $total)
        if ($start -gt 0) {
            $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
            if ($firstNewline -ge 0) { $text = $text.Substring($firstNewline + 1) }
        }
        if ($text.Length -gt $MaxChars) { $text = $text.Substring($text.Length - $MaxChars) }
        return $text
    }
    catch {
        return "<output-tail-read-error: $($_.Exception.Message)>"
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-PesterShardCliXmlDiagnostic {
    param([Parameter()][AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.TrimStart()
    $marker = '#< CLIXML'
    if (-not $trimmed.StartsWith($marker, [StringComparison]::Ordinal)) { return $Text }
    $payload = $trimmed.Substring($marker.Length).Trim()
    if ([string]::IsNullOrWhiteSpace($payload)) { return $Text }

    $stringReader = $null
    $xmlReader = $null
    try {
        $document = New-Object Xml.XmlDocument
        $document.PreserveWhitespace = $false
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $maxCharactersInDocument = 1048577
        $quotaVariable = Get-Variable -Name PesterShardChildOutputQuotaCharacters -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $quotaVariable) {
            $configuredQuota = [int64]$quotaVariable.Value
            if ($configuredQuota -gt 0 -and $configuredQuota -lt [int64]::MaxValue) {
                $maxCharactersInDocument = $configuredQuota + 1
            }
        }
        $settings.MaxCharactersInDocument = $maxCharactersInDocument
        $stringReader = New-Object IO.StringReader($payload)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $document.Load($xmlReader)

        $diagnosticLines = New-Object 'System.Collections.Generic.List[string]'
        $diagnosticLineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $sawStreamNode = $false
        $sawNonProgressStream = $false
        foreach ($streamNode in @($document.DocumentElement.ChildNodes)) {
            if ($null -eq $streamNode.Attributes) { continue }
            $streamAttribute = $streamNode.Attributes.GetNamedItem('S')
            if ($null -eq $streamAttribute) { continue }
            $sawStreamNode = $true
            $streamName = [string]$streamAttribute.Value
            if ([string]::Equals($streamName, 'progress', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $sawNonProgressStream = $true
            $value = ''
            foreach ($childNode in @($streamNode.ChildNodes)) {
                if ([string]$childNode.LocalName -ceq 'ToString') {
                    $value = [string]$childNode.InnerText
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($value) -and [string]$streamNode.LocalName -ceq 'S') {
                $value = [string]$streamNode.InnerText
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                foreach ($messageNode in @($streamNode.SelectNodes('.//*[local-name()="S"]'))) {
                    if ($null -eq $messageNode.Attributes) { continue }
                    $nameAttribute = $messageNode.Attributes.GetNamedItem('N')
                    if ($null -eq $nameAttribute -or [string]$nameAttribute.Value -notmatch '(?i)message|exception|error') { continue }
                    $value = [string]$messageNode.InnerText
                    if (-not [string]::IsNullOrWhiteSpace($value)) { break }
                }
            }
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $value = [System.Xml.XmlConvert]::DecodeName($value)
            foreach ($line in @($value -split "`r?`n")) {
                $line = ([string]$line).TrimEnd()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($diagnosticLineSet.Add($line)) { [void]$diagnosticLines.Add($line) }
            }
        }
        if ($diagnosticLines.Count -gt 0) { return ($diagnosticLines.ToArray() -join [Environment]::NewLine) }
        if ($sawStreamNode -and -not $sawNonProgressStream) { return '' }
        return $Text
    }
    catch {
        # Preserve unparseable or bounded/truncated CLIXML verbatim. Losing a
        # possible error record is worse than returning serialization markup.
        return $Text
    }
    finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
}

# Scan left-to-right so quota-sized control strings cannot trigger regex
# backtracking. Unterminated strings consume the remainder fail closed.
# Cursor controls that can reinterpret emitted text taint the whole line.
# Validated SGR color state is retained so equal foreground/background spans
# also taint their hidden glyphs; structural newlines remain intact.
function Remove-PesterShardTerminalControlSequences {
  param([Parameter()][AllowEmptyString()][string] $Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $x = $Text.ToCharArray()
  $l = $x.Length
  $o = New-Object Text.StringBuilder
  [void]$o.EnsureCapacity($l)
  $t = [char]0xE000
  $h = @('', '', $false)
  $e = { param($v)
    if($v -lt 16){return "i:$v"}
    if($v -lt 232){$v-=16;$d=0,95,135,175,215,255;return 'r:{0}:{1}:{2}' -f $d[[math]::Floor($v/36)],$d[[math]::Floor(($v%36)/6)],$d[$v%6]}
    $v=8+10*($v-232);'r:{0}:{0}:{0}' -f $v }
  $g = {
    param($p)
    $a = $p.Split(';')
    for ($i = 0; $i -lt $a.Count; $i++) {
      $n = 0; $q = $null; $z = 2
      if ($a[$i].Contains(':')) {
        $b = $a[$i].Split(':')
        if (-not [int]::TryParse($b[0], [ref]$n) -or $n -notin 38, 48, 58 -or
          (($b.Count -ne 3 -or $b[1] -cne '5') -and ($b.Count -notin 5, 6 -or $b[1] -cne '2'))) { return $false }
        $q = if ($b[1] -ceq '5') { 'i' } else { 'r' }
        for ($j = 2; $j -lt $b.Count; $j++) {
          if ($j -eq 2 -and $b.Count -eq 6 -and -not $b[$j]) { continue }
          $v = 0
          if (-not [int]::TryParse($b[$j], [ref]$v) -or $v -gt 255) { return $false }
          if ($j -eq 2 -and $b.Count -eq 6) { if ($v) { $q = "r@$v" }; continue }
          $q += ":$v"
        }
        if($b[1] -ceq '5'){$q=&$e $v}
        $z = if ($n -eq 38) { 0 } elseif ($n -eq 48) { 1 } else { 2 }
      }
      else {
        if ($a[$i] -and -not [int]::TryParse($a[$i], [ref]$n)) { return $false }
        if ($n -eq 8) { $h[2] = $true }
        elseif ($n -eq 28) { $h[2] = $false }
        if ($n -in 38, 48, 58) {
          $i++
          if ($i -ge $a.Count) { return $false }
          $c = if ($a[$i] -ceq '5') { 1 } elseif ($a[$i] -ceq '2') { 3 } else { return $false }
          $q = if ($c -eq 1) { 'i' } else { 'r' }
          for ($j = 0; $j -lt $c; $j++) {
            $i++; $v = 0
            if ($i -ge $a.Count -or -not [int]::TryParse($a[$i], [ref]$v) -or $v -gt 255) { return $false }
            $q += ":$v"
          }
          if($c -eq 1){$q=&$e $v}
          $z = if ($n -eq 38) { 0 } elseif ($n -eq 48) { 1 } else { 2 }
        }
        elseif ($n -eq 0) { $h[0] = $h[1] = ''; $h[2] = $false }
        elseif ($n -eq 39 -or $n -eq 49) { $h[[int]($n -eq 49)] = '' }
        else {
          $d = $n % 10
          if ($d -le 7 -and (($n -ge 30 -and $n -le 47) -or ($n -ge 90 -and $n -le 107))) {
            $z = [int](($n -ge 40 -and $n -le 47) -or $n -ge 100)
            $q = 'i:' + ($d + $(if ($n -ge 90) { 8 } else { 0 }))
          }
        }
      }
      if ($z -lt 2) { $h[$z] = $q }
    }
    $true
  }
  $k = 0
  while ($k -lt $l) {
    $c = [int]$x[$k]
    if ($c -eq 0x08 -or $c -eq 0x0B -or $c -eq 0x0C -or $c -eq 0x0E -or $c -eq 0x0F -or
      ($c -eq 0x0D -and (($k + 1) -ge $l -or [int]$x[$k + 1] -ne 0x0A))) {
      [void]$o.Append($t); $k++; continue
    }
    if ($c -eq 0x1B) {
      $k++
      if ($k -ge $l) { continue }
      $n = [int]$x[$k]
      if ($n -eq 0x5D -or $n -eq 0x50 -or $n -eq 0x58 -or $n -eq 0x5E -or $n -eq 0x5F) {
        $k++
        while ($k -lt $l) {
          $s = [int]$x[$k]
          if ($s -eq 0x07 -or $s -eq 0x9C) { $k++; break }
          if ($s -eq 0x1B -and ($k + 1) -lt $l -and [int]$x[$k + 1] -eq 0x5C) { $k += 2; break }
          $k++
        }
        continue
      }
      if ($n -eq 0x5B) {
        $k++; $p = $k
        while ($k -lt $l -and [int]$x[$k] -ge 0x30 -and [int]$x[$k] -le 0x3F) { $k++ }
        $r = $Text.Substring($p, $k - $p); $m = $k
        while ($k -lt $l -and [int]$x[$k] -ge 0x20 -and [int]$x[$k] -le 0x2F) { $k++ }
        if ($k -lt $l -and [int]$x[$k] -ge 0x40 -and [int]$x[$k] -le 0x7E) {
          $f = [int]$x[$k]; $k++
          $y = ($f -eq 0x6D -and $k - 1 -eq $m -and (& $g $r))
          if (-not $y) { [void]$o.Append($t) }
          continue
        }
        [void]$o.Append($t)
        if ($k -lt $l -and ([int]$x[$k] -eq 0x0D -or [int]$x[$k] -eq 0x0A)) {
          if ([int]$x[$k] -eq 0x0D -and ($k + 1) -lt $l -and [int]$x[$k + 1] -eq 0x0A) { $k++ }
          $k++
        }
        continue
      }
      while ($k -lt $l -and [int]$x[$k] -ge 0x20 -and [int]$x[$k] -le 0x2F) { $k++ }
      if ($k -lt $l -and [int]$x[$k] -ge 0x30 -and [int]$x[$k] -le 0x7E) {
        $k++; [void]$o.Append($t); continue
      }
      [void]$o.Append($t)
      if ($k -lt $l -and ([int]$x[$k] -eq 0x0D -or [int]$x[$k] -eq 0x0A)) {
        if ([int]$x[$k] -eq 0x0D -and ($k + 1) -lt $l -and [int]$x[$k + 1] -eq 0x0A) { $k++ }
        $k++
      }
      continue
    }
    if ($c -eq 0x90 -or $c -eq 0x98 -or $c -eq 0x9D -or $c -eq 0x9E -or $c -eq 0x9F) {
      $k++
      while ($k -lt $l) {
        $s = [int]$x[$k]
        if ($s -eq 0x07 -or $s -eq 0x9C) { $k++; break }
        if ($s -eq 0x1B -and ($k + 1) -lt $l -and [int]$x[$k + 1] -eq 0x5C) { $k += 2; break }
        $k++
      }
      continue
    }
    if ($c -eq 0x9B) {
      $k++; $p = $k
      while ($k -lt $l -and [int]$x[$k] -ge 0x30 -and [int]$x[$k] -le 0x3F) { $k++ }
      $r = $Text.Substring($p, $k - $p); $m = $k
      while ($k -lt $l -and [int]$x[$k] -ge 0x20 -and [int]$x[$k] -le 0x2F) { $k++ }
      if ($k -lt $l -and [int]$x[$k] -ge 0x40 -and [int]$x[$k] -le 0x7E) {
        $f = [int]$x[$k]; $k++
        $y = ($f -eq 0x6D -and $k - 1 -eq $m -and (& $g $r))
        if (-not $y) { [void]$o.Append($t) }
        continue
      }
      [void]$o.Append($t)
      if ($k -lt $l -and ([int]$x[$k] -eq 0x0D -or [int]$x[$k] -eq 0x0A)) {
        if ([int]$x[$k] -eq 0x0D -and ($k + 1) -lt $l -and [int]$x[$k + 1] -eq 0x0A) { $k++ }
        $k++
      }
      continue
    }
    if ($c -ge 0x80 -and $c -le 0x9F) { [void]$o.Append($t); $k++; continue }
    if (($c -ge 0x00 -and $c -le 0x08) -or $c -eq 0x0B -or $c -eq 0x0C -or ($c -ge 0x0E -and $c -le 0x1F) -or $c -eq 0x7F) { $k++; continue }
    $w=1;$u=$c;$uc=[char]::GetUnicodeCategory($x[$k])
    if(($k+1) -lt $l -and [char]::IsSurrogatePair($x[$k],$x[$k+1])){$w=2;$u=[char]::ConvertToUtf32($x[$k],$x[$k+1]);$uc=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text,$k)}
    if($uc-eq'Format'-or$u-in 0x034F,0x115F,0x1160,0x17B4,0x17B5,0x180B,0x180C,0x180D,0x180F,0x2028,0x2029,0x2065,0x3164,0xFFA0 -or
      ($u-band 0xFFF0)-eq 0xFE00 -or($u-0xFFF0)-in 0..8 -or($u-shr 12)-eq 0xE0) {
      [void]$o.Append($t);$k+=$w;continue
    }
    [void]$o.Append($(if ($c -in 10, 13 -or (-not $h[2] -and (-not $h[0] -or $h[0] -cne $h[1]))) { $x[$k] } else { $t }))
    $k++
  }
  $o.ToString()
}

function ConvertTo-PesterShardSanitizedDiagnosticText {
    param([Parameter()][AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $normalizedText = Remove-PesterShardTerminalControlSequences -Text $Text
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $redactSensitiveContinuation = $false
    foreach ($rawLine in @($normalizedText -split "`r?`n")) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($redactSensitiveContinuation) {
            $line = if ($line -match '(?i)^\s*\[-\]') {
                '[-] [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*Expected') {
                'Expected: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*But was') {
                'But was: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*Exception:') {
                'Exception: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)\bat\s+.+\.ps1:\d+') {
                'at [redacted sensitive diagnostic continuation]'
            }
            else {
                '[redacted sensitive diagnostic continuation]'
            }
        }
        else {
            if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match '(?i)(secret|password|token|authorization|credentials?|(api|private|access)[-_ ]?key|bearer|cookie|session(_?id)?)["'']?\s*[:=]') {
                $redactSensitiveContinuation = $true
                $line = '[redacted sensitive diagnostic line]'
            }
        }
        [void]$lines.Add($line)
    }
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-PesterShardFailureSummary {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [int] $MaxLines = 8,
        [int] $MaxLineLength = 512,
        [int] $MaxTotalLength = 4096,
        [switch] $OutputQuotaExceeded
    )

    if ($OutputQuotaExceeded) {
        # Quota is supervisor-owned state. Preserve capture files as evidence;
        # summarizing their contents cannot change the already-failed outcome.
        return 'Pester shard output exceeded the per-stream character limit; raw captures retained.'
    }

    $deferredCliXml = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        $rawText = Read-PesterShardOutputPrefix `
            -Path $path `
            -MaxChars ($script:PesterShardChildOutputQuotaCharacters + 1)
        $text = ConvertFrom-PesterShardCliXmlDiagnostic -Text $rawText
        if (-not [string]::IsNullOrWhiteSpace($rawText) -and
            $text -ceq $rawText -and
            $rawText.TrimStart().StartsWith('#< CLIXML', [StringComparison]::Ordinal)) {
            if (-not $deferredCliXml.Contains($rawText)) { [void]$deferredCliXml.Add($rawText) }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $sanitizedText = ConvertTo-PesterShardSanitizedDiagnosticText -Text $text
        if ([string]::IsNullOrWhiteSpace($sanitizedText)) { continue }
        $tailStart = [Math]::Max(0, $sanitizedText.Length - 65536)
        $tailWindow = $sanitizedText.Substring($tailStart)
        $prefixWindow = $sanitizedText.Substring(0, [Math]::Min(32768, $sanitizedText.Length))
        $diagnosticWindows = New-Object 'System.Collections.Generic.List[string]'
        [void]$diagnosticWindows.Add($tailWindow)
        if ($prefixWindow -cne $tailWindow) { [void]$diagnosticWindows.Add($prefixWindow) }
        foreach ($window in $diagnosticWindows) {
            $lines = @($window -split "`r?`n")
            for ($index = 0; $index -lt $lines.Count; $index++) {
                $candidate = [string]$lines[$index]
                if ($candidate -notmatch '(?i)\[-\]|^\s*(Expected|But was|Exception:)|\bat\s+.+\.ps1:\d+') { continue }
                $selected = New-Object 'System.Collections.Generic.List[string]'
                $start = [Math]::Max(0, $index - 1)
                $end = [Math]::Min($lines.Count - 1, $index + $MaxLines - 2)
                for ($lineIndex = $start; $lineIndex -le $end -and $selected.Count -lt $MaxLines; $lineIndex++) {
                    $line = [string]$lines[$lineIndex]
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line.Length -gt $MaxLineLength) { $line = $line.Substring(0, $MaxLineLength) }
                    if (-not $selected.Contains($line)) { $selected.Add($line) }
                }
                $summary = ($selected.ToArray() -join ' | ')
                if ($summary.Length -gt $MaxTotalLength) { $summary = $summary.Substring(0, $MaxTotalLength) }
                return $summary
            }
        }
    }

    $allowlistedFallback = New-Object 'System.Collections.Generic.List[string]'
    $sawUnrecognizedDiagnostic = $false
    foreach ($path in $Paths) {
        $rawText = Read-PesterShardOutputTail -Path $path
        $text = $rawText
        $text = ConvertFrom-PesterShardCliXmlDiagnostic -Text $text
        if (-not [string]::IsNullOrWhiteSpace($rawText) -and
            $text -ceq $rawText -and
            $rawText.TrimStart().StartsWith('#< CLIXML', [StringComparison]::Ordinal)) {
            if (-not $deferredCliXml.Contains($rawText)) { [void]$deferredCliXml.Add($rawText) }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $sawUnrecognizedDiagnostic = $true
        $text = Remove-PesterShardTerminalControlSequences -Text $text
        $lines = @($text -split "`r?`n")
        for ($index = $lines.Count - 1; $index -ge 0 -and $allowlistedFallback.Count -lt $MaxLines; $index--) {
            $line = ([string]$lines[$index]).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match '(?i)(secret|password|token|authorization|credentials?|(api|private|access)[-_ ]?key|bearer|cookie|session(_?id)?)["'']?\s*[:=]') {
                continue
            }
            $safeLine = if ($line -match '^PowerShell (?:5\.1|7(?:\.\d+)*) shard exited before writing its result file\.$') {
                $line
            }
            elseif ($line -match '^Pester shard child early failure \((initialization|invoke-pester|summary)\):') {
                "Pester shard child early failure ($($Matches[1]))."
            }
            elseif ($line -match '^Pester shard result evidence write failure:') {
                'Pester shard result evidence write failed.'
            }
            elseif ($line -match '^Tests (Passed|Failed|Skipped|Pending|Inconclusive):\s*([0-9]+)\s*$') {
                "Tests $($Matches[1]): $($Matches[2])"
            }
            elseif ($line -match '^Tests completed in\s+([0-9]+(?:\.[0-9]+)?)(ms|s)\s*$') {
                "Tests completed in $($Matches[1])$($Matches[2])"
            }
            elseif ($line -match '^Executing script\b') {
                'Pester progress: executing script.'
            }
            elseif ($line -match '^(Describing|Context)\b') {
                "Pester progress: $($Matches[1].ToLowerInvariant())."
            }
            else {
                $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$safeLine)) { continue }
            if ($safeLine.Length -gt $MaxLineLength) { $safeLine = $safeLine.Substring(0, $MaxLineLength) }
            $allowlistedFallback.Insert(0, $safeLine)
        }
        if ($allowlistedFallback.Count -gt 0) { break }
    }
    if ($allowlistedFallback.Count -gt 0) {
        $summary = ($allowlistedFallback.ToArray() -join ' | ')
        if ($summary.Length -gt $MaxTotalLength) { $summary = $summary.Substring(0, $MaxTotalLength) }
        return $summary
    }
    if ($deferredCliXml.Count -gt 0) {
        return 'PowerShell CLIXML diagnostic could not be safely decoded.'
    }
    if ($sawUnrecognizedDiagnostic) {
        return 'No allowlisted Pester diagnostic was found in the bounded output tail.'
    }
    return ''
}

function New-PesterShardPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]] $AllTestPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $IsolatedTestFileNames,
        [ValidateRange(1, 1024)][int] $BulkShardSize = 1
    )

    if (@($AllTestPaths).Count -eq 0) { throw 'No Pester test files were discovered.' }
    $seenTestPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $AllTestPaths) {
        $testPath = [string]$path
        if ([string]::IsNullOrWhiteSpace($testPath)) { throw 'Pester shard inventory contains an empty discovered path.' }
        if ($seenTestPaths.Contains($testPath)) { throw "Pester shard inventory contains duplicate discovered path '$testPath'." }
        $seenTestPaths.Add($testPath)
    }
    $orderedTestPaths = [string[]]@($AllTestPaths | ForEach-Object { [string]$_ })
    [Array]::Sort($orderedTestPaths, [StringComparer]::Ordinal)

    $isolatedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $IsolatedTestFileNames) {
        $matches = @($orderedTestPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
        if ($matches.Count -ne 1) { throw "Expected exactly one isolated test file named '$name'; found $($matches.Count)." }
        $isolatedPaths.Add([string]$matches[0])
    }

    $bulkPaths = @($orderedTestPaths | Where-Object { $isolatedPaths -notcontains [string]$_ })
    $partitionedPaths = @($isolatedPaths.ToArray()) + @($bulkPaths)
    $partitionedPathsOrdinal = [string[]]@($partitionedPaths)
    [Array]::Sort($partitionedPathsOrdinal, [StringComparer]::Ordinal)
    if (($partitionedPaths.Count -ne $orderedTestPaths.Count) -or
        (($partitionedPathsOrdinal -join [Environment]::NewLine) -cne
         ($orderedTestPaths -join [Environment]::NewLine))) {
        throw 'Pester shard inventory is not an exact partition of the discovered test files.'
    }

    $shards = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $IsolatedTestFileNames) {
        $shards.Add([pscustomobject][ordered]@{
            Name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($name))
            Paths = @($isolatedPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
        })
    }

    for ($offset = 0; $offset -lt $bulkPaths.Count; $offset += $BulkShardSize) {
        $take = [Math]::Min($BulkShardSize, $bulkPaths.Count - $offset)
        $paths = @($bulkPaths[$offset..($offset + $take - 1)])
        $ordinal = [int](($offset / $BulkShardSize) + 1)
        $name = if ($paths.Count -eq 1) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension([string]$paths[0]))
            'bulk-{0:D3}-{1}' -f $ordinal, $baseName
        }
        else {
            'bulk-{0:D3}' -f $ordinal
        }
        $shards.Add([pscustomobject][ordered]@{
            Name = $name
            Paths = $paths
        })
    }

    return @($shards.ToArray())
}

function Select-PesterShardTestPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $AllTestPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $SelectedTestFileNames
    )

    $orderedTestPaths = [string[]]@($AllTestPaths | ForEach-Object { [string]$_ })
    [Array]::Sort($orderedTestPaths, [StringComparer]::Ordinal)
    if ($SelectedTestFileNames.Count -eq 0) { return ,$orderedTestPaths }

    $selectedPaths = New-Object 'System.Collections.Generic.List[string]'
    $seenNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rawName in $SelectedTestFileNames) {
        $name = [string]$rawName
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'INVALID|Pester selection names must not be blank.'
        }
        if ($name -match '[<>:"/\\|?*\x00-\x1f]' -or
            [IO.Path]::IsPathRooted($name) -or
            -not $name.EndsWith('.Tests.ps1', [StringComparison]::OrdinalIgnoreCase) -or
            $name.EndsWith('.') -or $name.EndsWith(' ')) {
            throw 'INVALID|Pester selection requires one safe *.Tests.ps1 file name.'
        }
        $containsControl = $false
        foreach ($character in $name.ToCharArray()) {
            if ([char]::IsControl($character)) { $containsControl = $true; break }
        }
        if ($containsControl) { throw 'INVALID|Pester selection file names must not contain control characters.' }
        $deviceName = ($name.Split('.')[0])
        if ($deviceName -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9]|LPT[1-9])$') {
            throw 'INVALID|Pester selection file name is a reserved Windows device name.'
        }
        foreach ($seenName in $seenNames) {
            if ([string]::Equals($seenName, $name, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'INVALID|Pester selection contains a duplicate file name.'
            }
        }
        $seenNames.Add($name)

        $caseMatches = New-Object 'System.Collections.Generic.List[string]'
        $exactMatches = New-Object 'System.Collections.Generic.List[string]'
        foreach ($path in $orderedTestPaths) {
            $leaf = [IO.Path]::GetFileName([string]$path)
            if ([string]::Equals($leaf, $name, [StringComparison]::OrdinalIgnoreCase)) {
                $caseMatches.Add([string]$path)
            }
            if ([string]::Equals($leaf, $name, [StringComparison]::Ordinal)) {
                $exactMatches.Add([string]$path)
            }
        }
        if ($caseMatches.Count -gt 1) {
            throw 'INVALID|Pester selection is case-ambiguous in the discovered inventory.'
        }
        if ($exactMatches.Count -ne 1) {
            throw 'INVALID|Pester selection name does not exactly match one discovered test file.'
        }
        $selectedPaths.Add([string]$exactMatches[0])
    }

    $stableSelectedPaths = [string[]]@($selectedPaths.ToArray())
    [Array]::Sort($stableSelectedPaths, [StringComparer]::Ordinal)
    return ,$stableSelectedPaths
}

function Resolve-PesterShardSummaryOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $SummaryOutputPath,
        [Parameter(Mandatory = $true)][string] $EvidenceRoot,
        [Parameter(Mandatory = $true)][string] $TestRoot
    )

    if ([string]::IsNullOrWhiteSpace($SummaryOutputPath)) { return $null }
    try {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $rawSummarySeparators = [char[]]@([char]92, [char]47)
            $rawSummaryFileNameStart = $SummaryOutputPath.LastIndexOfAny($rawSummarySeparators) + 1
            $rawSummaryFileName = $SummaryOutputPath.Substring($rawSummaryFileNameStart)
            if ($rawSummaryFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw 'summary destination filename contains invalid Windows filename characters.'
            }
        }

        $summaryFullPath = Resolve-PesterShardFileSystemPath $SummaryOutputPath
        $evidenceFullPath = Resolve-PesterShardFileSystemPath $EvidenceRoot
        $testFullPath = Resolve-PesterShardFileSystemPath $TestRoot
        if (-not [string]::Equals([IO.Path]::GetExtension($summaryFullPath), '.json', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'summary destination must use the .json extension.'
        }

        $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $separator = [string][IO.Path]::DirectorySeparatorChar
        $evidencePrefix = $evidenceFullPath.TrimEnd($trimCharacters) + $separator
        $testPrefix = $testFullPath.TrimEnd($trimCharacters) + $separator
        $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        if ([string]::Equals($summaryFullPath, $evidenceFullPath, $pathComparison) -or
            -not $summaryFullPath.StartsWith($evidencePrefix, $pathComparison)) {
            throw 'summary destination must be strictly inside the evidence root.'
        }
        if ($summaryFullPath.StartsWith($testPrefix, $pathComparison)) {
            throw 'summary destination must not be inside the test root.'
        }

        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $summaryFileName = [IO.Path]::GetFileName($summaryFullPath)
            if ($summaryFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw 'summary destination filename contains invalid Windows filename characters.'
            }
        }

        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
            $summaryFullPath.Length -ge 240) {
            throw 'summary destination exceeds the controlled Windows path-length limit.'
        }

        Assert-PesterShardPathAncestorsNoReparse -Path $summaryFullPath -Context 'summary output path'
        if (Test-Path -LiteralPath $summaryFullPath) {
            throw 'summary destination already exists.'
        }

        $summaryParent = [IO.Path]::GetDirectoryName($summaryFullPath)
        if ([string]::IsNullOrWhiteSpace($summaryParent)) {
            throw 'summary destination has no parent directory.'
        }
        if (-not (Test-Path -LiteralPath $summaryParent -PathType Container)) {
            $createdParent = Open-PesterShardDirectory $summaryParent -Create; $createdParent.Dispose()
        }
        Assert-PesterShardPathAncestorsNoReparse -Path $summaryFullPath -Context 'summary output path'
        if (Test-Path -LiteralPath $summaryFullPath) {
            throw 'summary destination appeared during preflight.'
        }
        return $summaryFullPath
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith('INVALID|Pester summary', [StringComparison]::Ordinal)) { throw }
        throw "INVALID|Pester summary path preflight failed: $message"
    }
}

function Write-PesterShardExecutionSummary {
    param([string]$SummaryPath,$SummaryObject)
    Write-PesterShardJson $SummaryPath $SummaryObject
}

function Assert-PesterShardResultCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Summary,
        [Parameter(Mandatory = $true)][ValidateSet('shard', 'aggregate')][string] $Context
    )

    if ($null -eq $Summary) { throw "Pester $Context result summary is missing." }
    $fields = @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount')
    foreach ($field in $fields) {
        $property = $Summary.PSObject.Properties[$field]
        if ($null -eq $property) { throw "Pester $Context result is missing $field." }
        if ($property.Value -isnot [int] -and $property.Value -isnot [long]) {
            throw "Pester $Context result contains a non-integer $field."
        }
        if ([long]$property.Value -lt 0) { throw "Pester $Context result contains a negative $field." }
    }

    $totalCount = [long]$Summary.TotalCount
    $passedCount = [long]$Summary.PassedCount
    $failedCount = [long]$Summary.FailedCount
    $skippedCount = [long]$Summary.SkippedCount
    $pendingCount = [long]$Summary.PendingCount
    $inconclusiveCount = [long]$Summary.InconclusiveCount
    if ($totalCount -le 0) { throw "Pester $Context result must contain at least one discovered test." }
    if ($failedCount -ne 0) { throw "Pester $Context result reported $failedCount failed tests." }
    if ($pendingCount -ne 0) { throw "Pester $Context result reported $pendingCount pending tests." }
    if ($inconclusiveCount -ne 0) { throw "Pester $Context result reported $inconclusiveCount inconclusive tests." }
    if (($passedCount + $skippedCount) -ne $totalCount) { throw "Pester $Context result counts are incomplete." }
    if ($Context -ceq 'aggregate' -and $passedCount -le 0) { throw 'Pester aggregate must contain at least one passed test.' }
}

$runtimeGuards = [Collections.Generic.List[IDisposable]]::new()
try {
Import-PesterShardRuntime $PSScriptRoot $runtimeGuards
Open-PesterShardInput $PSCommandPath $runtimeGuards | Out-Null
$script:PesterShardCapabilities = Get-PlatformCapabilities -Required @('directory-lease','file-lease','file-identity','owned-process','process-cleanup','process-environment')
$repositoryRoot = Resolve-PesterShardFileSystemPath '.'
$resolvedTestRoot = Resolve-PesterShardFileSystemPath $TestRoot
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $repositoryRoot '.syp154-pester-evidence' }
$EvidenceRoot = Resolve-PesterShardFileSystemPath $EvidenceRoot
$runtimeGuards.Add((Open-PesterShardDirectory $repositoryRoot))
$runtimeGuards.Add((Open-PesterShardDirectory $resolvedTestRoot))
$runtimeGuards.Add((Open-PesterShardDirectory $EvidenceRoot -Create))
$PesterModulePath = Resolve-PesterShardFileSystemPath $PesterModulePath
$moduleRoot = [IO.Path]::GetDirectoryName($PesterModulePath)
$runtimeGuards.Add((Open-PesterShardDirectory $moduleRoot))
# The caller supplies trusted Pester fixtures. Protect the complete physical module
# tree before parsing/importing its entry point; P4 acquisition policy remains separate.
foreach ($item in @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Force)) {
    Assert-PesterShardPathAncestorsNoReparse $item.FullName 'Pester closure'
    if (-not $item.PSIsContainer) { Open-PesterShardInput $item.FullName $runtimeGuards | Out-Null }
}
$pesterData = Assert-PesterShardModuleManifest $PesterModulePath $PesterVersion
$loadedPester = [pscustomobject]@{Version=[version]$pesterData.ModuleVersion}

$allTestPaths = @(
    Get-ChildItem -LiteralPath $resolvedTestRoot -Filter '*.Tests.ps1' -File -Recurse |
        ForEach-Object { [string]$_.FullName }
)
$selectedTestPaths = Select-PesterShardTestPaths -AllTestPaths $allTestPaths -SelectedTestFileNames $SelectedTestFileNames
foreach ($selectedTestPath in $selectedTestPaths) {
    Open-PesterShardInput $selectedTestPath $runtimeGuards | Out-Null
}
$resolvedSummaryOutputPath = Resolve-PesterShardSummaryOutputPath -SummaryOutputPath $SummaryOutputPath -EvidenceRoot $EvidenceRoot -TestRoot $resolvedTestRoot
if (-not [string]::IsNullOrEmpty($resolvedSummaryOutputPath)) {
    $runtimeGuards.Add((Open-PesterShardDirectory ([IO.Path]::GetDirectoryName($resolvedSummaryOutputPath))))
}
$shards = New-Object 'System.Collections.Generic.List[object]'
foreach ($shard in @(New-PesterShardPlan `
        -AllTestPaths $selectedTestPaths `
        -IsolatedTestFileNames $IsolatedTestFileNames `
        -BulkShardSize $BulkShardSize)) {
    $shards.Add($shard)
}
if ($ShardPartitionIndex -ge $ShardPartitionCount) {
    throw 'ShardPartitionIndex must be less than ShardPartitionCount.'
}
if ($ExpectedFullShardCount -gt 0 -and $shards.Count -ne $ExpectedFullShardCount) {
    throw "Pester discovered $($shards.Count) shards; expected exactly $ExpectedFullShardCount before partitioning."
}
$selectedShards = New-Object 'System.Collections.Generic.List[object]'
for ($index = 0; $index -lt $shards.Count; $index++) {
    if (($index % $ShardPartitionCount) -eq $ShardPartitionIndex) {
        $selectedShards.Add($shards[$index])
    }
}
if ($selectedShards.Count -eq 0) { throw 'Pester shard partition is empty.' }
Write-Host "Pester shard plan: full=$($shards.Count) partition=$ShardPartitionIndex/$ShardPartitionCount selected=$($selectedShards.Count)"

$childPowerShell = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$childScript = @(
    '$ErrorActionPreference = ''Stop'''
    $(foreach ($name in @('Get-PesterShardCanonicalHash','Import-PesterShardRuntime','Resolve-PesterShardFileSystemPath','Test-PesterShardReparseItem','Assert-PesterShardPathAncestorsNoReparse','Open-PesterShardDirectory','Open-PesterShardInput','Write-PesterShardJson','Write-PesterShardBytes','ConvertTo-PesterShardSanitizedDiagnosticText')) { 'function '+$name+' {'; (Get-Command $name -CommandType Function).Definition; '}' })
    '$childGuards = [Collections.Generic.List[IDisposable]]::new()'
    'Import-PesterShardRuntime $env:SYP154_PESTER_RUNTIME_ROOT $childGuards'
    '# Keep independently invocable references to the verified P2 commands. A test may remove the module from the session, but it must not disable supervisor evidence writes.'
    '$script:PesterShardEvidenceOpenPlatformDirectory = Get-Command Open-PlatformDirectory -CommandType Function -ErrorAction Stop'
    '$script:PesterShardEvidenceOpenPlatformFile = Get-Command Open-PlatformFile -CommandType Function -ErrorAction Stop'
    'function Write-PesterShardChildEvidenceBytes {'
    '    param([string]$Path,[byte[]]$Bytes)'
    '    $Path = Resolve-PesterShardFileSystemPath $Path'
    '    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [IO.Path]::GetFullPath($Path).Length -ge 240) {'
    '        throw ''INVALID|Windows shard artifact paths must be fewer than 240 characters.'''
    '    }'
    '    $full = [IO.Path]::GetFullPath($Path)'
    '    $parentPath = [IO.Path]::GetDirectoryName($full).TrimEnd([IO.Path]::DirectorySeparatorChar)'
    '    $anchor = [IO.Path]::GetPathRoot($parentPath)'
    '    $parent = & $script:PesterShardEvidenceOpenPlatformDirectory -Root $anchor -RelativePath $parentPath.Substring($anchor.Length)'
    '    try {'
    '        $file = & $script:PesterShardEvidenceOpenPlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access ReadWrite -CreateMode CreateNew'
    '        try { $file.WriteNewBytes($Bytes) }'
    '        finally { $file.Dispose() }'
    '    } finally { $parent.Dispose() }'
    '    # Partial files are retained on failure. P7 publication/removal is not used.'
    '}'
    'function Write-PesterShardChildEvidenceJson {'
    '    param([string]$Path,$Value)'
    '    Write-PesterShardChildEvidenceBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 16 -Compress)))'
    '}'
    'function Remove-PesterShardTerminalControlSequences {'
    (Get-Command Remove-PesterShardTerminalControlSequences -CommandType Function -ErrorAction Stop).Definition
    '}'
    'function ConvertTo-PesterShardEarlyFailureDiagnostic {'
    '    param([Parameter()][AllowNull()][object] $ErrorRecord)'
    '    $text = if ($null -eq $ErrorRecord) { ''Pester shard child failed before producing a result.'' } else { [string]$ErrorRecord.Exception.ToString() }'
    '    if ([string]::IsNullOrWhiteSpace($text)) { $text = ''Pester shard child failed before producing a result.'' }'
    '    $normalizedText = Remove-PesterShardTerminalControlSequences -Text $text'
    '    $lines = New-Object ''System.Collections.Generic.List[string]'''
    '    $redactSensitiveContinuation = $false'
    '    foreach ($rawLine in @($normalizedText -split "`r?`n")) {'
    '        if ($lines.Count -ge 8) { break }'
    '        $line = ([string]$rawLine).Trim()'
    '        if ([string]::IsNullOrWhiteSpace($line)) {'
    '            continue'
    '        }'
    '        if ($redactSensitiveContinuation) {'
    '            $line = if ($line -match ''(?i)^\s*\[-\]'') {'
    '                ''[-] [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*Expected'') {'
    '                ''Expected: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*But was'') {'
    '                ''But was: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*Exception:'') {'
    '                ''Exception: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)\bat\s+.+\.ps1:\d+'') {'
    '                ''at [redacted sensitive diagnostic continuation]'''
    '            }'
    '            else {'
    '                ''[redacted sensitive diagnostic continuation]'''
    '            }'
    '        }'
    'else {'
    'if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match ''(?i)(secret|password|token|authorization|credentials?|(api|private|access)[-_ ]?key|bearer|cookie|session(_?id)?)["'''']?\s*[:=]'') {'
    '$redactSensitiveContinuation = $true'
    '$line = ''[redacted sensitive diagnostic line]'''
    '}'
    '}'
    '        if ($line.Length -gt 512) { $line = $line.Substring(0, 512) }'
    '        if (-not $lines.Contains($line)) { [void]$lines.Add($line) }'
    '    }'
    '    $diagnostic = ($lines.ToArray() -join '' | '')'
    '    if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = ''Pester shard child failed before producing a result.'' }'
    '    if ($diagnostic.Length -gt 4096) { $diagnostic = $diagnostic.Substring(0, 4096) }'
    '    return $diagnostic'
    '}'
    '$childFailurePhase = ''initialization'''
    '$summary = $null'
    '$childExitCode = 0'
    'try {'
    '    $paths = ConvertFrom-Json -InputObject $env:SYP154_PESTER_SHARD_PATHS'
    '    $casePaths = @($paths)'
    '    if ($casePaths.Count -eq 0) { throw ''Pester shard has no test paths.'' }'
    '    Import-Module $env:SYP154_PESTER_MODULE_PATH -Force'
    ('    $invoke = Get-Command Invoke-Pester -ErrorAction Stop | Where-Object {{ $_.Module.Version -eq [version]''{0}'' }} | Select-Object -First 1' -f $PesterVersion)
    ('    if ($null -eq $invoke) {{ throw ''Pester shard could not resolve version {0}.'' }}' -f $PesterVersion)
    '    $invokeParameters = @{ Script = $paths; PassThru = $true }'
    '    if ($invoke.Parameters.ContainsKey(''Show'')) { $invokeParameters.Show = ''All'' }'
    '    $childFailurePhase = ''invoke-pester'''
    '    $savedPesterErrorActionPreference = $ErrorActionPreference'
    '    try {'
    '        # Preserve the original workflow contract: Pester and its fixtures may emit non-terminating native stderr warnings.'
    '        $ErrorActionPreference = ''Continue'''
    '        $result = & $invoke @invokeParameters'
    '    }'
    '    finally {'
    '        $ErrorActionPreference = $savedPesterErrorActionPreference'
    '    }'
    '    if ($null -eq $result) { throw ''Pester shard did not return a result object.'' }'
    '    $childFailurePhase = ''summary'''
    '    $cases = [Collections.Generic.List[object]]::new()'
    '    foreach ($case in @($result.TestResult | Sort-Object { if ($_.Result -eq ''Skipped'') { 1 } elseif ($_.Result -eq ''Passed'') { 2 } else { 0 } })) {'
    '        if ($cases.Count -ge 256) { break }'
    '        $casePath = if (-not [string]::IsNullOrWhiteSpace([string]$case.Path)) { [string]$case.Path } elseif ($casePaths.Count -eq 1) { [string]$casePaths[0] } else { '''' }'
    '        $fields = [ordered]@{}'
    '        foreach ($pair in @(@(''path'',$casePath),@(''name'',[string]$case.Name),@(''result'',[string]$case.Result),@(''errorRecord'',[string]$case.ErrorRecord),@(''errorId'',[string]$case.ErrorRecord.FullyQualifiedErrorId),@(''stack'',([string]$case.StackTrace+"`n"+[string]$case.ErrorRecord.ScriptStackTrace)))) {'
    '            $value = ConvertTo-PesterShardSanitizedDiagnosticText $pair[1]'
    '            $fields[$pair[0]] = $value.Substring(0,[Math]::Min(1024,$value.Length))'
    '        }'
    '        $cases.Add([pscustomobject]$fields)'
    '    }'
    '    Write-PesterShardChildEvidenceJson ($env:SYP154_PESTER_RESULT_PATH + ''.cases.json'') ([ordered]@{schemaVersion=1;type=''pester-case-diagnostics'';truncated=(@($result.TestResult).Count -gt 256);cases=$cases.ToArray()})'
    '    $summary = [ordered]@{'
    '        schemaVersion = 1'
    '        status = ''completed'''
    '        TotalCount = $result.TotalCount'
    '        PassedCount = $result.PassedCount'
    '        FailedCount = $result.FailedCount'
    '        SkippedCount = $result.SkippedCount'
    '        PendingCount = $result.PendingCount'
    '        InconclusiveCount = $result.InconclusiveCount'
    '    }'
    '}'
    'catch {'
    '    $childExitCode = 3'
    '    $failureMessage = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_'
    '    try { [Console]::Error.WriteLine((''Pester shard child early failure ({0}): {1}'' -f $childFailurePhase, $failureMessage)) } catch { }'
    '    $summary = [ordered]@{'
    '        schemaVersion = 1'
    '        status = ''failed'''
    '        failureKind = ''early-child-failure'''
    '        failurePhase = $childFailurePhase'
    '        failureMessage = $failureMessage'
    '        TotalCount = 0'
    '        PassedCount = 0'
    '        FailedCount = 1'
    '        SkippedCount = 0'
    '        PendingCount = 0'
    '        InconclusiveCount = 0'
    '    }'
    '}'
    'try {'
    '    Write-PesterShardChildEvidenceJson $env:SYP154_PESTER_RESULT_PATH $summary'
    '}'
    'catch {'
    '    $childExitCode = 4'
    '    $failureMessage = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_'
    '    try { [Console]::Error.WriteLine((''Pester shard result evidence write failure: {0}'' -f $failureMessage)) } catch { }'
    '}'
    'if ($childExitCode -ne 0) { exit $childExitCode }'
    'if ($summary.FailedCount -gt 0 -or $summary.PendingCount -gt 0 -or $summary.InconclusiveCount -gt 0) { exit 2 }'
    'exit 0'
) -join [Environment]::NewLine

[long]$total = 0
[long]$passed = 0
[long]$failed = 0
[long]$skipped = 0
[long]$pending = 0
[long]$inconclusive = 0
$failedShardProcess = $false
$completedShardSummaries = New-Object 'System.Collections.Generic.List[object]'
$caseEvidenceDocuments = New-Object 'System.Collections.Generic.List[object]'
foreach ($shard in @($selectedShards.ToArray())) {
    foreach ($guard in $runtimeGuards) {
        Assert-PlatformFileIdentity -Lease $guard -Expected $guard.Observation -SingleLink:($guard.Observation.Kind -ceq 'file') | Out-Null
    }
    Write-Host "Starting Pester shard $($shard.Name)"
    $runToken = [guid]::NewGuid().ToString('N')
    $safeName = ($shard.Name -replace '[^A-Za-z0-9_.-]', '-')
    $resultPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.json" -f $safeName, $runToken)
    $processEvidencePath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.process.json" -f $safeName, $runToken)
    $stdoutPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stdout.log" -f $safeName, $runToken)
    $stderrPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stderr.log" -f $safeName, $runToken)
    $childScriptPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.child.ps1" -f $safeName, $runToken)
    Write-PesterShardBytes $childScriptPath ([Text.UTF8Encoding]::new($false).GetBytes($childScript))
    $environment = Get-PesterShardChildEnvironment
    $environment['SYP154_PESTER_SHARD_PATHS'] = ConvertTo-Json -InputObject ([string[]]$shard.Paths) -Compress
    $environment['SYP154_PESTER_MODULE_PATH'] = $PesterModulePath
    $environment['SYP154_PESTER_RESULT_PATH'] = $resultPath
    $environment['SYP154_PESTER_RUNTIME_ROOT'] = $PSScriptRoot
    $shardRun = Invoke-PesterShardProcess -Paths $shard.Paths -ModulePath $PesterModulePath -Version $PesterVersion `
        -ChildPowerShell $childPowerShell -ChildScriptPath $childScriptPath -ResultPath $resultPath `
        -ProcessEvidencePath $processEvidencePath -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -TimeoutSeconds $OuterTimeoutSeconds -WorkingDirectory $repositoryRoot -Environment $environment `
        -CancellationToken $CancellationToken -IsolationRequirement $IsolationRequirement
    $resultPath = [string]$shardRun.resultPath
    $summary = Read-PesterShardJson $resultPath
    if ($compareExpectedSkippedTests) {
        $caseEvidenceDocuments.Add((Read-PesterShardJson ($resultPath + '.cases.json')))
    }
    $processEvidence = Read-PesterShardJson ([string]$shardRun.processEvidencePath)
    $shardOutputQuotaExceeded = $false
    if ($shardRun.PSObject.Properties.Name -contains 'outputQuotaExceeded') {
        $shardOutputQuotaExceeded = [bool]$shardRun.outputQuotaExceeded
    }
    $processOutputQuotaExceeded = $false
    if ($processEvidence.PSObject.Properties.Name -contains 'outputQuotaExceeded') {
        $processOutputQuotaExceeded = [bool]$processEvidence.outputQuotaExceeded
    }
    $shardProcessStatusInvalid = ([string]$shardRun.status -cne 'completed' -or
        [string]$processEvidence.status -cne 'completed' -or
        $shardOutputQuotaExceeded -or $processOutputQuotaExceeded)
    if ($shardProcessStatusInvalid -or [int]$shardRun.exitCode -ne 0 -or [int]$summary.FailedCount -gt 0) {
        if ($shardProcessStatusInvalid) {
            Write-Host "Pester shard process status is not completed or output quota was exceeded: shard=$($shardRun.status), evidence=$($processEvidence.status), shardQuota=$shardOutputQuotaExceeded, evidenceQuota=$processOutputQuotaExceeded"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$processEvidence.failureSummary)) {
            Write-Host "Pester shard first failure (sanitized): $($processEvidence.failureSummary)"
        }
    }
    if (-not $shardRun.cleanedUp -or -not $processEvidence.cleanup.cleanedUp) { throw 'Pester shard cleanup is unconfirmed.' }
    Assert-PesterShardResultCounts -Summary $summary -Context 'shard'
    $completedShardSummaries.Add([pscustomobject][ordered]@{
        name = [string]$shard.Name
        paths = [string[]]@($shard.Paths)
        processEvidencePath = [IO.Path]::GetFullPath([string]$shardRun.processEvidencePath)
        resultPath = [IO.Path]::GetFullPath([string]$shardRun.resultPath)
        exitCode = [int]$shardRun.exitCode
        status = [string]$shardRun.status
        cleanedUp = [bool]$shardRun.cleanedUp
        outputQuotaExceeded = [bool]$shardOutputQuotaExceeded
    })
    Write-Host "$($shard.Name) - Total: $($summary.TotalCount) Passed: $($summary.PassedCount) Failed: $($summary.FailedCount) Skipped: $($summary.SkippedCount) Pending: $($summary.PendingCount) Inconclusive: $($summary.InconclusiveCount)"
    $total += [long]$summary.TotalCount
    $passed += [long]$summary.PassedCount
    $failed += [long]$summary.FailedCount
    $skipped += [long]$summary.SkippedCount
    $pending += [long]$summary.PendingCount
    $inconclusive += [long]$summary.InconclusiveCount
    if ($shardProcessStatusInvalid -or [int]$shardRun.exitCode -ne 0) { $failedShardProcess = $true }
}

if ($failedShardProcess) { throw 'At least one isolated Pester shard exited nonzero.' }
$aggregateSummary = [pscustomobject][ordered]@{
    TotalCount = $total
    PassedCount = $passed
    FailedCount = $failed
    SkippedCount = $skipped
    PendingCount = $pending
    InconclusiveCount = $inconclusive
}
Assert-PesterShardResultCounts -Summary $aggregateSummary -Context 'aggregate'
if ($ExpectedTotalCount -ge 0 -and $total -ne $ExpectedTotalCount) { throw "Pester discovered $total tests across shards; expected exactly $ExpectedTotalCount." }
if ($compareExpectedSkippedTests) {
    Assert-PesterShardExpectedSkippedTests -Expected $ExpectedSkippedTests -CaseEvidence $caseEvidenceDocuments.ToArray()
}
if ($ExpectedSkippedCount -ge 0 -and $skipped -ne $ExpectedSkippedCount) { throw "Pester expected exactly $ExpectedSkippedCount platform/version skips; got $skipped." }
Write-Host "Aggregate - Total: $total Passed: $passed Failed: $failed Skipped: $skipped Pending: $pending Inconclusive: $inconclusive"
if (-not [string]::IsNullOrWhiteSpace($resolvedSummaryOutputPath)) {
    foreach ($guard in $runtimeGuards) {
        Assert-PlatformFileIdentity -Lease $guard -Expected $guard.Observation -SingleLink:($guard.Observation.Kind -ceq 'file') | Out-Null
    }
    $executedTestPaths = [string[]]@(
        $completedShardSummaries.ToArray() | ForEach-Object { $_.paths }
    )
    [Array]::Sort($executedTestPaths, [StringComparer]::Ordinal)
    $executionSummary = [pscustomobject][ordered]@{
        schemaVersion = [int]1
        type = 'standard-pester-execution-summary'
        executed = [bool]$true
        status = 'completed'
        runtime = [pscustomobject][ordered]@{
            osPlatform = [string][Environment]::OSVersion.Platform
            psEdition = [string]$PSVersionTable.PSEdition
            psVersion = [string]$PSVersionTable.PSVersion
        }
        pesterVersion = [string]$loadedPester.Version
        pesterModuleSha256 = Get-PesterShardFileSha256 -Path $PesterModulePath
        executorSha256 = Get-PesterShardFileSha256 -Path $PSCommandPath
        testFiles = [string[]]@($executedTestPaths)
        counts = $aggregateSummary
        shards = [object[]]@($completedShardSummaries.ToArray())
    }
    Write-PesterShardExecutionSummary -SummaryPath $resolvedSummaryOutputPath -SummaryObject $executionSummary
}

} finally { for ($i=$runtimeGuards.Count-1;$i -ge 0;$i--) { $runtimeGuards[$i].Dispose() } }
