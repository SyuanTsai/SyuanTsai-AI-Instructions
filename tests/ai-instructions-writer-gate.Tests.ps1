$script:RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PowerShellExecutable=(Get-Process -Id $PID).Path
$script:InstallerPath=Join-Path $script:RepositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Force

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
param([string]$CatalogPath,[string]$LockPath,[string]$ConfigurationPath,[string]$TargetRoot,[string]$UserHome,[switch]$WhatIf)
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
        [ValidateSet('Auto','V2V4','V3V5')][string]$WriterSchema='Auto'
    )
    $archive=Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome)+'.zip')
    $hash=New-P7eSourceArchive -SourceRoot $SourceRoot -ArchivePath $archive
    $commit=(@(& git -C $script:RepositoryRoot rev-parse HEAD)-join'').Trim()
    $installer=Join-Path $SourceRoot 'scripts\install-ai-instructions-bootstrap.ps1'
    $arguments=@('-NoProfile','-NonInteractive','-File',$installer,'-RepositoryRoot',$SourceRoot,'-CodexHome',$CodexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$commit,'-ArchiveSha256',$hash,'-SourceArchivePath',$archive,'-WriterSchema',$WriterSchema)
    $output=& $script:PowerShellExecutable @arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
}

function Get-P7eTreeSnapshot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return ''}
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    return (@(Get-ChildItem -Force -LiteralPath $rootPath -Recurse -File|ForEach-Object{
        $relative=$_.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        "$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }|Sort-Object)-join"`n")
}

function Copy-P7eHome {
    param([string]$Source,[string]$Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    return $Destination
}

function Invoke-P7eLauncherFailure {
    param([string]$CodexHome,[switch]$Desktop)
    $engine=if($Desktop){'powershell.exe'}else{$script:PowerShellExecutable}
    $output=& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CodexHome 'hooks\bootstrap-ai-instructions.ps1') -ValidateOnly -SkipUpdateCheck 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output-join[Environment]::NewLine)}
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

    # Scenario: V2V4 targets an installed state containing v3 and v5.
    # Purpose: Refuse rollback before target bytes change.
    It 'InterT50_refuses_explicit_v2v4_downgrade_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'down');$before=Get-P7eTreeSnapshot $fixtureHome
        $result=Invoke-P7eInstaller -SourceRoot $script:RepositoryRoot -CodexHome $fixtureHome -WriterSchema V2V4
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

    # Scenario: The bundle declares a different host architecture.
    # Purpose: Return the fixed platform-mismatch code after the trusted capability probe and preserve all bytes.
    It 'InterT70_rejects_platform_mismatch_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'platform')
        $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.platform.architecture=if($bundle.platform.architecture-ceq'x64'){'arm64'}else{'x64'};$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be platform-mismatch
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
    }

    # Scenario: The bundle adds powershell-runtime, which the current Windows receipt genuinely reports unavailable.
    # Purpose: Satisfy D14 with a real host receipt rather than a production override.
    It 'InterT80_rejects_a_real_unavailable_capability_without_mutation' {
        $fixtureHome=Copy-P7eHome $script:BaseV3Home (Join-Path $script:ExternalRoot 'capability')
        $path=Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json';$bundle=Get-Content -Raw $path|ConvertFrom-Json;$bundle.requiredCapabilities=@($bundle.requiredCapabilities)+@('powershell-runtime');$bundle|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure $fixtureHome
        $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
        (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
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
