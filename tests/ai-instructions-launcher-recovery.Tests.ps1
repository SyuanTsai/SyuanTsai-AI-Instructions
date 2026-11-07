$script:RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:InstallerScript=Join-Path $script:RepositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1'
$script:PowerShellExecutable=(Get-Process -Id $PID).Path
Import-Module (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Force

function New-LauncherRecoverySourceArchive {
    param([Parameter(Mandatory=$true)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $files=@(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'scripts'),(Join-Path $script:RepositoryRoot 'catalog') -Recurse -File)
            $files+=@(Get-ChildItem -LiteralPath $script:RepositoryRoot -File|Where-Object Name -in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json'))
            foreach($file in @($files|Sort-Object FullName)){
                $relative=$file.FullName.Substring($script:RepositoryRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry=$archive.CreateEntry("candidate-root/$relative")
                $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
                try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
    return (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-LauncherRecoveryInstaller {
    param([Parameter(Mandatory=$true)][string]$CodexHome)
    $arguments=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallerScript,
        '-RepositoryRoot',$script:RepositoryRoot,'-CodexHome',$CodexHome,
        '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
        '-SourceCommit',$script:SourceCommit,'-ArchiveSha256',$script:ArchiveSha256,'-SourceArchivePath',$script:ArchivePath
    )
    $output=& $script:PowerShellExecutable @arguments 2>&1
    if($LASTEXITCODE-ne0){throw "Launcher recovery fixture install failed: $($output-join[Environment]::NewLine)"}
}

function Copy-LauncherRecoveryHome {
    param([Parameter(Mandatory=$true)][string]$Name)
    $path=Join-Path $script:ExternalTestRoot $Name
    Copy-Item -LiteralPath $script:TemplateHome -Destination $path -Recurse
    return $path
}

function Get-LauncherRecoveryHomeDigest {
    param([Parameter(Mandatory=$true)][string]$CodexHome)
    return (@(Get-ChildItem -LiteralPath $CodexHome -Recurse -Force -File|Sort-Object FullName|ForEach-Object{
        $relative=$_.FullName.Substring($CodexHome.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        "$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    })-join"`n")
}

function Invoke-LauncherRecoveryFailure {
    param([Parameter(Mandatory=$true)][string]$CodexHome,[switch]$ValidateOnly,[switch]$Recover)
    $launcher=Join-Path $CodexHome 'hooks\bootstrap-ai-instructions.ps1'
    try{
        if($Recover){& $launcher -RecoverInterruptedInstall|Out-Null}
        elseif($ValidateOnly){& $launcher -ValidateOnly -SkipUpdateCheck|Out-Null}
        else{& $launcher -SkipUpdateCheck|Out-Null}
        return $null
    }catch{return $_}
}

function Set-LauncherRecoveryPinMismatch {
    param([Parameter(Mandatory=$true)][string]$CodexHome)
    $path=Join-Path $CodexHome 'ai-instructions-sync.json'
    $configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath $path|ConvertFrom-Json
    $configuration.catalog.ref='0'*40
    [IO.File]::WriteAllText($path,(($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n"),[Text.UTF8Encoding]::new($false))
}

Describe 'AI instructions launcher recovery' {
    BeforeAll {
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){throw 'AI instructions launcher recovery is registered only on the native Windows host.'}
        $script:ExternalTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('ai-instructions-launcher-recovery-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ExternalTestRoot|Out-Null
        $script:ArchivePath=Join-Path $script:ExternalTestRoot 'source.zip'
        $script:ArchiveSha256=New-LauncherRecoverySourceArchive -ArchivePath $script:ArchivePath
        $script:SourceCommit=(@(& git -C $script:RepositoryRoot rev-parse HEAD)-join'').Trim()
        $script:TemplateHome=Join-Path $script:ExternalTestRoot 'template-home'
        Invoke-LauncherRecoveryInstaller -CodexHome $script:TemplateHome
    }

    AfterAll {
        if(-not [string]::IsNullOrWhiteSpace($script:ExternalTestRoot)-and(Test-Path -LiteralPath $script:ExternalTestRoot)){
            Remove-Item -LiteralPath $script:ExternalTestRoot -Recurse -Force
        }
    }

    # Scenario: Each D3 residue class is visible before runtime verification on ordinary and ValidateOnly launcher paths.
    # Purpose: Return interrupted-install without importing a deliberately corrupted platform runtime or changing any bytes.
    It 'LaunchT01_refuses_every_transaction_residue_class_before_runtime_import' -TestCases @(
        @{Variant='valid-journal'},@{Variant='malformed-journal'},@{Variant='orphan-without-journal'},@{Variant='invalid-name'}
    ) {
        param($Variant)
        foreach($validate in @($false,$true)){
            $fixtureHome=Copy-LauncherRecoveryHome -Name ("residue-$Variant-$validate-"+[Guid]::NewGuid().ToString('N'))
            $store=Join-Path $fixtureHome '.ai-instructions-txn';New-Item -ItemType Directory -Force -Path $store|Out-Null
            if($Variant-eq'valid-journal'){
                $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json')|ConvertFrom-Json
                $transaction=Join-Path $store ([string]$journal.transactionId);New-Item -ItemType Directory -Path $transaction|Out-Null
                [IO.File]::WriteAllText((Join-Path $transaction 'journal.json'),(($journal|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
            }else{
                $name=if($Variant-eq'invalid-name'){'invalid-name'}else{[Guid]::NewGuid().ToString('N')}
                $transaction=Join-Path $store $name;New-Item -ItemType Directory -Path $transaction|Out-Null
                if($Variant-eq'malformed-journal'){[IO.File]::WriteAllText((Join-Path $transaction 'journal.json'),'{',[Text.UTF8Encoding]::new($false))}
            }
            [IO.File]::AppendAllText((Join-Path $fixtureHome 'hooks\ai-instructions-runtime\platform-runtime.psm1'),"`nthrow 'must not import tampered platform runtime'`n")
            $before=Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome
            $caught=Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -ValidateOnly:$validate
            (Get-AiInstructionsRefusalCode $caught)|Should Be interrupted-install
            (Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome)|Should Be $before
        }
    }

    # Scenario: The transaction store exists as a junction, while an ordinary empty physical store is harmless.
    # Purpose: Treat the alias itself as residue without rejecting the installer's retained empty namespace.
    It 'LaunchT02_refuses_a_junction_store_and_accepts_an_empty_physical_store' {
        $emptyHome=Copy-LauncherRecoveryHome -Name 'empty-store';New-Item -ItemType Directory -Force -Path (Join-Path $emptyHome '.ai-instructions-txn')|Out-Null
        {& (Join-Path $emptyHome 'hooks\bootstrap-ai-instructions.ps1') -ValidateOnly -SkipUpdateCheck}|Should Not Throw
        $junctionHome=Copy-LauncherRecoveryHome -Name 'junction-store';$store=Join-Path $junctionHome '.ai-instructions-txn'
        if(Test-Path -LiteralPath $store){Remove-Item -LiteralPath $store -Recurse -Force}
        $target=Join-Path $script:ExternalTestRoot 'junction-target';New-Item -ItemType Directory -Force -Path $target|Out-Null
        New-Item -ItemType Junction -Path $store -Target $target|Out-Null
        (Get-AiInstructionsRefusalCode (Invoke-LauncherRecoveryFailure -CodexHome $junctionHome -ValidateOnly))|Should Be interrupted-install
    }

    # Scenario: A pre-journal legacy namespace remains beside an otherwise valid installed runtime.
    # Purpose: Preserve its evidence and refuse both ordinary launch and pin recovery.
    It 'LaunchT03_refuses_and_preserves_legacy_residue' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name 'legacy-residue';$path=Join-Path $fixtureHome '.ai-instructions-backup-evidence'
        New-Item -ItemType Directory -Path $path|Out-Null;[IO.File]::WriteAllText((Join-Path $path 'evidence.txt'),'keep')
        (Get-AiInstructionsRefusalCode (Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -ValidateOnly))|Should Be interrupted-install
        (Get-AiInstructionsRefusalCode (Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -Recover))|Should Be interrupted-install
        [IO.File]::ReadAllText((Join-Path $path 'evidence.txt'))|Should Be keep
    }

    # Scenario: Only the verified configuration pin differs from the installed immutable runtime.
    # Purpose: Repair it with the shared journal executor and leave no transaction or legacy recovery artifacts.
    It 'LaunchT04_repairs_a_pin_mismatch_with_one_journaled_write_file_operation' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name 'pin-repair';Set-LauncherRecoveryPinMismatch -CodexHome $fixtureHome
        $launcher=Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1';& $launcher -RecoverInterruptedInstall|Out-Null
        $bundle=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\runtime-bundle.json')|ConvertFrom-Json
        $configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtureHome 'ai-instructions-sync.json')|ConvertFrom-Json
        [string]$configuration.catalog.ref|Should Be ([string]$bundle.commit)
        @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn')).Count|Should Be 0
        @(Get-ChildItem -Force -LiteralPath $fixtureHome|Where-Object Name -Match '^\.ai-instructions-sync\.json\.(recovery|backup|failed)-').Count|Should Be 0
    }

    # Scenario: Pin publication reaches the failpoint before its applied journal state is durable.
    # Purpose: Make the next launcher fail closed until the installer rolls the retained transaction to a complete state.
    It 'LaunchT05_leaves_failfast_pin_publication_for_installer_only_recovery' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name 'pin-failfast';Set-LauncherRecoveryPinMismatch -CodexHome $fixtureHome
        $stdout=Join-Path $script:ExternalTestRoot 'pin-failfast.stdout';$stderr=Join-Path $script:ExternalTestRoot 'pin-failfast.stderr'
        $previous=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','Process')
        try{
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','after-operation-1-before-journal','Process')
            $process=Start-Process -FilePath $script:PowerShellExecutable -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1'),'-RecoverInterruptedInstall') -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        }finally{[Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT',$previous,'Process')}
        $process.ExitCode|Should Not Be 0;$process.Dispose()
        (Get-AiInstructionsRefusalCode (Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -ValidateOnly))|Should Be interrupted-install
        Invoke-LauncherRecoveryInstaller -CodexHome $fixtureHome
        {& (Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1') -ValidateOnly -SkipUpdateCheck}|Should Not Throw
        @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn')).Count|Should Be 0
    }

    if($null-ne(Get-Command powershell.exe -ErrorAction SilentlyContinue)){
        # Scenario: Windows PowerShell 5.1 requests the mutation-only recovery switch.
        # Purpose: Return the typed baseline refusal before creating a lock or transaction artifact.
        It 'LaunchT06_refuses_pin_recovery_below_the_pwsh7_dotnet8_baseline' {
            $fixtureHome=Copy-LauncherRecoveryHome -Name 'desktop-recovery';Set-LauncherRecoveryPinMismatch -CodexHome $fixtureHome
            $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1') -RecoverInterruptedInstall 2>&1
            $LASTEXITCODE|Should Not Be 0
            (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be runtime-baseline-unavailable
            @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
        }

        # Scenario: The stable launcher performs ordinary fan-out on Windows PowerShell 5.1.
        # Purpose: Skip the updater with a stderr hint, never select powershell.exe as its engine, and still complete fan-out.
        It 'LaunchT07_skips_the_desktop_update_check_and_completes_fan_out' {
            $fixtureHome=Copy-LauncherRecoveryHome -Name 'desktop-validation'
            $configurationPath=Join-Path $fixtureHome 'ai-instructions-sync.json'
            $configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json
            $configuration.catalog.profiles=@();$configuration.catalog.includeSkills=@();$configuration.catalog.excludeSkills=@()
            [IO.File]::WriteAllText($configurationPath,(($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n"),[Text.UTF8Encoding]::new($false))
            $fixtureUser=Join-Path $script:ExternalTestRoot 'desktop-user';New-Item -ItemType Directory -Path $fixtureUser|Out-Null
            $targetRoot=Join-Path $script:ExternalTestRoot 'desktop-target';New-Item -ItemType Directory -Path $targetRoot|Out-Null
            & git -C $targetRoot init --quiet
            & git -C $targetRoot config user.name 'Fixture User'
            & git -C $targetRoot config user.email 'fixture@example.test'
            [IO.File]::WriteAllText((Join-Path $targetRoot 'README.md'),"# Fixture`n",[Text.UTF8Encoding]::new($false))
            & git -C $targetRoot add README.md
            & git -C $targetRoot commit --quiet -m fixture
            & git -C $targetRoot remote add origin 'https://example.org/team/project.git'
            $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1') -TargetRoot $targetRoot -UserHome $fixtureUser 2>&1
            if($LASTEXITCODE-ne0){throw ('Windows PowerShell fan-out failed: '+(($output-join[Environment]::NewLine)-replace[regex]::Escape($script:ExternalTestRoot),'<test-root>'))}
            ($output-join[Environment]::NewLine)|Should Match 'automatic update check was skipped because it requires pwsh 7'
            Test-Path -LiteralPath (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|Should Be $true
            $source=Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1')
            $source|Should Match 'automatic update check was skipped because it requires pwsh 7'
            $source|Should Not Match "engineName = if \(.+Desktop.+powershell\.exe"
        }
    }
}
