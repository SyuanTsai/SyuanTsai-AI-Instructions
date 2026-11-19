# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-ConsumerRepositoryCheckArguments([object[]]$Tokens) {
    # The protected runner invokes a .ps1 command with array splatting, so named
    # strings are otherwise positionally bound. Parse only exact name/value
    # pairs here. Names use OrdinalIgnoreCase to match PowerShell parameter-name
    # casing, but abbreviations, prefixes, and -Name:value syntax are rejected.
    # A value that begins with '-' is rejected to prevent a missing value from
    # shifting a later name into the value position.
    # pwsh -File normalizes -Name:value into two script arguments before
    # populating $args. Inspect only this process's raw -File tail so that the
    # colon form remains rejectable; runner array-splat calls have no matching
    # -File tail and are validated directly from $args below.
    $processArguments=[Environment]::GetCommandLineArgs()
    for($rawIndex=0;$rawIndex-lt($processArguments.Count-1);$rawIndex++){
        if(-not[string]::Equals([string]$processArguments[$rawIndex],'-File',[StringComparison]::OrdinalIgnoreCase)){continue}
        $rawScript=[IO.Path]::GetFullPath([string]$processArguments[$rawIndex+1])
        if(-not[string]::Equals($rawScript,[IO.Path]::GetFullPath($PSCommandPath),[StringComparison]::OrdinalIgnoreCase)){continue}
        if($rawIndex+2-lt$processArguments.Count){
            foreach($rawToken in @($processArguments[($rawIndex+2)..($processArguments.Count-1)])){
                if(([string]$rawToken).StartsWith('-',[StringComparison]::Ordinal)-and([string]$rawToken).Contains(':',[StringComparison]::Ordinal)){
                    throw "Unknown repository check parameter: $rawToken"
                }
            }
        }
        break
    }
    $names=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in @('Mode','PesterReceiptSha256','PesterManifestSha256','PesterVersion')){$names.Add("-$name",$name)}
    $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($index=0;$index-lt$Tokens.Count;$index+=2){
        $name=[string]$Tokens[$index]
        if(-not$name.StartsWith('-',[StringComparison]::Ordinal)){throw "Unexpected positional repository check token: $name"}
        if(-not$names.ContainsKey($name)){throw "Unknown repository check parameter: $name"}
        $canonical=$names[$name]
        if($values.ContainsKey($canonical)){throw "Duplicate repository check parameter: -$canonical"}
        if($index+1-ge$Tokens.Count){throw "Repository check parameter -$canonical is missing a value."}
        $value=[string]$Tokens[$index+1]
        if($value.StartsWith('-',[StringComparison]::Ordinal)){throw "Repository check parameter -$canonical value must not begin with '-'."}
        $values.Add($canonical,$value)
    }
    if(-not$values.ContainsKey('Mode')){throw 'Repository check Mode is required.'}
    $mode=[string]$values['Mode']
    if(-not($mode.Equals('general',[StringComparison]::OrdinalIgnoreCase)-or
            $mode.Equals('pester',[StringComparison]::OrdinalIgnoreCase))){throw 'Repository check Mode must be general or pester.'}
    $mode=$mode.ToLowerInvariant()
    foreach($name in @('PesterReceiptSha256','PesterManifestSha256')){
        if($values.ContainsKey($name)-and[string]$values[$name]-cnotmatch'^[0-9a-f]{64}$'){
            throw "Repository check $name must be a 64-character lowercase SHA-256."
        }
    }
    if($values.ContainsKey('PesterVersion')-and[string]$values['PesterVersion']-cne'6.2.0'){
        throw 'Repository check PesterVersion must be 6.2.0.'
    }
    if($mode-ceq'pester'){
        foreach($name in @('PesterReceiptSha256','PesterManifestSha256','PesterVersion')){
            if(-not$values.ContainsKey($name)){throw "Repository check $name is required when Mode is pester."}
        }
    }
    # Mode=general intentionally accepts the three well-formed Pester bindings,
    # matching the former optional parameters; the general check does not use them.
    [pscustomobject]@{
        Mode=$mode
        PesterReceiptSha256=if($values.ContainsKey('PesterReceiptSha256')){[string]$values['PesterReceiptSha256']}else{$null}
        PesterManifestSha256=if($values.ContainsKey('PesterManifestSha256')){[string]$values['PesterManifestSha256']}else{$null}
        PesterVersion=if($values.ContainsKey('PesterVersion')){[string]$values['PesterVersion']}else{$null}
    }
}

