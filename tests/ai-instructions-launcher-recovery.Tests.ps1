$script:RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:InstallerScript=Join-Path $script:RepositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1'
$script:PowerShellExecutable=(Get-Process -Id $PID).Path
$script:CanonicalRepository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1') -Force

function New-LauncherRecoverySourceArchive {
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [string]$SourceRoot=$script:RepositoryRoot
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $files=@(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'scripts'),(Join-Path $SourceRoot 'catalog') -Recurse -File)
            $files+=@(Get-ChildItem -LiteralPath $SourceRoot -File|Where-Object Name -in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json'))
            foreach($file in @($files|Sort-Object FullName)){
                $relative=$file.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
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
    return (@(Get-ChildItem -LiteralPath $CodexHome -Recurse -Force|Sort-Object FullName|ForEach-Object{
        $relative=$_.FullName.Substring($CodexHome.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $kind=if(($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse'}elseif($_.PSIsContainer){'directory'}else{'file'}
        $hash=if($kind-ceq'file'){(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}else{'-'}
        "$relative=$kind;$([int64]$_.Attributes);$hash"
    })-join"`n")
}

function New-LauncherRecoveryFailpointCandidate {
    param([Parameter(Mandatory=$true)][string]$DestinationRoot)
    New-Item -ItemType Directory -Path $DestinationRoot|Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts'),(Join-Path $script:RepositoryRoot 'catalog') -Destination $DestinationRoot -Recurse
    foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $leaf) -Destination (Join-Path $DestinationRoot $leaf)
    }
    foreach($relative in @('bootstrap-ai-instructions-installed.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1','safe-zip.psm1')){
        [IO.File]::AppendAllText((Join-Path $DestinationRoot "scripts\$relative"),"`n# launcher recovery failpoint candidate: $relative`n",[Text.UTF8Encoding]::new($false))
    }
}

function Get-LauncherRecoveryCanonicalTextSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    [byte[]]$bytes=[IO.File]::ReadAllBytes($Path)
    $utf8=[Text.UTF8Encoding]::new($false,$true)
    $canonicalBytes=$utf8.GetBytes($utf8.GetString($bytes).Replace("`r`n","`n"))
    $sha256=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha256.ComputeHash($canonicalBytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha256.Dispose()}
}

function New-LauncherRecoveryPlatformCandidate {
    param([Parameter(Mandatory=$true)][string]$DestinationRoot)
    New-Item -ItemType Directory -Path $DestinationRoot|Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts'),(Join-Path $script:RepositoryRoot 'catalog') -Destination $DestinationRoot -Recurse
    foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $leaf) -Destination (Join-Path $DestinationRoot $leaf)
    }

    $fingerprintedRelativePath='platform/PlatformNative.cs'
    $fingerprintedPath=Join-Path $DestinationRoot ('scripts/'+$fingerprintedRelativePath)
    [IO.File]::AppendAllText($fingerprintedPath,"`n// launcher updater different-build candidate`n",[Text.UTF8Encoding]::new($false))
    $fingerprintedSha256=Get-LauncherRecoveryCanonicalTextSha256 -Path $fingerprintedPath

    $sourceManifestPath=Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1'
    $sourceManifestSha256=Get-LauncherRecoveryCanonicalTextSha256 -Path $sourceManifestPath
    $candidateManifestPath=Join-Path $DestinationRoot 'scripts/platform-runtime.psd1'
    $manifestText=[IO.File]::ReadAllText($candidateManifestPath)
    $inventoryPattern="(?m)(@\{ Path = 'platform/PlatformNative\.cs'; Sha256 = ')[0-9a-f]{64}(' \},)"
    if([regex]::Matches($manifestText,$inventoryPattern).Count-ne1){throw 'Expected one PlatformNative.cs inventory pin in the candidate manifest.'}
    $manifestText=[regex]::Replace($manifestText,$inventoryPattern,('${1}'+$fingerprintedSha256+'${2}'))
    [IO.File]::WriteAllText($candidateManifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
    $candidateManifestSha256=Get-LauncherRecoveryCanonicalTextSha256 -Path $candidateManifestPath

    foreach($relativePath in @('Invoke-PesterShardProcess.ps1','Invoke-StandardValidation.ps1','StandardSemanticBridge.psm1','install-ai-instructions-bootstrap.ps1')){
        $pinPath=Join-Path $DestinationRoot ('scripts/'+$relativePath)
        $pinText=[IO.File]::ReadAllText($pinPath)
        if([regex]::Matches($pinText,[regex]::Escape($sourceManifestSha256)).Count-ne1){throw "Expected one platform manifest pin in $relativePath."}
        [IO.File]::WriteAllText($pinPath,$pinText.Replace($sourceManifestSha256,$candidateManifestSha256),[Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{RelativePath=$fingerprintedRelativePath;Path=$fingerprintedPath;Sha256=$fingerprintedSha256}
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

if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
Describe 'AI instructions launcher recovery' {
    BeforeAll {
        # Keep recovery transaction descendants below the legacy CreateFileW path limit; this Describe does not test long-path support.
        $script:ExternalTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('ailr-'+[Guid]::NewGuid().ToString('N'))
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

    # Scenario: The transaction root is a dangling junction on each launcher entry path.
    # Purpose: Detect the namespace leaf without following its missing target and preserve every existing entry and byte.
    It 'LaunchT08_refuses_a_dangling_transaction_root_on_every_launcher_path_without_mutation' {
        foreach($mode in @('ordinary','validate','recover')){
            $fixtureHome=Copy-LauncherRecoveryHome -Name ("dangling-$mode-"+[Guid]::NewGuid().ToString('N'))
            $store=Join-Path $fixtureHome '.ai-instructions-txn'
            if(Test-Path -LiteralPath $store){Remove-Item -LiteralPath $store -Recurse -Force}
            $target=Join-Path $script:ExternalTestRoot ("dangling-target-$mode-"+[Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $target|Out-Null
            New-Item -ItemType Junction -Path $store -Target $target|Out-Null
            Remove-Item -LiteralPath $target -Force
            $before=Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome
            $caught=switch($mode){
                'ordinary'{Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome}
                'validate'{Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -ValidateOnly}
                'recover'{Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -Recover}
            }
            (Get-AiInstructionsRefusalCode $caught)|Should Be interrupted-install
            (Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome)|Should Be $before
        }
    }

    # Scenario: The real installer FailFasts after publishing an operation and leaves a half-applied transaction.
    # Purpose: Make direct launcher recovery refuse without changing config, runtime, transaction evidence, or lock inventory.
    It 'LaunchT09_preserves_a_half_applied_installer_transaction_during_direct_recovery_refusal' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name ('installer-failfast-'+[Guid]::NewGuid().ToString('N'))
        $candidateRoot=Join-Path $script:ExternalTestRoot ('candidate-'+[Guid]::NewGuid().ToString('N'))
        New-LauncherRecoveryFailpointCandidate -DestinationRoot $candidateRoot
        $archivePath=Join-Path $script:ExternalTestRoot ('candidate-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-LauncherRecoverySourceArchive -ArchivePath $archivePath -SourceRoot $candidateRoot
        $arguments=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallerScript,
            '-RepositoryRoot',$script:RepositoryRoot,'-CodexHome',$fixtureHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$script:SourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath
        )
        $stdout=Join-Path $script:ExternalTestRoot 'installer-failfast.stdout';$stderr=Join-Path $script:ExternalTestRoot 'installer-failfast.stderr'
        $previous=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','Process')
        try{
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','after-operation-1-before-journal','Process')
            $process=Start-Process -FilePath $script:PowerShellExecutable -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        }finally{[Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT',$previous,'Process')}
        $process.ExitCode|Should Not Be 0;$process.Dispose()
        @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn')).Count|Should BeGreaterThan 0
        $before=Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome
        (Get-AiInstructionsRefusalCode (Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -Recover))|Should Be interrupted-install
        (Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome)|Should Be $before
        @(Get-ChildItem -Force -LiteralPath $fixtureHome|Where-Object Name -Match '^\.recovery-|^\.ai-instructions-sync\.json\.(recovery|backup|failed)-').Count|Should Be 0
    }

    # Scenario: A concurrent installer exclusively owns the install lock before launcher recovery begins.
    # Purpose: Preserve the established recovery-specific lock-conflict message even when the shared trust lease fails first.
    It 'LaunchT10_reports_the_recovery_specific_message_for_a_shared_lease_conflict' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name ('recovery-lock-'+[Guid]::NewGuid().ToString('N'))
        Set-LauncherRecoveryPinMismatch -CodexHome $fixtureHome
        $stream=[IO.File]::Open((Join-Path $fixtureHome 'ai-instructions-install.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$caught=Invoke-LauncherRecoveryFailure -CodexHome $fixtureHome -Recover}finally{$stream.Dispose()}
        $caught.Exception.Message|Should Match 'recovery refused to run while another AI instructions installer is active'
        $caught.Exception.Message|Should Match 'classification=concurrency; retryable=false'
    }

    # Scenario: A complete installer replaces the verified runtime after the recovery trust lease is released but before its exclusive lock is acquired.
    # Purpose: Refuse the changed bundle generation before importing its platform runtime or performing any launcher-owned mutation.
    It 'LaunchT11_refuses_a_runtime_generation_changed_between_recovery_verifications' {
        $fixtureHome=Copy-LauncherRecoveryHome -Name ('mixed-generation-'+[Guid]::NewGuid().ToString('N'))
        Set-LauncherRecoveryPinMismatch -CodexHome $fixtureHome
        $candidateRoot=Join-Path $script:ExternalTestRoot ('mixed-generation-candidate-'+[Guid]::NewGuid().ToString('N'))
        New-LauncherRecoveryFailpointCandidate -DestinationRoot $candidateRoot
        $candidateArchive=Join-Path $script:ExternalTestRoot ('mixed-generation-candidate-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $candidateArchiveSha256=New-LauncherRecoverySourceArchive -ArchivePath $candidateArchive -SourceRoot $candidateRoot
        $candidateCommit='b'*40
        $candidateHome=Join-Path $script:ExternalTestRoot ('mixed-generation-home-'+[Guid]::NewGuid().ToString('N'))
        $candidateInstallerArguments=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallerScript,
            '-RepositoryRoot',$script:RepositoryRoot,'-CodexHome',$candidateHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$candidateCommit,'-ArchiveSha256',$candidateArchiveSha256,'-SourceArchivePath',$candidateArchive
        )
        $candidateInstallOutput=& $script:PowerShellExecutable @candidateInstallerArguments 2>&1
        if($LASTEXITCODE-ne0){throw "Candidate-home installer failed: $($candidateInstallOutput-join[Environment]::NewLine)"}
        $launcher=Join-Path $fixtureHome 'hooks\bootstrap-ai-instructions.ps1'
        $controlRoot=Join-Path $script:ExternalTestRoot ('mixed-generation-control-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $controlRoot|Out-Null
        $readyPath=Join-Path $controlRoot 'after-trust-verification-before-install-lock.ready'
        $releasePath=Join-Path $controlRoot 'after-trust-verification-before-install-lock.release'
        $stdout=Join-Path $controlRoot 'launcher.stdout';$stderr=Join-Path $controlRoot 'launcher.stderr'
        $previousFailpoint=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_FAILPOINT','Process')
        $previousControl=[Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_CONTROL_ROOT','Process')
        $process=$null
        try{
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_FAILPOINT','after-trust-verification-before-install-lock','Process')
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_CONTROL_ROOT',$controlRoot,'Process')
            $process=Start-Process -FilePath $script:PowerShellExecutable -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-RecoverInterruptedInstall') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            while(-not(Test-Path -LiteralPath $readyPath -PathType Leaf)){
                if($process.HasExited){throw "Launcher generation-swap fixture exited before ready: $(Get-Content -Raw -LiteralPath $stderr -ErrorAction SilentlyContinue)"}
                if([DateTime]::UtcNow-ge$deadline){throw 'Launcher generation-swap fixture did not reach the trust boundary.'}
                Start-Sleep -Milliseconds 25
            }
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_FAILPOINT',$null,'Process')
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_CONTROL_ROOT',$null,'Process')
            $fixtureRuntime=Join-Path $fixtureHome 'hooks\ai-instructions-runtime'
            Move-Item -LiteralPath $fixtureRuntime -Destination (Join-Path $controlRoot 'retired-runtime')
            Copy-Item -LiteralPath (Join-Path $candidateHome 'hooks\ai-instructions-runtime') -Destination (Join-Path $fixtureHome 'hooks') -Recurse
            foreach($leaf in @('bootstrap-ai-instructions.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1')){
                Copy-Item -LiteralPath (Join-Path $candidateHome "hooks\$leaf") -Destination (Join-Path $fixtureHome "hooks\$leaf") -Force
            }
            Copy-Item -LiteralPath (Join-Path $candidateHome 'ai-instructions-sync.json') -Destination (Join-Path $fixtureHome 'ai-instructions-sync.json') -Force
            $afterInstallDigest=Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome
            [IO.File]::WriteAllText($releasePath,"release`n",[Text.UTF8Encoding]::new($false))
            $process.WaitForExit()
            $exitCode=$process.ExitCode
        }finally{
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_FAILPOINT',$previousFailpoint,'Process')
            [Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_LAUNCHER_RECOVERY_CONTROL_ROOT',$previousControl,'Process')
            if($null-ne$process){
                if(-not$process.HasExited){
                    if(-not(Test-Path -LiteralPath $releasePath -PathType Leaf)){[IO.File]::WriteAllText($releasePath,"release`n",[Text.UTF8Encoding]::new($false))}
                    if(-not$process.WaitForExit(5000)){$process.Kill();$process.WaitForExit()}
                }
                $process.Dispose()
            }
        }
        $exitCode|Should Not Be 0
        $refusalText=(Get-Content -Raw -LiteralPath $stderr -ErrorAction SilentlyContinue)+(Get-Content -Raw -LiteralPath $stdout -ErrorAction SilentlyContinue)
        (Get-AiInstructionsRefusalCode $refusalText)|Should Be closure-invalid
        (Get-LauncherRecoveryHomeDigest -CodexHome $fixtureHome)|Should Be $afterInstallDigest
        (Get-Content -Raw -LiteralPath (Join-Path $fixtureHome 'hooks\ai-instructions-runtime\bootstrap-ai-instructions-installed.ps1'))|Should Match 'launcher recovery failpoint candidate'
        @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn')).Count|Should Be 0
    }

    # Scenario: Launcher update-check baseline decisions are evaluated against explicit Desktop/Core, PowerShell, and .NET version inputs.
    # Purpose: Keep PowerShell 7.0-7.3 and every pre-.NET-8 host on read-only fan-out without invoking the updater.
    It 'LaunchT12_matches_the_updater_baseline_for_update_check_eligibility' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-installed.ps1'),[ref]$tokens,[ref]$errors)
        $errors.Count|Should Be 0
        $definition=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Test-InstalledMutationRuntimeBaseline'},$true))
        $definition.Count|Should Be 1
        Invoke-Expression $definition[0].Extent.Text
        (Test-InstalledMutationRuntimeBaseline -EngineEdition Desktop -PowerShellMajor 5 -DotNetMajor 4)|Should Be $false
        (Test-InstalledMutationRuntimeBaseline -EngineEdition Core -PowerShellMajor 6 -DotNetMajor 8)|Should Be $false
        (Test-InstalledMutationRuntimeBaseline -EngineEdition Core -PowerShellMajor 7 -DotNetMajor 7)|Should Be $false
        (Test-InstalledMutationRuntimeBaseline -EngineEdition Core -PowerShellMajor 7 -DotNetMajor 8)|Should Be $true
    }

    # Scenario: Runtime A is loaded by the updater before a verified candidate changes a fingerprinted platform source and its required pins.
    # Purpose: Install runtime B in the default candidate subprocess so a different native platform build never collides with runtime A in the updater process.
    It 'LaunchT13_installs_a_real_different_platform_runtime_build_in_the_candidate_subprocess' {
        $fixtureHome=Join-Path $script:ExternalTestRoot ('dpb-'+[Guid]::NewGuid().ToString('N'))
        Invoke-LauncherRecoveryInstaller -CodexHome $fixtureHome
        $candidateRoot=Join-Path $script:ExternalTestRoot ('different-platform-candidate-'+[Guid]::NewGuid().ToString('N'))
        $candidatePlatform=New-LauncherRecoveryPlatformCandidate -DestinationRoot $candidateRoot
        $candidateArchive=Join-Path $script:ExternalTestRoot ('different-platform-candidate-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $candidateArchiveSha256=New-LauncherRecoverySourceArchive -ArchivePath $candidateArchive -SourceRoot $candidateRoot
        $candidateCommit='b'*40
        $resultPath=Join-Path $script:ExternalTestRoot ('different-platform-result-'+[Guid]::NewGuid().ToString('N')+'.json')
        $probePath=Join-Path $script:ExternalTestRoot ('different-platform-probe-'+[Guid]::NewGuid().ToString('N')+'.ps1')
        [IO.File]::WriteAllText($probePath,@'
param(
    [Parameter(Mandatory=$true)][string]$CodexHome,
    [Parameter(Mandatory=$true)][string]$CandidateRoot,
    [Parameter(Mandatory=$true)][string]$CandidateArchive,
    [Parameter(Mandatory=$true)][string]$CandidateArchiveSha256,
    [Parameter(Mandatory=$true)][string]$CandidateCommit,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
Import-Module (Join-Path $CodexHome 'hooks/ai-instructions-runtime/ai-instructions-updater.psm1') -Force
$package=[pscustomobject]@{SourceRoot=$CandidateRoot;ArchivePath=$CandidateArchive;ArchiveSha256=$CandidateArchiveSha256}
$result=Invoke-AiInstructionsUpdateWorkflow -CodexHome $CodexHome -ForceCheck -InstallApproved `
    -ResolveCandidate { $CandidateCommit } -AcquireCandidate { $package }
[IO.File]::WriteAllText($ResultPath,(($result|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
'@,[Text.UTF8Encoding]::new($false))
        $probeStdout=Join-Path $script:ExternalTestRoot ('different-platform-probe-'+[Guid]::NewGuid().ToString('N')+'.stdout')
        $probeStderr=Join-Path $script:ExternalTestRoot ('different-platform-probe-'+[Guid]::NewGuid().ToString('N')+'.stderr')
        $probeArguments=@(
            '-NoProfile','-NonInteractive','-File',$probePath,
            '-CodexHome',$fixtureHome,'-CandidateRoot',$candidateRoot,'-CandidateArchive',$candidateArchive,
            '-CandidateArchiveSha256',$candidateArchiveSha256,'-CandidateCommit',$candidateCommit,'-ResultPath',$resultPath
        )
        $probeProcess=Start-Process -FilePath $script:PowerShellExecutable -ArgumentList $probeArguments -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $probeStdout -RedirectStandardError $probeStderr
        $probeExitCode=$probeProcess.ExitCode;$probeProcess.Dispose()
        if($probeExitCode-ne0){
            $probeOutput=(Get-Content -Raw -LiteralPath $probeStdout -ErrorAction SilentlyContinue)+(Get-Content -Raw -LiteralPath $probeStderr -ErrorAction SilentlyContinue)
            throw "Different-platform updater probe failed: $probeOutput"
        }
        $result=Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath|ConvertFrom-Json

        $runtimeRoot=Join-Path $fixtureHome 'hooks/ai-instructions-runtime'
        $activePlatformPath=Join-Path $runtimeRoot ([string]$candidatePlatform.RelativePath)
        $bundle=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json')|ConvertFrom-Json
        $receipt=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtureHome 'ai-instructions-update-receipt.json')|ConvertFrom-Json
        $result.outcome|Should Be installed
        [string]$bundle.commit|Should Be $candidateCommit
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($activePlatformPath))|Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes([string]$candidatePlatform.Path)))
        [string]$receipt.outcome|Should Be installed
        [string]$receipt.currentCommit|Should Be $script:SourceCommit
        [string]$receipt.candidateCommit|Should Be $candidateCommit
        [string]$receipt.archiveSha256|Should Be $candidateArchiveSha256
        @(Get-ChildItem -Force -LiteralPath (Join-Path $fixtureHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
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
            $runtimeRoot=Join-Path $fixtureHome 'hooks\ai-instructions-runtime'
            $bootstrapPath=Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'
            $bootstrapFixture=@'
param([string]$CatalogPath,[string]$LockPath,[string]$ConfigurationPath,[string]$UserHome,[string]$TargetRoot,[switch]$WhatIf)
$manifestRoot=Join-Path $TargetRoot '.codex'
New-Item -ItemType Directory -Force -Path $manifestRoot|Out-Null
[IO.File]::WriteAllText((Join-Path $manifestRoot 'ai-instructions.manifest.json'),"{}`n",[Text.UTF8Encoding]::new($false))
'@
            [IO.File]::WriteAllText($bootstrapPath,$bootstrapFixture,[Text.UTF8Encoding]::new($false))
            $bundle=New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ([string]$configuration.catalog.ref) -Acquisition git-checkout
            [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime-bundle.json'),(($bundle|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n"),[Text.UTF8Encoding]::new($false))
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
}
