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
        [Parameter(Mandatory=$true)][string]$TargetRoot
    )
    $userHome=Join-Path (Split-Path -Parent $TargetRoot) 'p9b-user'
    New-Item -ItemType Directory -Force -Path $userHome|Out-Null
    $output=& $script:PowerShellExecutable -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1') `
        -SourceArchivePath $ArchivePath -ConfigurationPath $Context.RoutingPath -ProvenancePath $Context.ProvenancePath `
        -RuntimeRoot $Context.RuntimeRoot -TargetRoot $TargetRoot -UserHome $userHome 2>&1
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

Describe 'AI instructions writer and reader gate' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e'
        New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:V3Candidate=Join-Path $script:ExternalRoot 'src'
        New-P7eV3Candidate -Destination $script:V3Candidate
        $script:BaseV3Home=Join-Path $script:ExternalRoot 'v3'
        $install=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $script:BaseV3Home -WriterSchema V3V5
        if($install.ExitCode-ne0){throw "P7e v3 fixture install failed: $($install.Output)"}
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: Production explicitly requests V3V5 while the production Catalog remains v2.
    # Purpose: Enforce D4 before Codex Home staging, lock, journal, or any other target mutation.
    It 'InterT10_refuses_production_v3v5_without_any_target_mutation' {
        $fixtureHome=Join-Path $script:ExternalRoot 'prod-v3';$before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V3V5
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be projection-runtime-unavailable
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: A fresh production install uses the default Auto writer.
    # Purpose: Protect the v2/v4 default until production projection pins are available.
    It 'InterT20_keeps_fresh_auto_on_v2v4' {
        $fixtureHome=Join-Path $script:ExternalRoot 'auto-v2'
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 2
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json).schemaVersion|Should Be 4
    }

    # Scenario: The isolated Catalog v3 candidate writes v3/v5 and the stable launcher invokes its bound fan-out entry.
    # Purpose: Exercise the successful writer journal path and reader gate without exposing a production fixture switch.
    It 'InterT30_writes_v3v5_and_launches_verified_fan_out_from_the_fixture' {
        $bundle=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        $configuration=Get-Content -Raw -LiteralPath (Join-Path $script:BaseV3Home 'ai-instructions-sync.json')|ConvertFrom-Json
        $bundle.schemaVersion|Should Be 3;$configuration.schemaVersion|Should Be 5
        $target=Join-Path $script:ExternalRoot 'fanout';$user=Join-Path $script:ExternalRoot 'user';New-Item -ItemType Directory -Path $user|Out-Null
        & (Join-Path $script:BaseV3Home 'hooks\bootstrap-ai-instructions.ps1') -TargetRoot $target -UserHome $user -SkipUpdateCheck
        (Get-Content -Raw -LiteralPath (Join-Path $target 'p7e-fanout.txt')).Trim()|Should Be v3v5
    }

    # Scenario: Auto runs again over a consistent installed v3/v5 fixture.
    # Purpose: Re-run the live gate and preserve the new generation instead of silently downgrading.
    It 'InterT40_preserves_v3v5_when_auto_reinstalls_the_fixture' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'auto-v3')
        $result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
        $result.ExitCode|Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json).schemaVersion|Should Be 3
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json).schemaVersion|Should Be 5
    }

    # Scenario: A real v3/v5 installer advances the immutable Catalog pin from commit A to commit B.
    # Purpose: Preserve v5 exclusions, projections, and update policy while applying the new repository/ref.
    It 'InterT45_advances_v3v5_to_a_new_commit_without_losing_personal_configuration' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'advance-v3')
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        $configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $configuration.excludedRepositoryUrls=@('https://example.com/preserved.git')
        $configuration.excludedRepositoryPaths=@('preserved/path')
        $configuration.updates.mode='auto-install-approved'
        $configuration.updates.minimumCheckIntervalMinutes=60
        $configuration.projections.project=@('project-agents')
        [IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
        $commitB='b'*40
        $result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto -SourceCommit $commitB
        $result.ExitCode|Should Be 0
        $updated=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $bundle=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        [string]$updated.catalog.ref|Should Be $commitB
        [string]$bundle.commit|Should Be $commitB
        @($updated.excludedRepositoryUrls)|Should Be @('https://example.com/preserved.git')
        @($updated.excludedRepositoryPaths)|Should Be @('preserved/path')
        [string]$updated.updates.mode|Should Be 'auto-install-approved'
        [int]$updated.updates.minimumCheckIntervalMinutes|Should Be 60
        @($updated.projections.user)|Should Be @('user-agents','user-claude')
        @($updated.projections.project)|Should Be @('project-agents')
    }

    # Scenario: V2V4 targets an installed state containing v3 and v5.
    # Purpose: Refuse rollback before target bytes change.
    It 'InterT50_refuses_explicit_v2v4_downgrade_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'down');$before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V2V4
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be downgrade-refused
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: A buggy candidate selects v2/v4 while the updater requires the installed v3/v5 generation to be preserved.
    # Purpose: Detect the downgrade after journaled publication but before commit, roll back, and retain the exact original tree.
    It 'InterT55_rolls_back_a_candidate_downgrade_before_transaction_commit' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'transaction-downgrade')
        $candidate=Join-Path $script:ExternalRoot 'downgrade-src';New-P7eV3Candidate -Destination $candidate
        $contractPath=Join-Path $candidate 'scripts\ai-instructions-runtime-contract.psm1'
        $contract=[IO.File]::ReadAllText($contractPath)
        $old="if (`$WriterSchema -ceq 'V2V4' -or (`$WriterSchema -ceq 'Auto' -and `$installedGeneration -cne 'v3v5')) { return 'v2v4' }"
        if(-not$contract.Contains($old)){throw 'P7e downgrade selector fixture marker was not found.'}
        $contract=$contract.Replace($old,"if (`$WriterSchema -ceq 'V2V4' -or `$WriterSchema -ceq 'Auto') { return 'v2v4' }")
        [IO.File]::WriteAllText($contractPath,$contract,[Text.UTF8Encoding]::new($false))
        $installerPath=Join-Path $candidate 'scripts\install-ai-instructions-bootstrap.ps1'
        $installer=[IO.File]::ReadAllText($installerPath)
        $oldConfig='ExistingConfiguration=$existingConfiguration;CatalogRepository=$catalogRepository;CatalogRef=$catalogRef'
        if(-not$installer.Contains($oldConfig)){throw 'P7e downgrade configuration fixture marker was not found.'}
        $installer=$installer.Replace($oldConfig,'ExistingConfiguration=$null;CatalogRepository=$catalogRepository;CatalogRef=$catalogRef')
        [IO.File]::WriteAllText($installerPath,$installer,[Text.UTF8Encoding]::new($false))
        $before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $candidate -CodexHome $fixtureHome -WriterSchema Auto -ExpectedCurrentGeneration v3v5
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be downgrade-refused
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The v3 bundle is paired with a v4 configuration.
    # Purpose: Reject D11 mixed generation before runtime import or mutation.
    It 'InterT60_rejects_a_mixed_pair_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'mixed')
        $path=Join-Path $fixtureHome 'ai-instructions-sync.json';$configuration=Get-Content -Raw $path|ConvertFrom-Json;$configuration.schemaVersion=4;$configuration.PSObject.Properties.Remove('projections');$configuration|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be mixed-generation
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: Installed runtime files are missing, or existing JSON documents omit one or both schemaVersion fields.
    # Purpose: Distinguish partial absence from invalid present documents and refuse before journal or target mutation.
    It 'InterT65_installer_refuses_missing_or_versionless_live_state_without_mutation_<Variant>' -TestCases @(
        @{Variant='missing-bundle';Code='mixed-generation'},
        @{Variant='missing-configuration';Code='mixed-generation'},
        @{Variant='both-versionless';Code='unsupported-version'},
        @{Variant='bundle-versionless';Code='unsupported-version'}
    ) {
        param($Variant,$Code)
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot ("invalid-$Variant"))
        $bundlePath=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        if($Variant-ceq'missing-bundle'){Remove-Item -LiteralPath $bundlePath -Force}
        elseif($Variant-ceq'missing-configuration'){Remove-Item -LiteralPath $configurationPath -Force}
        else{
            $bundle=Get-Content -Raw -LiteralPath $bundlePath|ConvertFrom-Json;$bundle.PSObject.Properties.Remove('schemaVersion');[IO.File]::WriteAllText($bundlePath,(($bundle|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
            if($Variant-ceq'both-versionless'){$configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json;$configuration.PSObject.Properties.Remove('schemaVersion');[IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))}
        }
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be $Code
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The bundle declares a different host architecture.
    # Purpose: Return the fixed platform-mismatch code after the trusted capability probe and preserve all bytes.
    It 'InterT70_rejects_platform_mismatch_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'platform')
        $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.platform.architecture=if($bundle.platform.architecture-ceq'x64'){'arm64'}else{'x64'};$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be platform-mismatch
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    if(-not[string]::IsNullOrWhiteSpace($script:P7eUnavailableCapability)){
        # Scenario: The bundle adds a capability that the current native host receipt reports unavailable or unverified.
        # Purpose: Satisfy D14 with a dynamically selected real receipt rather than a production override.
        It 'InterT80_rejects_a_real_unavailable_capability_without_mutation' {
            $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'capability')
            $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.requiredCapabilities=@($bundle.requiredCapabilities)+@($script:P7eUnavailableCapability);$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
            $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
        }

        # Scenario: Auto reinstalls an existing v3/v5 runtime whose declared capability is no longer available.
        # Purpose: Prove the installer re-runs the real host gate under its install lease and performs zero mutation.
        It 'InterT85_installer_auto_refuses_real_capability_loss_without_mutation' {
            $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'installer-capability')
            $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.requiredCapabilities=@($bundle.requiredCapabilities)+@($script:P7eUnavailableCapability);$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eInstaller -SourceRoot $script:V3Candidate -CodexHome $fixtureHome -WriterSchema Auto
            $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
        }
    }

    # Scenario: platform-runtime.psm1 is tampered with a side-effect marker before launcher validation.
    # Purpose: Prove the inline closure verifier rejects bytes before importing any candidate runtime code.
    It 'InterT90_rejects_tampered_closure_before_its_side_effect_can_run' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'closure');$marker=Join-Path $script:ExternalRoot 'imported.txt'
        $module=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\platform-runtime.psm1';[IO.File]::AppendAllText($module,"`n[IO.File]::WriteAllText('$($marker.Replace("'","''"))','imported')`n",[Text.UTF8Encoding]::new($false))
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        (Test-Path -LiteralPath $marker)|Should Be $false
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The installed launcher, multi-source coordinator, and REPO bootstrap each receive projection-aware state.
    # Purpose: Require every layer to invoke the P7e gate from its own inputs and forbid a public parameter or environment-variable v4 bypass.
    It 'UnitT110_requires_independent_P7e_gates_and_exposes_no_v4_bypass' {
        $paths=@(
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-installed.ps1'),
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-multisource.ps1'),
            (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1')
        )
        foreach($path in $paths){
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0
            $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Assert-AiInstructionsRuntimeGate'},$true))
            $calls.Count|Should BeGreaterThan 0
            $gateText=@($calls|ForEach-Object{$_.Extent.Text})-join"`n"
            foreach($argument in @('-Bundle','-Configuration','-RuntimeRoot','-CapabilityReceipt')){$gateText|Should Match ([regex]::Escape($argument))}
            $parameterNames=@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
            @($parameterNames|Where-Object{$_-match'(?i)(writer|manifest.*v4|enable.*v4|projection.*bypass)'}).Count|Should Be 0
            $text=[IO.File]::ReadAllText($path)
            $text|Should Not Match '(?i)env:[A-Z0-9_]*(?:WRITER|MANIFEST_V4|ENABLE_V4|PROJECTION_BYPASS)'
        }
        $multi=[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-multisource.ps1'))
        foreach($identity in @('syncConfiguration','catalogId','lockSha256','projectionContractSha256')){$multi|Should Match ([regex]::Escape($identity))}
        $multi|Should Match 'schemaVersion\s*=\s*4'
        $multi|Should Match 'RuntimeRoot\s*=\s*\$RuntimeRoot'
        ([IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-installed.ps1')))|Should Match 'RuntimeRoot\s*=\s*\$runtimeRoot'
    }

    # Scenario: A verified v3/v5 routing context reaches an ordinary repository with no project-owned CLAUDE.md and no project projection selected.
    # Purpose: Preserve an explicit empty Claude protection set, emit complete v4 output, and repeat idempotently.
    It 'InterT111_writes_complete_v4_manifest_and_exact_excludes_idempotently' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-complete';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md')|Should Be $false

        $first=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $first.ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        [int64]$manifest.generation|Should Be 1
        [string]$manifest.lockSha256|Should Be $context.LockSha256
        [string]$manifest.projectionContractSha256|Should Be $context.ProjectionContractSha256
        @($manifest.projections).Count|Should Be 0
        (@($manifest.files|Where-Object artifactType -eq instruction|Select-Object -ExpandProperty host -Unique|Sort-Object)-join',')|Should Be 'claude,codex,copilot'
        foreach($entry in @($manifest.files|Where-Object artifactType -eq instruction)){
            [string]$entry.rendererId|Should Be 'build-ai-instructions'
            [string]$entry.rendererSha256|Should Be $source.RendererSha256
        }
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-ceq'CLAUDE.md'}).Count|Should Be 1
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-like'.claude/AI-Rules/*.en.md'}).Count|Should BeGreaterThan 0
        @($manifest.files|Where-Object{$_.host-ceq'claude'-and$_.targetPath-like'.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/*'}).Count|Should BeGreaterThan 0
        foreach($entry in @($manifest.files|Where-Object host -eq claude)){
            $path=Join-Path $target ([string]$entry.targetPath)
            Test-Path -LiteralPath $path -PathType Leaf|Should Be $true
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$entry.sha256)
        }
        $excludePath=(& git -C $target rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
        $excludeLines=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-like'/*'}|Sort-Object)
        $expectedLines=@('/.codex/ai-instructions.manifest.json')
        $expectedLines+=@($manifest.files|ForEach-Object{'/'+[string]$_.targetPath})
        $expectedLines=@($expectedLines|Sort-Object -Unique)
        $excludeLines|Should Be $expectedLines
        ([IO.File]::ReadAllText($excludePath))|Should Not Match '(?m)^/\.claude/\*\*$'
        $before=Get-P9bRepoSnapshot $target

        $second=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $second.ExitCode|Should Be 0
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 1
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A v4 desired state changes once, repeats, and then reaches Int64 generation maximum before another change.
    # Purpose: Increment generation only for changed desired state and fail closed without REPO mutation on overflow.
    It 'InterT112_advances_v4_generation_only_on_change_and_refuses_overflow' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-generation';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 2
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        $manifest.generation=[int64]::MaxValue;Set-P9bJson -Path $manifestPath -Document $manifest
        $before=Get-P9bRepoSnapshot $target

        $overflow=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target
        $overflow.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $overflow.Output)|Should Be closure-invalid
        $overflow.Output|Should Match 'generation would overflow'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Sync v5 selects a project projection before the P9c project runtime exists.
    # Purpose: Return the typed J9 refusal before any REPO byte, index, history, or exclude mutation.
    It 'InterT113_refuses_project_projection_before_REPO_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9b-project-unavailable';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root -SelectProjectProjection
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be projection-runtime-unavailable
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Each project-owned CLAUDE.md ownership form is crossed with tracked or untracked Claude Rules/licenses, including a linked worktree.
    # Purpose: Skip the complete Claude family, preserve every protected byte and HEAD, avoid remediation commits, and still update other host families.
    It 'InterT114_preserves_project_owned_Claude_family_for_<Case>' -TestCases @(
        @{Case='tracked-base-tracked-rule';Base='tracked';Companion='tracked-rule';Linked=$false},
        @{Case='staged-base-untracked-license';Base='staged';Companion='untracked-license';Linked=$false},
        @{Case='unmanaged-base-tracked-license';Base='unmanaged';Companion='tracked-license';Linked=$false},
        @{Case='manifest-customized-untracked-rule';Base='managed-customized';Companion='untracked-rule';Linked=$false},
        @{Case='manifest-tracked-tracked-rule';Base='managed-tracked';Companion='tracked-rule';Linked=$false},
        @{Case='linked-unmanaged-tracked-license';Base='unmanaged';Companion='tracked-license';Linked=$true}
    ) {
        param($Case,$Base,$Companion,$Linked)
        $root=Join-Path $script:ExternalRoot ("p9b-owned-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed
        $context=New-P9bBootstrapContext -Root $root
        $primary=Join-Path $root 'primary';New-P9bTargetRepository $primary
        $target=$primary
        if($Linked){
            $target=Join-Path $root 'linked'
            & git -C $primary worktree add --quiet -b p9b-linked $target
            if($LASTEXITCODE-ne0){throw 'Could not create linked-worktree fixture.'}
        }
        if($Base-like'managed-*'){
            (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        }
        $rulePath=Join-Path $target '.claude/AI-Rules/Database.en.md'
        $licensePath=Join-Path $target '.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/delivery.json'
        $companionPath=if($Companion-like'*-rule'){$rulePath}else{$licensePath}
        if(-not(Test-Path -LiteralPath $companionPath -PathType Leaf)){
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $companionPath)|Out-Null
            [IO.File]::WriteAllText($companionPath,"project companion $Case`n",[Text.UTF8Encoding]::new($false))
        }
        if($Companion-like'tracked-*'){
            & git -C $target add -f -- ($companionPath.Substring($target.Length).TrimStart([char[]]@('\','/')).Replace('\','/'))
            & git -C $target commit --quiet -m 'track project Claude companion'
        }
        $claudePath=Join-Path $target 'CLAUDE.md'
        switch($Base){
            'tracked' {[IO.File]::WriteAllText($claudePath,"tracked project Claude`n",[Text.UTF8Encoding]::new($false));& git -C $target add -f -- CLAUDE.md;& git -C $target commit --quiet -m 'track project Claude base'}
            'staged' {[IO.File]::WriteAllText($claudePath,"staged project Claude`n",[Text.UTF8Encoding]::new($false));& git -C $target add -f -- CLAUDE.md}
            'unmanaged' {[IO.File]::WriteAllText($claudePath,"unmanaged project Claude`n",[Text.UTF8Encoding]::new($false))}
            'managed-customized' {[IO.File]::AppendAllText($claudePath,"project customization`n",[Text.UTF8Encoding]::new($false))}
            'managed-tracked' {& git -C $target add -f -- CLAUDE.md;& git -C $target commit --quiet -m 'track formerly managed Claude base'}
        }
        $claudeBefore=[IO.File]::ReadAllBytes($claudePath)
        $companionBefore=[IO.File]::ReadAllBytes($companionPath)
        $claudeFamilyBefore=Get-P7eTreeSnapshot (Join-Path $target '.claude')
        $headBefore=(& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $result.Output|Should Match 'claude-base-skipped-project-owned'
        [IO.File]::ReadAllBytes($claudePath)|Should Be $claudeBefore
        [IO.File]::ReadAllBytes($companionPath)|Should Be $companionBefore
        (Get-P7eTreeSnapshot (Join-Path $target '.claude'))|Should Be $claudeFamilyBefore
        Test-Path -LiteralPath (Join-Path $target '.claude/AI-Rules/CodeReview.en.md')|Should Be ($Base-like'managed-*')
        ([IO.File]::ReadAllText((Join-Path $target 'AGENTS.md')))|Should Match '<!-- changed -->'
        Test-Path -LiteralPath (Join-Path $target '.github/copilot-instructions.md')|Should Be $true
        (& git -C $target rev-parse HEAD|Select-Object -First 1).Trim()|Should Be $headBefore
        $result.Output|Should Not Match 'Agent artifact remediation commit created'
    }

    # Scenario: Legacy production v2/v4 fan-out runs after Claude support is present in the source contract.
    # Purpose: Preserve all v2/v3 behavior and prove the legacy writer never creates Claude base, Rules, or license paths.
    It 'InterT115_keeps_legacy_writer_free_of_Claude_artifacts' {
        $root=Join-Path $script:ExternalRoot 'p9b-legacy-no-claude';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $configuration=Join-Path $root 'routing-v3.json';Set-P9bJson -Path $configuration -Document ([ordered]@{schemaVersion=3;excludedRepositoryUrls=@();excludedRepositoryPaths=@()})
        $provenance=Join-Path $root 'provenance.json';Set-P9bJson -Path $provenance -Document ([ordered]@{
            schemaVersion=1;catalogId='test-catalog';lockSha256=('a'*64)
            instruction=[ordered]@{sourceId='ai-instructions';sourceRepository='https://example.com/ai-instructions.git';sourceRef=('c'*40);sourceCommit=('c'*40);sourceVersion='test@cccccccc'};skills=@()
        })
        $output=& $script:PowerShellExecutable -NoProfile -NonInteractive -File (Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1') -SourceArchivePath $source.ArchivePath -ConfigurationPath $configuration -ProvenancePath $provenance -TargetRoot $target -UserHome (Join-Path $root 'user') 2>&1
        $LASTEXITCODE|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 2
        @($manifest.files|Where-Object{[string]$_.targetPath-like'CLAUDE.md'-or[string]$_.targetPath-like'.claude/*'}).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md')|Should Be $false
        Test-Path -LiteralPath (Join-Path $target '.claude')|Should Be $false
    }

    # Scenario: Installed runtime state is mixed, unknown, gate-invalid, or Catalog/Lock-incompatible before fan-out.
    # Purpose: Return the J4 typed refusal matrix and preserve the complete consumer REPO tree for every rejected v3/v5 input.
    It 'InterT116_rejects_invalid_writer_context_without_REPO_mutation_<Case>' -TestCases @(
        @{Case='v3-v4-mixed';Code='mixed-generation'},
        @{Case='v2-v5-mixed';Code='mixed-generation'},
        @{Case='unknown-bundle';Code='unsupported-version'},
        @{Case='platform-gate';Code='platform-mismatch'},
        @{Case='catalog-lock-incompatible';Code='closure-invalid'}
    ) {
        param($Case,$Code)
        $root=Join-Path $script:ExternalRoot ("p9b-writer-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $root 'home')
        $bundlePath=Join-Path $fixtureHome 'hooks/ai-instructions-runtime/runtime-bundle.json'
        $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
        if($Case-ceq'v3-v4-mixed'){$configuration=Get-Content -Raw $configurationPath|ConvertFrom-Json;$configuration.schemaVersion=4;$configuration.PSObject.Properties.Remove('projections');Set-P9bJson $configurationPath $configuration}
        elseif($Case-ceq'v2-v5-mixed'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.schemaVersion=2;Set-P9bJson $bundlePath $bundle}
        elseif($Case-ceq'unknown-bundle'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.schemaVersion=99;Set-P9bJson $bundlePath $bundle}
        elseif($Case-ceq'platform-gate'){$bundle=Get-Content -Raw $bundlePath|ConvertFrom-Json;$bundle.platform.architecture=if($bundle.platform.architecture-ceq'x64'){'arm64'}else{'x64'};Set-P9bJson $bundlePath $bundle}
        else{$lockPath=Join-Path $fixtureHome 'hooks/ai-instructions-runtime/catalog/skills-catalog-lock.json';$lock=Get-Content -Raw $lockPath|ConvertFrom-Json;$lock.catalogId='incompatible-catalog';Set-P9bJson $lockPath $lock}
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P7eLauncherFailure -CodexHome $fixtureHome -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be $Code
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: Bootstrap receives a routing envelope whose embedded v5 identity no longer matches the verified v3 bundle.
    # Purpose: Prove the final layer re-runs the P7e gate instead of trusting the installed or multi-source caller.
    It 'InterT117_bootstrap_revalidates_the_embedded_v5_context_without_REPO_mutation' {
        $root=Join-Path $script:ExternalRoot 'p9b-bootstrap-regate';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $routing=Get-Content -Raw -LiteralPath $context.RoutingPath|ConvertFrom-Json
        $routing.syncConfiguration.catalog.ref='d'*40
        Set-P9bJson -Path $context.RoutingPath -Document $routing
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: The immutable source advances, removes one Claude Rule, and moves license payloads to a new sourceCommit namespace.
    # Purpose: Delete obsolete Claude Rule/license paths, update the v4 manifest, and remove only their exact exclude entries.
    It 'InterT118_reconciles_Claude_rule_license_and_exclude_cleanup' {
        $root=Join-Path $script:ExternalRoot 'p9b-claude-cleanup';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -OmitClaudeDatabase
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $oldRule=Join-Path $target '.claude/AI-Rules/Database.en.md'
        $oldLicenseRoot=Join-Path $target '.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc'
        Test-Path -LiteralPath $oldRule -PathType Leaf|Should Be $true
        Test-Path -LiteralPath $oldLicenseRoot -PathType Container|Should Be $true
        $context=New-P9bBootstrapContext -Root $root -InstructionCommit ('d'*40)

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        Test-Path -LiteralPath $oldRule|Should Be $false
        @(Get-ChildItem -LiteralPath $oldLicenseRoot -File -Recurse -ErrorAction SilentlyContinue).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target '.claude/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/delivery.json') -PathType Leaf|Should Be $true
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        @($manifest.files|Where-Object{[string]$_.targetPath-ceq'.claude/AI-Rules/Database.en.md'-or[string]$_.targetPath-like'.claude/ai-instructions-licenses/cccc*'}).Count|Should Be 0
        $exclude=[IO.File]::ReadAllText((Join-Path $target '.git/info/exclude'))
        $exclude|Should Not Match '(?m)^/\.claude/AI-Rules/Database\.en\.md$'
        $exclude|Should Not Match '(?m)^/\.claude/ai-instructions-licenses/cccc'
        $exclude|Should Match '(?m)^/\.claude/ai-instructions-licenses/dddd'
    }

    # Scenario: A manifest-owned CLAUDE.md becomes project-owned before the source removes a Claude Rule and changes the license commit namespace.
    # Purpose: Protect obsolete as well as still-desired Claude family entries, bytes, and excludes once the family is project-owned.
    It 'InterT119_preserves_obsolete_Claude_entries_after_the_base_becomes_project_owned' {
        $root=Join-Path $script:ExternalRoot 'p9b-owned-obsolete';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -OmitClaudeDatabase
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $claudePath=Join-Path $target 'CLAUDE.md'
        [IO.File]::AppendAllText($claudePath,"project ownership`n",[Text.UTF8Encoding]::new($false))
        $claudeBytes=[IO.File]::ReadAllBytes($claudePath)
        $claudeFamily=Get-P7eTreeSnapshot (Join-Path $target '.claude')
        $excludePath=Join-Path $target '.git/info/exclude'
        $claudeExcludeBefore=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-eq'/CLAUDE.md'-or$_-like'/.claude/AI-Rules/*'-or$_-like'/.claude/ai-instructions-licenses/*'}|Sort-Object)
        $oldRule='.claude/AI-Rules/Database.en.md'
        $oldLicense='.claude/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/delivery.json'
        $context=New-P9bBootstrapContext -Root $root -InstructionCommit ('d'*40)

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $result.Output|Should Match 'claude-base-skipped-project-owned'
        [IO.File]::ReadAllBytes($claudePath)|Should Be $claudeBytes
        (Get-P7eTreeSnapshot (Join-Path $target '.claude'))|Should Be $claudeFamily
        Test-Path -LiteralPath (Join-Path $target $oldRule) -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $target $oldLicense) -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $target '.claude/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/delivery.json')|Should Be $false
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        @($manifest.files|Where-Object{[string]$_.targetPath-in@($oldRule,$oldLicense)}).Count|Should Be 2
        $claudeExcludeAfter=@([IO.File]::ReadAllLines($excludePath)|Where-Object{$_-eq'/CLAUDE.md'-or$_-like'/.claude/AI-Rules/*'-or$_-like'/.claude/ai-instructions-licenses/*'}|Sort-Object)
        $claudeExcludeAfter|Should Be $claudeExcludeBefore
        [IO.File]::ReadAllText($excludePath)|Should Match '(?m)^/\.codex/ai-instructions-licenses/dddddddddddddddddddddddddddddddddddddddd/'
        [IO.File]::ReadAllText($excludePath)|Should Not Match '(?m)^/\.codex/ai-instructions-licenses/cccccccccccccccccccccccccccccccccccccccc/'
        ([IO.File]::ReadAllText((Join-Path $target 'AGENTS.md')))|Should Match '<!-- changed -->'
    }

    # Scenario: A customized retained instruction is carried from an existing v4 manifest while the source renderer changes.
    # Purpose: Preserve the retained entry's host, renderer ID, and renderer hash instead of attributing old bytes to the current renderer.
    It 'InterT120_preserves_renderer_provenance_for_a_retained_v4_instruction' {
        $root=Join-Path $script:ExternalRoot 'p9b-retained-renderer';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -Marker baseline -RendererMarker renderer-a
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -Marker changed -RendererMarker renderer-b
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retained=@($manifest.files|Where-Object targetPath -eq $retainedTarget)[0]
        $retained.rendererId='retained-renderer'
        $retained.rendererSha256='1'*64
        Set-P9bJson -Path $manifestPath -Document $manifest
        [IO.File]::AppendAllText((Join-Path $target $retainedTarget),"project customization`n",[Text.UTF8Encoding]::new($false))

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target
        $result.ExitCode|Should Be 0
        $updated=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $entry=@($updated.files|Where-Object targetPath -eq $retainedTarget)[0]
        [string]$entry.host|Should Be codex
        [string]$entry.rendererId|Should Be retained-renderer
        [string]$entry.rendererSha256|Should Be ('1'*64)
        @($updated.files|Where-Object{[string]$_.targetPath-ne$retainedTarget-and[string]$_.rendererSha256-eq$changed.RendererSha256}).Count|Should BeGreaterThan 0
    }

    # Scenario: A schema-v1 Skill entry remains after its REPO payload was already removed without staged or tracked residue.
    # Purpose: Treat the absent payload as a completed migration and let the projection-aware writer emit a complete v4 instruction manifest.
    It 'InterT121_advances_to_v4_after_a_legacy_Skill_payload_was_already_migrated' {
        $root=Join-Path $script:ExternalRoot 'p9b-v1-skill-migrated';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $skillRelative='.agents/skills/legacy-skill/SKILL.md'
        Set-P9bJson -Path (Join-Path $target '.codex/ai-instructions.manifest.json') -Document ([ordered]@{
            schemaVersion=1;sourceRepository='https://example.com/legacy-ai-instructions.git';sourceRef='legacy-pin'
            files=@([ordered]@{sourcePath=$skillRelative;targetPath=$skillRelative;sha256=('a'*64)})
        })

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $target '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        @($manifest.files|Where-Object{[string]$_.targetPath-like'.agents/skills/*'}).Count|Should Be 0
        Test-Path -LiteralPath (Join-Path $target $skillRelative)|Should Be $false
        [IO.File]::ReadAllText((Join-Path $target '.git/info/exclude'))|Should Not Match '(?m)^/\.agents/skills/'
    }

    # Scenario: A schema-v1 Skill payload is still present, or its tracked payload is missing with a pending worktree deletion.
    # Purpose: Preserve both legacy ownership forms with a typed refusal before any REPO byte, index, HEAD, status, or exclude mutation.
    It 'InterT122_refuses_v4_while_legacy_Skill_ownership_must_be_retained_for_<Case>' -TestCases @(
        @{Case='untracked-present';TrackedMissing=$false},
        @{Case='tracked-missing';TrackedMissing=$true}
    ) {
        param($Case,$TrackedMissing)
        $root=Join-Path $script:ExternalRoot ("p9b-v1-skill-retained-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        $skillRelative='.agents/skills/legacy-skill/SKILL.md'
        $skillPath=Join-Path $target $skillRelative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath)|Out-Null
        [IO.File]::WriteAllText($skillPath,"# Legacy Skill`n",[Text.UTF8Encoding]::new($false))
        $skillHash=(Get-FileHash -LiteralPath $skillPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($TrackedMissing){
            & git -C $target add -- $skillRelative
            & git -C $target commit --quiet -m 'track legacy Skill payload'
            Remove-Item -LiteralPath $skillPath -Force
        }
        Set-P9bJson -Path (Join-Path $target '.codex/ai-instructions.manifest.json') -Document ([ordered]@{
            schemaVersion=1;sourceRepository='https://example.com/legacy-ai-instructions.git';sourceRef='legacy-pin'
            files=@([ordered]@{sourcePath=$skillRelative;targetPath=$skillRelative;sha256=$skillHash})
        })
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'cannot replace retained legacy REPO Skill ownership'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A customized v2 entry or staged v3 entry is retained byte-for-byte during its one legacy-to-v4 conversion.
    # Purpose: Record an explicit legacy retention sentinel instead of attributing unrendered bytes to the current renderer.
    It 'InterT123_marks_retained_<Case>_legacy_instruction_with_unrendered_sentinel' -TestCases @(
        @{Case='customized-v2';SchemaVersion=2;TargetPath='.codex/AI-Rules/CodeReview.en.md';Staged=$false},
        @{Case='staged-v3';SchemaVersion=3;TargetPath='CLAUDE.md';Staged=$true}
    ) {
        param($Case,$SchemaVersion,$TargetPath,$Staged)
        $root=Join-Path $script:ExternalRoot ("p9b-legacy-retained-$Case");New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip') -RendererMarker renderer-a
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion $SchemaVersion
        $targetFullPath=Join-Path $target $TargetPath
        [IO.File]::AppendAllText($targetFullPath,"retained $Case`n",[Text.UTF8Encoding]::new($false))
        $retainedBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetFullPath))
        if($Staged){& git -C $target add --force -- $TargetPath;if($LASTEXITCODE-ne0){throw "Could not stage $TargetPath."}}

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetFullPath))|Should Be $retainedBytes
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int]$manifest.schemaVersion|Should Be 4
        $entry=@($manifest.files|Where-Object targetPath -eq $TargetPath)[0]
        [string]$entry.retention|Should Be legacy-preserved
        [string]$entry.rendererId|Should Be legacy-unrendered
        ($null-eq$entry.rendererSha256)|Should Be $true
        [string]$entry.host|Should Be $(if($TargetPath-ceq'CLAUDE.md'){'claude'}else{'codex'})
        if($Staged){(@(& git -C $target diff --cached --name-only -- $TargetPath)-join'')|Should Be $TargetPath}
    }

    # Scenario: A valid v4 sentinel entry remains customized while a later v4 run uses different renderer bytes.
    # Purpose: Preserve the original sentinel and never mint or replace retention provenance during v4-to-v4 reconciliation.
    It 'InterT124_preserves_an_existing_v4_unrendered_sentinel' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-sentinel-preserved';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'baseline-work') -ArchivePath (Join-Path $root 'baseline.zip') -RendererMarker renderer-a
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'changed-work') -ArchivePath (Join-Path $root 'changed.zip') -RendererMarker renderer-b
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 2
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retainedPath=Join-Path $target $retainedTarget
        [IO.File]::AppendAllText($retainedPath,"legacy customization`n",[Text.UTF8Encoding]::new($false))
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $baseline.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($retainedPath))

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $changed.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($retainedPath))|Should Be $before
        $entry=@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object targetPath -eq $retainedTarget)[0]
        [string]$entry.retention|Should Be legacy-preserved
        [string]$entry.rendererId|Should Be legacy-unrendered
        ($null-eq$entry.rendererSha256)|Should Be $true
    }

    # Scenario: A sentinel entry's current bytes are restored to the desired render output before the next v4 run.
    # Purpose: Replace the legacy sentinel with verifiable renderer provenance as soon as normal reconciliation can own the bytes.
    It 'InterT125_replaces_sentinel_after_normal_rewrite_eligibility_returns' {
        $root=Join-Path $script:ExternalRoot 'p9b-sentinel-rewritten';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip') -RendererMarker renderer-a
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 3
        $retainedTarget='.codex/AI-Rules/CodeReview.en.md'
        $retainedPath=Join-Path $target $retainedTarget
        [IO.File]::AppendAllText($retainedPath,"legacy customization`n",[Text.UTF8Encoding]::new($false))
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        Copy-Item -LiteralPath (Join-Path $source.SourceRoot $retainedTarget) -Destination $retainedPath -Force

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Be 0
        $entry=@((Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).files|Where-Object targetPath -eq $retainedTarget)[0]
        @($entry.PSObject.Properties.Name)|Should Not Contain retention
        [string]$entry.rendererId|Should Be build-ai-instructions
        [string]$entry.rendererSha256|Should Be $source.RendererSha256
    }

    # Scenario: A retained legacy instruction uses a case-variant target that the legacy reader accepted but no exact v4 host owns.
    # Purpose: Return a typed refusal without mutation instead of guessing a host and manufacturing v4 ownership metadata.
    It 'InterT126_fails_closed_when_legacy_instruction_host_cannot_be_determined' {
        $root=Join-Path $script:ExternalRoot 'p9b-legacy-host-unknown';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $context=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        Convert-P9bManifestToLegacy -Path $manifestPath -SchemaVersion 2
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        $legacyBase=@($manifest.files|Where-Object targetPath -ceq 'AGENTS.md')[0]
        $legacyBase.targetPath='agents.md'
        Set-P9bJson -Path $manifestPath -Document $manifest
        [IO.File]::AppendAllText((Join-Path $target 'AGENTS.md'),"legacy customization`n",[Text.UTF8Encoding]::new($false))
        $before=Get-P9bRepoSnapshot $target

        $result=Invoke-P9bRepoBootstrap -Context $context -ArchivePath $source.ArchivePath -TargetRoot $target

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be closure-invalid
        $result.Output|Should Match 'Cannot determine exactly one instruction host'
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: A repository first writes v4 under one verified Catalog/Lock pair, then a newly installed v3/v5 runtime carries an updated valid Lock.
    # Purpose: Accept the old manifest as historical ownership, bind the next manifest to current verified context, increment once, and remain idempotent.
    It 'InterT127_advances_existing_v4_to_a_new_verified_Lock_idempotently' {
        $root=Join-Path $script:ExternalRoot 'p9b-v4-lock-advance';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $source=New-P9bInstructionArchive -WorkingRoot (Join-Path $root 'source-work') -ArchivePath (Join-Path $root 'source.zip')
        $initialContext=New-P9bBootstrapContext -Root $root
        $target=Join-Path $root 'target';New-P9bTargetRepository $target
        (Invoke-P9bRepoBootstrap -Context $initialContext -ArchivePath $source.ArchivePath -TargetRoot $target).ExitCode|Should Be 0
        $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 1

        $updatedCandidate=Join-Path $root 'updated-source';New-P7eV3Candidate -Destination $updatedCandidate
        $updatedLockPath=Join-Path $updatedCandidate 'catalog/skills-catalog-lock.json'
        $updatedLock=Get-Content -Raw -LiteralPath $updatedLockPath|ConvertFrom-Json
        $updatedLock.sources[0].requestedRef='v1.0.1'
        $updatedLock.sources[0].resolvedCommit='9'*40
        $updatedLock.sources[0].resolvedVersion='1.0.1'
        $updatedLock.sources[0].archiveSha256='8'*64
        foreach($skill in @($updatedLock.skills)){$skill.contentSha256='7'*64}
        Set-P9bJson -Path $updatedLockPath -Document $updatedLock
        $updatedHome=Join-Path $root 'updated-home'
        $install=Invoke-P7eInstaller -SourceRoot $updatedCandidate -CodexHome $updatedHome -WriterSchema V3V5
        $install.ExitCode|Should Be 0
        $updatedContext=New-P9bBootstrapContext -Root $root -CodexHome $updatedHome
        $updatedContext.LockSha256|Should Not Be $initialContext.LockSha256

        $advanced=Invoke-P9bRepoBootstrap -Context $updatedContext -ArchivePath $source.ArchivePath -TargetRoot $target
        $advanced.ExitCode|Should Be 0
        $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
        [int64]$manifest.generation|Should Be 2
        [string]$manifest.lockSha256|Should Be $updatedContext.LockSha256
        [string]$manifest.projectionContractSha256|Should Be $updatedContext.ProjectionContractSha256
        $before=Get-P9bRepoSnapshot $target

        $repeat=Invoke-P9bRepoBootstrap -Context $updatedContext -ArchivePath $source.ArchivePath -TargetRoot $target
        $repeat.ExitCode|Should Be 0
        [int64](Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json).generation|Should Be 2
        (Get-P9bRepoSnapshot $target)|Should Be $before
    }

    # Scenario: The stable launcher has opened a verified closure file with its read-only sharing contract.
    # Purpose: Bind verified bytes through import/inventory assertion by denying concurrent writes and deletion until disposal.
    It 'UnitT95_holds_launcher_closure_bytes_against_write_and_delete' {
        $launcherPath=Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-installed.ps1'
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($launcherPath,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $definition=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Open-TrustedRuntimeFileLease'},$true))[0]
        $definition|Should Not BeNullOrEmpty
        Invoke-Expression $definition.Extent.Text
        $path=Join-Path $script:ExternalRoot 'ai-instructions-runtime-contract.psm1';Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Destination $path
        $lease=Open-TrustedRuntimeFileLease -Path $path
        try{
            { $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose() }|Should Throw
            { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }|Should Throw
        }
        finally{$lease.Dispose()}
        { [IO.File]::AppendAllText($path,"# released`n",[Text.UTF8Encoding]::new($false)) }|Should Not Throw
    }
}

$script:HasWindowsPowerShell51=$false
if($env:OS-ceq'Windows_NT'-and$null-ne(Get-Command powershell.exe -ErrorAction SilentlyContinue)){
    $desktopVersion=(& powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'|Select-Object -Last 1)
    $script:HasWindowsPowerShell51=[string]$desktopVersion-like'5.1.*'
}
if($script:HasWindowsPowerShell51){
    Describe 'AI instructions v3 launcher Windows PowerShell baseline' {
        # Scenario: Windows PowerShell 5.1 opens an installed v3/v5 runtime.
        # Purpose: Register only on a real 5.1 host and return runtime-baseline-unavailable without a skip.
        It 'InterT100_refuses_v3v5_on_Windows_PowerShell_5_1' {
            $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';$root=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $root|Out-Null
            try{
                $candidate=Join-Path $root 'src';New-P7eV3Candidate $candidate;$fixtureHome=Join-Path $root 'home';$install=Invoke-P7eInstaller -SourceRoot $candidate -CodexHome $fixtureHome -WriterSchema V3V5;$install.ExitCode|Should Be 0
                $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure -CodexHome $fixtureHome -Desktop
                $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be runtime-baseline-unavailable
                (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
            }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
        }
    }
}
