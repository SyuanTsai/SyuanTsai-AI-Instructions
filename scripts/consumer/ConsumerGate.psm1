# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitCodes = @{ BLOCKED = 10
 FAILED = 20
 INVALID = 30
 CANCELLED = 40 }
$script:GatePlatformRuntimeModule = $null
$script:GatePlatformRuntimeAuthorityRoot = $null
$script:GateGitRemainingMilliseconds = $null
$script:GateGitCaptureRoot = $null

function Get-GateDeadlineBudget {
    $resolverAcquisitionSeconds=300
    $resolverProcessGraceSeconds=60
    $testOverride=[string]$env:CONSUMER_GATE_TEST_RESOLVER_TIMEOUT_SECONDS
    if(-not[string]::IsNullOrWhiteSpace($testOverride)){
        if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH)){
            Throw-GateResult INVALID 'Resolver timeout override requires the resolver fixture seam.'
        }
        $parsed=0
        if(-not[int]::TryParse($testOverride,[ref]$parsed)-or$parsed-lt1-or$parsed-gt$resolverAcquisitionSeconds){
            Throw-GateResult INVALID 'Resolver timeout override is invalid.'
        }
        $resolverAcquisitionSeconds=$parsed
        $resolverProcessGraceSeconds=[Math]::Min($resolverProcessGraceSeconds,$parsed)
    }
    $budget=[ordered]@{
        acquisitionRequestDefaultSeconds=100
        acquisitionRequestSeconds=600
        acquisitionRequestCount=3
        resolverAcquisitionSeconds=$resolverAcquisitionSeconds
        resolverInvocationCount=4
        resolverProcessGraceSeconds=$resolverProcessGraceSeconds
        validatorSeconds=1800
        validatorProcessGraceSeconds=120
        gitCommandSeconds=120
        phaseBudgets=[pscustomobject][ordered]@{prepare=[pscustomobject][ordered]@{httpAcquisitionSeconds=1800;resolverSeconds=1440;validatorSeconds=0;gitReserveSeconds=600;totalSeconds=3840};validate=[pscustomobject][ordered]@{httpAcquisitionSeconds=0;resolverSeconds=0;validatorSeconds=1920;gitReserveSeconds=600;totalSeconds=2520};finalize=[pscustomobject][ordered]@{httpAcquisitionSeconds=0;resolverSeconds=0;validatorSeconds=0;gitReserveSeconds=600;totalSeconds=600};aggregate=[pscustomobject][ordered]@{httpAcquisitionSeconds=0;resolverSeconds=0;validatorSeconds=0;gitReserveSeconds=0;totalSeconds=0}}
        workflowSetupSeconds=300
        evidenceBufferSeconds=600
        jobTimeoutMinutes=140
    }
    $budget.innerTotalSeconds=$budget.phaseBudgets.prepare.totalSeconds+
        $budget.phaseBudgets.validate.totalSeconds+$budget.phaseBudgets.finalize.totalSeconds+
        $budget.workflowSetupSeconds
    [pscustomobject]$budget
}

function Import-GatePlatformRuntime([string]$AuthorityRoot) {
    $root=[IO.Path]::GetFullPath($AuthorityRoot)
    if($null-ne$script:GatePlatformRuntimeModule){
        if($script:GatePlatformRuntimeAuthorityRoot-cne$root){Throw-GateResult INVALID 'Platform runtime authority root changed during the gate.'}
        return $script:GatePlatformRuntimeModule
    }
    $manifest=Join-Path $root 'scripts/platform-runtime.psd1'
    if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)){Throw-GateResult INVALID 'Platform runtime manifest is missing.'}
    $script:GatePlatformRuntimeModule=Import-Module $manifest -Force -PassThru -ErrorAction Stop
    $script:GatePlatformRuntimeAuthorityRoot=$root
    $script:GatePlatformRuntimeModule
}

function New-GateChildEnvironment([string[]]$PreserveNames,[string[]]$RemoveNames=@()) {
    $environment=[Collections.Generic.Dictionary[string,string]]::new($(if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))
    if($null-eq$PreserveNames){
        foreach($entry in @(Get-ChildItem Env:)){
            $name=[string]$entry.Name
            if($RemoveNames-icontains$name){continue}
            $value=[string]$entry.Value
            if($null-ne$value){$environment[$name]=$value}
        }
    }else{
        foreach($name in $PreserveNames){
            if($RemoveNames-icontains$name){continue}
            $value=[Environment]::GetEnvironmentVariable($name,'Process')
            if($null-ne$value){$environment[$name]=[string]$value}
        }
    }
    $environment
}

