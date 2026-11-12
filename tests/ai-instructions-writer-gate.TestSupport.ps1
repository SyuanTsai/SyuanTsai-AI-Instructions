$script:RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PowerShellExecutable=(Get-Process -Id $PID).Path
$script:InstallerPath=Join-Path $script:RepositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'scripts\platform-runtime.psd1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-composition.psm1') -Force
$script:P7eUnavailableCapability = @(
    (Get-PlatformCapabilities -Required @()).capabilities |
        Where-Object { [string]$_.status -cne 'available' } |
        Select-Object -ExpandProperty name
)[0]

function New-P7eSourceArchive {
    param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $root=[IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
            $files=@(Get-ChildItem -LiteralPath (Join-Path $root 'scripts'),(Join-Path $root 'catalog') -Recurse -File)
            $files+=@(Get-ChildItem -LiteralPath $root -File|Where-Object Name -in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json'))
            foreach($file in @($files|Sort-Object FullName)){
                $relative=$file.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry=$archive.CreateEntry("candidate-root/$relative")
                $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
                try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
    return (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-P7eV3Candidate {
    param([Parameter(Mandatory=$true)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination|Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts'),(Join-Path $script:RepositoryRoot 'catalog') -Destination $Destination -Recurse
    foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $leaf) -Destination (Join-Path $Destination $leaf)}
    Copy-Item -LiteralPath (Join-Path $Destination 'catalog\examples\skills-catalog-v3.example.json') -Destination (Join-Path $Destination 'catalog\skills-catalog.json') -Force
    Copy-Item -LiteralPath (Join-Path $Destination 'catalog\examples\skills-catalog-lock-v3.example.json') -Destination (Join-Path $Destination 'catalog\skills-catalog-lock.json') -Force
    $installerPath=Join-Path $Destination 'scripts\install-ai-instructions-bootstrap.ps1'
    $installer=[IO.File]::ReadAllText($installerPath)
    $marker='$projectionRuntimeAvailable = $false # P7E_TEST_FIXTURE_MARKER: production remains unavailable until production pins are installed.'
    if(-not$installer.Contains($marker)){throw 'P7e test-only writer marker was not found.'}
    $installer=$installer.Replace($marker,'$projectionRuntimeAvailable = $true # P7E_TEST_FIXTURE_MARKER: isolated Catalog v3 test candidate only.')
    [IO.File]::WriteAllText($installerPath,$installer,[Text.UTF8Encoding]::new($false))
    $fanOutStub=@'
[CmdletBinding()]
param([string]$CatalogPath,[string]$LockPath,[string]$ConfigurationPath,[string]$RuntimeRoot,[string]$TargetRoot,[string]$UserHome,[switch]$WhatIf)
if([string]::IsNullOrWhiteSpace($TargetRoot)){throw 'P7e fan-out fixture requires TargetRoot.'}
New-Item -ItemType Directory -Force -Path $TargetRoot|Out-Null
[IO.File]::WriteAllText((Join-Path $TargetRoot 'p7e-fanout.txt'),"v3v5`n",[Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText((Join-Path $Destination 'scripts\bootstrap-ai-instructions-multisource.ps1'),$fanOutStub,[Text.UTF8Encoding]::new($false))
}

function Invoke-P7eInstaller {
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [Parameter(Mandatory=$true)][string]$CodexHome,
        [ValidateSet('Auto','V2V4','V3V5')][string]$WriterSchema='Auto',
        [string]$SourceCommit,
        [string]$ExpectedCurrentGeneration
    )
    $archive=Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome)+'.zip')
    $hash=New-P7eSourceArchive -SourceRoot $SourceRoot -ArchivePath $archive
    $commit=if([string]::IsNullOrWhiteSpace($SourceCommit)){(@(& git -C $script:RepositoryRoot rev-parse HEAD)-join'').Trim()}else{$SourceCommit}
    $installer=Join-Path $SourceRoot 'scripts\install-ai-instructions-bootstrap.ps1'
    $arguments=@('-NoProfile','-NonInteractive','-File',$installer,'-RepositoryRoot',$SourceRoot,'-CodexHome',$CodexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$commit,'-ArchiveSha256',$hash,'-SourceArchivePath',$archive,'-WriterSchema',$WriterSchema)
    if(-not[string]::IsNullOrWhiteSpace($ExpectedCurrentGeneration)){$arguments+=@('-ExpectedCurrentGeneration',$ExpectedCurrentGeneration)}
    $output=& $script:PowerShellExecutable @arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
}

function Get-P7eTreeSnapshot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return '<root-absent>'}
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $entries=New-Object System.Collections.Generic.List[string]
    $rootItem=Get-Item -Force -LiteralPath $rootPath
    $rootKind=if(($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse'}elseif($rootItem.PSIsContainer){'directory'}else{'file'}
    $entries.Add(".<TAB>$rootKind<TAB>$([int64]$rootItem.Attributes)<TAB>-")
    foreach($item in @(Get-ChildItem -Force -LiteralPath $rootPath -Recurse)){
        $kind=if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse'}elseif($item.PSIsContainer){'directory'}else{'file'}
        $relative=$item.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $hash=if($kind-ceq'file'){(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}else{'-'}
        $entries.Add("$relative<TAB>$kind<TAB>$([int64]$item.Attributes)<TAB>$hash")
    }
    $values=$entries.ToArray();[Array]::Sort($values,[StringComparer]::Ordinal)
    return ($values -join "`n").Replace('<TAB>',"`t")
}

function Copy-P7eHome {
    param([string]$Source,[string]$Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    return $Destination
}

function Invoke-P7eLauncherFailure {
    param([string]$CodexHome,[string]$TargetRoot,[switch]$Desktop)
    $engine=if($Desktop){'powershell.exe'}else{$script:PowerShellExecutable}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $CodexHome 'hooks\bootstrap-ai-instructions.ps1'),'-ValidateOnly','-SkipUpdateCheck')
    if(-not[string]::IsNullOrWhiteSpace($TargetRoot)){$arguments+=@('-TargetRoot',$TargetRoot)}
    $output=& $engine @arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
}

function Set-P9bJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object]$Document)
    $parent=Split-Path -Parent $Path
    if(-not[string]::IsNullOrWhiteSpace($parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    [IO.File]::WriteAllText($Path,(($Document|ConvertTo-Json -Depth 40).Replace("`r`n","`n")+"`n"),[Text.UTF8Encoding]::new($false))
}

function New-P9bInstructionArchive {
    param([Parameter(Mandatory=$true)][string]$WorkingRoot,[Parameter(Mandatory=$true)][string]$ArchivePath,[string]$Marker='baseline',[string]$RendererMarker,[switch]$OmitClaudeDatabase,[switch]$OmitCodexTesting)
    $sourceRoot=Join-Path $WorkingRoot 'p9b-instructions'
    Remove-Item -LiteralPath $WorkingRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    foreach($relative in @('.codex/AI-Rules','.github/AI-Rules','.claude/AI-Rules','scripts')){
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot $relative)|Out-Null
    }
    foreach($relative in @('.codex/AGENTS.en.md','.github/copilot-instructions.en.md','.claude/CLAUDE.en.md')){
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination (Join-Path $sourceRoot $relative)
    }
    foreach($root in @('.codex/AI-Rules','.github/AI-Rules','.claude/AI-Rules')){
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot $root) -Filter '*.en.md' -File)){
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $sourceRoot "$root/$($file.Name)")
        }
    }
    if($OmitClaudeDatabase){Remove-Item -LiteralPath (Join-Path $sourceRoot '.claude/AI-Rules/Database.en.md') -Force}
    if($OmitCodexTesting){Remove-Item -LiteralPath (Join-Path $sourceRoot '.codex/AI-Rules/Testing.en.md') -Force}
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Build-AiInstructions.ps1') -Destination (Join-Path $sourceRoot 'scripts/Build-AiInstructions.ps1')
    if(-not[string]::IsNullOrWhiteSpace($RendererMarker)){
        [IO.File]::AppendAllText((Join-Path $sourceRoot 'scripts/Build-AiInstructions.ps1'),"`n# $RendererMarker`n",[Text.UTF8Encoding]::new($false))
    }
    foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $leaf) -Destination (Join-Path $sourceRoot $leaf)
    }
    [IO.File]::AppendAllText((Join-Path $sourceRoot '.codex/AGENTS.en.md'),"`n<!-- $Marker -->`n",[Text.UTF8Encoding]::new($false))

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $root=[IO.Path]::GetFullPath($sourceRoot).TrimEnd([char[]]@('\','/'))
            foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File|Sort-Object FullName)){
                $relative=$file.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry=$archive.CreateEntry("p9b-source/$relative",[IO.Compression.CompressionLevel]::Optimal)
                $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
                try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
    return [pscustomobject]@{ArchivePath=$ArchivePath;SourceRoot=$sourceRoot;RendererSha256=(Get-FileHash -LiteralPath (Join-Path $sourceRoot 'scripts/Build-AiInstructions.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function New-P9bBootstrapContext {
    param([Parameter(Mandatory=$true)][string]$Root,[switch]$SelectProjectProjection,[string[]]$ProjectProjectionIds,[string]$ProjectCandidateArchivePath,[object[]]$SkillProvenance=@(),[string]$InstructionCommit=('c'*40),[string]$CodexHome=$script:BaseV3Home)
    $runtimeRoot=Join-Path $CodexHome 'hooks/ai-instructions-runtime'
    $configuration=Get-Content -Raw -LiteralPath (Join-Path $CodexHome 'ai-instructions-sync.json')|ConvertFrom-Json
    if($SelectProjectProjection){$configuration.projections.project=@('project-agents')}
    if($PSBoundParameters.ContainsKey('ProjectProjectionIds')){$configuration.projections.project=@($ProjectProjectionIds)}
    $catalog=Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog.json')|ConvertFrom-Json
    $lock=Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json')|ConvertFrom-Json
    $lockSha=(Get-FileHash -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $routingPath=Join-Path $Root 'routing.json'
    $provenancePath=Join-Path $Root 'provenance.json'
    $routing=[ordered]@{
        schemaVersion=4;syncConfiguration=$configuration;catalogId=[string]$catalog.catalogId
        lockSha256=$lockSha;projectionContractSha256=[string]$lock.projectionContractSha256
    }
    if(-not[string]::IsNullOrWhiteSpace($ProjectCandidateArchivePath)){$routing.projectCandidateSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $ProjectCandidateArchivePath).Hash.ToLowerInvariant()}
    Set-P9bJson -Path $routingPath -Document $routing
    Set-P9bJson -Path $provenancePath -Document ([ordered]@{
        schemaVersion=1;catalogId=[string]$catalog.catalogId;lockSha256=$lockSha
        instruction=[ordered]@{sourceId='ai-instructions';sourceRepository='https://example.com/ai-instructions.git';sourceRef=$InstructionCommit;sourceCommit=$InstructionCommit;sourceVersion="test@$($InstructionCommit.Substring(0,8))"}
        skills=@($SkillProvenance)
    })
    return [pscustomobject]@{RuntimeRoot=$runtimeRoot;RoutingPath=$routingPath;ProvenancePath=$provenancePath;ProjectionContractSha256=[string]$lock.projectionContractSha256;LockSha256=$lockSha;ProjectCandidateArchivePath=$ProjectCandidateArchivePath}
}

function New-P9bTargetRepository {
    param([Parameter(Mandatory=$true)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path|Out-Null
    & git -C $Path init --quiet
    & git -C $Path config user.name 'P9b Test'
    & git -C $Path config user.email 'p9b@example.test'
    & git -C $Path remote add origin 'https://example.com/team/p9b-product.git'
    [IO.File]::WriteAllText((Join-Path $Path 'README.md'),"# P9b product`n",[Text.UTF8Encoding]::new($false))
    & git -C $Path add -- README.md
    & git -C $Path commit --quiet -m initial
    if($LASTEXITCODE-ne0){throw 'Could not create the P9b target repository fixture.'}
}

function Get-P9bRepoSnapshot {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $root=[IO.Path]::GetFullPath($Repository).TrimEnd([char[]]@('\','/'))
    $gitPrefix=(Join-Path $root '.git').TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
    $rows=@(
        foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File|Where-Object{-not$_.FullName.StartsWith($gitPrefix,[StringComparison]::OrdinalIgnoreCase)})){
            $relative=$file.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            "$relative`t$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
        }
    )
    $excludePath=(& git -C $root rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
    if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $root $excludePath}
    $excludeHash=if(Test-Path -LiteralPath $excludePath -PathType Leaf){(Get-FileHash -LiteralPath $excludePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{'absent'}
    $head=(& git -C $root rev-parse HEAD|Select-Object -First 1).Trim()
    $status=@(& git -C $root status --porcelain=v1 --untracked-files=all)-join"`n"
    return ((@($rows|Sort-Object)+@("exclude`t$excludeHash","head`t$head","status`t$status"))-join"`n")
}

function Get-P9bNormalizedSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n").Replace("`r","`n")
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Invoke-P9bRepoBootstrap {
    param(
        [Parameter(Mandatory=$true)][object]$Context,
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [string]$GitExecutable,
        [string]$BootstrapPath=(Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1')
    )
    $userHome=Join-Path (Split-Path -Parent $TargetRoot) 'p9b-user'
    New-Item -ItemType Directory -Force -Path $userHome|Out-Null
    $arguments=@(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$BootstrapPath,
        '-SourceArchivePath',$ArchivePath,'-ConfigurationPath',$Context.RoutingPath,'-ProvenancePath',$Context.ProvenancePath,
        '-RuntimeRoot',$Context.RuntimeRoot,'-TargetRoot',$TargetRoot,'-UserHome',$userHome
    )
    if(-not[string]::IsNullOrWhiteSpace($GitExecutable)){$arguments+=@('-GitExecutable',$GitExecutable)}
    if(-not[string]::IsNullOrWhiteSpace([string]$Context.ProjectCandidateArchivePath)){$arguments+=@('-ProjectCandidateArchivePath',[string]$Context.ProjectCandidateArchivePath)}
    $output=& $script:PowerShellExecutable @arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
}

function New-P9cProjectFixture {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string[]]$ProjectionIds,
        [hashtable]$AdditionalSkillFiles=@{}
    )
    $candidateSource=Join-Path $Root 'runtime-candidate';New-P7eV3Candidate -Destination $candidateSource
    $catalogPath=Join-Path $candidateSource 'catalog/skills-catalog.json';$lockPath=Join-Path $candidateSource 'catalog/skills-catalog-lock.json'
    $catalog=Get-Content -Raw -LiteralPath $catalogPath|ConvertFrom-Json
    foreach($projectionId in @($ProjectionIds)){
        if(@($catalog.projections|Where-Object id -ceq $projectionId).Count-eq0){
            $rootPath=switch($projectionId){'project-claude'{'.claude/skills'}'project-github'{'.github/skills'}default{'.agents/skills'}}
            $catalog.projections=@($catalog.projections)+@([pscustomobject][ordered]@{id=$projectionId;scope='project';root=$rootPath})
        }
    }
    Set-P9bJson -Path $catalogPath -Document $catalog
    $lock=Get-Content -Raw -LiteralPath $lockPath|ConvertFrom-Json
    $lock.projectionContractSha256=Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections
    $sourceRoot=Join-Path $Root 'skill-source';New-Item -ItemType Directory -Force -Path $sourceRoot|Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'LICENSE'),"fixture license`n",[Text.UTF8Encoding]::new($false))
    $resolved=New-Object System.Collections.Generic.List[object]
    foreach($skill in @($catalog.skills)){
        $skillRoot=Join-Path $sourceRoot ([string]$skill.source.sourcePath)
        New-Item -ItemType Directory -Force -Path $skillRoot|Out-Null
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),"# $([string]$skill.id)`n",[Text.UTF8Encoding]::new($false))
        if($AdditionalSkillFiles.ContainsKey([string]$skill.id)){
            foreach($relative in @($AdditionalSkillFiles[[string]$skill.id].Keys|Sort-Object)){
                if([string]$relative-cmatch '(^|/)(?:\.|\.\.)(?:/|$)' -or [string]$relative-cmatch '\\'){throw "Unsafe additional Skill fixture path: $relative"}
                $additionalPath=Join-Path $skillRoot ([string]$relative).Replace('/',[IO.Path]::DirectorySeparatorChar)
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $additionalPath)|Out-Null
                [IO.File]::WriteAllText($additionalPath,[string]$AdditionalSkillFiles[[string]$skill.id][$relative],[Text.UTF8Encoding]::new($false))
            }
        }
        $contentRows=@(
            foreach($file in @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse|Sort-Object FullName)){
                $relative=$file.FullName.Substring($skillRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $sourcePath="$([string]$skill.source.sourcePath)/$relative"
                $raw=(Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
                "$sourcePath`t$raw`n"
            }
        )
        [Array]::Sort($contentRows,[StringComparer]::Ordinal)
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]::Concat([string[]]$contentRows));$sha=[Security.Cryptography.SHA256]::Create();try{$content=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $lockedSkill=@($lock.skills|Where-Object{[string]$_.id-ceq[string]$skill.id})[0]
        if($null-eq$lockedSkill){throw "P9c fixture Lock is missing Skill '$([string]$skill.id)'."}
        $lockedSkill.contentSha256=$content
        $resolved.Add([pscustomobject]@{id=[string]$skill.id;sourceId='agent-skills';skillRootPath=$skillRoot;sourceRootPath=$sourceRoot})
    }
    $lock.catalogSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $catalogPath).Hash.ToLowerInvariant();Set-P9bJson -Path $lockPath -Document $lock
    $fixtureHome=Join-Path $Root 'home';$install=Invoke-P7eInstaller -SourceRoot $candidateSource -CodexHome $fixtureHome -WriterSchema V3V5
    if($install.ExitCode-ne0){throw "P9c runtime fixture install failed: $($install.Output)"}
    $runtimeRoot=Join-Path $fixtureHome 'hooks/ai-instructions-runtime';$runtimeLockPath=Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json'
    $runtimeLock=Get-Content -Raw -LiteralPath $runtimeLockPath|ConvertFrom-Json;$sourcePlan=$runtimeLock.sources[0]
    $plans=@{'agent-skills'=$sourcePlan};$candidateRoot=Join-Path $Root 'project-candidate'
    $runtimeCatalog=Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog.json')|ConvertFrom-Json
    New-ProjectSkillsCandidate -ResolvedSkills $resolved.ToArray() -SourcePlansById $plans -ProjectionIds $ProjectionIds `
        -CatalogId ([string]$runtimeCatalog.catalogId) -LockSha256 ((Get-FileHash -Algorithm SHA256 -LiteralPath $runtimeLockPath).Hash.ToLowerInvariant()) `
        -ProjectionContractSha256 ([string]$runtimeLock.projectionContractSha256) -DestinationRoot $candidateRoot|Out-Null
    $candidateArchive=Join-Path $Root 'project-candidate.zip';New-ComposedBootstrapArchive -SourceRoot $candidateRoot -DestinationPath $candidateArchive|Out-Null
    $provenance=@(foreach($skill in $resolved){[pscustomobject][ordered]@{id=$skill.id;sourceId='agent-skills';sourceRepository=[string]$sourcePlan.repository;sourceRef=[string]$sourcePlan.requestedRef;sourceCommit=[string]$sourcePlan.resolvedCommit;sourceVersion=[string]$sourcePlan.resolvedVersion;files=@()}})
    $context=New-P9bBootstrapContext -Root $Root -CodexHome $fixtureHome -ProjectProjectionIds $ProjectionIds -ProjectCandidateArchivePath $candidateArchive -SkillProvenance $provenance
    return [pscustomobject]@{Context=$context;Home=$fixtureHome;CandidateArchive=$candidateArchive;CandidateRoot=$candidateRoot;SkillProvenance=$provenance}
}

