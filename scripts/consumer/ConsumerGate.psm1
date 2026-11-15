# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitCodes = @{ BLOCKED = 10
 FAILED = 20
 INVALID = 30
 CANCELLED = 40 }

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
function Assert-GateExceptionSetUnchanged([string]$CandidateRoot,[string]$BaseRevision,[string]$CandidateRevision) {
    $changed=@((Invoke-GateGit $CandidateRoot @('diff','--name-only',$BaseRevision,$CandidateRevision,'--','config/skillspector-exceptions.json',`
        'config/skillspector-exceptions')).Output|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    if($changed.Count-gt0){Throw-GateResult BLOCKED 'SkillSpector exception set changed and requires the PR-2 signed approval path.'}
}
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
        $release=Invoke-GateAcquisitionRequest metadata $metadataUri $headers $null
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
        [void](Invoke-GateAcquisitionRequest download ([uri][string]$hashAsset[0].browser_download_url) $headers $hashes)
        [void](Invoke-GateAcquisitionRequest download ([uri][string]$asset[0].browser_download_url) $headers $archive)
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
        $lease=Open-PlatformDirectory -Root $pwshRoot -RootOnly
        try{$receipt=Resolve-PlatformPowerShell -Policy $policy -DestinationLease $lease -OfflineCache $archive `
            -ReleaseMetadata @{assets=@(@{name=$assetName
            sha256=$sha})}}finally{$lease.Dispose()}
    }
    Write-GateBoundaryEvent 'runtime-installed'
    $receipt
}
function Invoke-GateResolver([string]$PowerShell,[string]$AuthorityRoot,[string]$InstallRoot,[string]$Tool,[string]$RunId,[string]$OutputPath,`
    [string]$GoVersion,[string]$Token) {
    foreach($name in @('GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$Token,'Process')
    try{
        $resolverPath=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH)){
            Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
        }else{[IO.Path]::GetFullPath($env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH)}
        if(-not(Test-Path -LiteralPath $resolverPath -PathType Leaf)){Throw-GateResult INVALID 'Resolver executable source is invalid.'}
        $arguments = @('-NoProfile','-NonInteractive','-File',$resolverPath,
            '-PolicyPath',(Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json'),'-ToolName',$Tool,'-Install',
            '-InstallRoot',$InstallRoot,'-ExpectedGoRuntimeVersion',$GoVersion,'-RunId',$RunId,'-OutputPath',$OutputPath)
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$PowerShell
        $start.UseShellExecute=$false
        $start.RedirectStandardOutput=$true
        $start.RedirectStandardError=$true
        foreach($argument in $arguments){[void]$start.ArgumentList.Add($argument)}
        $preserved=@{}
        foreach($name in @('PATH','Path','PATHEXT','SystemRoot','WINDIR','TEMP','TMP','TMPDIR','HOME','USERPROFILE','PSModulePath','PSExecutionPolicyPreference')){
            $value=[Environment]::GetEnvironmentVariable($name,'Process');if($null-ne$value){$preserved[$name]=$value}
        }
        $start.Environment.Clear()
        foreach($name in $preserved.Keys){$start.Environment[$name]=[string]$preserved[$name]}
        if(-not[string]::IsNullOrEmpty($Token)){$start.Environment['STANDARD_VALIDATION_GITHUB_API_TOKEN']=$Token}
        $process=[Diagnostics.Process]::new()
        try{$process.StartInfo=$start;[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $process.WaitForExit();$standardOutput=$stdout.GetAwaiter().GetResult();$standardError=$stderr.GetAwaiter().GetResult();$exitCode=$process.ExitCode
            if(-not[string]::IsNullOrEmpty($Token)-and($standardOutput.Contains($Token,[StringComparison]::Ordinal)-or
                $standardError.Contains($Token,[StringComparison]::Ordinal))){Throw-GateResult FAILED 'Resolver output contained a credential sentinel.'}}
        finally{[void]$start.Environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN');$preserved.Clear();$start.Environment.Clear()
            $standardOutput=$null;$standardError=$null;$stdout=$null;$stderr=$null;$process.Dispose();$start=$null;$Token=$null
            Remove-Variable standardOutput,standardError,stdout,stderr,preserved,process,start,Token -ErrorAction SilentlyContinue}
        if($exitCode-ne0){Throw-GateResult FAILED "Resolver failed for $Tool."}
    }finally{foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $Token=$null
    Remove-Variable Token -ErrorAction SilentlyContinue}
    Read-GateJson $OutputPath "$Tool resolver receipt"
}
function New-GateSourceSetup([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$PowerShell,[string]$RunId,`
    [string]$AuthorityRevision,[string]$CandidateRevision,[string]$SourceRepository,[string]$Token) {
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
}
function Invoke-GateCredentialScopedPreparation([string]$WorkRoot,[string]$Token,[scriptblock]$Action) {
    $failure=$null
    $result=$null
    try{$result=& $Action}catch{$failure=$_}finally{
        foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        Assert-GateCredentialAbsent $WorkRoot $Token
        $Token=$null
        Remove-Variable Token -ErrorAction SilentlyContinue
    }
    if($null-ne$failure){throw $failure}
    $result
}
function New-GateAdapter([string]$Path,$Config,$Setup,[string]$PowerShell) {
    $executable=[string]$Setup.repositoryCheck
    $executableSha256=Get-GateSha256 $executable
    $checks=@(
        [ordered]@{id='repository-general'
        kind='general'
        executable=$executable
        executableSha256=$executableSha256
        arguments=@('-Mode','general')},
        [ordered]@{id='repository-pester'
        kind='pester'
        executable=$executable
        executableSha256=$executableSha256
        arguments=@('-Mode','pester','-PesterReceiptSha256',[string]$Setup.pesterReceiptSha256,'-PesterManifestSha256',`
            [string]$Setup.pesterManifestSha256,'-PesterVersion',[string]$Setup.pesterVersion)}
    )
    Write-GateJsonCreateOnly $Path([ordered]@{schemaVersion=2
    adapter='standard-core-adapter-v2'
    skillsRoot='skills'
    activeSkills=@($Config.activeSkills)
    checks=$checks
    sourceValidation=$Setup.sourceValidation})
}
function Invoke-GateValidation([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,$Config,[string]$PowerShell) {
    $setup=Read-GateJson (Join-Path $WorkRoot 'source-tools.json') 'source tool setup'
    $adapter=Join-Path $WorkRoot 'consumer-core-adapter.json'
    New-GateAdapter $adapter $Config $setup $PowerShell
    $artifacts=Join-Path $WorkRoot 'validation-artifacts'
    [IO.Directory]::CreateDirectory($artifacts)|Out-Null
    $output=Join-Path $artifacts 'consumer-core-evidence.json'
    & $PowerShell -NoProfile -NonInteractive -File (Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1') -CandidateRoot `
        $CandidateRoot -AdapterPath $adapter -ArtifactsRoot $artifacts -OutputPath $output -SourceRepository ([string]$Config.sourceRepository) `
            -SourceRevision ([string]$Binding.candidateRevision) -BaseRevision ([string]$Binding.baseRevision) -EventName (`
                [string]$Binding.canonicalEvent) -RunId ([string]$Binding.runId) -AuthorityRevision ([string]$Binding.commit) -TrustedToolRoot (`
                    [string]$setup.trustedRoot) -SourceValidation -TimeoutSeconds 1800
    if($LASTEXITCODE-ne0){exit $LASTEXITCODE}
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
    Assert-GatePlatformTestInventory $cases
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
        $null -eq $receipt.platformTestInventory -or
        -not $seen.Add([string]$receipt.platform) -or
        [string]$receipt.platform -cnotin @('windows','linux','macos')
    ) {
        Throw-GateResult FAILED 'Leg platform set is invalid.'
    }
    Assert-GatePlatformTestInventory $receipt.platformTestInventory
    foreach($pair in @(@('result','PASS'),@('runId',[string]$Binding.runId),@('candidateRevision',[string]$Binding.candidateRevision),@(`
        'headRevision',[string]$Binding.headRevision),@('baseRevision',[string]$Binding.baseRevision),@('authorityCommit',`
            [string]$Binding.commit),@('aiiMainTip',[string]$Binding.aiiMainTip),@('interface','consumer-gate-v1'),@('triggerEvent',`
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

function Initialize-GateGitHooks([string]$WorkRoot) {
    if ($null -ne $script:GateGitHooksPath) { Throw-GateResult INVALID 'Git hooks isolation was initialized more than once.' }
    $script:GateGitHooksPath = New-GateGitHooksDirectory $WorkRoot
}

function Invoke-GateGit([string]$Root,[string[]]$Arguments,[int[]]$Allowed=@(0)) {
    if ([string]::IsNullOrWhiteSpace($script:GateGitHooksPath)) { Throw-GateResult INVALID 'Git hooks isolation is not initialized.' }
    $output = @(& git -c "core.hooksPath=$script:GateGitHooksPath" -c protocol.file.allow=never `
        -c credential.helper= -C $Root @Arguments 2>&1)
    $exit = $LASTEXITCODE
    if ($exit -notin $Allowed) { Throw-GateResult INVALID "git failed ($exit): $($output -join ' ')" }
    [pscustomobject]@{ ExitCode=$exit
     Output=$output }
}

function Test-GateSafeRelativePath([string]$Path,[string[]]$Roots,[switch]$DirectoryPrefix) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\',[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($Path)) { return $false }
    $value = if ($DirectoryPrefix) { $Path.TrimEnd('/') } else { $Path }
    if ($DirectoryPrefix -and -not $Path.EndsWith('/',[StringComparison]::Ordinal)) { return $false }
    if ($value -cnotmatch '^(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$') { return $false }
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

function Assert-GateProtectedFiles([string]$AuthorityRoot,[string]$BaseRoot,[string]$CandidateRoot,$ManifestEntry,
    [string]$BaseRevision,[string]$CandidateRevision,[bool]$Transition) {
    $candidateBootstrap = Join-Path $CandidateRoot 'scripts/Invoke-PinnedAuthority.ps1'
     $baseBootstrap = Join-Path $BaseRoot 'scripts/Invoke-PinnedAuthority.ps1'
    $templateBootstrap = Join-Path $AuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
    if (-not (Test-GateBytesEqual $candidateBootstrap $templateBootstrap) -and -not (Test-GateBytesEqual $candidateBootstrap $baseBootstrap)) {
        Throw-GateResult FAILED 'Candidate bootstrap differs from both authority template and base.'
    }
    $workflowRoot = Join-Path $CandidateRoot '.github/workflows'
     $allowed = @('consumer-gate.yml','consumer-gate-transition.yml')
    $items = @(Get-ChildItem -LiteralPath $workflowRoot -Recurse -Force -ErrorAction Stop)
    if (@($items | Where-Object PSIsContainer).Count -ne 0) { Throw-GateResult FAILED 'Nested workflow directories are not allowed.' }
    foreach ($file in @($items)) {
        $relative = [IO.Path]::GetRelativePath($workflowRoot,$file.FullName).Replace('\','/')
        if ($relative.Contains('/') -or $allowed -cnotcontains $relative) { Throw-GateResult FAILED "Unexpected workflow: $relative" }
        $template = Join-Path $AuthorityRoot "consumer/workflows/$relative"
         $base = Join-Path $BaseRoot ".github/workflows/$relative"
        if ($relative -ceq 'consumer-gate-transition.yml' -and -not $Transition -and -not (Test-Path $base -PathType Leaf)) {
            Throw-GateResult FAILED 'Transition workflow is not allowed after transition.'
        }
        if (-not (Test-GateBytesEqual $file.FullName $template) -and -not (Test-GateBytesEqual $file.FullName $base)) {
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
        if ($Transition -and $record.disposition -ceq 'retain') {
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
        AuthorityRoot=$AuthorityRoot}
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
    $needle=[Text.Encoding]::Latin1.GetString([Text.UTF8Encoding]::new($false).GetBytes($Token))
    foreach($path in @(Get-GateCredentialSurfaceFiles $Root)){$content=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($path))
    if($content.IndexOf($needle,[StringComparison]::Ordinal)-ge0){Throw-GateResult FAILED 'Credential sentinel remained in a gate-owned output surface.'}}
}

function Invoke-GateAcquisitionRequest([string]$Operation,[uri]$Uri,[hashtable]$Headers,[string]$Destination) {
    $timeoutSeconds=if([string]::IsNullOrWhiteSpace($env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS)){100}else{
        [int]$env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS}
    if($timeoutSeconds-lt1-or$timeoutSeconds-gt600){Throw-GateResult INVALID 'Acquisition timeout setting is invalid.'}
    $cancelPath=[string]$env:CONSUMER_GATE_ACQUISITION_CANCEL_PATH
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
    foreach($name in $Headers.Keys){[void]$request.Headers.TryAddWithoutValidation([string]$name,[string]$Headers[$name])}
    $cts=[Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds($timeoutSeconds))
    [Net.Http.HttpResponseMessage]$response=$null
    try{
        if(-not[string]::IsNullOrWhiteSpace($cancelPath)-and(Test-Path -LiteralPath $cancelPath)){Throw-GateResult CANCELLED `
            'GATE_ACQUISITION_CANCELLED: acquisition was cancelled.'}
        try{$response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()}
        catch [OperationCanceledException]{
            if(-not[string]::IsNullOrWhiteSpace($cancelPath)-and(Test-Path -LiteralPath $cancelPath)){Throw-GateResult CANCELLED `
                'GATE_ACQUISITION_CANCELLED: acquisition was cancelled.'}
            Throw-GateResult FAILED 'GATE_ACQUISITION_TIMEOUT: acquisition timed out.'
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
        if($null-ne$response){$response.Dispose()};$request.Dispose();$client.Dispose();$handler.Dispose();$cts.Dispose()
        $bytes=$null;$buffer=$null;$response=$null;$request=$null;$stream=$null;$memory=$null;$Headers=$null
        Remove-Variable bytes,buffer,response,request,stream,memory,Headers -ErrorAction SilentlyContinue
    }
}
Export-ModuleMember -Function *
