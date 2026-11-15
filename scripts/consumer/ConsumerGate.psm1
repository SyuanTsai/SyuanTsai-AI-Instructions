# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitCodes = @{ BLOCKED = 10; FAILED = 20; INVALID = 30; CANCELLED = 40 }

function Throw-GateResult([string]$State, [string]$Message) { throw "$State|$Message" }
function Get-GateSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
function Test-GatePathWithin([string]$Path, [string]$Root) {
    $p=[IO.Path]::GetFullPath($Path); $r=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $p.Equals($r,$comparison)-or $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,$comparison)
}
function Assert-GateExactProperties($Value,[string[]]$Expected,[string]$Context) {
    $actual=@($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count -or @($actual|Where-Object{$Expected-cnotcontains $_}).Count-ne 0) { Throw-GateResult INVALID "$Context has an unexpected property set." }
}
function Assert-GateNoDuplicateJson([Text.Json.JsonElement]$Element,[string]$Context) {
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){if(-not$seen.Add($property.Name)){Throw-GateResult INVALID "$Context has duplicate or case-conflicting keys."};Assert-GateNoDuplicateJson $property.Value $Context}
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){foreach($item in $Element.EnumerateArray()){Assert-GateNoDuplicateJson $item $Context}}
}
function Read-GateJson([string]$Path,[string]$Context) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){Throw-GateResult INVALID "$Context is missing."}
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){Throw-GateResult INVALID "$Context must be a regular file."}
    $bytes=[IO.File]::ReadAllBytes($item.FullName)
    if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){Throw-GateResult INVALID "$Context has a UTF-8 BOM."}
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-GateNoDuplicateJson $document.RootElement $Context}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }catch{if($_.Exception.Message-match'^(BLOCKED|FAILED|INVALID|CANCELLED)\|'){throw};Throw-GateResult INVALID "$Context is not unambiguous UTF-8 JSON."}
}
function Write-GateJsonCreateOnly([string]$Path,$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 60)+"`n")
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Invoke-GateGit([string]$Root,[string[]]$Arguments,[int[]]$Allowed=@(0)) {
    $hooks=Join-Path([IO.Path]::GetTempPath())'consumer-gate-disabled-hooks';[IO.Directory]::CreateDirectory($hooks)|Out-Null
    $output=@(& git -c "core.hooksPath=$hooks" -c protocol.file.allow=never -c credential.helper= -C $Root @Arguments 2>&1);$exit=$LASTEXITCODE
    if($exit-notin$Allowed){Throw-GateResult INVALID "git failed ($exit): $($output-join' ')"}
    [pscustomobject]@{ExitCode=$exit;Output=$output}
}
function Get-GateManifestEntry([string]$AuthorityRoot,[string]$RepositoryId) {
    $manifest=Read-GateJson (Join-Path $AuthorityRoot 'consumer/legacy-migration.json') 'legacy migration manifest'
    Assert-GateExactProperties $manifest @('schemaVersion','repositories') 'legacy migration manifest'
    if($manifest.schemaVersion-ne1-or$manifest.repositories-isnot[array]-or@($manifest.repositories).Count-ne5-or@($manifest.repositories.id|Select-Object -Unique).Count-ne5-or@($manifest.repositories.repository|Select-Object -Unique).Count-ne5){Throw-GateResult INVALID 'Legacy migration manifest inventory is invalid.'}
    $matches=@($manifest.repositories|Where-Object{[string]$_.id-ceq$RepositoryId})
    if($matches.Count-ne1){Throw-GateResult INVALID 'repositoryId has no unique legacy manifest entry.'}
    $entry=$matches[0];Assert-GateExactProperties $entry @('id','repository','status','inventoryCommit','inventoryTree','requiredRepositoryChecks','files') 'legacy repository entry'
    if([string]$entry.repository-cnotmatch'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$'-or[string]$entry.status-cnotin@('ready','deferred')-or[string]$entry.inventoryCommit-cnotmatch'^[0-9a-f]{40}$'-or[string]$entry.inventoryTree-cnotmatch'^[0-9a-f]{40}$'-or$entry.requiredRepositoryChecks-isnot[array]-or$entry.files-isnot[array]){Throw-GateResult INVALID 'Legacy repository entry is invalid.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($required in @($entry.requiredRepositoryChecks)){
        Assert-GateExactProperties $required @('id','kind','path') 'legacy required check'
        $kind=[string]$required.kind;$path=[string]$required.path
        if([string]$required.id-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'-or$kind-cnotin@('general','pester')-or($kind-ceq'pester'-and$path-cne'tests')-or($kind-ceq'general'-and($path-cnotmatch'^(?:scripts|tests)/[A-Za-z0-9._/-]+\.ps1$'-or$path-match'\.Tests\.ps1$'))-or-not$ids.Add([string]$required.id)-or-not$paths.Add($path)){Throw-GateResult INVALID 'Legacy required check IDs and paths must be unique and valid.'}
    }
    $filePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($record in @($entry.files)){
        $expected=if([string]$record.disposition-ceq'split'){@('path','disposition','target','reason')}else{@('path','disposition','reason')};Assert-GateExactProperties $record $expected 'legacy file disposition'
        if([string]$record.path-cnotmatch'^(?:\.github|config|scripts|tests)/[A-Za-z0-9._/-]+$'-or[string]$record.path-match'(?:^|/)\.\.(?:/|$)'-or-not$filePaths.Add([string]$record.path)-or[string]$record.disposition-cnotin@('delete','split','retain','update-tests')-or[string]::IsNullOrWhiteSpace([string]$record.reason)){Throw-GateResult INVALID 'Legacy file disposition is invalid.'}
        if([string]$record.disposition-ceq'split'-and([string]$record.target-cnotmatch'^(?:scripts|tests)/[A-Za-z0-9._/-]+$'-or[string]$record.target-match'(?:^|/)\.\.(?:/|$)')){Throw-GateResult INVALID 'Legacy split target is invalid.'}
    }
    $entry
}
function Get-GateActiveSkills([string]$CandidateRoot) {
    $paths=@((Invoke-GateGit $CandidateRoot @('ls-files','--','skills/*/SKILL.md')).Output|ForEach-Object{[string]$_}|Where-Object{$_-match'^skills/([^/]+)/SKILL\.md$'}|ForEach-Object{$Matches[1]}|Sort-Object -Unique)
    if($paths.Count-eq0){Throw-GateResult INVALID 'Tracked snapshot contains no active Skill.'};[string[]]$paths
}
function Assert-GateConfig([string]$AuthorityRoot,[string]$CandidateRoot,[string]$EventRepository) {
    $config=Read-GateJson (Join-Path $CandidateRoot 'config/consumer-gate.json') 'consumer gate config'
    Assert-GateExactProperties $config @('schemaVersion','repositoryId','sourceRepository','activeSkills','repositoryChecks') 'consumer gate config'
    if($config.schemaVersion-ne1-or[string]$config.repositoryId-cnotmatch'^[a-z0-9]+(?:-[a-z0-9]+)*$'-or[string]$config.sourceRepository-cnotmatch'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$'-or[string]$config.sourceRepository-cne$EventRepository){Throw-GateResult INVALID 'Consumer gate config identity is invalid.'}
    if($config.activeSkills-isnot[array]-or$config.repositoryChecks-isnot[array]-or@($config.repositoryChecks).Count-eq0){Throw-GateResult INVALID 'Consumer gate config arrays are invalid.'}
    $declaredSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($skill in @($config.activeSkills)){if($skill-isnot[string]-or[string]$skill-cnotmatch'^[a-z0-9]+(?:-[a-z0-9]+)*$'-or-not$declaredSet.Add([string]$skill)){Throw-GateResult INVALID 'activeSkills must contain unique safe Skill IDs.'}}
    $actualSkills=Get-GateActiveSkills $CandidateRoot;$declared=@([string[]]$config.activeSkills|Sort-Object)
    if(($actualSkills-join"`n")-cne($declared-join"`n")){Throw-GateResult INVALID 'activeSkills differs from the tracked snapshot.'}
    $entry=Get-GateManifestEntry $AuthorityRoot ([string]$config.repositoryId)
    if([string]$entry.repository-cne$EventRepository){Throw-GateResult INVALID 'Event repository differs from the legacy manifest.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($check in @($config.repositoryChecks)){
        Assert-GateExactProperties $check @('id','kind','path') "repository check"
        if([string]$check.id-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'-or-not$ids.Add([string]$check.id)-or-not$paths.Add([string]$check.path)){Throw-GateResult INVALID 'Repository check IDs and paths must be safe and unique.'}
        if([string]$check.kind-ceq'general'){
            if([string]$check.path-cnotmatch'^(?:scripts|tests)/.+\.ps1$'-or[string]$check.path-match'\.Tests\.ps1$'){Throw-GateResult INVALID 'General repository check path is invalid.'}
            $tracked=@((Invoke-GateGit $CandidateRoot @('ls-files','--',[string]$check.path)).Output);if($tracked.Count-ne1){Throw-GateResult INVALID 'General repository check is not a tracked file.'}
            $generalPath=Join-Path $CandidateRoot ([string]$check.path);if(-not(Test-Path -LiteralPath $generalPath -PathType Leaf)){Throw-GateResult INVALID 'General repository check is missing.'};$generalItem=Get-Item -LiteralPath $generalPath -Force -ErrorAction Stop
            if($generalItem.PSIsContainer-or($generalItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$generalItem.LinkType){Throw-GateResult INVALID 'General repository check must be a regular file.'}
            if(@($entry.files|Where-Object{[string]$_.path-ceq[string]$check.path-and[string]$_.disposition-ceq'delete'}).Count-ne0){Throw-GateResult INVALID 'General repository check points to a deleted legacy path.'}
        }elseif([string]$check.kind-ceq'pester'){
            if([string]$check.path-cne'tests'){Throw-GateResult INVALID 'Pester repository check must discover the complete tests tree.'}
        }else{Throw-GateResult INVALID 'Unknown repository check kind.'}
    }
    if(@($config.repositoryChecks|Where-Object{[string]$_.kind-ceq'general'}).Count-lt1-or@($config.repositoryChecks|Where-Object{[string]$_.kind-ceq'pester'}).Count-ne1){Throw-GateResult INVALID 'Consumer config requires repository general checks and one complete Pester check.'}
    foreach($required in @($entry.requiredRepositoryChecks)){
        $matches=@($config.repositoryChecks|Where-Object{[string]$_.id-ceq[string]$required.id-and[string]$_.kind-ceq[string]$required.kind-and[string]$_.path-ceq[string]$required.path})
        if($matches.Count-ne1){Throw-GateResult INVALID "Required repository check is missing: $($required.id)"}
    }
    [pscustomobject]@{Config=$config;ManifestEntry=$entry;ActiveSkills=$actualSkills}
}
function Test-GateBytesEqual([string]$Left,[string]$Right) {
    if(-not(Test-Path -LiteralPath $Left -PathType Leaf)-or-not(Test-Path -LiteralPath $Right -PathType Leaf)){return $false}
    foreach($path in @($Left,$Right)){$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$null-ne$item.LinkType){return $false}}
    (Get-GateSha256 $Left)-ceq(Get-GateSha256 $Right)
}
function Assert-GateProtectedFiles([string]$AuthorityRoot,[string]$BaseRoot,[string]$CandidateRoot,$ManifestEntry,[bool]$Transition) {
    $candidateBootstrap=Join-Path $CandidateRoot 'scripts/Invoke-PinnedAuthority.ps1';$baseBootstrap=Join-Path $BaseRoot 'scripts/Invoke-PinnedAuthority.ps1';$templateBootstrap=Join-Path $AuthorityRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
    if(-not((Test-GateBytesEqual $candidateBootstrap $templateBootstrap)-or(Test-GateBytesEqual $candidateBootstrap $baseBootstrap))){Throw-GateResult FAILED 'Candidate bootstrap differs from both authority template and base.'}
    $allowed=@('consumer-gate.yml','consumer-gate-transition.yml');$candidateWorkflowRoot=Join-Path $CandidateRoot '.github/workflows'
    if(-not(Test-Path -LiteralPath (Join-Path $candidateWorkflowRoot 'consumer-gate.yml') -PathType Leaf)){Throw-GateResult FAILED 'Candidate consumer-gate.yml is missing.'}
    if($Transition-and-not(Test-Path -LiteralPath (Join-Path $candidateWorkflowRoot 'consumer-gate-transition.yml') -PathType Leaf)){Throw-GateResult FAILED 'Transition workflow is missing during conversion.'}
    foreach($file in @(Get-ChildItem -LiteralPath $candidateWorkflowRoot -File -Force -ErrorAction Stop)){
        if($allowed-cnotcontains$file.Name){Throw-GateResult FAILED "Unexpected workflow: $($file.Name)"}
        $template=Join-Path $AuthorityRoot ("consumer/workflows/"+$file.Name);$base=Join-Path $BaseRoot (".github/workflows/"+$file.Name)
        if($file.Name-ceq'consumer-gate-transition.yml'-and-not$Transition-and-not(Test-Path -LiteralPath $base -PathType Leaf)){Throw-GateResult FAILED 'Transition workflow is not allowed after transition.'}
        if(-not((Test-GateBytesEqual $file.FullName $template)-or(Test-GateBytesEqual $file.FullName $base))){Throw-GateResult FAILED "Workflow differs from both authority template and base: $($file.Name)"}
    }
    foreach($record in @($ManifestEntry.files|Where-Object{[string]$_.disposition-ceq'delete'})){
        if(Test-Path -LiteralPath (Join-Path $CandidateRoot ([string]$record.path))){Throw-GateResult FAILED "Deleted legacy path is present: $($record.path)"}
    }
}
function Assert-GateTransitionInventory([string]$BaseRoot,$Entry,[string]$BaseRevision,[bool]$Transition) {
    if(-not$Transition){return}
    $tree=([string](Invoke-GateGit $BaseRoot @('rev-parse',"$BaseRevision^{tree}")).Output[0]).Trim()
    if([string]$Entry.status-ceq'deferred'){Throw-GateResult BLOCKED 'This repository migration is deferred.'}
    if([string]$Entry.inventoryCommit-cne$BaseRevision-or[string]$Entry.inventoryTree-cne$tree){Throw-GateResult BLOCKED 'Repository has advanced; regenerate its manifest in an AII PR first.'}
}
function Assert-GateExceptionSetUnchanged([string]$CandidateRoot,[string]$BaseRevision,[string]$CandidateRevision) {
    $changed=@((Invoke-GateGit $CandidateRoot @('diff','--name-only',$BaseRevision,$CandidateRevision,'--','config/skillspector-exceptions.json','config/skillspector-exceptions')).Output|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    if($changed.Count-gt0){Throw-GateResult BLOCKED 'SkillSpector exception set changed and requires the PR-2 signed approval path.'}
}
function Copy-GateTrustedFile([string]$Source,[string]$Destination) {
    if(Test-Path -LiteralPath $Destination){Throw-GateResult FAILED 'Trusted runtime file destination already exists.'}
    [IO.File]::Copy($Source,$Destination,$false);if((Get-GateSha256 $Source)-cne(Get-GateSha256 $Destination)){Throw-GateResult FAILED 'Trusted runtime file copy changed bytes.'}
}
function Get-GateReleaseAssetName([string]$Version,[string]$Platform) {
    $architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if($architecture-cnotin@('x64','arm64')){Throw-GateResult INVALID 'Unsupported runner architecture.'}
    if($Platform-ceq'windows'){"PowerShell-$Version-win-$architecture.zip"}elseif($Platform-ceq'linux'){"powershell-$Version-linux-$architecture.tar.gz"}else{"powershell-$Version-osx-$architecture.tar.gz"}
}
function Install-GatePowerShell([string]$AuthorityRoot,[string]$WorkRoot,[string]$Platform,[string]$Token) {
    $runtimeRoot=Join-Path $WorkRoot 'runtime';$pwshRoot=Join-Path $runtimeRoot 'pwsh';$downloads=Join-Path $runtimeRoot 'downloads'
    foreach($path in @($runtimeRoot,$pwshRoot,$downloads)){[IO.Directory]::CreateDirectory($path)|Out-Null}
    $headers=@{'User-Agent'='consumer-gate-v1';Accept='application/vnd.github+json'};if(-not[string]::IsNullOrEmpty($Token)){$headers.Authorization="Bearer $Token"}
    try{
        $release=Invoke-RestMethod -Uri'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'-Headers $headers -Method Get
        if($release.draft-or$release.prerelease-or[string]$release.tag_name-cnotmatch'^v([0-9]+\.[0-9]+\.[0-9]+)$'){Throw-GateResult FAILED 'Latest official PowerShell release metadata is not stable.'}
        $version=$Matches[1];$assetName=Get-GateReleaseAssetName $version $Platform
        $asset=@($release.assets|Where-Object{[string]$_.name-ceq$assetName});$hashAsset=@($release.assets|Where-Object{[string]$_.name-ceq'hashes.sha256'})
        if($asset.Count-ne1-or$hashAsset.Count-ne1){Throw-GateResult FAILED 'Official PowerShell release assets are incomplete.'}
        $releasePrefix="https://github.com/PowerShell/PowerShell/releases/download/v$version/"
        if(-not([string]$asset[0].browser_download_url).StartsWith($releasePrefix,[StringComparison]::Ordinal)-or-not([string]$hashAsset[0].browser_download_url).StartsWith($releasePrefix,[StringComparison]::Ordinal)){Throw-GateResult FAILED 'PowerShell release assets are not on the approved official endpoint.'}
        $archive=Join-Path $downloads $assetName;$hashes=Join-Path $downloads 'hashes.sha256'
        Invoke-WebRequest -Uri([string]$hashAsset[0].browser_download_url)-Headers $headers -OutFile $hashes
        Invoke-WebRequest -Uri([string]$asset[0].browser_download_url)-Headers $headers -OutFile $archive
        $line=@([IO.File]::ReadAllLines($hashes)|Where-Object{$_-match("^([0-9a-f]{64})\s+\*?"+[regex]::Escape($assetName)+"$")})
        if($line.Count-ne1){Throw-GateResult FAILED 'Official PowerShell hashes do not bind the selected asset.'};$sha=$line[0].Substring(0,64)
        if((Get-GateSha256 $archive)-cne$sha){Throw-GateResult FAILED 'Downloaded PowerShell archive hash differs from the official manifest.'}
    }finally{$headers.Remove('Authorization');$Token=$null;[Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$null,'Process')}
    Import-Module (Join-Path $AuthorityRoot 'scripts/platform-runtime.psd1') -Force
    $lease=Open-PlatformDirectory -Root $pwshRoot -RootOnly
    try{$receipt=Resolve-PlatformPowerShell -Policy @{version=$version;assets=@(@{name=$assetName;sha256=$sha})} -DestinationLease $lease -OfflineCache $archive -ReleaseMetadata @{assets=@(@{name=$assetName;sha256=$sha})}}finally{$lease.Dispose()}
    $receipt
}
function Invoke-GateResolver([string]$PowerShell,[string]$AuthorityRoot,[string]$InstallRoot,[string]$Tool,[string]$RunId,[string]$OutputPath,[string]$GoVersion,[string]$Token) {
    [Environment]::SetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN',$Token,'Process')
    try{
        & $PowerShell -NoProfile -NonInteractive -File (Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1') -PolicyPath (Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json') -ToolName $Tool -Install -InstallRoot $InstallRoot -ExpectedGoRuntimeVersion $GoVersion -RunId $RunId -OutputPath $OutputPath
        if($LASTEXITCODE-ne0){Throw-GateResult FAILED "Resolver failed for $Tool."}
    }finally{foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')};$Token=$null}
    Read-GateJson $OutputPath "$Tool resolver receipt"
}
function New-GateSourceSetup([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$PowerShell,[string]$RunId,[string]$AuthorityRevision,[string]$CandidateRevision,[string]$SourceRepository,[string]$Token) {
    $setupRoot=Join-Path $WorkRoot 'source-tools';[IO.Directory]::CreateDirectory($setupRoot)|Out-Null;$installRoot=Join-Path $WorkRoot 'runtime/installed';[IO.Directory]::CreateDirectory($installRoot)|Out-Null
    $goVersion=[string]$env:STANDARD_GO_RUNTIME_VERSION;if([string]::IsNullOrWhiteSpace($goVersion)){$goVersion='latest'}
    $receipts=@{};$bindings=@()
    foreach($tool in @('pester','skill-validator','skill-tools','skillspector')){
        $path=Join-Path $setupRoot ("receipt-$tool.json");$receipts[$tool]=Invoke-GateResolver $PowerShell $AuthorityRoot $installRoot $tool $RunId $path $goVersion $Token
        if($tool-cne'pester'){$bindings+= [pscustomobject]@{path=[IO.Path]::GetFullPath($path);sha256=Get-GateSha256 $path}}
    }
    $trustedRoot=Join-Path $WorkRoot 'runtime/trusted';[IO.Directory]::CreateDirectory($trustedRoot)|Out-Null
    $child=Join-Path $trustedRoot 'Invoke-ConsumerValidationChild.ps1';Copy-GateTrustedFile (Join-Path $AuthorityRoot 'scripts/consumer/Invoke-ConsumerValidationChild.ps1') $child
    $repositoryCheck=Join-Path $trustedRoot 'Invoke-ConsumerRepositoryCheck.ps1';Copy-GateTrustedFile (Join-Path $AuthorityRoot 'scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1') $repositoryCheck
    $archive=Join-Path $setupRoot 'candidate.zip';[void](Invoke-GateGit $CandidateRoot @('archive','--format=zip',"--output=$archive",$CandidateRevision))
    $toolchain=[ordered]@{
        centralRunnerPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'));centralRunnerSha256=Get-GateSha256 (Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1')
        upstreamAdapterValidatorPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1'));upstreamAdapterValidatorSha256=Get-GateSha256 (Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1')
        upstreamPolicyPath=[IO.Path]::GetFullPath((Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json'));upstreamPolicySha256=Get-GateSha256 (Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json')
        skillValidatorPath=[string]$receipts.'skill-validator'.executablePath;skillValidatorSha256=[string]$receipts.'skill-validator'.executableSha256
        skillToolsNodePath=[string]$receipts.'skill-tools'.nodePath;skillToolsNodeSha256=[string]$receipts.'skill-tools'.nodeSha256
        skillToolsEntryPointPath=[string]$receipts.'skill-tools'.entryPointPath;skillToolsEntryPointSha256=[string]$receipts.'skill-tools'.entryPointSha256
        skillSpectorPath=[string]$receipts.skillspector.executablePath;skillSpectorSha256=[string]$receipts.skillspector.executableSha256
        pesterModulePath=[string]$receipts.pester.modulePath;pesterModuleSha256=[string]$receipts.pester.executableSha256;pesterVersion=[string]$receipts.pester.resolvedVersion
    }
    $toolchainPath=Join-Path $setupRoot 'toolchain.json';Write-GateJsonCreateOnly $toolchainPath $toolchain
    $common=@('-NoProfile','-NonInteractive','-File',$child,'-ToolchainPath',$toolchainPath,'-ToolchainSha256',(Get-GateSha256 $toolchainPath),'-SourceRepository',$SourceRepository,'-SourceRevision',$CandidateRevision,'-ArchiveSha256',(Get-GateSha256 $archive))
    $frozenPaths=@($PowerShell,$child,$repositoryCheck,$toolchainPath,$toolchain.centralRunnerPath,$toolchain.upstreamAdapterValidatorPath,$toolchain.upstreamPolicyPath,$toolchain.skillValidatorPath,$toolchain.skillToolsNodePath,$toolchain.skillToolsEntryPointPath,$toolchain.skillSpectorPath,$toolchain.pesterModulePath)+@($bindings.path)
    $frozen=@($frozenPaths|Select-Object -Unique|ForEach-Object{[pscustomobject]@{path=[IO.Path]::GetFullPath([string]$_);sha256=Get-GateSha256([string]$_)}})
    $dispatch=[ordered]@{packageAdapter=@{command=$PowerShell;arguments=@($common+@('-Mode','package-adapter'))};skillValidator=@{command=$PowerShell;arguments=@($common+@('-Mode','skill-validator'))};skillTools=@{command=$PowerShell;arguments=@($common+@('-Mode','skill-tools'))};staticAnalyzer=@{command=$PowerShell;arguments=@($common+@('-Mode','static'))};frozenFiles=$frozen;toolReceipts=$bindings}
    $prepared=[ordered]@{schemaVersion=1;report='consumer-source-tools-v1';runId=$RunId;sourceRevision=$CandidateRevision;authorityRevision=$AuthorityRevision;ownedRoot=$setupRoot;trustedRoot=(Join-Path $WorkRoot 'runtime');repositoryCheck=$repositoryCheck;pesterReceiptSha256=Get-GateSha256 (Join-Path $setupRoot 'receipt-pester.json');pesterManifestSha256=[string]$toolchain.pesterModuleSha256;pesterVersion=[string]$toolchain.pesterVersion;sourceValidation=$dispatch}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'source-tools.json') $prepared;$prepared
}
function Assert-GateCredentialAbsent([string]$Root,[string]$Token) {
    if([string]::IsNullOrEmpty($Token)){return};$needle=[Text.Encoding]::Latin1.GetString([Text.UTF8Encoding]::new($false).GetBytes($Token))
    foreach($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)){
        $content=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
        if($content.IndexOf($needle,[StringComparison]::Ordinal)-ge0){Throw-GateResult FAILED 'Credential sentinel remained in WorkRoot.'}
    }
}
function Invoke-GateCredentialScopedPreparation([string]$WorkRoot,[string]$Token,[scriptblock]$Action) {
    $failure=$null;$result=$null
    try{$result=& $Action}catch{$failure=$_}finally{
        foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        Assert-GateCredentialAbsent $WorkRoot $Token
        $Token=$null
    }
    if($null-ne$failure){throw $failure}
    $result
}
function New-GateAdapter([string]$Path,$Config,$Setup,[string]$PowerShell) {
    $executable=[string]$Setup.repositoryCheck;$executableSha256=Get-GateSha256 $executable
    $checks=@(
        [ordered]@{id='repository-general';kind='general';executable=$executable;executableSha256=$executableSha256;arguments=@('-Mode','general')},
        [ordered]@{id='repository-pester';kind='pester';executable=$executable;executableSha256=$executableSha256;arguments=@('-Mode','pester','-PesterReceiptSha256',[string]$Setup.pesterReceiptSha256,'-PesterManifestSha256',[string]$Setup.pesterManifestSha256,'-PesterVersion',[string]$Setup.pesterVersion)}
    )
    Write-GateJsonCreateOnly $Path([ordered]@{schemaVersion=2;adapter='standard-core-adapter-v2';skillsRoot='skills';activeSkills=@($Config.activeSkills);checks=$checks;sourceValidation=$Setup.sourceValidation})
}
function Invoke-GateValidation([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,$Config,[string]$PowerShell) {
    $setup=Read-GateJson (Join-Path $WorkRoot 'source-tools.json') 'source tool setup';$adapter=Join-Path $WorkRoot 'consumer-core-adapter.json';New-GateAdapter $adapter $Config $setup $PowerShell
    $artifacts=Join-Path $WorkRoot 'validation-artifacts';[IO.Directory]::CreateDirectory($artifacts)|Out-Null;$output=Join-Path $artifacts 'consumer-core-evidence.json'
    & $PowerShell -NoProfile -NonInteractive -File (Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1') -CandidateRoot $CandidateRoot -AdapterPath $adapter -ArtifactsRoot $artifacts -OutputPath $output -SourceRepository ([string]$Config.sourceRepository) -SourceRevision ([string]$Binding.candidateRevision) -BaseRevision ([string]$Binding.baseRevision) -EventName ([string]$Binding.canonicalEvent) -RunId ([string]$Binding.runId) -AuthorityRevision ([string]$Binding.commit) -TrustedToolRoot ([string]$setup.trustedRoot) -SourceValidation -TimeoutSeconds 1800
    if($LASTEXITCODE-ne0){exit $LASTEXITCODE}
    $report=Read-GateJson $output 'source validation evidence'
    if([string]$report.state-cne'PASS'-or[bool]$report.releaseEligible){Throw-GateResult FAILED 'Source validation evidence is not a passing source result.'}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'validated-report-binding.json') ([ordered]@{schemaVersion=1;runId=[string]$Binding.runId;candidateRevision=[string]$Binding.candidateRevision;baseRevision=[string]$Binding.baseRevision;authorityCommit=[string]$Binding.commit;canonicalEvent=[string]$Binding.canonicalEvent;evidenceSha256=Get-GateSha256 $output})
}
function Assert-GateFinalSourceReport([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,$Report,[string]$EvidencePath) {
    $runner=Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
    . $runner -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath (Join-Path $WorkRoot 'consumer-core-adapter.json') `
        -ArtifactsRoot (Join-Path $WorkRoot 'validation-artifacts') -OutputPath $EvidencePath -SourceRepository ([string]$env:CONSUMER_GATE_EVENT_REPOSITORY) `
        -SourceRevision ([string]$Binding.candidateRevision) -BaseRevision ([string]$Binding.baseRevision)
    $security=Read-GateJson (Join-Path $AuthorityRoot 'docs/standards/validation-security-gate.json') 'validation security policy'
    $stages=@($security.stages|Where-Object{[string]$_.id-ceq'skillspector-static'})
    if($stages.Count-ne1-or$null-eq$stages[0].platformUnavailableException){Throw-GateResult INVALID 'Validation security policy has no unique platformUnavailableException contract.'}
    Assert-StandardCoreSourceCheckReport -Report $Report -ExpectedSourceRevision([string]$Binding.candidateRevision) `
        -ExpectedBaseRevision([string]$Binding.baseRevision) -ExpectedAuthorityRevision([string]$Binding.commit) `
        -ExpectedEventName ([string]$Binding.canonicalEvent) -ArtifactsRoot (Join-Path $WorkRoot 'validation-artifacts') `
        -OutputPath $EvidencePath -ProcessExitCode 0 -ValidationSecurityPolicy $stages[0].platformUnavailableException
}
function Assert-GatePlatformTestInventory($Inventory) {
    Assert-GateExactProperties $Inventory @('sha256','caseDiscoveryCount','caseExecutionCount','testFileInventory','containerFileInventory','discoveredCaseFileInventory') 'platform test inventory'
    $discoveryIsInteger=$Inventory.caseDiscoveryCount-is[int]-or$Inventory.caseDiscoveryCount-is[long]
    $executionIsInteger=$Inventory.caseExecutionCount-is[int]-or$Inventory.caseExecutionCount-is[long]
    if([string]$Inventory.sha256-cnotmatch'^[0-9a-f]{64}$'-or-not$discoveryIsInteger-or-not$executionIsInteger-or
        [long]$Inventory.caseDiscoveryCount-lt1-or[long]$Inventory.caseExecutionCount-ne[long]$Inventory.caseDiscoveryCount){Throw-GateResult FAILED 'Platform test inventory counts are invalid.'}
    foreach($name in @('testFileInventory','containerFileInventory','discoveredCaseFileInventory')){
        $values=@($Inventory.$name)
        if($Inventory.$name-isnot[array]-or$values.Count-lt1-or@($values|Where-Object{$_-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$_)}).Count-ne0-or@($values|Select-Object -Unique).Count-ne$values.Count){Throw-GateResult FAILED "Platform test inventory is invalid: $name"}
    }
}
function Write-GateLegReceipt([string]$AuthorityRoot,[string]$CandidateRoot,[string]$WorkRoot,$Binding,[string]$Platform) {
    $evidencePath=Join-Path $WorkRoot 'validation-artifacts/consumer-core-evidence.json';$report=Read-GateJson $evidencePath 'source validation evidence'
    Assert-GateFinalSourceReport $AuthorityRoot $CandidateRoot $WorkRoot $Binding $report $evidencePath
    $validated=Read-GateJson (Join-Path $WorkRoot 'validated-report-binding.json') 'validated report binding'
    Assert-GateExactProperties $validated @('schemaVersion','runId','candidateRevision','baseRevision','authorityCommit','canonicalEvent','evidenceSha256') 'validated report binding'
    if($validated.schemaVersion-ne1){Throw-GateResult FAILED 'Validated source report binding schema is invalid.'}
    foreach($pair in @(@('runId',[string]$Binding.runId),@('candidateRevision',[string]$Binding.candidateRevision),@('baseRevision',[string]$Binding.baseRevision),@('authorityCommit',[string]$Binding.commit),@('canonicalEvent',[string]$Binding.canonicalEvent),@('evidenceSha256',(Get-GateSha256 $evidencePath)))){if([string]$validated.($pair[0])-cne[string]$pair[1]){Throw-GateResult FAILED "Validated source report binding changed: $($pair[0])"}}
    $caseBinding=$report.sourceValidation.pesterCaseInventory;Assert-GateExactProperties $caseBinding @('path','sha256') 'source Pester case inventory binding';$casePath=[string]$caseBinding.path
    if(-not(Test-GatePathWithin $casePath (Join-Path $WorkRoot 'validation-artifacts'))-or(Get-GateSha256 $casePath)-cne[string]$caseBinding.sha256){Throw-GateResult FAILED 'Source Pester case inventory changed after validation.'}
    $cases=Read-GateJson $casePath 'source Pester case inventory'
    $inventory=[ordered]@{sha256=[string]$caseBinding.sha256;caseDiscoveryCount=[int]$cases.caseDiscoveryCount;caseExecutionCount=[int]$cases.caseExecutionCount;testFileInventory=@($cases.testFileInventory);containerFileInventory=@($cases.containerFileInventory);discoveredCaseFileInventory=@($cases.discoveredCaseFileInventory)}
    Assert-GatePlatformTestInventory ([pscustomobject]$inventory)
    $receipt=[ordered]@{schemaVersion=1;report='consumer-gate-leg-receipt-v1';result='PASS';platform=$Platform;runId=[string]$Binding.runId;candidateRevision=[string]$Binding.candidateRevision;headRevision=[string]$Binding.headRevision;baseRevision=[string]$Binding.baseRevision;authorityCommit=[string]$Binding.commit;aiiMainTip=[string]$Binding.aiiMainTip;interface='consumer-gate-v1';triggerEvent=[string]$Binding.triggerEvent;canonicalEvent=[string]$Binding.canonicalEvent;platformTestInventory=$inventory;evidenceSha256=Get-GateSha256 $evidencePath}
    $root=Join-Path $WorkRoot 'receipts';[IO.Directory]::CreateDirectory($root)|Out-Null;Write-GateJsonCreateOnly (Join-Path $root ("leg-$Platform.json")) $receipt
}
function Invoke-GateAggregate([string]$WorkRoot,$Binding) {
    $root=Join-Path $WorkRoot 'receipts';$files=@(Get-ChildItem -LiteralPath $root -File -Filter '*.json' -ErrorAction Stop)
    if($files.Count-ne3){Throw-GateResult FAILED 'Aggregate requires exactly three leg receipts.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($file in $files){$receipt=Read-GateJson $file.FullName 'leg receipt';Assert-GateExactProperties $receipt @('schemaVersion','report','result','platform','runId','candidateRevision','headRevision','baseRevision','authorityCommit','aiiMainTip','interface','triggerEvent','canonicalEvent','platformTestInventory','evidenceSha256') 'leg receipt';if($receipt.schemaVersion-ne1-or[string]$receipt.report-cne'consumer-gate-leg-receipt-v1'-or[string]$receipt.evidenceSha256-cnotmatch'^[0-9a-f]{64}$'-or$null-eq$receipt.platformTestInventory-or-not$seen.Add([string]$receipt.platform)-or[string]$receipt.platform-cnotin @('windows','linux','macos')){Throw-GateResult FAILED 'Leg platform set is invalid.'};Assert-GatePlatformTestInventory $receipt.platformTestInventory;foreach($pair in @(@('result','PASS'),@('runId',[string]$Binding.runId),@('candidateRevision',[string]$Binding.candidateRevision),@('headRevision',[string]$Binding.headRevision),@('baseRevision',[string]$Binding.baseRevision),@('authorityCommit',[string]$Binding.commit),@('aiiMainTip',[string]$Binding.aiiMainTip),@('interface','consumer-gate-v1'),@('triggerEvent',[string]$Binding.triggerEvent),@('canonicalEvent',[string]$Binding.canonicalEvent))){if([string]$receipt.($pair[0])-cne[string]$pair[1]){Throw-GateResult FAILED "Leg receipt binding differs: $($pair[0])"}}}
    if(($seen|Sort-Object)-join','-cne'linux,macos,windows'){Throw-GateResult FAILED 'Aggregate platform set is incomplete.'}
    $output=[ordered]@{schemaVersion=1;report='consumer-gate-aggregate-receipt-v1';result='PASS';runId=[string]$Binding.runId;authorityCommit=[string]$Binding.commit;platforms=@('windows','linux','macos')}
    Write-GateJsonCreateOnly (Join-Path $WorkRoot 'aggregate-receipt.json') $output
    if(-not[string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)){[IO.File]::AppendAllText($env:GITHUB_OUTPUT,"authorityCommit=$($Binding.commit)`n",[Text.UTF8Encoding]::new($false))}
}
Export-ModuleMember -Function *
