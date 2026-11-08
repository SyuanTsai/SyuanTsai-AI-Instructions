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