function New-P9cProjectPublicationFailpointBootstrap {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Failpoint,
        [ValidateSet('InProcess','NextRun')][string]$RecoveryPath='InProcess'
    )
    $scriptRoot=Join-Path $Root 'scripts'
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $scriptRoot -Recurse
    $bootstrapPath=Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1'
    $failpointName=switch($Failpoint){
        'BeforeCommit'{'before-committed-journal-write'}
        'ApplyingFailure'{'after-operation-1-before-journal'}
        'CommitWriteFailure'{'before-committed-journal-write'}
        'AfterCommitted'{'after-committed-journal-write'}
        'CleanupFailure'{'after-cleanup-journal-before-directory'}
        default{$Failpoint}
    }
    if($Failpoint-ceq'RecoveryOnly'){
        $text=[IO.File]::ReadAllText($bootstrapPath)
        $invocation='            Invoke-ProjectPublicationRecovery -Repository $targetRootPath'
        if(-not$text.Contains($invocation)){throw 'Project publication recovery invocation was not found.'}
        $text=$text.Replace($invocation,$invocation+"`r`n            throw 'Injected project publication RecoveryOnly failure.'")
        [IO.File]::WriteAllText($bootstrapPath,$text,[Text.UTF8Encoding]::new($false))
        return $bootstrapPath
    }
    $modulePath=Join-Path $scriptRoot 'ai-instructions-install-transaction.psm1'
    $moduleText=[IO.File]::ReadAllText($modulePath)
    if($RecoveryPath-ceq'InProcess'){
        $failFast='    [Environment]::FailFast("AI instructions installer failpoint: $Name")'
        if(-not$moduleText.Contains($failFast)){throw 'Install failpoint invocation was not found.'}
        $replacement='    [Environment]::SetEnvironmentVariable(''AI_INSTRUCTIONS_INSTALL_FAILPOINT'',$null,''Process'')' + "`r`n" + '    throw "Injected AI instructions installer failpoint: $Name"'
        $moduleText=$moduleText.Replace($failFast,$replacement)
        [IO.File]::WriteAllText($modulePath,$moduleText,[Text.UTF8Encoding]::new($false))
    }
    $bootstrapText=[IO.File]::ReadAllText($bootstrapPath)
    $prefix="[Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','$failpointName','Process')`r`n"
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($bootstrapText,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count-ne0-or$null-eq$ast.ParamBlock){throw 'Bootstrap failpoint copy does not contain a valid param block.'}
    $bootstrapText=$bootstrapText.Insert($ast.ParamBlock.Extent.EndOffset,"`r`n"+$prefix)
    [IO.File]::WriteAllText($bootstrapPath,$bootstrapText,[Text.UTF8Encoding]::new($false))
    return $bootstrapPath
}