function Throw-GateResult([string]$State, [string]$Message) { throw "$State|$Message" }
function Get-GateSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
function Test-GatePathWithin([string]$Path, [string]$Root) {
    $p=[IO.Path]::GetFullPath($Path)
     $r=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $p.Equals($r,$comparison)-or $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,$comparison)
}
function Assert-GateExactProperties($Value,[string[]]$Expected,[string]$Context) {
    $actual=@($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count -or @($actual|Where-Object{$Expected-cnotcontains $_}).Count-ne 0) { Throw-GateResult INVALID `
        "$Context has an unexpected property set." }
}
function Assert-GateNoDuplicateJson([Text.Json.JsonElement]$Element,[string]$Context) {
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){if(-not$seen.Add($property.Name)){Throw-GateResult INVALID `
            "$Context has duplicate or case-conflicting keys."}
        Assert-GateNoDuplicateJson $property.Value $Context}
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){foreach($item in $Element.EnumerateArray()){Assert-GateNoDuplicateJson $item $Context}}
}
function Read-GateJson([string]$Path,[string]$Context) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){Throw-GateResult INVALID "$Context is missing."}
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){Throw-GateResult INVALID "$Context must be a regular file."}
    $bytes=[IO.File]::ReadAllBytes($item.FullName)
    if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){Throw-GateResult INVALID "$Context has a UTF-8 BOM."}
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-GateNoDuplicateJson $document.RootElement $Context}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }catch{if($_.Exception.Message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|'){throw}
    Throw-GateResult INVALID "$Context is not unambiguous UTF-8 JSON."}
}
function Write-GateJsonCreateOnly([string]$Path,$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 60)+"`n")
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length)
    $stream.Flush($true)}finally{$stream.Dispose()}
}
function Write-GateDiagnosticTextCreateOnly([string]$Path,[string]$Value,[int]$MaximumBytes=65536) {
    if($MaximumBytes-lt1){Throw-GateResult INVALID 'Diagnostic size limit is invalid.'}
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $text=if($null-eq$Value){''}else{[string]$Value}
    $bytes=$encoding.GetBytes($text)
    if($bytes.Length-gt$MaximumBytes){
        $length=$MaximumBytes
        while($length-gt0){try{$text=$encoding.GetString($bytes,0,$length);break}catch [Text.DecoderFallbackException]{$length--}}
        $suffix="`n[TRUNCATED]`n"
        $suffixBytes=$encoding.GetBytes($suffix)
        $available=[Math]::Max(0,$MaximumBytes-$suffixBytes.Length)
        $length=[Math]::Min($length,$available)
        while($length-gt0){try{$text=$encoding.GetString($bytes,0,$length);break}catch [Text.DecoderFallbackException]{$length--}}
        $bytes=$encoding.GetBytes($text+$suffix)
    }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-GateActiveSkills([string]$CandidateRoot) {
    $paths=@((Invoke-GateGit $CandidateRoot @('ls-files','--','skills/*/SKILL.md')).Output|ForEach-Object{[string]$_}|Where-Object{`
        $_-match'^skills/([^/]+)/SKILL\.md$'}|ForEach-Object{$Matches[1]}|Sort-Object -Unique)
    if($paths.Count-eq0){Throw-GateResult INVALID 'Tracked snapshot contains no active Skill.'}
    [string[]]$paths
}
function Test-GateBytesEqual([string]$Left,[string]$Right) {
    if(-not(Test-Path -LiteralPath $Left -PathType Leaf)-or-not(Test-Path -LiteralPath $Right -PathType Leaf)){return $false}
    foreach($path in @($Left,$Right)){$item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){return $false}}
    (Get-GateSha256 $Left)-ceq(Get-GateSha256 $Right)
}
# The shrink-only exception gate is defined near the end of this module.
# This five-line placeholder keeps unrelated exception helpers out of earlier code.
# UnitT32 records exact cleanup locations and must move with intentional edits.
# Keep new exception-gate helpers immediately before Export-ModuleMember.
# Do not add or remove lines in this placeholder.
function Copy-GateTrustedFile([string]$Source,[string]$Destination) {
    if(Test-Path -LiteralPath $Destination){Throw-GateResult FAILED 'Trusted runtime file destination already exists.'}
    [IO.File]::Copy($Source,$Destination,$false)
    if((Get-GateSha256 $Source)-cne(Get-GateSha256 $Destination)){Throw-GateResult FAILED 'Trusted runtime file copy changed bytes.'}
}
function Write-GateBoundaryEvent([string]$Event) {
    $path=[string]$env:CONSUMER_GATE_EVENT_LOG_PATH
    if([string]::IsNullOrWhiteSpace($path)){return}
    $full=[IO.Path]::GetFullPath($path)
    [IO.File]::AppendAllText($full,"$Event`n",[Text.UTF8Encoding]::new($false))
}
function Get-GateReleaseAssetName([string]$Version,[string]$Platform) {
    $architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if($architecture-cnotin@('x64','arm64')){Throw-GateResult INVALID 'Unsupported runner architecture.'}
    if($Platform-ceq'windows'){"PowerShell-$Version-win-$architecture.zip"}elseif($Platform-ceq'linux'){`
        "powershell-$Version-linux-$architecture.tar.gz"}else{"powershell-$Version-osx-$architecture.tar.gz"}
}
function Install-GatePowerShell([string]$AuthorityRoot,[string]$WorkRoot,[string]$Platform,[string]$Token) {
    $runtimeRoot=Join-Path $WorkRoot 'runtime'
    $pwshRoot=Join-Path $runtimeRoot 'pwsh'
    $downloads=Join-Path $runtimeRoot 'downloads'
    foreach($path in @($runtimeRoot,$pwshRoot,$downloads)){[IO.Directory]::CreateDirectory($path)|Out-Null}
    $headers=@{'User-Agent'='consumer-gate-v1'
    Accept='application/vnd.github+json'}
    if(-not[string]::IsNullOrEmpty($Token)){$headers.Authorization="Bearer $Token"}
    try{
        $metadataUri=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_POWERSHELL_METADATA_URI)){
            [uri]'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        }else{[uri]$env:CONSUMER_GATE_POWERSHELL_METADATA_URI}
        $fixtureAcquisition=$metadataUri.Host-ceq'127.0.0.1'
        $metadataHosts=if($fixtureAcquisition){@('127.0.0.1')}else{@('api.github.com')}
        $assetHosts=if($fixtureAcquisition){@('127.0.0.1')}else{@('github.com','release-assets.githubusercontent.com')}
        $release=Invoke-GateAcquisitionRequest metadata $metadataUri $headers $null $metadataHosts $metadataUri.Host $fixtureAcquisition
        if($release.draft-or$release.prerelease-or[string]$release.tag_name-cnotmatch'^v([0-9]+\.[0-9]+\.[0-9]+)$'){Throw-GateResult FAILED `
            'Latest official PowerShell release metadata is not stable.'}
        $version=$Matches[1]
        $assetName=Get-GateReleaseAssetName $version $Platform
        $asset=@($release.assets|Where-Object{[string]$_.name-ceq$assetName})
        $hashAsset=@($release.assets|Where-Object{[string]$_.name-ceq'hashes.sha256'})
        if($asset.Count-ne1-or$hashAsset.Count-ne1){Throw-GateResult FAILED 'Official PowerShell release assets are incomplete.'}
        $releasePrefix=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_POWERSHELL_METADATA_URI)){
            "https://github.com/PowerShell/PowerShell/releases/download/v$version/"
        }else{"$($metadataUri.Scheme)://$($metadataUri.Authority)/"}
        if(-not([string]$asset[0].browser_download_url).StartsWith($releasePrefix,[StringComparison]::Ordinal)-or-not(`
            [string]$hashAsset[0].browser_download_url).StartsWith($releasePrefix,[StringComparison]::Ordinal)){Throw-GateResult FAILED`
                'PowerShell release assets are not on the approved official endpoint.'}
        $archive=Join-Path $downloads $assetName
        $hashes=Join-Path $downloads 'hashes.sha256'
        [void](Invoke-GateAcquisitionRequest download ([uri][string]$hashAsset[0].browser_download_url) $headers $hashes $assetHosts '' $fixtureAcquisition)
        [void](Invoke-GateAcquisitionRequest download ([uri][string]$asset[0].browser_download_url) $headers $archive $assetHosts '' $fixtureAcquisition)
        $line=@([IO.File]::ReadAllLines($hashes)|Where-Object{$_-match("^([0-9a-f]{64})\s+\*?"+[regex]::Escape($assetName)+"$")})
        if($line.Count-ne1){Throw-GateResult FAILED 'Official PowerShell hashes do not bind the selected asset.'}
        $sha=$line[0].Substring(0,64)
        if((Get-GateSha256 $archive)-cne$sha){Throw-GateResult FAILED 'Downloaded PowerShell archive hash differs from the official manifest.'}
    }finally{$headers.Remove('Authorization')
    $Token=$null
    [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')
    Remove-Variable Token -ErrorAction SilentlyContinue}
    $policy = @{version=$version
    assets=@(@{name=$assetName
    sha256=$sha})}
    $runtimeSourceRoot=[string]$env:CONSUMER_GATE_RUNTIME_SOURCE_ROOT
    if(-not[string]::IsNullOrWhiteSpace($runtimeSourceRoot)){
        $runtimeSourceRoot=[IO.Path]::GetFullPath($runtimeSourceRoot)
        if(-not(Test-Path -LiteralPath $runtimeSourceRoot -PathType Container)){Throw-GateResult INVALID 'Fixture runtime source root is invalid.'}
        foreach($file in @(Get-ChildItem -LiteralPath $runtimeSourceRoot -Recurse -File -Force)){
            if(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$file.LinkType){continue}
            $relative=[IO.Path]::GetRelativePath($runtimeSourceRoot,$file.FullName)
            $target=Join-Path $pwshRoot $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy($file.FullName,$target,$true)
        }
        $relativeExecutable=[string]$env:CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH
        if([string]::IsNullOrWhiteSpace($relativeExecutable)){$relativeExecutable=[IO.Path]::GetFileName((Get-Process -Id $PID).Path)}
        $fixtureExecutable=[IO.Path]::GetFullPath((Join-Path $pwshRoot $relativeExecutable))
        if(-not(Test-GatePathWithin $fixtureExecutable $pwshRoot)-or-not(Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)){
            Throw-GateResult INVALID 'Fixture runtime executable source is invalid.'
        }
        $receipt=[pscustomobject]@{executablePath=$fixtureExecutable;executableSha256=Get-GateSha256 $fixtureExecutable
            version=$version;archiveSha256=$sha}
    }else{
        Import-Module (Join-Path $AuthorityRoot 'scripts/platform-runtime.psd1') -Force
        $lease=Open-PlatformDirectory -Root (Resolve-PlatformPhysicalPath -Path $pwshRoot) -RootOnly
        try{$receipt=Resolve-PlatformPowerShell -Policy $policy -DestinationLease $lease -OfflineCache $archive `
            -ReleaseMetadata @{assets=@(@{name=$assetName
            sha256=$sha})}}finally{$lease.Dispose()}
    }
    Write-GateBoundaryEvent 'runtime-installed'
    $receipt
}
function Invoke-GateResolver([string]$PowerShell,[string]$AuthorityRoot,[string]$InstallRoot,[string]$Tool,[string]$RunId,[string]$OutputPath,`
    [string]$GoVersion,[string]$Token) {
    try{
        $budget=Get-GateDeadlineBudget
        $resolverPath=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH)){
            Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
        }else{[IO.Path]::GetFullPath($env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH)}
        if(-not(Test-Path -LiteralPath $resolverPath -PathType Leaf)){Throw-GateResult INVALID 'Resolver executable source is invalid.'}
        $arguments = @('-NoProfile','-NonInteractive','-File',$resolverPath,
            '-PolicyPath',(Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json'),'-ToolName',$Tool,'-Install',
            '-InstallRoot',$InstallRoot,'-ExpectedGoRuntimeVersion',$GoVersion,'-RunId',$RunId,'-OutputPath',$OutputPath,
            '-AcquisitionTimeoutSeconds',([string]$budget.resolverAcquisitionSeconds))
        $preservedNames=@('PATH','Path','PATHEXT','SystemRoot','WINDIR','TEMP','TMP','TMPDIR','HOME','USERPROFILE','PSModulePath',
            'PSExecutionPolicyPreference','ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','LOCALAPPDATA','APPDATA')
        $environment=New-GateChildEnvironment $preservedNames
        if(-not[string]::IsNullOrEmpty($Token)){$environment['STANDARD_VALIDATION_GITHUB_API_TOKEN']=$Token}
        $runtime=Import-GatePlatformRuntime $AuthorityRoot
        $standardOutput='';$standardError='';$executionFailure=$null;$exitCode=$null;$credentialLeak=$false
        try{
            try{
                $result=& $runtime.ExportedCommands['Invoke-PlatformPreparationCommand'] -Command $PowerShell -Arguments $arguments `
                    -Environment $environment -WorkingDirectory (Split-Path -Parent $OutputPath) `
                    -TimeoutMilliseconds (($budget.resolverAcquisitionSeconds+$budget.resolverProcessGraceSeconds)*1000)
                $standardOutput=[string]$result.stdout;$standardError=[string]$result.stderr;$exitCode=$result.exitCode
            }catch{$executionFailure=$_;$standardError=[string]$_.Exception.Message}
            $credentialLeak=-not[string]::IsNullOrEmpty($Token)-and($standardOutput.Contains($Token,[StringComparison]::Ordinal)-or
                $standardError.Contains($Token,[StringComparison]::Ordinal))
            if(-not[string]::IsNullOrEmpty($Token)){$standardOutput=$standardOutput.Replace($Token,'[REDACTED]');$standardError=$standardError.Replace($Token,'[REDACTED]')}
            $diagnostics=Join-Path (Split-Path -Parent $OutputPath) 'diagnostics'
            [void][IO.Directory]::CreateDirectory($diagnostics)
            Write-GateDiagnosticTextCreateOnly (Join-Path $diagnostics "resolver-$Tool.stdout.txt") $standardOutput
            Write-GateDiagnosticTextCreateOnly (Join-Path $diagnostics "resolver-$Tool.stderr.txt") $standardError
            [Console]::Out.Write($standardOutput);[Console]::Error.Write($standardError)
            if($credentialLeak){Throw-GateResult FAILED 'Resolver output contained a credential sentinel.'}
            if($null-ne$executionFailure){Throw-GateResult FAILED "Resolver owned process failed for $Tool. $standardError Diagnostics were preserved."}
            if($exitCode-isnot[int]-and$exitCode-isnot[long]){Throw-GateResult FAILED 'Resolver exit status is unknown.'};if($exitCode-ne0){Throw-GateResult FAILED "Resolver failed for $Tool. Diagnostics were preserved."}
        }finally{
            [void]$environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN');$environment.Clear()
            $standardOutput=$null;$standardError=$null;$credentialLeak=$null;$executionFailure=$null;$result=$null;$runtime=$null;$Token=$null
            Remove-Variable standardOutput,standardError,credentialLeak,executionFailure,result,runtime,environment,Token -ErrorAction SilentlyContinue
        }
    }finally{foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $Token=$null
    Remove-Variable Token -ErrorAction SilentlyContinue}
    Read-GateJson $OutputPath "$Tool resolver receipt"
}
function New-GateSourceSetup([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$PowerShell,[string]$RunId,`
    [string]$AuthorityRevision,[string]$CandidateRevision,[string]$SourceRepository,[string]$Token) {
    try {
    $setupRoot=Join-Path $WorkRoot 'source-tools'
    [IO.Directory]::CreateDirectory($setupRoot)|Out-Null
    $installRoot=Join-Path $WorkRoot 'runtime/installed'
    [IO.Directory]::CreateDirectory($installRoot)|Out-Null
    $goVersion=[string]$env:STANDARD_GO_RUNTIME_VERSION
    if([string]::IsNullOrWhiteSpace($goVersion)){$goVersion='latest'}
    $receipts=@{}
    $bindings=@()
    foreach($tool in @('pester','skill-validator','skill-tools','skillspector')){
        $path=Join-Path $setupRoot ("receipt-$tool.json")
        $receipts[$tool]=Invoke-GateResolver $PowerShell $AuthorityRoot $installRoot $tool $RunId $path $goVersion $Token
        if($tool-cne'pester'){$bindings+= [pscustomobject]@{path=[IO.Path]::GetFullPath($path)
        sha256=Get-GateSha256 $path}}
    }
    $trustedRoot=Join-Path $WorkRoot 'runtime/trusted'
    [IO.Directory]::CreateDirectory($trustedRoot)|Out-Null
    $child=Join-Path $trustedRoot 'Invoke-ConsumerValidationChild.ps1'
    Copy-GateTrustedFile (Join-Path $AuthorityRoot 'scripts/consumer/Invoke-ConsumerValidationChild.ps1') $child
    $repositoryCheck=Join-Path $trustedRoot 'Invoke-ConsumerRepositoryCheck.ps1'
    Copy-GateTrustedFile (Join-Path $AuthorityRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1') $repositoryCheck
    $archive=Join-Path $setupRoot 'candidate.zip'
    [void](Invoke-GateGit $CandidateRoot @('archive','--format=zip',"--output=$archive",$CandidateRevision))
    $toolchain=[ordered]@{
        centralRunnerPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'))
        centralRunnerSha256=Get-GateSha256 (Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1')
        upstreamAdapterValidatorPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1'))
        upstreamAdapterValidatorSha256=Get-GateSha256 (Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1')
        upstreamPolicyPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json'))
        upstreamPolicySha256=Get-GateSha256 (Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json')
        skillValidatorPath=[string]$receipts.'skill-validator'.executablePath
        skillValidatorSha256=[string]$receipts.'skill-validator'.executableSha256
        skillToolsNodePath=[string]$receipts.'skill-tools'.nodePath
        skillToolsNodeSha256=[string]$receipts.'skill-tools'.nodeSha256
        skillToolsEntryPointPath=[string]$receipts.'skill-tools'.entryPointPath
        skillToolsEntryPointSha256=[string]$receipts.'skill-tools'.entryPointSha256
        skillSpectorPath=[string]$receipts.skillspector.executablePath
        skillSpectorSha256=[string]$receipts.skillspector.executableSha256
        pesterModulePath=[string]$receipts.pester.modulePath
        pesterModuleSha256=[string]$receipts.pester.executableSha256
        pesterVersion=[string]$receipts.pester.resolvedVersion
    }
    $toolchainPath=Join-Path $setupRoot 'toolchain.json'
    Write-GateJsonCreateOnly $toolchainPath $toolchain
    $common=@('-NoProfile','-NonInteractive','-File',$child,'-ToolchainPath',$toolchainPath,'-ToolchainSha256',(Get-GateSha256 $toolchainPath),`
        '-SourceRepository',$SourceRepository,'-SourceRevision',$CandidateRevision,'-ArchiveSha256',(Get-GateSha256 $archive))
    $frozenPaths=@($PowerShell,$child,$repositoryCheck,$toolchainPath,$toolchain.centralRunnerPath,$toolchain.upstreamAdapterValidatorPath,`
        $toolchain.upstreamPolicyPath,$toolchain.skillValidatorPath,$toolchain.skillToolsNodePath,$toolchain.skillToolsEntryPointPath,`
            $toolchain.skillSpectorPath,$toolchain.pesterModulePath)+@($bindings.path)
    $frozen=@($frozenPaths|Select-Object -Unique|ForEach-Object{[pscustomobject]@{path=[IO.Path]::GetFullPath([string]$_)
    sha256=Get-GateSha256([string]$_)}})
    $dispatch=[ordered]@{packageAdapter=@{command=$PowerShell
    arguments=@($common+@('-Mode','package-adapter'))}
    skillValidator=@{command=$PowerShell
    arguments=@($common+@('-Mode','skill-validator'))}
    skillTools=@{command=$PowerShell
    arguments=@($common+@('-Mode','skill-tools'))}
    staticAnalyzer=@{command=$PowerShell
    arguments=@($common+@('-Mode','static'))}
    frozenFiles=$frozen
    toolReceipts=$bindings}
    $prepared=[ordered]@{schemaVersion=1
    report='consumer-source-tools-v1'
    runId=$RunId
    sourceRevision=$CandidateRevision
    authorityRevision=$AuthorityRevision
    ownedRoot=$setupRoot
    trustedRoot=(Join-Path $WorkRoot 'runtime')
    repositoryCheck=$repositoryCheck
    pesterReceiptSha256=Get-GateSha256 (Join-Path $setupRoot 'receipt-pester.json')
    pesterManifestSha256=[string]$toolchain.pesterModuleSha256
    pesterVersion=[string]$toolchain.pesterVersion
    sourceValidation=$dispatch}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'source-tools.json') $prepared
    Write-GateBoundaryEvent 'source-tools-prepared'
    $prepared
    } finally {
        foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
            [Environment]::SetEnvironmentVariable($name,$null,'Process')
        }
        $Token=$null
        Remove-Variable Token -ErrorAction SilentlyContinue
    }
}
function Invoke-GateCredentialScopedPreparation([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,`
    [string]$Platform,$Binding,[string]$EventRepository,[string]$Token) {
    $failure=$null
    $scanFailure=$null
    $result=$null
    try{
        $runtime=Install-GatePowerShell $AuthorityRoot $WorkRoot $Platform $Token
        $receipt=[ordered]@{schemaVersion=1
        report='consumer-runtime-receipt-v1'
        executablePath=[string]$runtime.executablePath
        executableSha256=[string]$runtime.executableSha256
        version=[string]$runtime.version
        archiveSha256=[string]$runtime.archiveSha256}
        Write-GateJsonCreateOnly (Join-Path $WorkRoot 'runtime/consumer-runtime-receipt.json') $receipt
        $result=New-GateSourceSetup $AuthorityRoot $CandidateRoot $WorkRoot ([string]$runtime.executablePath) `
            ([string]$Binding.runId) ([string]$Binding.commit) ([string]$Binding.candidateRevision) $EventRepository $Token
    }catch{$failure=$_}finally{
        foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        try{Assert-GateCredentialAbsent $WorkRoot $Token}catch{$scanFailure=$_}finally{
            $runtime=$null;$receipt=$null;$Token=$null
            Remove-Variable runtime,receipt,Token -ErrorAction SilentlyContinue
        }
    }
    if($null-ne$failure){throw $failure}
    if($null-ne$scanFailure){throw $scanFailure}
    $result
}
function New-GateAdapter([string]$Path,$Config,$Setup,[string]$PowerShell) {
    $executable=[IO.Path]::GetFullPath($PowerShell)
    $executableSha256=Get-GateSha256 $executable
    $repositoryCheck=[IO.Path]::GetFullPath([string]$Setup.repositoryCheck)
    $checks=@(
        [ordered]@{id='repository-general'
        kind='general'
        executable=$executable
        executableSha256=$executableSha256
        arguments=@('-NoProfile','-NonInteractive','-File',$repositoryCheck,'-Mode','general')},
        [ordered]@{id='repository-pester'
        kind='pester'
        executable=$executable
        executableSha256=$executableSha256
        arguments=@('-NoProfile','-NonInteractive','-File',$repositoryCheck,'-Mode','pester','-PesterReceiptSha256',[string]$Setup.pesterReceiptSha256,'-PesterManifestSha256',`
            [string]$Setup.pesterManifestSha256,'-PesterVersion',[string]$Setup.pesterVersion)}
    )
    Assert-GateAdapterExecutableBindings -Checks $checks -Setup $Setup -PowerShell $PowerShell
    Write-GateJsonCreateOnly $Path([ordered]@{schemaVersion=2
    adapter='standard-core-adapter-v2'
    skillsRoot='skills'
    activeSkills=@($Config.activeSkills)
    checks=$checks
    sourceValidation=$Setup.sourceValidation})
}
function Assert-GateAdapterExecutableBindings([object[]]$Checks,$Setup,[string]$PowerShell) {
    $repositoryCheck=[IO.Path]::GetFullPath([string]$Setup.repositoryCheck)
    $expected=[IO.Path]::GetFullPath((Join-Path ([string]$Setup.trustedRoot) 'trusted/Invoke-ConsumerRepositoryCheck.ps1'))
    $powerShellPath=[IO.Path]::GetFullPath($PowerShell)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$repositoryCheck.Equals($expected,$comparison)-or-not(Test-Path -LiteralPath $repositoryCheck -PathType Leaf)){
        Throw-GateResult INVALID 'Setup does not bind the trusted repository check path.'
    }
    if(-not(Test-GatePathWithin $powerShellPath ([string]$Setup.trustedRoot))-or-not(Test-Path -LiteralPath $powerShellPath -PathType Leaf)-or
        -not[IO.Path]::GetFileName($powerShellPath).Equals($(if($IsWindows){'pwsh.exe'}else{'pwsh'}),[StringComparison]::OrdinalIgnoreCase)){
        Throw-GateResult INVALID 'Setup does not bind a trusted pwsh runtime.'
    }
    $repositoryCheckHash=Get-GateSha256 $repositoryCheck
    $powerShellHash=Get-GateSha256 $powerShellPath
    $sourceValidationProperty=$Setup.PSObject.Properties['sourceValidation']
    $frozenFilesProperty=if($null-ne$sourceValidationProperty-and$null-ne$sourceValidationProperty.Value){
        $sourceValidationProperty.Value.PSObject.Properties['frozenFiles']
    }else{$null}
    if($null-eq$frozenFilesProperty-or$frozenFilesProperty.Value-isnot[array]){
        Throw-GateResult INVALID 'Setup source validation must bind a frozenFiles array.'
    }
    $frozenFiles=@($frozenFilesProperty.Value)
    foreach($binding in @(@{Path=$repositoryCheck;Hash=$repositoryCheckHash;Name='repository check'},
            @{Path=$powerShellPath;Hash=$powerShellHash;Name='pwsh runtime'})){
        $frozen=@($frozenFiles|Where-Object{
                [IO.Path]::GetFullPath([string]$_.path).Equals([string]$binding.Path,$comparison)})
        if($frozen.Count-ne1-or[string]$frozen[0].sha256-cne[string]$binding.Hash){
            Throw-GateResult INVALID "Setup does not bind the trusted $($binding.Name) hash exactly once."
        }
    }
    $expectedChecks=@{
        'repository-general'=@{Kind='general';Arguments=@('-NoProfile','-NonInteractive','-File',$repositoryCheck,'-Mode','general')}
        'repository-pester'=@{Kind='pester';Arguments=@('-NoProfile','-NonInteractive','-File',$repositoryCheck,'-Mode','pester','-PesterReceiptSha256',
            [string]$Setup.pesterReceiptSha256,'-PesterManifestSha256',[string]$Setup.pesterManifestSha256,
            '-PesterVersion',[string]$Setup.pesterVersion)}
    }
    if($Checks.Count-ne$expectedChecks.Count){Throw-GateResult INVALID 'Consumer adapter must contain exactly the two trusted repository checks.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($check in $Checks){
        $id=[string]$check.id
        $expectedCheck=$expectedChecks[$id]
        if($null-eq$expectedCheck-or-not$seen.Add($id)-or[string]$check.kind-cne[string]$expectedCheck.Kind-or
            -not[IO.Path]::GetFullPath([string]$check.executable).Equals($powerShellPath,$comparison)-or
            [string]$check.executableSha256-cne$powerShellHash-or
            $check.arguments-isnot[array]-or(@([string[]]$check.arguments)-join"`n")-cne(@([string[]]$expectedCheck.Arguments)-join"`n")){
            Throw-GateResult INVALID "Core check '$id' does not bind the trusted pwsh -File repository check."
        }
    }
}
function Invoke-GateValidation([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,$Config,[string]$PowerShell) {
    $budget=Get-GateDeadlineBudget
    $setup=Read-GateJson (Join-Path $WorkRoot 'source-tools.json') 'source tool setup'
    $adapter=Join-Path $WorkRoot 'consumer-core-adapter.json'
    New-GateAdapter $adapter $Config $setup $PowerShell
    $adapterValue=Read-GateJson $adapter 'consumer core adapter'
    Assert-GateAdapterExecutableBindings -Checks @($adapterValue.checks) -Setup $setup -PowerShell $PowerShell
    $artifacts=Join-Path $WorkRoot 'validation-artifacts'
    [IO.Directory]::CreateDirectory($artifacts)|Out-Null
    $output=Join-Path $artifacts 'consumer-core-evidence.json'
    $arguments=@('-NoProfile','-NonInteractive','-File',(Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'),'-CandidateRoot',
        $CandidateRoot,'-AdapterPath',$adapter,'-ArtifactsRoot',$artifacts,'-OutputPath',$output,'-SourceRepository',
        ([string]$Config.sourceRepository),'-SourceRevision',([string]$Binding.candidateRevision),'-BaseRevision',([string]$Binding.baseRevision),
        '-EventName',([string]$Binding.canonicalEvent),'-RunId',([string]$Binding.runId),'-AuthorityRevision',([string]$Binding.commit),
        '-TrustedToolRoot',([string]$setup.trustedRoot),'-SourceValidation','-TimeoutSeconds',([string]$budget.validatorSeconds))
    $credentialNames=@('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')
    $environment=New-GateChildEnvironment $null $credentialNames
    $runtime=Import-GatePlatformRuntime $AuthorityRoot
    $standardOutput='';$standardError='';$executionFailure=$null;$exitCode=$null
    try{
        try{
            $result=& $runtime.ExportedCommands['Invoke-PlatformPreparationCommand'] -Command $PowerShell -Arguments $arguments `
                -Environment $environment -WorkingDirectory $WorkRoot `
                -TimeoutMilliseconds (($budget.validatorSeconds+$budget.validatorProcessGraceSeconds)*1000)
            $standardOutput=[string]$result.stdout;$standardError=[string]$result.stderr;$exitCode=$result.exitCode
        }catch{$executionFailure=$_;$standardError=[string]$_.Exception.Message}
        Write-GateDiagnosticTextCreateOnly (Join-Path $artifacts 'validator.stdout.txt') $standardOutput
        Write-GateDiagnosticTextCreateOnly (Join-Path $artifacts 'validator.stderr.txt') $standardError
        [Console]::Out.Write($standardOutput);[Console]::Error.Write($standardError)
        if($null-ne$executionFailure){Throw-GateResult FAILED "Validator owned process failed. $standardError Diagnostics were preserved."}
        if($exitCode-isnot[int]-and$exitCode-isnot[long]){Throw-GateResult FAILED 'Validator exit status is unknown.'};if($exitCode-ne0){Throw-GateResult FAILED "Validator failed with exit code $exitCode. Diagnostics were preserved."}
    }finally{$environment.Clear();$standardOutput=$null;$standardError=$null;$executionFailure=$null;$result=$null;$runtime=$null
        Remove-Variable standardOutput,standardError,executionFailure,result,runtime,environment -ErrorAction SilentlyContinue}
    $report=Read-GateJson $output 'source validation evidence'
    if([string]$report.state-cne'PASS'-or[bool]$report.releaseEligible){Throw-GateResult FAILED 'Source validation evidence is not a passing source result.'}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'validated-report-binding.json') ([ordered]@{schemaVersion=1
    runId=[string]$Binding.runId
    candidateRevision=[string]$Binding.candidateRevision
    baseRevision=[string]$Binding.baseRevision
    authorityCommit=[string]$Binding.commit
    canonicalEvent=[string]$Binding.canonicalEvent
    evidenceSha256=Get-GateSha256 $output})
}
function Assert-GateFinalSourceReport([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,$Report,[string]$EvidencePath) {
    $runner=Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
    . $runner -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath (Join-Path $WorkRoot 'consumer-core-adapter.json') `
        -ArtifactsRoot (Join-Path $WorkRoot 'validation-artifacts') -OutputPath $EvidencePath -SourceRepository ([string]$env:CONSUMER_GATE_EVENT_REPOSITORY) `
        -SourceRevision ([string]$Binding.candidateRevision) -BaseRevision ([string]$Binding.baseRevision)
    $security=Read-GateJson (Join-Path $AuthorityRoot 'docs/standards/validation-security-gate.json') 'validation security policy'
    $stages=@($security.stages|Where-Object{[string]$_.id-ceq'skillspector-static'})
    if($stages.Count-ne1-or$null-eq$stages[0].platformUnavailableException){Throw-GateResult INVALID `
        'Validation security policy has no unique platformUnavailableException contract.'}
    Assert-StandardCoreSourceCheckReport -Report $Report -ExpectedSourceRevision([string]$Binding.candidateRevision) `
        -ExpectedBaseRevision([string]$Binding.baseRevision) -ExpectedAuthorityRevision([string]$Binding.commit) `
        -ExpectedEventName ([string]$Binding.canonicalEvent) -ArtifactsRoot (Join-Path $WorkRoot 'validation-artifacts') `
        -OutputPath $EvidencePath -ProcessExitCode 0 -ValidationSecurityPolicy $stages[0].platformUnavailableException
    Assert-GateExceptionScannerTransitionEvidence $AuthorityRoot $CandidateRoot ([string]$Binding.baseRevision) `
        ([string]$Binding.candidateRevision) $Report (Join-Path $WorkRoot 'validation-artifacts')
    Write-GateBoundaryEvent 'source-report-asserted'
}
function Assert-GatePlatformTestInventory($Inventory) {
    Assert-GateExactProperties $Inventory @('sha256','caseDiscoveryCount','caseExecutionCount','testFileInventory','containerFileInventory',`
        'discoveredCaseFileInventory') 'platform test inventory'
    $discoveryIsInteger=$Inventory.caseDiscoveryCount-is[int]-or$Inventory.caseDiscoveryCount-is[long]
    $executionIsInteger=$Inventory.caseExecutionCount-is[int]-or$Inventory.caseExecutionCount-is[long]
    if([string]$Inventory.sha256-cnotmatch'^[0-9a-f]{64}$'-or-not$discoveryIsInteger-or-not$executionIsInteger-or
        [long]$Inventory.caseDiscoveryCount-lt1-or[long]$Inventory.caseExecutionCount-ne[long]$Inventory.caseDiscoveryCount){Throw-GateResult `
            FAILED 'Platform test inventory counts are invalid.'}
    foreach($name in @('testFileInventory','containerFileInventory','discoveredCaseFileInventory')){
        $values=@($Inventory.$name)
        if($Inventory.$name-isnot[array]-or$values.Count-lt1-or@($values|Where-Object{$_-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$_)`
            }).Count-ne0-or@($values|Select-Object -Unique).Count-ne$values.Count){Throw-GateResult FAILED "Platform test inventory is invalid: $name"}
    }
}
function Assert-GatePesterCaseLedger($Ledger,$Binding) {
    $expected=@('schemaVersion','report','coreRunId','candidateSnapshotIdentity','candidateSnapshotSha256',`
        'pesterModule','runPath','runScope','testFileInventory','containerFileInventory','discoveredCaseFileInventory',`
        'caseDiscoveryCount','caseExecutionCount','containerCount','failedBlockCount','failedContainerCount','terminalStatus',`
        'reportedCounts','shardIdentity','shardCaseIdentities','shardUnion','discoveryCases','executionCases','complete','errors')
    $actual=@($Ledger.PSObject.Properties.Name)
    if($actual.Count-ne$expected.Count-or(@($actual|Sort-Object)-join"`n")-cne(@($expected|Sort-Object)-join"`n")){
        Throw-GateResult FAILED 'Source Pester case inventory ledger has an unexpected property set.'
    }
    $discoveryIsInteger=$Ledger.caseDiscoveryCount-is[int]-or$Ledger.caseDiscoveryCount-is[long]
    $executionIsInteger=$Ledger.caseExecutionCount-is[int]-or$Ledger.caseExecutionCount-is[long]
    if($Ledger.schemaVersion-ne1-or[string]$Ledger.report-cne'standard-core-pester-case-inventory-v1'-or
        [string]$Ledger.coreRunId-cne[string]$Binding.runId-or-not$discoveryIsInteger-or-not$executionIsInteger-or
        [long]$Ledger.caseDiscoveryCount-lt1-or[long]$Ledger.caseExecutionCount-ne[long]$Ledger.caseDiscoveryCount){
        Throw-GateResult FAILED 'Source Pester case inventory ledger binding or counts are invalid.'
    }
}
function Write-GateLegReceipt([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,[string]$Platform) {
    $evidencePath=Join-Path $WorkRoot 'validation-artifacts/consumer-core-evidence.json'
    $report=Read-GateJson $evidencePath 'source validation evidence'
    Assert-GateFinalSourceReport $AuthorityRoot $CandidateRoot $WorkRoot $Binding $report $evidencePath
    $validated=Read-GateJson (Join-Path $WorkRoot 'validated-report-binding.json') 'validated report binding'
    Assert-GateExactProperties $validated @('schemaVersion','runId','candidateRevision','baseRevision','authorityCommit','canonicalEvent',`
        'evidenceSha256') 'validated report binding'
    if($validated.schemaVersion-ne1){Throw-GateResult FAILED 'Validated source report binding schema is invalid.'}
    foreach($pair in @(@('runId',[string]$Binding.runId),@('candidateRevision',[string]$Binding.candidateRevision),@('baseRevision',`
        [string]$Binding.baseRevision),@('authorityCommit',[string]$Binding.commit),@('canonicalEvent',[string]$Binding.canonicalEvent),@(`
            'evidenceSha256',(Get-GateSha256 $evidencePath)))){if([string]$validated.($pair[0])-cne[string]$pair[1]){Throw-GateResult FAILED`
                "Validated source report binding changed: $($pair[0])"}}
    $caseBinding=$report.sourceValidation.pesterCaseInventory
    Assert-GateExactProperties $caseBinding @('path','sha256') 'source Pester case inventory binding'
    $casePath=[string]$caseBinding.path
    if(-not(Test-GatePathWithin $casePath (Join-Path $WorkRoot 'validation-artifacts'))-or(Get-GateSha256 $casePath)`
        -cne[string]$caseBinding.sha256){Throw-GateResult FAILED 'Source Pester case inventory changed after validation.'}
    $cases=Read-GateJson $casePath 'source Pester case inventory'
    Assert-GatePesterCaseLedger $cases $Binding
    $inventory=[ordered]@{sha256=[string]$caseBinding.sha256
    caseDiscoveryCount=[long]$cases.caseDiscoveryCount
    caseExecutionCount=[long]$cases.caseExecutionCount
    testFileInventory=@($cases.testFileInventory)
    containerFileInventory=@($cases.containerFileInventory)
    discoveredCaseFileInventory=@($cases.discoveredCaseFileInventory)}
    Assert-GatePlatformTestInventory ([pscustomobject]$inventory)
    $receipt=[ordered]@{schemaVersion=1
    report='consumer-gate-leg-receipt-v1'
    result='PASS'
    platform=$Platform
    runId=[string]$Binding.runId
    candidateRevision=[string]$Binding.candidateRevision
    headRevision=[string]$Binding.headRevision
    baseRevision=[string]$Binding.baseRevision
    authorityCommit=[string]$Binding.commit
    aiiMainTip=[string]$Binding.aiiMainTip
    interface='consumer-gate-v1'
    triggerEvent=[string]$Binding.triggerEvent
    canonicalEvent=[string]$Binding.canonicalEvent
    platformTestInventory=$inventory
    evidenceSha256=Get-GateSha256 $evidencePath}
    $root=Join-Path $WorkRoot 'receipts'
    [IO.Directory]::CreateDirectory($root)|Out-Null
    Write-GateJsonCreateOnly (Join-Path $root ("leg-$Platform.json")) $receipt
}
function Invoke-GateAggregate([string]$WorkRoot,$Binding) {
    $root=Join-Path $WorkRoot 'receipts'
    $files=@(Get-ChildItem -LiteralPath $root -File -Filter '*.json' -ErrorAction Stop)
    if($files.Count-ne3){Throw-GateResult FAILED 'Aggregate requires exactly three leg receipts.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($file in $files){$receipt=Read-GateJson $file.FullName 'leg receipt'
    Assert-GateExactProperties $receipt @('schemaVersion','report','result','platform','runId','candidateRevision','headRevision','baseRevision',`
        'authorityCommit','aiiMainTip','interface','triggerEvent','canonicalEvent','platformTestInventory','evidenceSha256') 'leg receipt'
    if (
        $receipt.schemaVersion -ne 1 -or
        [string]$receipt.report -cne 'consumer-gate-leg-receipt-v1' -or
        [string]$receipt.evidenceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$receipt.aiiMainTip -cnotmatch '^[0-9a-f]{40}$' -or
        $null -eq $receipt.platformTestInventory -or
        -not $seen.Add([string]$receipt.platform) -or
        [string]$receipt.platform -cnotin @('windows','linux','macos')
    ) {
        Throw-GateResult FAILED 'Leg platform set is invalid.'
    }
    Assert-GatePlatformTestInventory $receipt.platformTestInventory
    foreach($pair in @(@('result','PASS'),@('runId',[string]$Binding.runId),@('candidateRevision',[string]$Binding.candidateRevision),@(`
        'headRevision',[string]$Binding.headRevision),@('baseRevision',[string]$Binding.baseRevision),@('authorityCommit',`
            [string]$Binding.commit),@('interface','consumer-gate-v1'),@('triggerEvent',`
                [string]$Binding.triggerEvent),@('canonicalEvent',[string]$Binding.canonicalEvent))){if([string]$receipt.($pair[0])`
                    -cne[string]$pair[1]){Throw-GateResult FAILED "Leg receipt binding differs: $($pair[0])"}}}
    if(($seen|Sort-Object)-join','-cne'linux,macos,windows'){Throw-GateResult FAILED 'Aggregate platform set is incomplete.'}
    $output=[ordered]@{schemaVersion=1
    report='consumer-gate-aggregate-receipt-v1'
    result='PASS'
    runId=[string]$Binding.runId
    authorityCommit=[string]$Binding.commit
    platforms=@('windows','linux','macos')}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'aggregate-receipt.json') $output
    if(-not[string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)){[IO.File]::AppendAllText($env:GITHUB_OUTPUT,"authorityCommit=$($Binding.commit)`n",`
        [Text.UTF8Encoding]::new($false))}
}

$script:GateGitHooksPath = $null

function New-GateGitHooksDirectory(
    [string]$WorkRoot,
    [string]$DirectoryName = ("git-hooks-{0}" -f [guid]::NewGuid().ToString('N'))
) {
    $root = Get-Item -LiteralPath $WorkRoot -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $root.LinkType) {
        Throw-GateResult INVALID 'WorkRoot is not a physical directory.'
    }
    if ($DirectoryName -cnotmatch '^git-hooks-[0-9a-f]{32}$') {
        Throw-GateResult INVALID 'The dedicated Git hooks directory name is invalid.'
    }
    $hooks = Join-Path $root.FullName $DirectoryName
    if (Test-Path -LiteralPath $hooks) { Throw-GateResult INVALID 'The dedicated Git hooks directory already exists.' }
    [void](New-Item -ItemType Directory -Path $hooks -ErrorAction Stop)
    $item = Get-Item -LiteralPath $hooks -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $null -ne $item.LinkType -or @(Get-ChildItem -LiteralPath $hooks -Force).Count -ne 0) {
        Throw-GateResult INVALID 'The dedicated Git hooks directory is not an empty physical directory.'
    }
    $item.FullName
}

function Initialize-GateGitHooks([string]$WorkRoot,[string]$AuthorityRoot=([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))),[ValidateSet('prepare','validate','finalize','aggregate')][string]$Phase='prepare') {
    if ($null -ne $script:GateGitHooksPath) { Throw-GateResult INVALID 'Git hooks isolation was initialized more than once.' }
    $runtime=Import-GatePlatformRuntime $AuthorityRoot
    $hooksPath=New-GateGitHooksDirectory $WorkRoot
    $script:GateGitHooksPath=& $runtime.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $hooksPath
    $captureName='git-process-capture-'+[guid]::NewGuid().ToString('N')
    $captureRoot=Join-Path $WorkRoot $captureName
    [void][IO.Directory]::CreateDirectory($captureRoot)
    $script:GateGitCaptureRoot=& $runtime.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $captureRoot
    $script:GateGitRemainingMilliseconds=[long](Get-GateDeadlineBudget).phaseBudgets.$Phase.gitReserveSeconds*1000
}

function Invoke-GateOwnedGitCapture([string]$Root,[string[]]$Arguments,[switch]$ByteExact) {
    if($null-eq$script:GatePlatformRuntimeModule-or[string]::IsNullOrWhiteSpace($script:GateGitCaptureRoot)-or
        $null-eq$script:GateGitRemainingMilliseconds){Throw-GateResult INVALID 'Git owned-process runtime is not initialized.'}
    $budget=Get-GateDeadlineBudget
    $limit=[Math]::Min([long]$budget.gitCommandSeconds*1000,[long]$script:GateGitRemainingMilliseconds)
    if($limit-lt1){Throw-GateResult FAILED 'Git phase deadline was exhausted.'}
    $git=& $script:GatePlatformRuntimeModule.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path `
        (Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $environment=New-GateChildEnvironment $null @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')
    $id=[guid]::NewGuid().ToString('N')
    $stdoutPath=Join-Path $script:GateGitCaptureRoot "$id.stdout"
    $stderrPath=Join-Path $script:GateGitCaptureRoot "$id.stderr"
    $bytePath=if($ByteExact){Join-Path $script:GateGitCaptureRoot "$id.bytes"}else{$null}
    $workingDirectory=$null;$lease=$null;$stopwatch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $physicalRoot=& $script:GatePlatformRuntimeModule.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $Root
        $workingDirectory=& $script:GatePlatformRuntimeModule.ExportedCommands['Open-PlatformDirectory'] -Root $physicalRoot -RootOnly
        $deadline=[DateTimeOffset]::UtcNow.AddMilliseconds($limit)
        $executable=$git;$ownedArguments=[string[]]@($Arguments)
        for($index=0;$index-lt$ownedArguments.Count-1;$index++){
            if($ownedArguments[$index]-ceq'-C' -and $ownedArguments[$index+1]-ceq$Root){$ownedArguments[$index+1]=$physicalRoot}
        }
        if($ByteExact){
            $executable=& $script:GatePlatformRuntimeModule.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path (Get-Process -Id $PID).Path
            $helper=& $script:GatePlatformRuntimeModule.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path `
                (Join-Path $PSScriptRoot 'Invoke-GateGitByteCapture.ps1')
            $payload=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($ownedArguments|ConvertTo-Json -Compress)))
            $ownedArguments=@('-NoProfile','-NonInteractive','-File',$helper,
                '-GitPath',$git,'-OutputPath',$bytePath,'-GitArgumentsBase64',$payload)
        }
        $lease=& $script:GatePlatformRuntimeModule.ExportedCommands['Start-PlatformOwnedProcess'] -ExecutablePath $executable `
            -ArgumentList $ownedArguments -Environment $environment -WorkingDirectoryLease $workingDirectory -Deadline $deadline `
            -StdoutPath $stdoutPath -StderrPath $stderrPath -OutputLimitCharacters 1048576 -ArgumentZero $executable
        while(-not($lease.HasExited-and$lease.CaptureCompletedNaturally)-and$null-eq$lease.Cleanup-and[DateTimeOffset]::UtcNow-lt$deadline){
            Start-Sleep -Milliseconds 10
        }
        $timedOut=[DateTimeOffset]::UtcNow-ge$deadline-or$lease.TerminationReason-ceq'deadline'
        $reason=$lease.TerminationReason
        try{$cleanup=& $script:GatePlatformRuntimeModule.ExportedCommands['Stop-PlatformOwnedProcess'] -Lease $lease `
            -GracePeriod ([TimeSpan]::FromMilliseconds(100)) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -ExpectedStartIdentity $lease.StartIdentity}catch{Throw-GateResult FAILED "Git owned-process cleanup failed: $($_.Exception.Message)"}
        if(-not$cleanup.CleanedUp){Throw-GateResult FAILED "Git owned-process cleanup is unconfirmed: $($cleanup.Uncertainty)"}
        if($timedOut){Throw-GateResult FAILED "Git command exceeded its bounded deadline of $([Math]::Ceiling($limit/1000)) seconds."}
        if($lease.OutputLimitExceeded){Throw-GateResult FAILED 'Git owned-process output exceeded the 1,048,576-character stream limit.'};if($reason-notin@($null,'')){Throw-GateResult FAILED "Git owned-process capture failed: $reason"}
        $resultPath=if($ByteExact){$bytePath}else{$stdoutPath}
        if(-not[IO.File]::Exists($resultPath)){Throw-GateResult FAILED 'Git owned-process output capture is missing.'}
        if(([IO.FileInfo]::new($resultPath)).Length-gt[int]::MaxValue){Throw-GateResult FAILED 'Git byte output exceeds the supported 2 GiB read bound.'};if($lease.ExitCode-isnot[int]-and$lease.ExitCode-isnot[long]){Throw-GateResult FAILED 'git exit status is unknown.'}
        [pscustomobject]@{ExitCode=$lease.ExitCode
            StdoutBytes=[IO.File]::ReadAllBytes($resultPath)
            StderrBytes=[IO.File]::ReadAllBytes($stderrPath)
            ProcessOwnership=$cleanup}
    }finally{
        $stopwatch.Stop()
        $script:GateGitRemainingMilliseconds=[Math]::Max(0,[long]$script:GateGitRemainingMilliseconds-[long]$stopwatch.ElapsedMilliseconds)
        if($null-ne$lease){$lease.Dispose()}
        if($null-ne$workingDirectory){$workingDirectory.Dispose()}
        $environment.Clear()
        foreach($path in @($stdoutPath,$stderrPath,$bytePath)){if(-not[string]::IsNullOrWhiteSpace($path)-and[IO.File]::Exists($path)){[IO.File]::Delete($path)}}
    }
}

function Invoke-GateGit([string]$Root,[string[]]$Arguments,[int[]]$Allowed=@(0)) {
    if ([string]::IsNullOrWhiteSpace($script:GateGitHooksPath)) { Throw-GateResult INVALID 'Git hooks isolation is not initialized.' }
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process');Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
    $run=Invoke-GateOwnedGitCapture $Root (@('-c',"core.hooksPath=$script:GateGitHooksPath",'-c','protocol.file.allow=never',
            '-c','credential.helper=','-C',$Root)+$Arguments) -ByteExact
    try{
        $encoding=[Text.UTF8Encoding]::new($false,$true)
        $stdoutText=$encoding.GetString($run.StdoutBytes);$stderrText=$encoding.GetString($run.StderrBytes);$text=$stdoutText+$(if($stdoutText.Length-gt0-and$stderrText.Length-gt0-and-not$stdoutText.EndsWith("`n",[StringComparison]::Ordinal)){"`n"}else{''})+$stderrText
    }catch{Throw-GateResult INVALID 'git output was not valid UTF-8.'}
    $output=if([string]::IsNullOrEmpty($text)){@()}else{@($text.TrimEnd("`r","`n")-split"`r?`n")}
    $exit = $run.ExitCode;if($exit-isnot[int]-and$exit-isnot[long]){Throw-GateResult FAILED 'git exit status is unknown.'}
    if ($exit -notin $Allowed) { Throw-GateResult INVALID "git failed ($exit): $($output -join ' ')" }
    [pscustomobject]@{ ExitCode=$exit
     Output=[string[]]@($output) }
}

function Test-GateSafeRelativePath([string]$Path,[string[]]$Roots,[switch]$DirectoryPrefix) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\',[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($Path)) { return $false }
    $value = if ($DirectoryPrefix) { $Path.TrimEnd('/') } else { $Path }
    if ($DirectoryPrefix -and -not $Path.EndsWith('/',[StringComparison]::Ordinal)) { return $false }
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('\',[StringComparison]::Ordinal) -or
        $value.IndexOfAny([char[]]@('*','?','[',']')) -ge 0) { return $false }
    $segments = @($value -split '/')
    if (@($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) { return $false }
    @($Roots | Where-Object { $value -ceq $_ -or $value.StartsWith("$_/",[StringComparison]::Ordinal) }).Count -ne 0
}

function Get-GateManifestEntry([string]$AuthorityRoot,[string]$RepositoryId) {
    $manifest = Read-GateJson (Join-Path $AuthorityRoot 'consumer/legacy-migration.json') 'legacy migration manifest'
    Assert-GateExactProperties $manifest @('schemaVersion','repositories') 'legacy migration manifest'
    if ($manifest.schemaVersion -ne 1 -or $manifest.repositories -isnot [array] -or @($manifest.repositories).Count -ne 5 -or
        @($manifest.repositories.id | Select-Object -Unique).Count -ne 5 -or
        @($manifest.repositories.repository | Select-Object -Unique).Count -ne 5) {
        Throw-GateResult INVALID 'Legacy migration manifest inventory is invalid.'
    }
    $matches = @($manifest.repositories | Where-Object { [string]$_.id -ceq $RepositoryId })
    if ($matches.Count -ne 1) { Throw-GateResult INVALID 'repositoryId has no unique legacy manifest entry.' }
    $entry = $matches[0]
    $required = @('id','repository','status','inventoryCommit','inventoryTree','requiredRepositoryChecks','files')
    $allowed = @($required + @('additionalScope','prerequisites','literalReferenceExemptions'))
    $actual = @($entry.PSObject.Properties.Name)
    if (@($required | Where-Object { $actual -cnotcontains $_ }).Count -ne 0 -or
        @($actual | Where-Object { $allowed -cnotcontains $_ }).Count -ne 0) {
        Throw-GateResult INVALID 'legacy repository entry has an unexpected property set.'
    }
    if ([string]$entry.status -cnotin @('ready','pending-prerequisites') -or
        [string]$entry.inventoryCommit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$entry.inventoryTree -cnotmatch '^[0-9a-f]{40}$' -or
        $entry.requiredRepositoryChecks -isnot [array] -or $entry.files -isnot [array]) {
        Throw-GateResult INVALID 'Legacy repository entry is invalid.'
    }
    $scope = @()
    if ($null -ne $entry.PSObject.Properties['additionalScope']) {
        if ($entry.additionalScope -isnot [array] -or @($entry.additionalScope).Count -eq 0) { Throw-GateResult INVALID 'additionalScope must be non-empty.' }
        $scopeSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($prefix in @($entry.additionalScope)) {
            if ($prefix -isnot [string] -or -not (Test-GateSafeRelativePath ([string]$prefix) @('skills') -DirectoryPrefix) -or
                -not $scopeSet.Add([string]$prefix)) { Throw-GateResult INVALID 'additionalScope is unsafe or duplicate.' }
        }
        $scope = @($entry.additionalScope)
    }
    $checkIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $checkPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($check in @($entry.requiredRepositoryChecks)) {
        Assert-GateExactProperties $check @('id','kind','path') 'legacy required check'
        $kind = [string]$check.kind
         $path = [string]$check.path
        if ([string]$check.id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
            $kind -cnotin @('general','pester') -or ($kind -eq 'pester' -and $path -cne 'tests') -or
            ($kind -eq 'general' -and (-not (Test-GateSafeRelativePath $path @('scripts','tests')) -or
                $path -cnotmatch '\.ps1$' -or $path -match '\.Tests\.ps1$')) -or
            -not $checkIds.Add([string]$check.id) -or -not $checkPaths.Add($path)) {
            Throw-GateResult INVALID 'Legacy required check IDs and paths must be unique and valid.'
        }
    }
    $filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($entry.files)) {
        $disposition = [string]$record.disposition
        $expected = if ($disposition -eq 'split') { @('path','disposition','target','reason') } elseif ($disposition -eq 'update-tests') {
            @('path','disposition','reason','expectedOutcome')
        } else { @('path','disposition','reason') }
        Assert-GateExactProperties $record $expected 'legacy file disposition'
        $path = [string]$record.path
        $basic = Test-GateSafeRelativePath $path @('.github','config','scripts','tests')
        $extra = @($scope | Where-Object { $path.StartsWith([string]$_,[StringComparison]::Ordinal) }).Count -eq 1
        if ((-not $basic -and -not $extra) -or -not $filePaths.Add($path) -or
            $disposition -cnotin @('delete','split','retain','update-tests') -or
            [string]::IsNullOrWhiteSpace([string]$record.reason)) { Throw-GateResult INVALID 'Legacy file disposition is invalid.' }
        if ($disposition -eq 'split') {
            $target = [string]$record.target
            if (-not (Test-GateSafeRelativePath $target @('scripts','tests')) -or
                @($entry.requiredRepositoryChecks | Where-Object { $_.kind -ceq 'general' -and $_.path -ceq $target }).Count -ne 1) {
                Throw-GateResult INVALID 'Legacy split target must be a required general check.'
            }
        }
        if ($disposition -eq 'update-tests' -and [string]$record.expectedOutcome -cnotin @('delete','rewrite')) {
            Throw-GateResult INVALID 'update-tests requires an expectedOutcome.'
        }
    }
    $prerequisites = @()
    if ($null -ne $entry.PSObject.Properties['prerequisites']) {
        $prerequisites = @($entry.prerequisites)
        if ($entry.prerequisites -isnot [array] -or $prerequisites.Count -eq 0) { Throw-GateResult INVALID 'prerequisites must be non-empty.' }
        $prerequisiteIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in $prerequisites) {
            Assert-GateExactProperties $item @('id','path','requirement') 'legacy prerequisite'
            if (-not $prerequisiteIds.Add([string]$item.id) -or -not $filePaths.Contains([string]$item.path) -or
                [string]::IsNullOrWhiteSpace([string]$item.requirement)) { Throw-GateResult INVALID 'Legacy prerequisite semantics are invalid.' }
        }
    }
    if (($entry.status -ceq 'pending-prerequisites' -and $prerequisites.Count -eq 0) -or
        ($entry.status -ceq 'ready' -and $prerequisites.Count -ne 0)) { Throw-GateResult INVALID 'Legacy status and prerequisites are inconsistent.' }
    if ($null -ne $entry.PSObject.Properties['literalReferenceExemptions']) {
        if ($entry.literalReferenceExemptions -isnot [array]) { Throw-GateResult INVALID 'literalReferenceExemptions must be an array.' }
        $legacyTargets = @($entry.files | Where-Object { $_.disposition -in @('delete','split','update-tests') } | ForEach-Object path)
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in @($entry.literalReferenceExemptions)) {
            Assert-GateExactProperties $item @('file','blobOid','line','column','occurrenceOrdinal','targetPath','reason') 'literal reference exemption'
            $numbers = @($item.line,$item.column,$item.occurrenceOrdinal)
            $key = "$($item.file):$($item.line):$($item.column):$($item.occurrenceOrdinal):$($item.targetPath)"
            if ([string]$item.blobOid -cnotmatch '^[0-9a-f]{40}$' -or @($numbers | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -ne 0 -or
                @($numbers | Where-Object { [long]$_ -lt 1 }).Count -ne 0 -or [string]::IsNullOrWhiteSpace([string]$item.reason) -or
                @($entry.files | Where-Object { $_.path -ceq $item.file -and $_.disposition -ceq 'retain' }).Count -ne 1 -or
                [string]$item.targetPath -cnotin $legacyTargets -or -not $keys.Add($key)) { Throw-GateResult INVALID `
                    'Literal reference exemption semantics are invalid.' }
        }
    }
    $entry
}

function Assert-GateConfig([string]$AuthorityRoot,[string]$CandidateRoot,[string]$EventRepository) {
    $config = Read-GateJson (Join-Path $CandidateRoot 'config/consumer-gate.json') 'consumer gate config'
    Assert-GateExactProperties $config @('schemaVersion','repositoryId','sourceRepository','activeSkills','repositoryChecks') 'consumer gate config'
    if ($config.schemaVersion -ne 1 -or [string]$config.sourceRepository -cne $EventRepository -or
        $config.activeSkills -isnot [array] -or $config.repositoryChecks -isnot [array]) { Throw-GateResult INVALID `
            'Consumer gate config identity is invalid.' }
    $actualSkills = Get-GateActiveSkills $CandidateRoot
     $declared = @([string[]]$config.activeSkills | Sort-Object)
    if (($actualSkills -join "`n") -cne ($declared -join "`n")) { Throw-GateResult INVALID 'activeSkills differs from the tracked snapshot.' }
    $entry = Get-GateManifestEntry $AuthorityRoot ([string]$config.repositoryId)
    if ([string]$entry.repository -cne $EventRepository) { Throw-GateResult INVALID 'Event repository differs from the legacy manifest.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
     $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($check in @($config.repositoryChecks)) {
        Assert-GateExactProperties $check @('id','kind','path') 'repository check'
        $path = [string]$check.path
        if (-not $ids.Add([string]$check.id) -or -not $paths.Add($path)) { Throw-GateResult INVALID 'Repository check IDs and paths must be safe and unique.' }
        if ($check.kind -ceq 'general') {
            if (-not (Test-GateSafeRelativePath $path @('scripts','tests')) -or $path -cnotmatch '\.ps1$' -or $path -match '\.Tests\.ps1$') {
                Throw-GateResult INVALID 'General repository check path is invalid.'
            }
            $tracked = @((Invoke-GateGit $CandidateRoot @('ls-files','--',$path)).Output)
            if ($tracked.Count -ne 1 -or [string]$tracked[0] -cne $path) { Throw-GateResult INVALID `
                'General repository check is not a canonical tracked file.' }
            $item = Get-Item -LiteralPath (Join-Path $CandidateRoot $path) -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
                Throw-GateResult INVALID 'General repository check must be a regular file.'
            }
            if (@($entry.files | Where-Object { $_.path -ceq $path -and $_.disposition -ceq 'delete' }).Count -ne 0) {
                Throw-GateResult INVALID 'General repository check points to a deleted legacy path.'
            }
        } elseif ($check.kind -ceq 'pester') {
            if ($path -cne 'tests') { Throw-GateResult INVALID 'Pester repository check must discover the complete tests tree.' }
        } else { Throw-GateResult INVALID 'Unknown repository check kind.' }
    }
    foreach ($requiredCheck in @($entry.requiredRepositoryChecks)) {
        if (@($config.repositoryChecks | Where-Object { $_.id -ceq $requiredCheck.id -and $_.kind -ceq $requiredCheck.kind -and $_.path -ceq `
            $requiredCheck.path }).Count -ne 1) {
            Throw-GateResult INVALID "Required repository check is missing: $($requiredCheck.id)"
        }
    }
    [pscustomobject]@{ Config=$config
     ManifestEntry=$entry
     ActiveSkills=$actualSkills }
}

function Get-GateBlobOid([string]$Root,[string]$Revision,[string]$Path) {
    $records = @((Invoke-GateGit $Root @('ls-tree',$Revision,'--',$Path)).Output)
    if ($records.Count -eq 0) { return $null }
    if ($records.Count -ne 1 -or [string]$records[0] -cnotmatch '^100(?:644|755) blob ([0-9a-f]{40})\t(.+)$' -or [string]$Matches[2] -cne $Path) {
        Throw-GateResult FAILED "Tracked path is not a canonical regular file: $Path"
    }
    [string]$Matches[1]
}

function Get-GateTreeBlobEntry([string]$Root,[string]$Revision,[string]$Path) {
    [byte[]]$bytes=Invoke-GateGitBytes $Root @('ls-tree','-z',$Revision,'--',$Path)
    if($bytes.Length-eq0){return $null}
    if($bytes[$bytes.Length-1]-ne0-or@($bytes|Where-Object{$_-eq0}).Count-ne1){Throw-GateResult BLOCKED `
        "SkillSpector scanner-transition referenced path '$Path' is not a unique canonical tree entry."}
    try{$record=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$bytes.Length-1)}catch{Throw-GateResult BLOCKED `
        "SkillSpector scanner-transition referenced path '$Path' is not valid UTF-8."}
    if ($record-cnotmatch '^(?<mode>[0-9]{6}) (?<type>[^ ]+) (?<oid>[0-9a-f]{40}|[0-9a-f]{64})\t(?<path>.+)$' -or
        [string]$Matches.path -cne $Path) {
        Throw-GateResult BLOCKED "SkillSpector scanner-transition referenced path '$Path' is not a unique canonical tree entry."
    }
    [pscustomobject]@{Mode=[string]$Matches.mode;Type=[string]$Matches.type;Oid=[string]$Matches.oid;Path=[string]$Matches.path}
}

function Test-GateRegularFile([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    $item=Get-Item -LiteralPath $Path -Force
    -not $item.PSIsContainer-and($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-eq0-and$null-eq$item.LinkType
}

function Test-GateTextProjectionEqual([string]$Left,[string]$Right) {
    try{
        $encoding=[Text.UTF8Encoding]::new($false,$true)
        $leftText=$encoding.GetString([IO.File]::ReadAllBytes($Left))
        $rightText=$encoding.GetString([IO.File]::ReadAllBytes($Right))
    }catch{return $false}
    if($leftText-match'\r(?!\n)'-or$rightText-match'\r(?!\n)'){return $false}
    $leftText.Replace("`r`n","`n")-ceq$rightText.Replace("`r`n","`n")
}

function Test-GateTrackedBlobMatchesFile([string]$TrackedRoot,[string]$Revision,[string]$TrackedPath,
    [string]$FileRoot,[string]$FilePath) {
    $trackedFile=Join-Path $TrackedRoot $TrackedPath
    $comparisonFile=Join-Path $FileRoot $FilePath
    if(-not(Test-GateRegularFile $trackedFile)-or-not(Test-GateRegularFile $comparisonFile)-or
        -not(Test-GateTextProjectionEqual $trackedFile $comparisonFile)){return $false}
    if($Revision-cnotmatch'^[0-9a-f]{40}$'){return Test-GateBytesEqual $trackedFile $comparisonFile}
    $trackedOid=Get-GateBlobOid $TrackedRoot $Revision $TrackedPath
    if($null-eq$trackedOid){return $false}
    $comparisonOid=([string](Invoke-GateGit $FileRoot @('hash-object','--no-filters','--',$comparisonFile)).Output[0]).Trim()
    $trackedOid-ceq$comparisonOid
}

function Test-GateTrackedBlobsEqual([string]$LeftRoot,[string]$LeftRevision,[string]$LeftPath,
    [string]$RightRoot,[string]$RightRevision,[string]$RightPath) {
    $leftFile=Join-Path $LeftRoot $LeftPath
    $rightFile=Join-Path $RightRoot $RightPath
    if(-not(Test-GateRegularFile $leftFile)-or-not(Test-GateRegularFile $rightFile)-or
        -not(Test-GateTextProjectionEqual $leftFile $rightFile)){return $false}
    if($LeftRevision-cnotmatch'^[0-9a-f]{40}$'-or$RightRevision-cnotmatch'^[0-9a-f]{40}$'){return Test-GateBytesEqual $leftFile $rightFile}
    $leftOid=Get-GateBlobOid $LeftRoot $LeftRevision $LeftPath
    $rightOid=Get-GateBlobOid $RightRoot $RightRevision $RightPath
    $null-ne$leftOid-and$null-ne$rightOid-and$leftOid-ceq$rightOid
}

function Assert-GateProtectedFiles([string]$AuthorityRoot,[string]$BaseRoot,[string]$CandidateRoot,$ManifestEntry,
    [string]$BaseRevision,[string]$CandidateRevision,[bool]$Transition) {
    $bootstrapPath='scripts/Invoke-PinnedAuthority.ps1'
    if (-not (Test-GateTrackedBlobMatchesFile $CandidateRoot $CandidateRevision $bootstrapPath $AuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') -and
        -not (Test-GateTrackedBlobsEqual $CandidateRoot $CandidateRevision $bootstrapPath $BaseRoot $BaseRevision $bootstrapPath)) {
        Throw-GateResult FAILED 'Candidate bootstrap differs from both authority template and base.'
    }
    $workflowRoot = Join-Path $CandidateRoot '.github/workflows'
     $allowed = @('consumer-gate.yml','consumer-gate-transition.yml')
    $items = @(Get-ChildItem -LiteralPath $workflowRoot -Recurse -Force -ErrorAction Stop)
    if (@($items | Where-Object PSIsContainer).Count -ne 0) { Throw-GateResult FAILED 'Nested workflow directories are not allowed.' }
    foreach ($file in @($items)) {
        $relative = [IO.Path]::GetRelativePath($workflowRoot,$file.FullName).Replace('\','/')
        if ($relative.Contains('/') -or $allowed -cnotcontains $relative) { Throw-GateResult FAILED "Unexpected workflow: $relative" }
        $workflowPath=".github/workflows/$relative"
        $base = Join-Path $BaseRoot $workflowPath
        if ($relative -ceq 'consumer-gate-transition.yml' -and -not $Transition -and -not (Test-Path $base -PathType Leaf)) {
            Throw-GateResult FAILED 'Transition workflow is not allowed after transition.'
        }
        if (-not (Test-GateTrackedBlobMatchesFile $CandidateRoot $CandidateRevision $workflowPath $AuthorityRoot "consumer/workflows/$relative") -and
            -not (Test-GateTrackedBlobsEqual $CandidateRoot $CandidateRevision $workflowPath $BaseRoot $BaseRevision $workflowPath)) {
            Throw-GateResult FAILED "Workflow differs from both authority template and base: $relative"
        }
    }
    if (-not (Test-Path (Join-Path $workflowRoot 'consumer-gate.yml') -PathType Leaf)) { Throw-GateResult FAILED 'Candidate consumer-gate.yml is missing.' }
    if ($Transition -and -not (Test-Path (Join-Path $workflowRoot 'consumer-gate-transition.yml') -PathType Leaf)) { Throw-GateResult FAILED `
        'Transition workflow is missing.' }
    foreach ($record in @($ManifestEntry.files)) {
        $path=[string]$record.path
         $candidatePath=Join-Path $CandidateRoot $path
        if ($record.disposition -in @('delete','split') -and (Test-Path $candidatePath)) { Throw-GateResult FAILED "Removed legacy path is present: $path" }
        if ($Transition -and $record.disposition -ceq 'split' -and $null -eq (Get-GateBlobOid $CandidateRoot $CandidateRevision ([string]$record.target))) {
            Throw-GateResult FAILED "Split target is not a tracked regular file: $($record.target)"
        }
        if ($Transition -and $record.disposition -ceq 'retain' -and -not(Test-GateExceptionPathInScope $path)) {
            $candidateOid = Get-GateBlobOid $CandidateRoot $CandidateRevision $path
            $baseOid = Get-GateBlobOid $BaseRoot $BaseRevision $path
            if ($null -eq $candidateOid -or $null -eq $baseOid -or $candidateOid -cne $baseOid) {
                Throw-GateResult FAILED "Retained path must remain unchanged: $path"
            }
        }
        if ($Transition -and $record.disposition -ceq 'update-tests') {
            $oid=Get-GateBlobOid $CandidateRoot $CandidateRevision $path
            if ($record.expectedOutcome -ceq 'delete' -and ($null -ne $oid -or (Test-Path $candidatePath))) { Throw-GateResult FAILED `
                "update-tests path must be deleted: $path" }
            if ($record.expectedOutcome -ceq 'rewrite') {
                $baseOid=Get-GateBlobOid $BaseRoot $BaseRevision $path
                if ($null -eq $oid -or $null -eq $baseOid -or $oid -ceq $baseOid) { Throw-GateResult FAILED "update-tests path must be rewritten: $path" }
            }
        }
    }
}

function Assert-GateTransitionInventory([string]$BaseRoot,$Entry,[string]$BaseRevision,[bool]$Transition) {
    if (-not $Transition) { return }
    $tree=([string](Invoke-GateGit $BaseRoot @('rev-parse',"$BaseRevision^{tree}")).Output[0]).Trim()
    if ($Entry.status -ceq 'pending-prerequisites') { Throw-GateResult BLOCKED 'Darktide prerequisites are incomplete; see consumer/README.md#darktide-轉換前提.' }
    if ($Entry.inventoryCommit -cne $BaseRevision -or $Entry.inventoryTree -cne $tree) { Throw-GateResult BLOCKED `
        'Repository has advanced; regenerate its manifest in an AII PR first.' }
    $prefixes=@('scripts/','config/','.github/','tests/')
    if($null-ne$Entry.PSObject.Properties['additionalScope']){$prefixes+=@($Entry.additionalScope)}
    $actual=@((Invoke-GateGit $BaseRoot @('ls-tree','-r','--name-only',$BaseRevision)).Output|Where-Object{$p=[string]$_
    @($prefixes|Where-Object{$p.StartsWith([string]$_,[StringComparison]::Ordinal)}).Count-ne0}|Sort-Object -Unique)
    $expected=@($Entry.files|ForEach-Object{[string]$_.path}|Sort-Object -Unique)
    if(($actual-join"`n")-cne($expected-join"`n")){Throw-GateResult FAILED 'Legacy manifest files do not equal the inventory tree scope.'}
}

function Invoke-GateManifestClosureCheck([string]$AuthorityRoot,[string]$BaseRoot,[string]$CandidateRoot,$Entry,
    [string]$BaseRevision,[string]$CandidateRevision,[string]$WorkRoot,[bool]$Transition) {
    if(-not$Transition){return}
    Import-Module (Join-Path $AuthorityRoot 'scripts/consumer/ConsumerManifestClosure.psm1') -Force
    foreach($stage in @('inventory','conversion')){
        $parameters=@{RepositoryRoot=if($stage-eq'inventory'){$BaseRoot}else{$CandidateRoot}
        Commit=if($stage-eq'inventory'){$BaseRevision}else{$CandidateRevision}
        Stage=$stage
        Manifest=(Join-Path $AuthorityRoot 'consumer/legacy-migration.json')
        RepositoryId=[string]$Entry.id
        AuthorityRoot=$AuthorityRoot;GitByteInvoker={param([string]$RepositoryRoot,[string[]]$Arguments,[int[]]$AllowedExitCodes) Invoke-GateGitBytes $RepositoryRoot $Arguments}.GetNewClosure()}
        if($stage-eq'conversion'){$parameters.InventoryCommit=[string]$Entry.inventoryCommit}
        $result=Get-ConsumerManifestClosure @parameters
        Write-GateJsonCreateOnly (Join-Path $WorkRoot "manifest-closure-$stage.json") $result
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
            [IO.File]::AppendAllText(
                $env:GITHUB_STEP_SUMMARY,
            (
                "Manifest closure $stage`: $($result.result); violations=$(@($result.violations).Count); " +
                "advisories=$(@($result.advisories).Count)`n"
            ),
            [Text.UTF8Encoding]::new($false)
        )
        }
        if($result.result-cne'PASS'){Throw-GateResult FAILED "Manifest closure failed during $stage."}
    }
}

function Get-GateCredentialSurfaceFiles([string]$WorkRoot) {
    $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $paths=[Collections.Generic.HashSet[string]]::new($comparer)
    foreach($file in @(Get-ChildItem $WorkRoot -Recurse -File -Force -ErrorAction Stop)){[void]$paths.Add($file.FullName)}
    foreach($name in @('GITHUB_STEP_SUMMARY','CONSUMER_GATE_ARTIFACT_PATHS')){
        $value=[Environment]::GetEnvironmentVariable($name,'Process')
        if([string]::IsNullOrWhiteSpace($value)){continue}
        $surfacePaths=if($name-eq'GITHUB_STEP_SUMMARY'){@($value)}else{@($value-split[regex]::Escape([string][IO.Path]::PathSeparator))}
        foreach($path in $surfacePaths){if(-not(Test-Path $path)){continue}
        $item=Get-Item $path -Force
        if($item.PSIsContainer){foreach($file in @(Get-ChildItem $item.FullName -Recurse -File -Force)){[void]$paths.Add($file.FullName)}}else{`
            [void]$paths.Add($item.FullName)}}
    }
    @($paths)
}

function Assert-GateCredentialAbsent([string]$Root,[string]$Token) {
    if([string]::IsNullOrEmpty($Token)){return}
    $needle=$null
    $content=$null
    try{
        $needle=[Text.Encoding]::Latin1.GetString([Text.UTF8Encoding]::new($false).GetBytes($Token))
        foreach($path in @(Get-GateCredentialSurfaceFiles $Root)){
            $content=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($path))
            if($content.IndexOf($needle,[StringComparison]::Ordinal)-ge0){Throw-GateResult FAILED 'Credential sentinel remained in a gate-owned output surface.'}
            $content=$null
        }
    }finally{
        $content=$null;$needle=$null;$Token=$null
        Remove-Variable content,needle,Token -ErrorAction SilentlyContinue
    }
}

function Invoke-GateAcquisitionRequest([string]$Operation,[uri]$Uri,[hashtable]$Headers,[string]$Destination,`
    [string[]]$ApprovedHosts,[string]$AuthorizationHost,[bool]$AllowLoopbackHttp) {
    $budget=Get-GateDeadlineBudget
    $timeoutSeconds=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS)){[int]$budget.acquisitionRequestDefaultSeconds}else{
        [int]$env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS}
    if($timeoutSeconds-lt1-or$timeoutSeconds-gt$budget.acquisitionRequestSeconds){Throw-GateResult INVALID 'Acquisition timeout setting is invalid.'}
    $cancelPath=[string]$env:CONSUMER_GATE_ACQUISITION_CANCEL_PATH
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    [Net.Http.HttpRequestMessage]$request=$null
    $cts=[Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds($timeoutSeconds))
    [Net.Http.HttpResponseMessage]$response=$null
    try{
        $requestUri=$Uri
        for($redirectCount=0;$true;$redirectCount++){
            if($redirectCount-gt5){Throw-GateResult FAILED 'GATE_ACQUISITION_REDIRECT_LIMIT: acquisition exceeded the redirect limit.'}
            $schemeApproved=$requestUri.Scheme-ceq'https'-or($AllowLoopbackHttp-and$requestUri.Scheme-ceq'http'-and$requestUri.Host-ceq'127.0.0.1')
            if(-not$schemeApproved-or$ApprovedHosts-cnotcontains$requestUri.Host-or-not[string]::IsNullOrEmpty($requestUri.UserInfo)-or
                (-not$AllowLoopbackHttp-and-not$requestUri.IsDefaultPort)){Throw-GateResult FAILED `
                    'GATE_ACQUISITION_REDIRECT_HOST: acquisition used an unapproved endpoint.'}
            if($null-ne$request){$request.Dispose();$request=$null}
            if($null-ne$response){$response.Dispose();$response=$null}
            $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$requestUri)
            foreach($name in $Headers.Keys){
                if([string]$name-ieq'Authorization'-and$requestUri.Host-cne$AuthorizationHost){continue}
                [void]$request.Headers.TryAddWithoutValidation([string]$name,[string]$Headers[$name])
            }
            if(-not[string]::IsNullOrWhiteSpace($cancelPath)-and(Test-Path -LiteralPath $cancelPath)){Throw-GateResult CANCELLED `
                'GATE_ACQUISITION_CANCELLED: acquisition was cancelled.'}
            try{$response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()}
            catch [OperationCanceledException]{
                if(-not[string]::IsNullOrWhiteSpace($cancelPath)-and(Test-Path -LiteralPath $cancelPath)){Throw-GateResult CANCELLED `
                    'GATE_ACQUISITION_CANCELLED: acquisition was cancelled.'}
                Throw-GateResult FAILED 'GATE_ACQUISITION_TIMEOUT: acquisition timed out.'
            }
            if([int]$response.StatusCode-notin@(301,302,303,307,308)){break}
            $location=$response.Headers.Location
            if($null-eq$location){Throw-GateResult FAILED 'GATE_ACQUISITION_REDIRECT_LOCATION: redirect omitted Location.'}
            $requestUri=if($location.IsAbsoluteUri){$location}else{[uri]::new($requestUri,$location)}
        }
        $stream=$response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
        $memory=[IO.MemoryStream]::new()
        $buffer=[byte[]]::new(8192)
        try{
            while($true){
                if(-not[string]::IsNullOrWhiteSpace($cancelPath)-and(Test-Path -LiteralPath $cancelPath)){Throw-GateResult CANCELLED `
                    'GATE_ACQUISITION_CANCELLED: acquisition was cancelled.'}
                try{$read=$stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult()}
                catch [OperationCanceledException]{Throw-GateResult FAILED 'GATE_ACQUISITION_TIMEOUT: acquisition timed out.'}
                if($read-eq0){break};$memory.Write($buffer,0,$read)
            }
            $bytes=$memory.ToArray()
        }finally{$stream.Dispose();$memory.Dispose()}
        if(-not$response.IsSuccessStatusCode){Throw-GateResult FAILED "GATE_ACQUISITION_HTTP_ERROR: HTTP $([int]$response.StatusCode)."}
        if($Operation-eq'metadata'){
            try{return ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json -Depth 30 -ErrorAction Stop)}
            catch{Throw-GateResult FAILED 'GATE_ACQUISITION_METADATA_INVALID: metadata was invalid.'}
        }
        [IO.File]::WriteAllBytes($Destination,$bytes)
    }finally{
        if($null-ne$response){$response.Dispose()};if($null-ne$request){$request.Dispose()};$client.Dispose();$handler.Dispose();$cts.Dispose()
        $bytes=$null;$buffer=$null;$response=$null;$request=$null;$stream=$null;$memory=$null;$Headers=$null
        Remove-Variable bytes,buffer,response,request,stream,memory,Headers -ErrorAction SilentlyContinue
    }
}
function Assert-GateJsonStringsDecodable([Text.Json.JsonElement]$Element,[string]$Context) {
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        foreach($property in $Element.EnumerateObject()){
            try{$name=$property.Name}catch{Throw-GateResult INVALID "$Context contains an object key that cannot be decoded."}
            if($null-eq$name){Throw-GateResult INVALID "$Context contains an object key that cannot be decoded."}
            Assert-GateJsonStringsDecodable $property.Value $Context
        }
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){
        foreach($item in $Element.EnumerateArray()){Assert-GateJsonStringsDecodable $item $Context}
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::String){
        try{[void]$Element.GetString()}catch{Throw-GateResult INVALID "$Context contains a string value that cannot be decoded."}
    }
}
function ConvertFrom-GateJsonBytes([byte[]]$Bytes,[string]$Context) {
    if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){Throw-GateResult INVALID "$Context has a UTF-8 BOM."}
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-GateNoDuplicateJson $document.RootElement $Context}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }catch{if($_.Exception.Message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|'){throw}
    Throw-GateResult INVALID "$Context is not unambiguous UTF-8 JSON."}
}
function Open-GateJsonDocument([byte[]]$Bytes,[string]$Context) {
    if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){Throw-GateResult INVALID "$Context has a UTF-8 BOM."}
    $document=$null
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        Assert-GateJsonStringsDecodable $document.RootElement $Context
        Assert-GateNoDuplicateJson $document.RootElement $Context
        $document
    }catch{
        if($null-ne$document){$document.Dispose()}
        if($_.Exception.Message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|'){throw}
        Throw-GateResult INVALID "$Context is not unambiguous UTF-8 JSON."
    }
}
function Invoke-GateGitBytes([string]$Root,[string[]]$Arguments) {
    if([string]::IsNullOrWhiteSpace($script:GateGitHooksPath)){Throw-GateResult INVALID 'Git hooks isolation is not initialized.'}
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){
        [Environment]::SetEnvironmentVariable($name,$null,'Process');Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $run=Invoke-GateOwnedGitCapture $Root (@('-c',"core.hooksPath=$script:GateGitHooksPath",'-c','protocol.file.allow=never',
            '-c','credential.helper=','-C',$Root)+$Arguments) -ByteExact
    if($run.ExitCode-isnot[int]-and$run.ExitCode-isnot[long]){Throw-GateResult FAILED 'git exit status is unknown.'};if($run.ExitCode-ne0){
        try{$errorText=[Text.UTF8Encoding]::new($false,$true).GetString($run.StderrBytes)}catch{$errorText='stderr was not valid UTF-8'}
        Throw-GateResult INVALID "git failed ($($run.ExitCode)): $errorText"
    }
    Write-Output -NoEnumerate ([byte[]]$run.StdoutBytes)
}
function Get-GateExceptionScope {
    [pscustomobject]@{RegistryPath='config/skillspector-exceptions.json';BaselinePrefix='config/skillspector-exceptions/'}
}
function Test-GateExceptionPathInScope([string]$Path) {
    $scope=Get-GateExceptionScope;$comparisonKey=ConvertTo-GateExceptionPathComparisonKey $Path
    $comparisonKey.Equals($scope.RegistryPath,[StringComparison]::Ordinal)-or`
        $comparisonKey.StartsWith($scope.BaselinePrefix,[StringComparison]::Ordinal)
}
function Assert-GateProtectedFilesWithExceptionShrinkOnly([string]$AuthorityRoot,[string]$BaseRoot,[string]$CandidateRoot,$ManifestEntry,
    [string]$BaseRevision,[string]$CandidateRevision,[bool]$Transition) {
    Assert-GateExceptionSetShrinkOnly $CandidateRoot $BaseRevision $CandidateRevision $AuthorityRoot
    Assert-GateProtectedFiles $AuthorityRoot $BaseRoot $CandidateRoot $ManifestEntry $BaseRevision $CandidateRevision $Transition
}
function ConvertTo-GateExceptionPathComparisonKey([string]$Path) {
    $Path.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
}
function Test-GateExceptionPathPatternCouldMatch([string]$Pattern,[string]$Target,[switch]$TargetIsPrefix) {
    $pending=[Collections.Generic.Stack[Tuple[int,int]]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending.Push([Tuple]::Create([int]0,[int]0))
    while($pending.Count-gt0){
        $state=$pending.Pop();$patternIndex=$state.Item1;$targetIndex=$state.Item2
        if(-not$seen.Add("$patternIndex`:$targetIndex")){continue}
        if($TargetIsPrefix-and$targetIndex-eq$Target.Length){return $true}
        if($patternIndex-eq$Pattern.Length){if($targetIndex-eq$Target.Length){return $true};continue}
        if($Pattern[$patternIndex]-eq[char]0xfffd){
            # Each loose-decoder replacement marker can stand for one non-ASCII position only, never an arbitrary
            # substring. The canonical registry path and baseline prefix are entirely ASCII, so invalid UTF-8
            # cannot decode or normalize into any of their characters.
            if($targetIndex-lt$Target.Length-and[int]$Target[$targetIndex]-gt127){
                $pending.Push([Tuple]::Create($patternIndex+1,$targetIndex+1))
            }
        }elseif($targetIndex-lt$Target.Length-and$Pattern[$patternIndex]-ceq$Target[$targetIndex]){
            $pending.Push([Tuple]::Create($patternIndex+1,$targetIndex+1))
        }
    }
    $false
}
function Get-GateExceptionTree([string]$Root,[string]$Revision) {
    [byte[]]$bytes=Invoke-GateGitBytes $Root @('ls-tree','-r','-z','--full-tree',$Revision)
    $tree=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $scope=Get-GateExceptionScope;$registryPath=$scope.RegistryPath;$baselinePrefix=$scope.BaselinePrefix
    $looseUtf8=[Text.UTF8Encoding]::new($false,$false);$strictUtf8=[Text.UTF8Encoding]::new($false,$true)
    $recordStart=0
    for($recordEnd=0;$recordEnd-lt$bytes.Length;$recordEnd++){
        if($bytes[$recordEnd]-ne0){continue}
        if($recordEnd-eq$recordStart){Throw-GateResult INVALID 'SkillSpector exception tree entry is invalid.'}
        [byte[]]$recordBytes=$bytes[$recordStart..($recordEnd-1)];$recordStart=$recordEnd+1
        $tab=[Array]::IndexOf($recordBytes,[byte]9)
        if($tab-le0-or$tab-ge$recordBytes.Length-1){Throw-GateResult INVALID 'SkillSpector exception tree entry is invalid.'}
        [byte[]]$headerBytes=$recordBytes[0..($tab-1)]
        foreach($headerByte in $headerBytes){if($headerByte-gt127){Throw-GateResult INVALID 'SkillSpector exception tree entry is invalid.'}}
        $header=[Text.Encoding]::ASCII.GetString($headerBytes)
        if($header-cnotmatch'^(?<mode>[0-9]{6}) (?<type>[^ ]+) (?<oid>[0-9a-f]{40}|[0-9a-f]{64})$'){
            Throw-GateResult INVALID 'SkillSpector exception tree entry is invalid.'
        }
        $mode=$Matches.mode;$type=$Matches.type;$oid=$Matches.oid
        [byte[]]$pathBytes=$recordBytes[($tab+1)..($recordBytes.Length-1)]
        $loosePath=$looseUtf8.GetString($pathBytes);$comparisonKey=$null;$needsStrict=$false
        try{
            $comparisonKey=ConvertTo-GateExceptionPathComparisonKey $loosePath
            $needsStrict=$comparisonKey.Equals($registryPath,[StringComparison]::Ordinal)-or`
                $comparisonKey.StartsWith($baselinePrefix,[StringComparison]::Ordinal)
            if(-not$needsStrict){
                $replacement=$comparisonKey.IndexOf([char]0xfffd)
                if($replacement-ge0){
                    $needsStrict=(Test-GateExceptionPathPatternCouldMatch $comparisonKey $registryPath)-or`
                        (Test-GateExceptionPathPatternCouldMatch $comparisonKey $baselinePrefix -TargetIsPrefix)
                }
            }
        }catch{$needsStrict=$true}
        if(-not$needsStrict){continue}
        try{$path=$strictUtf8.GetString($pathBytes)}catch{Throw-GateResult INVALID `
            'SkillSpector exception tree contains a non-UTF-8 path within the SkillSpector exception scope.'}
        try{$comparisonKey=ConvertTo-GateExceptionPathComparisonKey $path}catch{Throw-GateResult INVALID `
            'SkillSpector exception tree contains a path that cannot be normalized within the SkillSpector exception scope.'}
        if(-not$comparisonKey.Equals($registryPath,[StringComparison]::Ordinal)-and`
            -not$comparisonKey.StartsWith($baselinePrefix,[StringComparison]::Ordinal)){continue}
        if($mode-cne'100644'){Throw-GateResult BLOCKED "SkillSpector exception path '$path' has mode '$mode'; expected 100644."}
        if($type-cne'blob'-or-not$tree.TryAdd($path,[pscustomobject]@{Path=$path;Mode=$mode;Oid=$oid})){
            Throw-GateResult INVALID "SkillSpector exception path '$path' is not a unique blob."
        }
    }
    if($recordStart-ne$bytes.Length){Throw-GateResult INVALID 'SkillSpector exception tree entry is not NUL terminated.'}
    $tree
}
function Get-GateExceptionBlob([string]$Root,$Entry) {
    [byte[]]$bytes=Invoke-GateGitBytes $Root @('cat-file','blob',[string]$Entry.Oid)
    Write-Output -NoEnumerate $bytes
}
function Join-GateJsonIdentity([string]$Kind,[string[]]$Parts) {
    $builder=[Text.StringBuilder]::new()
    [void]$builder.Append($Kind).Append($Parts.Count).Append(':')
    foreach($part in $Parts){[void]$builder.Append($part.Length).Append(':').Append($part)}
    $builder.ToString()
}
function Get-GateJsonIdentity([Text.Json.JsonElement]$Element) {
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        [string[]]$names=@($Element.EnumerateObject()|ForEach-Object{$_.Name});[Array]::Sort($names,[StringComparer]::Ordinal)
        $parts=[Collections.Generic.List[string]]::new()
        foreach($name in $names){
            $nameIdentity=Join-GateJsonIdentity 's' @($name)
            [void]$parts.Add((Join-GateJsonIdentity 'p' @($nameIdentity,(Get-GateJsonIdentity $Element.GetProperty($name)))))
        }
        return Join-GateJsonIdentity 'o' $parts.ToArray()
    }
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){
        $parts=[Collections.Generic.List[string]]::new()
        foreach($item in $Element.EnumerateArray()){[void]$parts.Add((Get-GateJsonIdentity $item))}
        return Join-GateJsonIdentity 'a' $parts.ToArray()
    }
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::String){return Join-GateJsonIdentity 's' @($Element.GetString())}
    # Preserve the exact JSON number token deliberately: fail closed on 0 versus 0.0 instead of risking lossy CLR conversion.
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Number){return Join-GateJsonIdentity 'n' @($Element.GetRawText())}
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::True){return 't'}
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::False){return 'f'}
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Null){return 'z'}
    Throw-GateResult INVALID 'SkillSpector exception JSON contains an unsupported value kind.'
}
function Get-GateJsonPropertyNames([Text.Json.JsonElement]$Value,[string]$Context) {
    if($Value.ValueKind-ne[Text.Json.JsonValueKind]::Object){Throw-GateResult BLOCKED "$Context top-level value was modified from an object."}
    [string[]]$names=@($Value.EnumerateObject()|ForEach-Object{$_.Name});[Array]::Sort($names,[StringComparer]::Ordinal)
    Write-Output -NoEnumerate $names
}
function Get-GateJsonArrayProperty([Text.Json.JsonElement]$Value,[string]$Name,[string]$Context) {
    if($Value.ValueKind-ne[Text.Json.JsonValueKind]::Object){Throw-GateResult BLOCKED "$Context top-level value was modified from an object."}
    $property=[Text.Json.JsonElement]::new()
    if(-not$Value.TryGetProperty($Name,[ref]$property)){Write-Output -NoEnumerate ([Text.Json.JsonElement[]]@());return}
    if($property.ValueKind-ne[Text.Json.JsonValueKind]::Array){Throw-GateResult BLOCKED "$Context field '$Name' was modified from an array."}
    Write-Output -NoEnumerate ([Text.Json.JsonElement[]]@($property.EnumerateArray()))
}
function Get-GateJsonElementLabel([Text.Json.JsonElement]$Value,[string]$Name) {
    if($Value.ValueKind-ne[Text.Json.JsonValueKind]::Object){return '<non-object>'}
    $property=[Text.Json.JsonElement]::new()
    if(-not$Value.TryGetProperty($Name,[ref]$property)){return '<missing>'}
    if($property.ValueKind-eq[Text.Json.JsonValueKind]::String){return $property.GetString()}
    if($property.ValueKind-in@([Text.Json.JsonValueKind]::Number,[Text.Json.JsonValueKind]::True,`
        [Text.Json.JsonValueKind]::False,[Text.Json.JsonValueKind]::Null)){return $property.GetRawText()}
    Get-GateJsonIdentity $property
}
function Test-GateJsonElementPropertyEqual([Text.Json.JsonElement]$Left,[Text.Json.JsonElement]$Right,[string]$Name) {
    if($Left.ValueKind-ne[Text.Json.JsonValueKind]::Object-or$Right.ValueKind-ne[Text.Json.JsonValueKind]::Object){return $false}
    $leftProperty=[Text.Json.JsonElement]::new();$rightProperty=[Text.Json.JsonElement]::new()
    if(-not$Left.TryGetProperty($Name,[ref]$leftProperty)-or-not$Right.TryGetProperty($Name,[ref]$rightProperty)){return $false}
    (Get-GateJsonIdentity $leftProperty)-ceq(Get-GateJsonIdentity $rightProperty)
}
function Assert-GateJsonOuterFieldsEqual([Text.Json.JsonElement]$Base,[Text.Json.JsonElement]$Candidate,`
    [string[]]$SetFields,[string]$Context) {
    [string[]]$baseNames=Get-GateJsonPropertyNames $Base $Context;[string[]]$candidateNames=Get-GateJsonPropertyNames $Candidate $Context
    if(($baseNames-join"`n")-cne($candidateNames-join"`n")){Throw-GateResult BLOCKED "$Context top-level field set was modified."}
    foreach($name in @($candidateNames|Where-Object{$SetFields-cnotcontains$_})){
        if((Get-GateJsonIdentity $Candidate.GetProperty($name))-cne(Get-GateJsonIdentity $Base.GetProperty($name))){
            Throw-GateResult BLOCKED "$Context field '$name' was modified."
        }
    }
}
function Assert-GateJsonItemsShrinkOnly([Text.Json.JsonElement[]]$BaseItems,[Text.Json.JsonElement[]]$CandidateItems,`
    [string]$Context,[ValidateSet('exception','baseline','fingerprint')][string]$Kind,[string]$SkillId='') {
    $baseIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $BaseItems){[void]$baseIdentities.Add((Get-GateJsonIdentity $item))}
    $candidateIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $CandidateItems){
        $identity=Get-GateJsonIdentity $item
        $itemLabel=if($Kind-ceq'exception'){"exception $(Get-GateJsonElementLabel $item 'exceptionId')"}elseif($Kind-ceq'baseline'){
            "baseline $(Get-GateJsonElementLabel $item 'skillId')"}else{
            "fingerprint (skillId=$SkillId, rule_id=$(Get-GateJsonElementLabel $item 'rule_id'), file=$(Get-GateJsonElementLabel $item 'file'), hash=$(Get-GateJsonElementLabel $item 'hash'))"}
        if(-not$candidateIdentities.Add($identity)){Throw-GateResult BLOCKED "$Context $itemLabel is duplicate."}
        if(-not$baseIdentities.Contains($identity)){
            $modified=$false
            foreach($baseItem in $BaseItems){
                $modificationMatch=if($Kind-ceq'exception'){Test-GateJsonElementPropertyEqual $baseItem $item 'exceptionId'}elseif($Kind-ceq'baseline'){
                    (Test-GateJsonElementPropertyEqual $baseItem $item 'skillId')-or(Test-GateJsonElementPropertyEqual $baseItem $item 'path')}else{
                    (Test-GateJsonElementPropertyEqual $baseItem $item 'rule_id')-and(Test-GateJsonElementPropertyEqual $baseItem $item 'file')}
                if($modificationMatch){$modified=$true;break}
            }
            $changeType=if($modified){'modified'}else{'added'}
            Throw-GateResult BLOCKED "$Context $itemLabel was $changeType."
        }
    }
}
function Get-GateJsonObjectIdentityExcept([Text.Json.JsonElement]$Value,[string[]]$Excluded,[string]$Context) {
    [string[]]$names=Get-GateJsonPropertyNames $Value $Context
    $parts=[Collections.Generic.List[string]]::new()
    foreach($name in @($names|Where-Object{$Excluded-cnotcontains$_})){
        $nameIdentity=Join-GateJsonIdentity 's' @($name)
        [void]$parts.Add((Join-GateJsonIdentity 'p' @($nameIdentity,(Get-GateJsonIdentity $Value.GetProperty($name)))))
    }
    Join-GateJsonIdentity 'o' $parts.ToArray()
}
function Assert-GateJsonItemsScannerTransition([Text.Json.JsonElement[]]$BaseItems,[Text.Json.JsonElement[]]$CandidateItems,`
    [string]$MutableField,[string]$Context,[ValidateSet('exception','fingerprint')][string]$Kind,[string]$SkillId='') {
    $baseByIdentity=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($item in $BaseItems){
        $identity=Get-GateJsonObjectIdentityExcept $item @($MutableField) $Context
        if($baseByIdentity.ContainsKey($identity)){Throw-GateResult BLOCKED "$Context base $Kind identity is ambiguous."}
        $baseByIdentity.Add($identity,$item)
    }
    $candidateIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $CandidateItems){
        $itemLabel=if($Kind-ceq'exception'){"exception $(Get-GateJsonElementLabel $item 'exceptionId')"}else{
            "fingerprint (skillId=$SkillId, rule_id=$(Get-GateJsonElementLabel $item 'rule_id'), file=$(Get-GateJsonElementLabel $item 'file'))"}
        $identity=Get-GateJsonObjectIdentityExcept $item @($MutableField) $Context
        if(-not$candidateIdentities.Add($identity)){Throw-GateResult BLOCKED "$Context $itemLabel is duplicate during scanner transition."}
        if(-not$baseByIdentity.ContainsKey($identity)){Throw-GateResult BLOCKED `
            "$Context $itemLabel changed a field other than '$MutableField' or was added during scanner transition."}
        [string[]]$baseNames=Get-GateJsonPropertyNames $baseByIdentity[$identity] $Context
        [string[]]$candidateNames=Get-GateJsonPropertyNames $item $Context
        if(($baseNames-join"`n")-cne($candidateNames-join"`n")){Throw-GateResult BLOCKED `
            "$Context $itemLabel field set changed during scanner transition."}
    }
}
function Get-GateJsonRequiredString([Text.Json.JsonElement]$Value,[string]$Name,[string]$Context) {
    $property=[Text.Json.JsonElement]::new()
    if($Value.ValueKind-ne[Text.Json.JsonValueKind]::Object-or-not$Value.TryGetProperty($Name,[ref]$property)-or
        $property.ValueKind-ne[Text.Json.JsonValueKind]::String-or[string]::IsNullOrWhiteSpace($property.GetString())){
        Throw-GateResult BLOCKED "$Context requires a nonempty string '$Name'."
    }
    $property.GetString()
}
function Get-GateJsonRequiredPositiveInteger([Text.Json.JsonElement]$Value,[string]$Name,[string]$Context) {
    $property=[Text.Json.JsonElement]::new();[long]$number=0
    if($Value.ValueKind-ne[Text.Json.JsonValueKind]::Object-or-not$Value.TryGetProperty($Name,[ref]$property)-or
        $property.ValueKind-ne[Text.Json.JsonValueKind]::Number-or-not$property.TryGetInt64([ref]$number)-or$number-lt1){
        Throw-GateResult BLOCKED "$Context requires a positive integer '$Name'."
    }
    $number
}
function ConvertTo-GateCanonicalSeverity($Value,[string]$Context) {
    $severity=[string]$Value
    if([string]::IsNullOrWhiteSpace($severity)){Throw-GateResult BLOCKED "$Context has an empty severity."}
    switch($severity.ToLowerInvariant()){
        'critical' {'critical';break}
        'high' {'high';break}
        'medium' {'medium';break}
        'low' {'low';break}
        'informational' {'informational';break}
        'info' {'informational';break}
        default {Throw-GateResult BLOCKED "$Context has unsupported severity '$severity'."}
    }
}
function ConvertTo-GateTransitionExceptionRecord([Text.Json.JsonElement]$Value) {
    $context="SkillSpector scanner-transition exception $(Get-GateJsonElementLabel $Value 'exceptionId')"
    [pscustomobject]@{
        exceptionId=Get-GateJsonRequiredString $Value 'exceptionId' $context
        skillId=Get-GateJsonRequiredString $Value 'skillId' $context
        ruleId=Get-GateJsonRequiredString $Value 'ruleId' $context
        severity=ConvertTo-GateCanonicalSeverity (Get-GateJsonRequiredString $Value 'severity' $context) $context
        file=Get-GateJsonRequiredString $Value 'file' $context
        fingerprint=Get-GateJsonRequiredString $Value 'fingerprint' $context
        startLine=Get-GateJsonRequiredPositiveInteger $Value 'startLine' $context
    }
}
function ConvertTo-GateTransitionFingerprintRecord([Text.Json.JsonElement]$Value,[string]$SkillId) {
    $context="SkillSpector scanner-transition fingerprint for '$SkillId'"
    [pscustomobject]@{
        skillId=$SkillId
        ruleId=Get-GateJsonRequiredString $Value 'rule_id' $context
        file=Get-GateJsonRequiredString $Value 'file' $context
        hash=Get-GateJsonRequiredString $Value 'hash' $context
        reason=Get-GateJsonRequiredString $Value 'reason' $context
    }
}
function Get-GateTransitionExpectations([object[]]$Exceptions,[object[]]$Fingerprints) {
    $used=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectations=[Collections.Generic.List[object]]::new()
    foreach($exception in $Exceptions){
        $matches=@($Fingerprints|Where-Object{
            [string]$_.skillId-ceq[string]$exception.skillId-and[string]$_.ruleId-ceq[string]$exception.ruleId-and
            [string]$_.file-ceq[string]$exception.file-and[string]$_.hash-ceq[string]$exception.fingerprint})
        if($matches.Count-ne1){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition exception '$($exception.exceptionId)' does not match exactly one candidate baseline fingerprint."}
        $match=$matches[0]
        $identity=Join-GateJsonIdentity 'x' @([string]$match.skillId,[string]$match.ruleId,[string]$match.file,[string]$match.hash,[string]$match.reason)
        if(-not$used.Add($identity)){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition fingerprint '$($match.hash)' is paired more than once."}
        [void]$expectations.Add([pscustomobject]@{
            skillId=[string]$match.skillId;ruleId=[string]$match.ruleId;file=[string]$match.file;reason=[string]$match.reason
            severity=[string]$exception.severity;hash=[string]$match.hash;exceptionId=[string]$exception.exceptionId
            startLine=[long]$exception.startLine
        })
    }
    if($used.Count-ne$Fingerprints.Count){Throw-GateResult BLOCKED `
        'SkillSpector scanner-transition candidate baseline contains an unpaired fingerprint.'}
    return $expectations.ToArray()
}
function Test-GateScannerTransitionReferencePath([string]$SkillId,[string]$File) {
    if($SkillId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'-or[string]::IsNullOrWhiteSpace($File)-or
        $File.Contains('\',[StringComparison]::Ordinal)-or[IO.Path]::IsPathRooted($File)-or
        $File.IndexOfAny([char[]]@('*','?','[',']',':'))-ge0-or$File.IndexOfAny([char[]](0..31))-ge0){return $false}
    $segments=@($File-split'/')
    @($segments|Where-Object{$_-in@('','.','..')}).Count-eq0
}
function Assert-GateScannerTransitionReferencedFilesUnchanged([string]$Root,[string]$BaseRevision,`
    [string]$CandidateRevision,[object[]]$Exceptions) {
    foreach($exception in $Exceptions){
        $skillId=[string]$exception.skillId;$file=[string]$exception.file
        if(-not(Test-GateScannerTransitionReferencePath $skillId $file)){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition exception '$($exception.exceptionId)' has an unsafe referenced file: skills/$skillId/$file"}
        $path="skills/$skillId/$file"
        $baseEntry=Get-GateTreeBlobEntry $Root $BaseRevision $path
        $candidateEntry=Get-GateTreeBlobEntry $Root $CandidateRevision $path
        if($null-eq$baseEntry-or$null-eq$candidateEntry-or$baseEntry.Type-cne'blob'-or$candidateEntry.Type-cne'blob'-or
            $baseEntry.Mode-cnotin@('100644','100755')-or$candidateEntry.Mode-cnotin@('100644','100755')-or
            $baseEntry.Mode-cne$candidateEntry.Mode-or$baseEntry.Oid-cne$candidateEntry.Oid){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition referenced file '$path' must be the same regular blob in base and candidate trees."}
    }
}
function Get-GateStandardValidationOutputHash([string]$Stdout,[string]$Stderr) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$Stdout+"`n---stderr---`n"+[string]$Stderr)
        ([BitConverter]::ToString($sha.ComputeHash($bytes))-replace'-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
}
function Get-GateSkillSpectorApprovedSources([string]$AuthorityRoot) {
    if([string]::IsNullOrWhiteSpace($AuthorityRoot)){return $null}
    $toolchain=Read-GateJson (Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json') 'validation toolchain policy'
    $registryPath=Join-Path $AuthorityRoot ([string]$toolchain.tools.skillspector.approvedSources)
    & {
        param([string]$ResolverPath,[string]$ApprovedSourcesPath)
        . $ResolverPath -ValidatePolicyOnly|Out-Null
        Get-SkillSpectorApprovedSources -Path $ApprovedSourcesPath
    } (Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1') $registryPath
}
function Get-GateExceptionScannerTransition([Text.Json.JsonElement]$BaseRegistry,[Text.Json.JsonElement]$CandidateRegistry,`
    [string]$AuthorityRoot) {
    if([string]::IsNullOrWhiteSpace($AuthorityRoot)){return $null}
    $baseScanner=[Text.Json.JsonElement]::new();$candidateScanner=[Text.Json.JsonElement]::new()
    if(-not$BaseRegistry.TryGetProperty('scanner',[ref]$baseScanner)-or-not$CandidateRegistry.TryGetProperty('scanner',[ref]$candidateScanner)-or
        $baseScanner.ValueKind-ne[Text.Json.JsonValueKind]::Object-or$candidateScanner.ValueKind-ne[Text.Json.JsonValueKind]::Object){return $null}
    $baseVersion=[Text.Json.JsonElement]::new();$candidateVersion=[Text.Json.JsonElement]::new()
    $baseWheel=[Text.Json.JsonElement]::new();$candidateWheel=[Text.Json.JsonElement]::new()
    if(-not$baseScanner.TryGetProperty('version',[ref]$baseVersion)-or-not$candidateScanner.TryGetProperty('version',[ref]$candidateVersion)-or
        -not$baseScanner.TryGetProperty('wheelSha256',[ref]$baseWheel)-or-not$candidateScanner.TryGetProperty('wheelSha256',[ref]$candidateWheel)-or
        $baseVersion.ValueKind-ne[Text.Json.JsonValueKind]::String-or$candidateVersion.ValueKind-ne[Text.Json.JsonValueKind]::String-or
        $baseWheel.ValueKind-ne[Text.Json.JsonValueKind]::String-or$candidateWheel.ValueKind-ne[Text.Json.JsonValueKind]::String){return $null}
    $oldVersion=$baseVersion.GetString();$newVersion=$candidateVersion.GetString()
    if($oldVersion-ceq$newVersion){return $null}
    $approved=Get-GateSkillSpectorApprovedSources $AuthorityRoot
    if($null-eq$approved-or[string]$approved.active-cne$newVersion-or[string]$approved.active-ceq$oldVersion){return $null}
    $oldEntries=@($approved.entries.PSObject.Properties|Where-Object{$_.Name-ceq$oldVersion})
    $newEntries=@($approved.entries.PSObject.Properties|Where-Object{$_.Name-ceq$newVersion})
    if($oldEntries.Count-ne1-or$newEntries.Count-ne1-or[string]$baseWheel.GetString()-cne[string]$oldEntries[0].Value.wheelSha256-or
        [string]$candidateWheel.GetString()-cne[string]$newEntries[0].Value.wheelSha256){return $null}
    [pscustomobject]@{OldVersion=$oldVersion;NewVersion=$newVersion;OldEntry=$oldEntries[0].Value;NewEntry=$newEntries[0].Value}
}
function Assert-GateExceptionSetShrinkOnly([string]$CandidateRoot,[string]$BaseRevision,[string]$CandidateRevision,[string]$AuthorityRoot='') {
    $scope=Get-GateExceptionScope;$registryPath=$scope.RegistryPath;$baselinePrefix=$scope.BaselinePrefix
    $baseTree=Get-GateExceptionTree $CandidateRoot $BaseRevision
    $candidateTree=Get-GateExceptionTree $CandidateRoot $CandidateRevision
    foreach($path in $candidateTree.Keys){
        $canonicalPath=ConvertTo-GateExceptionPathComparisonKey $path
        if($path-cne$canonicalPath){Throw-GateResult BLOCKED `
            "SkillSpector exception path '$path' casing or Unicode variant does not match its canonical form."}
        if(-not$baseTree.ContainsKey($path)){Throw-GateResult BLOCKED "SkillSpector exception path '$path' was added."}
    }
    $candidateBaselines=@($candidateTree.Keys|Where-Object{$_.StartsWith($baselinePrefix,[StringComparison]::Ordinal)})
    if(-not$candidateTree.ContainsKey($registryPath)){
        if($candidateBaselines.Count-gt0){Throw-GateResult BLOCKED 'SkillSpector exception registry was deleted while baseline files remain.'}
        return
    }
    $baseRegistryDocument=$null;$candidateRegistryDocument=$null;$scannerTransition=$null
    [object[]]$candidateExceptionRecords=@();$candidateFingerprintRecords=[Collections.Generic.List[object]]::new()
    try{
        $baseRegistryDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $baseTree[$registryPath]) `
            "SkillSpector exception JSON '$registryPath'"
        $candidateRegistryDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $candidateTree[$registryPath]) `
            "SkillSpector exception JSON '$registryPath'"
        $baseRegistry=$baseRegistryDocument.RootElement;$candidateRegistry=$candidateRegistryDocument.RootElement
        $scannerTransition=Get-GateExceptionScannerTransition $baseRegistry $candidateRegistry $AuthorityRoot
        if($null-eq$scannerTransition){
            Assert-GateJsonOuterFieldsEqual $baseRegistry $candidateRegistry @('baselines','exceptions') "SkillSpector exception registry '$registryPath'"
        }else{
            Assert-GateJsonOuterFieldsEqual $baseRegistry $candidateRegistry @('baselines','exceptions','scanner') `
                "SkillSpector exception registry '$registryPath' scanner transition"
            Assert-GateJsonOuterFieldsEqual $baseRegistry.GetProperty('scanner') $candidateRegistry.GetProperty('scanner') `
                @('version','wheelSha256') "SkillSpector exception registry '$registryPath' scanner"
        }
        [Text.Json.JsonElement[]]$baseExceptions=Get-GateJsonArrayProperty $baseRegistry 'exceptions' "SkillSpector exception registry '$registryPath'"
        [Text.Json.JsonElement[]]$candidateExceptions=Get-GateJsonArrayProperty $candidateRegistry 'exceptions' "SkillSpector exception registry '$registryPath'"
        if($null-eq$scannerTransition){
            Assert-GateJsonItemsShrinkOnly $baseExceptions $candidateExceptions "SkillSpector exception registry '$registryPath'" 'exception'
        }else{
            Assert-GateJsonItemsScannerTransition $baseExceptions $candidateExceptions 'fingerprint' `
                "SkillSpector exception registry '$registryPath'" 'exception'
            $candidateExceptionRecords=@($candidateExceptions|ForEach-Object{ConvertTo-GateTransitionExceptionRecord $_})
        }
        [Text.Json.JsonElement[]]$baseBaselines=Get-GateJsonArrayProperty $baseRegistry 'baselines' "SkillSpector exception registry '$registryPath'"
        [Text.Json.JsonElement[]]$candidateRegistryBaselines=Get-GateJsonArrayProperty $candidateRegistry 'baselines' "SkillSpector exception registry '$registryPath'"
        Assert-GateJsonItemsShrinkOnly $baseBaselines $candidateRegistryBaselines "SkillSpector exception registry '$registryPath'" 'baseline'
    }finally{
        if($null-ne$candidateRegistryDocument){$candidateRegistryDocument.Dispose()}
        if($null-ne$baseRegistryDocument){$baseRegistryDocument.Dispose()}
    }
    foreach($path in $candidateBaselines){
        if($path-cnotmatch'^config/skillspector-exceptions/(?<skillId>[^/]+)\.baseline\.json$'){
            if($candidateTree[$path].Oid-cne$baseTree[$path].Oid){Throw-GateResult BLOCKED "SkillSpector exception path '$path' was modified."}
            if($path.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)){
                $document=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $candidateTree[$path]) "SkillSpector exception JSON '$path'"
                $document.Dispose()
            }
            continue
        }
        $skillId=$Matches.skillId
        $baseBaselineDocument=$null;$candidateBaselineDocument=$null
        try{
            $baseBaselineDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $baseTree[$path]) "SkillSpector exception JSON '$path'"
            $candidateBaselineDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $candidateTree[$path]) "SkillSpector exception JSON '$path'"
            $baseBaseline=$baseBaselineDocument.RootElement;$candidateBaseline=$candidateBaselineDocument.RootElement
            if($null-eq$scannerTransition){
                Assert-GateJsonOuterFieldsEqual $baseBaseline $candidateBaseline @('fingerprints') "SkillSpector baseline '$path'"
            }else{
                Assert-GateJsonOuterFieldsEqual $baseBaseline $candidateBaseline @('fingerprints','scanner_version') `
                    "SkillSpector baseline '$path' scanner transition"
                if((Get-GateJsonRequiredString $baseBaseline 'scanner_version' "SkillSpector baseline '$path'")-cne$scannerTransition.OldVersion-or
                    (Get-GateJsonRequiredString $candidateBaseline 'scanner_version' "SkillSpector baseline '$path'")-cne$scannerTransition.NewVersion){
                    Throw-GateResult BLOCKED "SkillSpector baseline '$path' scanner_version does not match the scanner transition."
                }
            }
            [Text.Json.JsonElement[]]$baseFingerprints=Get-GateJsonArrayProperty $baseBaseline 'fingerprints' "SkillSpector baseline '$path'"
            [Text.Json.JsonElement[]]$candidateFingerprints=Get-GateJsonArrayProperty $candidateBaseline 'fingerprints' "SkillSpector baseline '$path'"
            if($null-eq$scannerTransition){
                Assert-GateJsonItemsShrinkOnly $baseFingerprints $candidateFingerprints "SkillSpector baseline '$path'" 'fingerprint' $skillId
            }else{
                Assert-GateJsonItemsScannerTransition $baseFingerprints $candidateFingerprints 'hash' `
                    "SkillSpector baseline '$path'" 'fingerprint' $skillId
                foreach($fingerprint in $candidateFingerprints){
                    [void]$candidateFingerprintRecords.Add((ConvertTo-GateTransitionFingerprintRecord $fingerprint $skillId))
                }
            }
        }finally{
            if($null-ne$candidateBaselineDocument){$candidateBaselineDocument.Dispose()}
            if($null-ne$baseBaselineDocument){$baseBaselineDocument.Dispose()}
        }
    }
    if($null-ne$scannerTransition){
        [void](Get-GateTransitionExpectations $candidateExceptionRecords $candidateFingerprintRecords.ToArray())
        Assert-GateScannerTransitionReferencedFilesUnchanged $CandidateRoot $BaseRevision $CandidateRevision $candidateExceptionRecords
    }
}
function Get-GateCandidateTransitionExpectations([string]$CandidateRoot,[string]$CandidateRevision) {
    $scope=Get-GateExceptionScope;$tree=Get-GateExceptionTree $CandidateRoot $CandidateRevision
    $registryDocument=$null;$exceptions=@();$fingerprints=[Collections.Generic.List[object]]::new()
    try{
        $registryDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $tree[$scope.RegistryPath]) `
            "SkillSpector exception JSON '$($scope.RegistryPath)'"
        [Text.Json.JsonElement[]]$items=Get-GateJsonArrayProperty $registryDocument.RootElement 'exceptions' 'SkillSpector exception registry'
        $exceptions=@($items|ForEach-Object{ConvertTo-GateTransitionExceptionRecord $_})
    }finally{if($null-ne$registryDocument){$registryDocument.Dispose()}}
    foreach($path in @($tree.Keys|Where-Object{$_-match'^config/skillspector-exceptions/(?<skillId>[^/]+)\.baseline\.json$'})){
        $skillId=[regex]::Match($path,'^config/skillspector-exceptions/(?<skillId>[^/]+)\.baseline\.json$').Groups['skillId'].Value
        $document=$null
        try{
            $document=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $tree[$path]) "SkillSpector exception JSON '$path'"
            [Text.Json.JsonElement[]]$items=Get-GateJsonArrayProperty $document.RootElement 'fingerprints' "SkillSpector baseline '$path'"
            foreach($item in $items){[void]$fingerprints.Add((ConvertTo-GateTransitionFingerprintRecord $item $skillId))}
        }finally{if($null-ne$document){$document.Dispose()}}
    }
    Get-GateTransitionExpectations $exceptions $fingerprints.ToArray()
}
function Assert-GateTransitionSuppressedFindings([object[]]$Expectations,$SuppressedFindings) {
    if($SuppressedFindings-isnot[array]-or$SuppressedFindings.Count-ne$Expectations.Count){Throw-GateResult BLOCKED `
        'SkillSpector scanner transition did not use every candidate baseline fingerprint exactly once in this run.'}
    foreach($expectation in $Expectations){
        $matches=@($SuppressedFindings|Where-Object{
            [string]$_.skillId-ceq$expectation.skillId-and[string]$_.ruleId-ceq$expectation.ruleId-and
            [string]$_.file-ceq$expectation.file-and[string]$_.suppressionReason-ceq$expectation.reason-and
            (ConvertTo-GateCanonicalSeverity $_.severity 'SkillSpector scanner-transition suppressed finding')-ceq$expectation.severity})
        if($matches.Count-ne1){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition fingerprint '$($expectation.hash)' was not used exactly once with its approved severity in this run."}
        $line=$matches[0].line
        if(($line-isnot[int]-and$line-isnot[long])-or[long]$line-ne[long]$expectation.startLine){Throw-GateResult BLOCKED `
            "SkillSpector scanner-transition exception '$($expectation.exceptionId)' suppressed finding line does not match startLine."
        }
    }
}
function Assert-GateExceptionScannerTransitionEvidence([string]$AuthorityRoot,[string]$CandidateRoot,[string]$BaseRevision,`
    [string]$CandidateRevision,$Report,[string]$ArtifactsRoot) {
    $scope=Get-GateExceptionScope;$baseTree=Get-GateExceptionTree $CandidateRoot $BaseRevision
    $candidateTree=Get-GateExceptionTree $CandidateRoot $CandidateRevision
    if(-not$baseTree.ContainsKey($scope.RegistryPath)-or-not$candidateTree.ContainsKey($scope.RegistryPath)){return}
    $baseDocument=$null;$candidateDocument=$null
    try{
        $baseDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $baseTree[$scope.RegistryPath]) 'base SkillSpector exception registry'
        $candidateDocument=Open-GateJsonDocument (Get-GateExceptionBlob $CandidateRoot $candidateTree[$scope.RegistryPath]) 'candidate SkillSpector exception registry'
        $transition=Get-GateExceptionScannerTransition $baseDocument.RootElement $candidateDocument.RootElement $AuthorityRoot
    }finally{
        if($null-ne$candidateDocument){$candidateDocument.Dispose()};if($null-ne$baseDocument){$baseDocument.Dispose()}
    }
    if($null-eq$transition){return}
    [void](Assert-GateExceptionSetShrinkOnly $CandidateRoot $BaseRevision $CandidateRevision $AuthorityRoot)
    [object[]]$expectations=@(Get-GateCandidateTransitionExpectations $CandidateRoot $CandidateRevision)
    $events=@($Report.sourceValidation.events|Where-Object{[string]$_.toolId-ceq'static-analyzer'})
    if($events.Count-ne1-or-not(Test-GatePathWithin ([string]$events[0].outputPath) $ArtifactsRoot)){Throw-GateResult BLOCKED `
        'SkillSpector scanner transition has no unique authority-bound static analyzer event.'}
    $eventPath=[string]$events[0].outputPath;$eventHash=[string]$events[0].outputSha256
    if($eventHash-cnotmatch'^[0-9a-f]{64}$'-or-not(Test-Path -LiteralPath $eventPath -PathType Leaf)){Throw-GateResult BLOCKED `
        'SkillSpector scanner transition static analyzer event has no valid reported output hash.'}
    $rawFileHash=Get-GateSha256 $eventPath
    $raw=Read-GateJson $eventPath 'SkillSpector scanner-transition raw event'
    if((Get-GateSha256 $eventPath)-cne$rawFileHash){Throw-GateResult BLOCKED `
        'SkillSpector scanner transition static analyzer event changed during final comparison.'}
    if((Get-GateStandardValidationOutputHash ([string]$raw.stdout) ([string]$raw.stderr))-cne$eventHash){Throw-GateResult BLOCKED `
        'SkillSpector scanner transition static analyzer output hash does not match its raw stdout and stderr.'}
    if([string]$events[0].status-ceq'platform-unavailable'){return}
    try{$envelope=([string]$raw.stdout)|ConvertFrom-Json -Depth 100 -ErrorAction Stop}catch{Throw-GateResult BLOCKED `
        'SkillSpector scanner-transition raw envelope is unavailable for final comparison.'}
    $property=$envelope.PSObject.Properties['suppressedFindings']
    if($null-eq$property){Throw-GateResult BLOCKED 'SkillSpector scanner transition did not report suppressed findings.'}
    Assert-GateTransitionSuppressedFindings $expectations $property.Value
}
Export-ModuleMember -Function *
