# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:SupervisorAuthorityRoot=$null
$script:SupervisorPlatformRuntime=$null
$script:SupervisorConsumerGate=$null

function Throw-SupervisorResult([string]$State,[string]$Message){throw "$State|$Message"}
function Test-SupervisorPathEqual([string]$Left,[string]$Right){
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right),$comparison)
}
function Assert-SupervisorExactProperties($Value,[string[]]$Names,[string]$Context){
    $actual=@($Value.PSObject.Properties.Name)
    if($actual.Count-ne$Names.Count-or@($actual|Where-Object{$_-cnotin$Names}).Count-ne0){
        Throw-SupervisorResult INVALID "$Context has an unexpected property set."
    }
}
function Assert-SupervisorNoDuplicateJson([Text.Json.JsonElement]$Element,[string]$Context){
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){
            if(-not$seen.Add($property.Name)){Throw-SupervisorResult INVALID "$Context has a duplicate or case-conflicting key."}
            Assert-SupervisorNoDuplicateJson $property.Value $Context
        }
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){
        foreach($item in $Element.EnumerateArray()){Assert-SupervisorNoDuplicateJson $item $Context}
    }
}
function Read-SupervisorJson([string]$Path,[string]$Context,[int]$MaximumBytes=1048576){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){Throw-SupervisorResult INVALID "$Context is missing."}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){
        Throw-SupervisorResult INVALID "$Context must be a regular file."
    }
    $bytes=[IO.File]::ReadAllBytes($item.FullName)
    if($bytes.Length-gt$MaximumBytes){Throw-SupervisorResult INVALID "$Context exceeds its size limit."}
    if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){
        Throw-SupervisorResult INVALID "$Context must not contain a UTF-8 BOM."
    }
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-SupervisorNoDuplicateJson $document.RootElement $Context}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }catch{
        if($_.Exception.Message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|'){throw}
        Throw-SupervisorResult INVALID "$Context is not unambiguous UTF-8 JSON."
    }
}
function Assert-ConsumerBootstrapInterface($Contract){
    Assert-SupervisorExactProperties $Contract @('schemaVersion','supportedInterfaces','currentInterface','retiredInterfaces',
        'phaseEnvironment','requiredContexts','canonicalEventMap') 'consumer gate interface'
    if($Contract.schemaVersion-ne1-or[string]$Contract.currentInterface-cne'consumer-gate-v1'-or
        $Contract.supportedInterfaces-isnot[array]-or@($Contract.supportedInterfaces)-cnotcontains'consumer-gate-v1'-or
        $Contract.retiredInterfaces-isnot[array]){
        Throw-SupervisorResult INVALID 'Pinned authority does not support consumer-gate-v1; the pin cannot cross a retired interface boundary.'
    }
    Assert-SupervisorExactProperties $Contract.phaseEnvironment @('prepare','validate','finalize','aggregate') 'consumer phase environment'
    foreach($phaseName in @('prepare','validate','finalize','aggregate')){
        $names=@($Contract.phaseEnvironment.$phaseName)
        if($Contract.phaseEnvironment.$phaseName-isnot[array]-or@($names|Select-Object -Unique).Count-ne$names.Count){
            Throw-SupervisorResult INVALID 'Consumer phase environment is invalid.'
        }
        foreach($name in $names){if($name-isnot[string]-or[string]$name-cnotmatch'^[A-Z][A-Z0-9_]*$'){
            Throw-SupervisorResult INVALID 'Consumer phase environment contains an unsafe name.'
        }}
        if($phaseName-cne'prepare'-and@($names|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'}).Count-ne0){
            Throw-SupervisorResult INVALID 'Only prepare may receive a credential environment variable.'
        }
    }
    if(@($Contract.phaseEnvironment.prepare|Where-Object{[string]$_-ceq'STANDARD_VALIDATION_GITHUB_API_TOKEN'}).Count-ne1){
        Throw-SupervisorResult INVALID 'Prepare must declare the resolver token exactly once.'
    }
    if((@($Contract.phaseEnvironment.prepare|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'})-join',')-cne
        'STANDARD_VALIDATION_GITHUB_API_TOKEN'){Throw-SupervisorResult INVALID 'Prepare declares an unsupported credential environment variable.'}
    if((@($Contract.requiredContexts)-join',')-cne'repository-contract,skill-validator,skill-tools'){
        Throw-SupervisorResult INVALID 'Consumer required contexts are invalid.'
    }
    Assert-SupervisorExactProperties $Contract.canonicalEventMap @('pull_request_target','push','pull_request(transition)') `
        'consumer canonical event map'
    if([string]$Contract.canonicalEventMap.pull_request_target-cne'pull_request'-or
        [string]$Contract.canonicalEventMap.push-cne'push'-or
        [string]$Contract.canonicalEventMap.'pull_request(transition)'-cne'pull_request'){
        Throw-SupervisorResult INVALID 'Consumer canonical event map is invalid.'
    }
}
function Import-ConsumerBootstrapSupervisorDependencies([string]$AuthorityRoot){
    $root=[IO.Path]::GetFullPath($AuthorityRoot)
    $expectedModule=Join-Path $root 'scripts/consumer/ConsumerBootstrapSupervisor.psm1'
    if(-not(Test-SupervisorPathEqual $PSCommandPath $expectedModule)){
        Throw-SupervisorResult INVALID 'Consumer bootstrap supervisor was not imported from the verified authority root.'
    }
    if($null-ne$script:SupervisorPlatformRuntime){
        if($script:SupervisorAuthorityRoot-cne$root){Throw-SupervisorResult INVALID 'Consumer bootstrap supervisor authority root changed.'}
        return
    }
    foreach($path in @($expectedModule,(Join-Path $root 'scripts/platform-runtime.psd1'),
            (Join-Path $root 'scripts/consumer/ConsumerGate.psm1'))){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){Throw-SupervisorResult INVALID 'Verified authority supervisor dependency is missing.'}
    }
    $script:SupervisorPlatformRuntime=Import-Module (Join-Path $root 'scripts/platform-runtime.psd1') -Force -PassThru -ErrorAction Stop
    $script:SupervisorConsumerGate=Import-Module (Join-Path $root 'scripts/consumer/ConsumerGate.psm1') -Force -PassThru -ErrorAction Stop
    $script:SupervisorAuthorityRoot=$root
}
function Write-SupervisorTextCreateOnly([string]$Path,[string]$Value,[int]$MaximumBytes=65536){
    $encoding=[Text.UTF8Encoding]::new($false,$true);$text=if($null-eq$Value){''}else{[string]$Value};$bytes=$encoding.GetBytes($text)
    if($bytes.Length-gt$MaximumBytes){
        $suffixBytes=$encoding.GetBytes("`n[TRUNCATED]`n");$length=[Math]::Max(0,$MaximumBytes-$suffixBytes.Length)
        while($length-gt0){try{$text=$encoding.GetString($bytes,0,$length);break}catch [Text.DecoderFallbackException]{$length--}}
        $bytes=$encoding.GetBytes($text+"`n[TRUNCATED]`n")
    }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Write-SupervisorJsonCreateOnly([string]$Path,$Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20)+"`n")
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function New-ConsumerBootstrapEnvironment([string[]]$Allowed,[string]$CurrentPhase,[string]$Token){
    $environment=[Collections.Generic.Dictionary[string,string]]::new($(if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))
    $osNames=@('PATH','Path','PATHEXT','SystemRoot','WINDIR','OS','TEMP','TMP','TMPDIR','HOME','USERPROFILE','HOMEDRIVE','HOMEPATH',
        'APPDATA','LOCALAPPDATA','PROGRAMDATA','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','COMMONPROGRAMFILES',
        'COMMONPROGRAMFILES(X86)','COMMONPROGRAMW6432','COMSPEC','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER','LANG','LC_ALL','LC_CTYPE','DOTNET_ROOT','DOTNET_ROOT_X64','XDG_RUNTIME_DIR','PSExecutionPolicyPreference')
    try{
        foreach($name in $osNames+$Allowed){
            $value=if($name-ceq'STANDARD_VALIDATION_GITHUB_API_TOKEN'-and$CurrentPhase-ceq'prepare'){$Token}else{
                [Environment]::GetEnvironmentVariable($name,'Process')
            }
            try{if($null-ne$value){$environment[$name]=[string]$value}}finally{$value=$null;Remove-Variable value -ErrorAction SilentlyContinue}
        }
        if($CurrentPhase-cne'prepare'){[void]$environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN')}
        $environment
    }finally{
        $Token=$null
        Remove-Variable Token -ErrorAction SilentlyContinue
    }
}
function Invoke-ConsumerGateProcess{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorityRoot,[Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$GatePath,[Parameter(Mandatory)][string]$InterfacePath,
        [Parameter(Mandatory)][ValidateSet('prepare','validate','finalize','aggregate')][string]$CurrentPhase,
        [Parameter(Mandatory)][string]$BindingPath,[Parameter(Mandatory)][string]$BaseRoot,
        [Parameter(Mandatory)][string]$CandidateRoot,[Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][ValidateSet('windows','linux','macos','aggregate')][string]$Platform,
        [switch]$TransitionFromLegacy,[AllowEmptyString()][string]$Token='',
        [ValidateRange(0,7200)][int]$DeadlineOverrideSeconds=0
    )
    Import-ConsumerBootstrapSupervisorDependencies $AuthorityRoot
    $root=[IO.Path]::GetFullPath($AuthorityRoot)
    if(-not(Test-SupervisorPathEqual $GatePath (Join-Path $root 'scripts/consumer/Invoke-ConsumerSourceGate.ps1'))-or
        -not(Test-SupervisorPathEqual $InterfacePath (Join-Path $root 'consumer/consumer-gate-interface.json'))){
        Throw-SupervisorResult INVALID 'Consumer gate code and interface must come from the verified authority root.'
    }
    $contract=Read-SupervisorJson $InterfacePath 'consumer gate interface';Assert-ConsumerBootstrapInterface $contract
    $allowed=@($contract.phaseEnvironment.$CurrentPhase)
    $credentialNames=@($allowed|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'})
    $environment=New-ConsumerBootstrapEnvironment $allowed $CurrentPhase $Token
    $arguments=@('-NoProfile','-NonInteractive','-File',$GatePath,'-Interface','consumer-gate-v1','-Phase',$CurrentPhase,
        '-AuthorityBindingPath',$BindingPath,'-BaseRoot',$BaseRoot,'-CandidateRoot',$CandidateRoot,'-WorkRoot',$WorkRoot,'-Platform',$Platform)
    if($TransitionFromLegacy){$arguments+='-TransitionFromLegacy'}
    $budget=& $script:SupervisorConsumerGate.ExportedCommands['Get-GateDeadlineBudget']
    $phaseBudget=$budget.phaseBudgets.$CurrentPhase
    $deadlineSeconds=if($DeadlineOverrideSeconds-gt0){$DeadlineOverrideSeconds}else{[int]$phaseBudget.gateSeconds+[int]$phaseBudget.supervisorGraceSeconds}
    $diagnosticRoot=Join-Path $WorkRoot 'bootstrap-supervisor-diagnostics';[void][IO.Directory]::CreateDirectory($diagnosticRoot)
    $id="$CurrentPhase-$([guid]::NewGuid().ToString('N'))";$stdoutCapture=Join-Path $diagnosticRoot "$id.capture.stdout"
    $stderrCapture=Join-Path $diagnosticRoot "$id.capture.stderr";$stdoutDiagnostic=Join-Path $diagnosticRoot "$id.stdout.txt"
    $stderrDiagnostic=Join-Path $diagnosticRoot "$id.stderr.txt";$receiptPath=Join-Path $diagnosticRoot "$id.process.json"
    $workingDirectory=$null;$lease=$null;$cleanup=$null;$standardOutput=$null;$standardError=$null;$sentinel=$null
    $credentialLeak=$false;$resultCode=30;$timedOut=$false
    try{
        $physicalWork=& $script:SupervisorPlatformRuntime.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $WorkRoot
        $workingDirectory=& $script:SupervisorPlatformRuntime.ExportedCommands['Open-PlatformDirectory'] -Root $physicalWork -RootOnly
        $physicalExecutable=& $script:SupervisorPlatformRuntime.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $Executable
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds($deadlineSeconds)
        $lease=& $script:SupervisorPlatformRuntime.ExportedCommands['Start-PlatformOwnedProcess'] -ExecutablePath $physicalExecutable `
            -ArgumentList $arguments -Environment $environment -WorkingDirectoryLease $workingDirectory -Deadline $deadline `
            -StdoutPath $stdoutCapture -StderrPath $stderrCapture -OutputLimitCharacters 1048576 -ArgumentZero $physicalExecutable
        while(-not($lease.HasExited-and$lease.CaptureCompletedNaturally)-and$null-eq$lease.Cleanup-and[DateTimeOffset]::UtcNow-lt$deadline){
            Start-Sleep -Milliseconds 25
        }
        $timedOut=[DateTimeOffset]::UtcNow-ge$deadline-or$lease.TerminationReason-ceq'deadline'
        $cleanup=& $script:SupervisorPlatformRuntime.ExportedCommands['Stop-PlatformOwnedProcess'] -Lease $lease `
            -GracePeriod ([TimeSpan]::FromMilliseconds(250)) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(5)) `
            -ExpectedStartIdentity $lease.StartIdentity
        if(-not$cleanup.CleanedUp-or-not$cleanup.CaptureReadersStopped-or-not$cleanup.CaptureResourcesClosed){
            Throw-SupervisorResult FAILED "Gate owned-process cleanup is unconfirmed: $($cleanup.Uncertainty)"
        }
        $expectedIsolation=if($IsWindows){'windows-job-object'}elseif($IsLinux){'linux-process-group-subreaper'}else{'macos-process-group'}
        if([string]$lease.Isolation-cne$expectedIsolation-or[string]$cleanup.Isolation-cne$expectedIsolation){
            Throw-SupervisorResult FAILED 'Gate owned-process isolation does not match the current platform.'
        }
        $standardOutput=[IO.File]::ReadAllText($stdoutCapture,[Text.UTF8Encoding]::new($false,$true))
        $standardError=[IO.File]::ReadAllText($stderrCapture,[Text.UTF8Encoding]::new($false,$true))
        foreach($name in $credentialNames){
            try{$sentinel=[string]$environment[$name]
                if(-not[string]::IsNullOrEmpty($sentinel)-and($standardOutput.Contains($sentinel,[StringComparison]::Ordinal)-or
                    $standardError.Contains($sentinel,[StringComparison]::Ordinal))){$credentialLeak=$true}
            }finally{$sentinel=$null;Remove-Variable sentinel -ErrorAction SilentlyContinue}
        }
        if($credentialLeak){
            Write-SupervisorTextCreateOnly $stdoutDiagnostic ''
            Write-SupervisorTextCreateOnly $stderrDiagnostic 'Gate output contained a credential sentinel and was suppressed.'
            [Console]::Error.WriteLine('Gate output contained a credential sentinel and was suppressed.');$resultCode=20
        }else{
            Write-SupervisorTextCreateOnly $stdoutDiagnostic $standardOutput;Write-SupervisorTextCreateOnly $stderrDiagnostic $standardError
            [Console]::Out.Write($standardOutput);[Console]::Error.Write($standardError)
            if($timedOut){[Console]::Error.WriteLine("Gate exceeded its bounded deadline of $deadlineSeconds seconds.");$resultCode=20}
            elseif($lease.OutputLimitExceeded){[Console]::Error.WriteLine('Gate output exceeded the 1,048,576-character stream limit.');$resultCode=20}
            elseif($lease.TerminationReason-notin@($null,'')){[Console]::Error.WriteLine("Gate owned-process capture failed: $($lease.TerminationReason)");$resultCode=20}
            elseif($lease.ExitCode-isnot[int]-and$lease.ExitCode-isnot[long]){$resultCode=30}
            else{$resultCode=if([int]$lease.ExitCode-in@(0,10,20,30,40)){[int]$lease.ExitCode}else{30}}
        }
        Write-SupervisorJsonCreateOnly $receiptPath ([ordered]@{schemaVersion=1;phase=$CurrentPhase;deadlineSeconds=$deadlineSeconds
            timedOut=$timedOut;outputLimitExceeded=[bool]$lease.OutputLimitExceeded;exitCode=$lease.ExitCode;isolation=$lease.Isolation
            cleanup=[ordered]@{cleanedUp=$cleanup.CleanedUp;captureReadersStopped=$cleanup.CaptureReadersStopped
                captureResourcesClosed=$cleanup.CaptureResourcesClosed;signalsSent=$cleanup.SignalsSent;uncertainty=$cleanup.Uncertainty}})
        $resultCode
    }finally{
        foreach($name in $credentialNames){[void]$environment.Remove([string]$name)}
        $standardOutput=$null;$standardError=$null;$sentinel=$null;$Token=$null;$credentialLeak=$null
        $environment.Clear()
        if($null-ne$lease){$lease.Dispose()};if($null-ne$workingDirectory){$workingDirectory.Dispose()}
        foreach($path in @($stdoutCapture,$stderrCapture)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        Remove-Variable standardOutput,standardError,sentinel,Token,credentialLeak -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('Assert-ConsumerBootstrapInterface','Invoke-ConsumerGateProcess')