function Get-P9cPublicationStateSnapshot {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $manifestPath=Join-Path $Repository '.codex/ai-instructions.manifest.json'
    $manifest=if(Test-Path -LiteralPath $manifestPath -PathType Leaf){Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json}else{$null}
    $indexPath=(& git -C $Repository rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $Repository $indexPath}
    $excludePath=(& git -C $Repository rev-parse --git-path info/exclude|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $Repository $excludePath}
    $fileRows=@(
        foreach($entry in @($manifest.files|Sort-Object targetPath)){
            $path=Join-Path $Repository ([string]$entry.targetPath)
            "$([string]$entry.artifactType)`t$([string]$entry.targetPath)`t$(if(Test-Path -LiteralPath $path -PathType Leaf){(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()}else{'absent'})"
        }
    )
    $headReference=(@(& git -C $Repository symbolic-ref -q HEAD 2>$null)|Select-Object -First 1)
    $headObject=(@(& git -C $Repository rev-parse --verify HEAD 2>$null)|Select-Object -First 1)
    $refObject=if([string]::IsNullOrWhiteSpace([string]$headReference)){$null}else{(@(& git -C $Repository rev-parse --verify ([string]$headReference) 2>$null)|Select-Object -First 1)}
    $headMode=if(-not[string]::IsNullOrWhiteSpace([string]$headReference)){if([string]::IsNullOrWhiteSpace([string]$headObject)){'unborn'}else{'symbolic'}}else{'detached'}
    $headPath=(& git -C $Repository rev-parse --git-path HEAD|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($headPath)){$headPath=Join-Path $Repository $headPath}
    $indexRows=@(& git -C $Repository ls-files --stage)|Sort-Object -CaseSensitive
    $indexEntryBytes=[Text.UTF8Encoding]::new($false).GetBytes((($indexRows-join"`n")+"`n"));$sha=[Security.Cryptography.SHA256]::Create();try{$indexEntrySha=([BitConverter]::ToString($sha.ComputeHash($indexEntryBytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $status=(@(& git -C $Repository status --porcelain=v1 --untracked-files=all)-join"`n")
    $transactionRoot=Join-Path $Repository '.ai-instructions-txn';$transactionResidue=if((Test-Path -LiteralPath $transactionRoot -PathType Container)-and@(Get-ChildItem -Force -LiteralPath $transactionRoot).Count-gt0){Get-P7eTreeSnapshot $transactionRoot}else{''}
    return ([ordered]@{
        headMode=$headMode
        headReference=if([string]::IsNullOrWhiteSpace([string]$headReference)){$null}else{[string]$headReference.Trim()}
        headObject=if([string]::IsNullOrWhiteSpace([string]$headObject)){$null}else{[string]$headObject.Trim()}
        headRaw=(Get-FileHash -Algorithm SHA256 -LiteralPath $headPath).Hash.ToLowerInvariant()
        refObject=if([string]::IsNullOrWhiteSpace([string]$refObject)){$null}else{[string]$refObject.Trim()}
        indexRaw=if(Test-Path -LiteralPath $indexPath -PathType Leaf){(Get-FileHash -Algorithm SHA256 -LiteralPath $indexPath).Hash.ToLowerInvariant()}else{'absent'}
        indexEntrySet=$indexEntrySha
        status=$status
        exclude=if(Test-Path -LiteralPath $excludePath -PathType Leaf){[Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))}else{'absent'}
        manifest=if($null-ne$manifest){[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))}else{'absent'}
        files=$fileRows
        transactionResidue=$transactionResidue
    }|ConvertTo-Json -Depth 6 -Compress)
}

function New-P9cPreManifestTamperBootstrap {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$TargetRelativePath
    )
    $scriptRoot=Join-Path $Root 'scripts'
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $scriptRoot -Recurse
    $bootstrapPath=Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1'
    $text=[IO.File]::ReadAllText($bootstrapPath)
    $marker='            Assert-ProjectSkillManifestFilesCurrent -TargetRoot $targetRootPath -ManifestEntries $nextManifestEntries.ToArray()'
    if(-not$text.Contains($marker)){throw 'Project pre-manifest verification invocation was not found.'}
    $relative=$TargetRelativePath.Replace("'","''")
    $injection="            [IO.File]::AppendAllText((Join-Path `$targetRootPath '$relative'),`"concurrent project edit``n`",[Text.UTF8Encoding]::new(`$false))`r`n$marker"
    [IO.File]::WriteAllText($bootstrapPath,$text.Replace($marker,$injection),[Text.UTF8Encoding]::new($false))
    return $bootstrapPath
}

function Convert-P9bManifestToLegacy {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet(2,3)][int]$SchemaVersion
    )
    $manifest=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json
    $manifest.schemaVersion=$SchemaVersion
    foreach($propertyName in @('projectionContractSha256','generation','projections')){$manifest.PSObject.Properties.Remove($propertyName)}
    foreach($entry in @($manifest.files|Where-Object artifactType -eq instruction)){
        foreach($propertyName in @('host','rendererId','rendererSha256','retention')){$entry.PSObject.Properties.Remove($propertyName)}
    }
    Set-P9bJson -Path $Path -Document $manifest
}