function Read-ConsumerJson([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Consumer JSON must not contain a UTF-8 BOM.' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $document.RootElement.EnumerateObject()) { if (-not $seen.Add($property.Name)) { throw 'Consumer JSON has duplicate keys.' } }
    } finally { $document.Dispose() }
    $text | ConvertFrom-Json -Depth 50 -ErrorAction Stop
}
function Test-Within([string]$Path, [string]$Root) {
    $pathFull = [IO.Path]::GetFullPath($Path)
     $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)
}
function Get-ConsumerOrdinalClosureEntries([object[]]$Entries) {
    $sorted=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($entry in $Entries){
        if($null-eq$entry-or[string]::IsNullOrEmpty([string]$entry.path)-or$sorted.ContainsKey([string]$entry.path)){
            throw 'Verified Pester closure contains a duplicate or empty path.'
        }
        $sorted.Add([string]$entry.path,$entry)
    }
    @($sorted.Values)
}
function Assert-PesterClosure([string]$WorkRoot,[string]$ReceiptSha256,[string]$ManifestSha256,[string]$Version) {
    $receiptPath=Join-Path $WorkRoot 'source-tools/receipt-pester.json'
    if (
        $ReceiptSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReceiptSha256
    ) { throw 'Verified Pester receipt changed.' }
    $receipt=Read-ConsumerJson $receiptPath
    if (
        [string]$receipt.toolName -cne 'pester' -or [string]$receipt.resolvedVersion -cne $Version -or
        [string]$receipt.identityKind -cne 'approved-payload-and-installed-closure' -or
        -not [bool]$receipt.frozenForRun -or $receipt.dependencyClosure -isnot [array] -or
        @($receipt.dependencyClosure).Count -lt 1
    ) { throw 'Verified Pester receipt identity is invalid.' }
    $installRoot=[IO.Path]::GetFullPath([string]$receipt.installRoot)
    if(-not(Test-Within $installRoot(Join-Path $WorkRoot 'runtime/installed'))){throw 'Verified Pester install root is outside the run-owned runtime.'}
    $expected=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($receipt.dependencyClosure)){
        if (
            @($entry.PSObject.Properties.Name).Count -ne 2 -or
            $null -eq $entry.PSObject.Properties['path'] -or $null -eq $entry.PSObject.Properties['sha256'] -or
            [string]$entry.path -cnotmatch '^[A-Za-z0-9._/-]+$' -or [string]$entry.path -match '(^|/)\.\.(/|$)' -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $expected.ContainsKey([string]$entry.path)
        ) { throw 'Verified Pester closure receipt is invalid.' }
        $expected.Add([string]$entry.path,[string]$entry.sha256)
    }
    $actual=@(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force)
    if($actual.Count-ne$expected.Count){throw 'Verified Pester closure file count changed.'}
    $entries=[Collections.Generic.List[object]]::new()
    foreach($file in $actual){
        if(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$file.LinkType){throw 'Verified Pester closure contains a reparse point.'}
        $relative=[IO.Path]::GetRelativePath($installRoot,$file.FullName).Replace('\','/')
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if(-not$expected.ContainsKey($relative)-or$expected[$relative]-cne$hash){throw 'Verified Pester closure bytes changed.'}
        $entries.Add([pscustomobject]@{path=$relative;sha256=$hash})
    }
    $ordered=@(Get-ConsumerOrdinalClosureEntries $entries.ToArray())
    $canonical=($ordered|ForEach-Object{"$($_.path)`t$($_.sha256)`n"})-join''
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($canonical)
    $closure=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if($closure-cne[string]$receipt.dependencyClosureSha256-or$closure-cne[string]$receipt.installedClosureSha256){throw `
        'Verified Pester closure identity changed.'}
    $modulePath=[IO.Path]::GetFullPath([string]$receipt.modulePath)
    if (
        -not (Test-Within $modulePath $installRoot) -or
        (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestSha256 -or
        [string]$receipt.executableSha256 -cne $ManifestSha256
    ) { throw 'Verified Pester manifest identity differs from setup.' }
    $modulePath
}
function Get-ConsumerTextSha256([string]$Text) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Add-ConsumerGitConfiguration {
    $rawCount=[Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT','Process')
    $count=0
    if(-not[string]::IsNullOrEmpty($rawCount)-and-not[int]::TryParse(
            $rawCount,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$count)){
        throw 'GIT_CONFIG_COUNT must be a non-negative decimal integer.'
    }
    if($count-gt[int]::MaxValue-2){throw 'GIT_CONFIG_COUNT cannot accommodate the two required repository check settings.'}
    for($index=0;$index-lt$count;$index++){
        foreach($kind in @('KEY','VALUE')){
            $name="GIT_CONFIG_${kind}_$index"
            if($null-eq[Environment]::GetEnvironmentVariable($name,'Process')){
                throw "Existing git environment configuration is incomplete: $name is missing."
            }
        }
    }
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$count",'maintenance.auto','Process')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$count",'false','Process')
    $next=$count+1
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$next",'gc.autoDetach','Process')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$next",'false','Process')
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT',[string]($count+2),'Process')
}
function Get-ConsumerSnapshotRows([string]$Root) {
    $rows=@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
            [pscustomobject]@{path=[IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')
    sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
    @($rows|Sort-Object -Property path -CaseSensitive)
}
function New-ConsumerPesterCase($Test,[string]$TestRoot,[string[]]$TestFiles) {
    if($Test.ScriptBlock-isnot[scriptblock]-or[string]::IsNullOrWhiteSpace([string]$Test.ExpandedPath)){throw `
        'Pester case has no source block or expanded identity.'}
    $extent=$Test.ScriptBlock.Ast.Extent
    $full=[IO.Path]::GetFullPath([string]$extent.File)
    $root=[IO.Path]::GetFullPath($TestRoot).TrimEnd('/','\')+[IO.Path]::DirectorySeparatorChar
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$full.StartsWith($root,$comparison)){throw 'Pester case originates outside the complete tests tree.'}
    $relative=$full.Substring($root.Length).Replace('\','/')
    if (
        $TestFiles -cnotcontains $relative -or $extent.StartOffset -lt 0 -or
        [string]$Test.Result -cnotin @('Passed','Failed','Skipped','Inconclusive','NotRun')
    ) { throw 'Pester case source or result is outside the complete suite.' }
    $tuple=ConvertTo-Json -InputObject ([object[]]@($relative.ToUpperInvariant(),[int]$extent.StartOffset,[string]$Test.ExpandedPath))-Depth 3 -Compress
    [pscustomobject]@{identity=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($tuple))
    sourceFile=$relative
    sourceStartOffset=[int]$extent.StartOffset
    sourceStartLine=[int]$extent.StartLineNumber
    expandedPath=[string]$Test.ExpandedPath
    result=[string]$Test.Result
    identityError=$null}
}

