$script:RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PowerShellExecutable=(Get-Process -Id $PID).Path
$script:InstallerPath=Join-Path $script:RepositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'scripts\platform-runtime.psd1') -Force
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
    param([Parameter(Mandatory=$true)][string]$WorkingRoot,[Parameter(Mandatory=$true)][string]$ArchivePath,[string]$Marker='baseline',[string]$RendererMarker,[switch]$OmitClaudeDatabase)
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
    param([Parameter(Mandatory=$true)][string]$Root,[switch]$SelectProjectProjection,[string]$InstructionCommit=('c'*40),[string]$CodexHome=$script:BaseV3Home)
    $runtimeRoot=Join-Path $CodexHome 'hooks/ai-instructions-runtime'
    $configuration=Get-Content -Raw -LiteralPath (Join-Path $CodexHome 'ai-instructions-sync.json')|ConvertFrom-Json
    if($SelectProjectProjection){$configuration.projections.project=@('project-agents')}
    $catalog=Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog.json')|ConvertFrom-Json
    $lock=Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json')|ConvertFrom-Json
    $lockSha=(Get-FileHash -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $routingPath=Join-Path $Root 'routing.json'
    $provenancePath=Join-Path $Root 'provenance.json'
    Set-P9bJson -Path $routingPath -Document ([ordered]@{
        schemaVersion=4;syncConfiguration=$configuration;catalogId=[string]$catalog.catalogId
        lockSha256=$lockSha;projectionContractSha256=[string]$lock.projectionContractSha256
    })
    Set-P9bJson -Path $provenancePath -Document ([ordered]@{
        schemaVersion=1;catalogId=[string]$catalog.catalogId;lockSha256=$lockSha
        instruction=[ordered]@{sourceId='ai-instructions';sourceRepository='https://example.com/ai-instructions.git';sourceRef=$InstructionCommit;sourceCommit=$InstructionCommit;sourceVersion="test@$($InstructionCommit.Substring(0,8))"}
        skills=@()
    })
    return [pscustomobject]@{RuntimeRoot=$runtimeRoot;RoutingPath=$routingPath;ProvenancePath=$provenancePath;ProjectionContractSha256=[string]$lock.projectionContractSha256;LockSha256=$lockSha}
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

function Invoke-P9bRepoBootstrap {
    param(
        [Parameter(Mandatory=$true)][object]$Context,
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [string]$GitExecutable
    )
    $userHome=Join-Path (Split-Path -Parent $TargetRoot) 'p9b-user'
    New-Item -ItemType Directory -Force -Path $userHome|Out-Null
    $arguments=@(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1'),
        '-SourceArchivePath',$ArchivePath,'-ConfigurationPath',$Context.RoutingPath,'-ProvenancePath',$Context.ProvenancePath,
        '-RuntimeRoot',$Context.RuntimeRoot,'-TargetRoot',$TargetRoot,'-UserHome',$userHome
    )
    if(-not[string]::IsNullOrWhiteSpace($GitExecutable)){$arguments+=@('-GitExecutable',$GitExecutable)}
    $output=& $script:PowerShellExecutable @arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
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