try {
    $parsedArguments=ConvertFrom-ConsumerRepositoryCheckArguments @($args)
    $Mode=[string]$parsedArguments.Mode
    $PesterReceiptSha256=[string]$parsedArguments.PesterReceiptSha256
    $PesterManifestSha256=[string]$parsedArguments.PesterManifestSha256
    $PesterVersion=[string]$parsedArguments.PesterVersion
    foreach ($name in @('STANDARD_VALIDATION_CORE_RUN_ID', 'STANDARD_VALIDATION_CORE_CHECK_ID', 'STANDARD_VALIDATION_CORE_SKILLS')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) { throw "Central runner did not bind $name." }
    }
    foreach ($name in [Environment]::GetEnvironmentVariables('Process').Keys) {
        if ([string]$name -match '(?i)(TOKEN|SECRET|PASSWORD|PRIVATE_KEY)') { [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process') }
    }
    Add-ConsumerGitConfiguration
    $candidateRoot = [IO.Path]::GetFullPath((Get-Location).Path)
    $config = Read-ConsumerJson (Join-Path $candidateRoot 'config/consumer-gate.json')
    $activeSkills=@([string]$env:STANDARD_VALIDATION_CORE_SKILLS -split ';'|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    if($activeSkills.Count-lt1-or(@($activeSkills|Sort-Object)-join"`n")-cne(@([string[]]$config.activeSkills|Sort-Object)-join"`n")){throw `
        'Central runner active Skill binding differs from consumer config.'}
    if ($Mode -eq 'general') {
        $generalChecks=@($config.repositoryChecks|Where-Object{[string]$_.kind-ceq'general'})
        if($generalChecks.Count-lt1){throw 'At least one general repository check is required.'}
        foreach($check in $generalChecks){
            $relative = [string]$check.path
            if ($relative -cnotmatch '^(?:scripts|tests)/.+\.ps1$' -or $relative -match '\.Tests\.ps1$') { throw 'General repository check path is invalid.' }
            $scriptPath = [IO.Path]::GetFullPath((Join-Path $candidateRoot $relative))
            if (-not (Test-Within $scriptPath $candidateRoot) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw `
                'General repository check is missing or outside the candidate.' }
            $command = Get-Command $scriptPath -CommandType ExternalScript -ErrorAction Stop
            $arguments = @{}
            if ($command.Parameters.ContainsKey('RepositoryRoot')) { $arguments.RepositoryRoot = $candidateRoot }
            if ($command.Parameters.ContainsKey('ReadOnlySnapshot')) { $arguments.ReadOnlySnapshot = $true }
            $powerShell = (Get-Process -Id $PID).Path
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $powerShell
            $start.WorkingDirectory = $candidateRoot
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath)) {
                [void] $start.ArgumentList.Add($argument)
            }
            if ($arguments.ContainsKey('RepositoryRoot')) {
                [void] $start.ArgumentList.Add('-RepositoryRoot')
                [void] $start.ArgumentList.Add($candidateRoot)
            }
            if ($arguments.ContainsKey('ReadOnlySnapshot')) {
                [void] $start.ArgumentList.Add('-ReadOnlySnapshot')
            }
            foreach ($name in @($start.Environment.Keys)) {
                if ([string] $name -match '(?i)(TOKEN|SECRET|PASSWORD|PRIVATE_KEY)') {
                    [void] $start.Environment.Remove([string] $name)
                }
            }
            $process = [Diagnostics.Process]::new()
            try {
                $process.StartInfo = $start
                [void] $process.Start()
                $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
                $standardErrorTask = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
                $standardError = $standardErrorTask.GetAwaiter().GetResult()
                [Console]::Out.Write($standardOutput)
                [Console]::Error.Write($standardError)
                if ($process.ExitCode -ne 0) {
                    throw "General repository check failed with exit code $($process.ExitCode)."
                }
            }
            finally {
                $standardOutput = $null
                $standardError = $null
                $standardOutputTask = $null
                $standardErrorTask = $null
                $start.Environment.Clear()
                $process.Dispose()
                Remove-Variable standardOutput, standardError, standardOutputTask, standardErrorTask, process -ErrorAction SilentlyContinue
            }
        }
        exit 0
    }

    $pesterChecks = @($config.repositoryChecks | Where-Object { [string]$_.kind -ceq 'pester' })
    if ($pesterChecks.Count -ne 1) { throw 'Pester repository check must be declared exactly once.' }
    $runtimeRoot = Split-Path -Parent $PSScriptRoot
    $workRoot=Split-Path -Parent $runtimeRoot
    if ($PesterVersion -cne '6.2.0') { throw 'Verified Pester version differs from setup.' }
    $pesterManifest=Assert-PesterClosure $workRoot $PesterReceiptSha256 $PesterManifestSha256 $PesterVersion
    if(@(Get-Module Pester).Count-ne0){throw 'Verified Pester must not already be loaded.'}
    Import-Module -Name $pesterManifest -Force -ErrorAction Stop
    $loadedPester = Get-Module Pester | Select-Object -First 1
    if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne $PesterVersion) { throw 'Verified runtime did not load Pester 6.2.0.' }
    if ($pesterChecks.Count -ne 1 -or [string]$pesterChecks[0].path -cne 'tests') { throw 'Pester check must declare the complete tests path exactly once.' }
    $configuration = New-PesterConfiguration
    $testRoot=Join-Path $candidateRoot 'tests'
    if(-not(Test-Path -LiteralPath $testRoot -PathType Container)){throw 'Complete tests tree is missing.'}
    $testFiles=@(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.Tests.ps1' |
            ForEach-Object { [IO.Path]::GetRelativePath($testRoot,$_.FullName).Replace('\','/') } |
            Sort-Object -CaseSensitive)
    if($testFiles.Count-lt1){throw 'Complete tests tree contains no Pester test file.'}
    $beforeSnapshot=Get-ConsumerSnapshotRows $candidateRoot
    $beforeSnapshotSha=Get-ConsumerTextSha256 (ConvertTo-Json -InputObject $beforeSnapshot -Depth 3 -Compress)
    $configuration.Run.Path = $testRoot
    $configuration.Run.PassThru = $true
    $configuration.Run.RepoRoot = $candidateRoot
    $configuration.Output.Verbosity = 'None'
    $configuration.TestRegistry.Enabled = $false
    $result = Invoke-Pester -Configuration $configuration
    $discovery=@($result.Tests|ForEach-Object{New-ConsumerPesterCase $_ $testRoot $testFiles})
    $execution=@($result.Tests|Where-Object{[bool]$_.Executed}|ForEach-Object{New-ConsumerPesterCase $_ $testRoot $testFiles})
    $containerFiles=@($result.Containers|ForEach-Object{$name=if($null-ne$_.PSObject.Properties['Name']){[string]$_.Name}else{[string]$_.Item}
    [IO.Path]::GetRelativePath($testRoot,[IO.Path]::GetFullPath($name)).Replace('\','/')}|Sort-Object -Unique -CaseSensitive)
    $discoveredFiles=@($discovery.sourceFile|Sort-Object -Unique -CaseSensitive)
    $identities=@($execution.identity)
    $identitySet=@($identities|Select-Object -Unique)
    $afterManifest=Assert-PesterClosure $workRoot $PesterReceiptSha256 $PesterManifestSha256 $PesterVersion
    $afterSnapshot=Get-ConsumerSnapshotRows $candidateRoot
    $afterSnapshotSha=Get-ConsumerTextSha256 (ConvertTo-Json -InputObject $afterSnapshot -Depth 3 -Compress)
    $errors=[Collections.Generic.List[string]]::new()
    if($afterManifest-cne$pesterManifest-or$afterSnapshotSha-cne$beforeSnapshotSha){$errors.Add('Pester changed its verified closure or candidate snapshot.')}
    if (
        [string]$result.Result -cne 'Passed' -or $result.TotalCount -lt 1 -or $result.PassedCount -ne $result.TotalCount -or
        $result.FailedCount -ne 0 -or $result.SkippedCount -ne 0 -or $result.InconclusiveCount -ne 0 -or
        $result.NotRunCount -ne 0 -or $result.FailedBlocksCount -ne 0 -or $result.FailedContainersCount -ne 0
    ) { $errors.Add('Pester did not report a complete unskipped pass.') }
    if (
        $discovery.Count -ne $result.TotalCount -or $execution.Count -ne $result.TotalCount -or
        $identitySet.Count -ne $identities.Count -or ($testFiles -join ';') -cne ($containerFiles -join ';') -or
        ($testFiles -join ';') -cne ($discoveredFiles -join ';')
    ) { $errors.Add('Pester case, container, or test-file identity is incomplete.') }
    $runRoot=Split-Path -Parent $candidateRoot
    $runId=[string]$env:STANDARD_VALIDATION_CORE_RUN_ID
    if (
        [IO.Path]::GetFileName($runRoot) -cne $runId -or
        [IO.Path]::GetFileName($candidateRoot) -cne 'candidate'
    ) { $errors.Add('Pester case inventory is outside the canonical run root.') }
    $ledger=[ordered]@{
        schemaVersion=1
        report='standard-core-pester-case-inventory-v1'
        coreRunId=$runId
        candidateSnapshotIdentity=[ordered]@{coreRunId=$runId
        root=$candidateRoot}
        candidateSnapshotSha256=$beforeSnapshotSha
        pesterModule=[ordered]@{version=[string]$loadedPester.Version
        manifestPath=$pesterManifest
        moduleRoot=Split-Path -Parent $pesterManifest
        lockPath=Join-Path $workRoot 'source-tools/receipt-pester.json'
        lockSha256=$PesterReceiptSha256
        closureSha256Before=(Read-ConsumerJson (Join-Path $workRoot 'source-tools/receipt-pester.json')).installedClosureSha256
        closureSha256After=(Read-ConsumerJson (Join-Path $workRoot 'source-tools/receipt-pester.json')).installedClosureSha256}
        runPath='tests'
        runScope='complete-unfiltered-tests-tree'
        testFileInventory=$testFiles
        containerFileInventory=$containerFiles
        discoveredCaseFileInventory=$discoveredFiles
        caseDiscoveryCount=$discovery.Count
        caseExecutionCount=$execution.Count
        containerCount=@($result.Containers).Count
        failedBlockCount=[int]$result.FailedBlocksCount
        failedContainerCount=[int]$result.FailedContainersCount
        terminalStatus=if($errors.Count-eq0){'complete'}else{'failed'}
        reportedCounts=[ordered]@{Passed=[int]$result.PassedCount
        Failed=[int]$result.FailedCount
        Skipped=[int]$result.SkippedCount
        Inconclusive=[int]$result.InconclusiveCount
        NotRun=[int]$result.NotRunCount}
        shardIdentity='core-full'
        shardCaseIdentities=$identities
        shardUnion=[ordered]@{discoveryCount=$discovery.Count
        executionUnionCount=$identitySet.Count
        complete=($errors.Count-eq0)}
        discoveryCases=$discovery
        executionCases=$execution
        complete=($errors.Count-eq0)
        errors=@($errors)
    }
    $ledgerPath=Join-Path $runRoot 'repository-pester-case-inventory-v1.json'
    $ledgerBytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 30 -Compress)+"`n")
    $stream=[IO.FileStream]::new($ledgerPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($ledgerBytes)
    $stream.Flush($true)}finally{$stream.Dispose()}
    $summary = [ordered]@{
        schemaVersion = 1
        report = 'standard-core-pester-result-v1'
        total = [int]$result.TotalCount
        passed = [int]$result.PassedCount
        failed = [int]$result.FailedCount
        skipped = [int]$result.SkippedCount
    }
    if($errors.Count-ne0){foreach($error in $errors){[Console]::Error.WriteLine($error)}
    exit 1}
    [Console]::Out.WriteLine(($summary | ConvertTo-Json -Compress))
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
