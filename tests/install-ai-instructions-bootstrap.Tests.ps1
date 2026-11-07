$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:InstalledBootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-installed.ps1'
$script:TestPowerShellExecutable = (Get-Process -Id $PID).Path
Import-Module (Join-Path $PSScriptRoot '..\scripts\ai-instructions-runtime-contract.psm1') -Force

function New-InstallerSourceArchive {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [switch] $Unrelated
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $ArchivePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $stream = [System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            if ($Unrelated) {
                $entry = $archive.CreateEntry('unrelated-root/README.md')
                $writer = New-Object System.IO.StreamWriter($entry.Open(),(New-Object System.Text.UTF8Encoding($false)))
                try { $writer.Write("# Unrelated archive fixture`n") }
                finally { $writer.Dispose() }
            }
            else {
                $sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
                $sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $sourceRootPath 'scripts'),(Join-Path $sourceRootPath 'catalog') -Recurse -File)
                $sourceFiles += @(Get-ChildItem -LiteralPath $sourceRootPath -File | Where-Object { $_.Name -in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json') })
                foreach ($file in @($sourceFiles | Sort-Object FullName)) {
                    $relativePath = $file.FullName.Substring($sourceRootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                    $entry = $archive.CreateEntry("candidate-root/$relativePath")
                    $input = [System.IO.File]::OpenRead($file.FullName)
                    $output = $entry.Open()
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose(); $input.Dispose() }
                }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    return (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-InstallScript {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [string[]] $ExcludedRepositoryUrls = @(),
        [string[]] $ExcludedRepositoryPaths = @()
    )

    $sourceCommit = (@(& git -C $RepositoryRoot rev-parse HEAD) -join '').Trim()
    $archivePath = Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome) + '-source.zip')
    $archiveSha256 = New-InstallerSourceArchive -SourceRoot $RepositoryRoot -ArchivePath $archivePath
    $arguments = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,
        '-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome,
        '-Acquisition','github-codeload',
        '-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
        '-SourceCommit',$sourceCommit,
        '-ArchiveSha256',$archiveSha256,
        '-SourceArchivePath',$archivePath
    )
    if ($ExcludedRepositoryUrls.Count -gt 0) {
        $arguments += '-ExcludedRepositoryUrls'
        foreach ($repositoryUrl in $ExcludedRepositoryUrls) { $arguments += $repositoryUrl }
    }
    if ($ExcludedRepositoryPaths.Count -gt 0) {
        $arguments += '-ExcludedRepositoryPaths'
        foreach ($repositoryPath in $ExcludedRepositoryPaths) { $arguments += $repositoryPath }
    }

    $output = & $script:TestPowerShellExecutable @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Install script failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-InstallExpectFailure {
    param(
        [string]$RepositoryRoot,
        [string]$CodexHome,
        [switch]$GitCheckout,
        [switch]$InvalidArchiveHash,
        [switch]$UnrelatedArchive,
        [string]$ExpectedCurrentCommit,
        [string]$ExpectedUpdateMode,
        [string]$ExpectedUpdateChannel,
        [string]$ExpectedUpdateRef
    )
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome)
    if (-not $GitCheckout) {
        $sourceCommit = (@(& git -C $RepositoryRoot rev-parse HEAD) -join '').Trim()
        $archivePath = Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome) + '-source.zip')
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $RepositoryRoot -ArchivePath $archivePath -Unrelated:$UnrelatedArchive
        if ($InvalidArchiveHash) { $archiveSha256 = ('0' * 64) }
        $arguments += @(
            '-Acquisition','github-codeload',
            '-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-SourceArchivePath',$archivePath
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit)) { $arguments += @('-ExpectedCurrentCommit',$ExpectedCurrentCommit) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateMode)) { $arguments += @('-ExpectedUpdateMode',$ExpectedUpdateMode) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateChannel)) { $arguments += @('-ExpectedUpdateChannel',$ExpectedUpdateChannel) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateRef)) { $arguments += @('-ExpectedUpdateRef',$ExpectedUpdateRef) }
    $output = & $script:TestPowerShellExecutable @arguments 2>&1
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($output -join [Environment]::NewLine) }
}

function Set-TestText {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-TestJson {
    param([string]$Path,[object]$Document)
    Set-TestText -Path $Path -Value (($Document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
}

function Invoke-TestAgentEnvironmentEntryWithExclusiveLockProbe {
    param(
        [Parameter(Mandatory=$true)][string]$EntryPath,
        [Parameter(Mandatory=$true)][string]$CodexHome,
        [Parameter(Mandatory=$true)][string]$UserHome,
        [Parameter(Mandatory=$true)][string]$InstallLockPath
    )
    $powershell=[PowerShell]::Create()
    try {
        [void]$powershell.AddCommand($EntryPath).AddParameter('CodexHome',$CodexHome).AddParameter('UserHome',$UserHome).AddParameter('Apply').AddParameter('OutputFormat','Json')
        $entryOutput=@($powershell.Invoke()|ForEach-Object{[string]$_})
        $entryHadErrors=$powershell.HadErrors
        $powershell.Commands.Clear()
        $escapedInstallLockPath=$InstallLockPath.Replace("'","''")
        [void]$powershell.AddScript(@"
`$exclusive=`$null
try {
    `$exclusive=[IO.File]::Open('$escapedInstallLockPath',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    'exclusive-acquired'
}
finally { if (`$null-ne`$exclusive) { `$exclusive.Dispose() } }
"@)
        $exclusiveOutput=@($powershell.Invoke()|ForEach-Object{[string]$_})
        return [pscustomobject]@{EntryOutput=$entryOutput;EntryHadErrors=$entryHadErrors;ExclusiveOutput=$exclusiveOutput;ProbeHadErrors=$powershell.HadErrors}
    }
    finally{$powershell.Dispose()}
}

function Remove-TestAnsiControlSequence {
    param([AllowEmptyString()][string]$Text)
    $textWithoutAnsi = $Text -replace '\x1b\[[0-?]*[ -/]*[@-~]',''
    $textWithoutAnsi = $textWithoutAnsi -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)',''
    return ($textWithoutAnsi -replace '\x1b','')
}

function ConvertTo-TestComparableText {
    param([AllowEmptyString()][string]$Text)
    return ((Remove-TestAnsiControlSequence $Text) -replace '\s','')
}

function New-InstallerFailpointCandidate {
    param([Parameter(Mandatory = $true)][string]$SourceRoot,[Parameter(Mandatory = $true)][string]$DestinationRoot)
    New-Item -ItemType Directory -Force -Path $DestinationRoot|Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts'),(Join-Path $SourceRoot 'catalog') -Destination $DestinationRoot -Recurse
    foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
        Copy-Item -LiteralPath (Join-Path $SourceRoot $leaf) -Destination (Join-Path $DestinationRoot $leaf)
    }
    foreach($relative in @('bootstrap-ai-instructions-installed.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1','safe-zip.psm1')){
        [IO.File]::AppendAllText((Join-Path $DestinationRoot "scripts\$relative"),"`n# failpoint candidate: $relative`n",[Text.UTF8Encoding]::new($false))
    }
}

function Get-InstallerStateSnapshot {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot,[Parameter(Mandatory = $true)][string]$CodexHome)
    Import-Module (Join-Path $RepositoryRoot 'scripts\platform-runtime.psd1') -Force
    Import-Module (Join-Path $RepositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force
    $missingFile=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null}
    $missingDirectory=[pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null;permissions=$null}
    $states=[ordered]@{}
    foreach($leaf in @('bootstrap-ai-instructions.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1')){$states["hooks/$leaf"]=$missingFile}
    $states['hooks/ai-instructions-runtime']=$missingDirectory
    foreach($leaf in @('ai-instructions-sync.json','AGENTS.md','hooks.json')){$states[$leaf]=$missingFile}
    if(-not(Test-Path -LiteralPath $CodexHome -PathType Container)){return ($states|ConvertTo-Json -Depth 20 -Compress)}
    $root=Open-PlatformDirectory -Root $CodexHome -RootOnly
    $hooks=$null
    try{
        foreach($leaf in @('ai-instructions-sync.json','AGENTS.md','hooks.json')){
            $states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $root -Leaf $leaf -LiteralPath (Join-Path $CodexHome $leaf) -PlatformOs windows
        }
        if(Test-Path -LiteralPath (Join-Path $CodexHome 'hooks') -PathType Container){
            $hooks=Open-PlatformDirectory -Root $CodexHome -RelativePath hooks
            foreach($leaf in @('bootstrap-ai-instructions.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1')){
                $states["hooks/$leaf"]=Get-AiInstructionsInstallFileState -ParentLease $hooks -Leaf $leaf -LiteralPath (Join-Path $CodexHome "hooks\$leaf") -PlatformOs windows
            }
            $states['hooks/ai-instructions-runtime']=Get-AiInstructionsInstallDirectoryState -ParentLease $hooks -Leaf ai-instructions-runtime -LiteralPath (Join-Path $CodexHome 'hooks\ai-instructions-runtime')
        }
    }
    finally{if($null-ne$hooks){$hooks.Dispose()};$root.Dispose()}
    return ($states|ConvertTo-Json -Depth 20 -Compress)
}

function Get-InstallerAppliedSnapshotFromTransaction {
    param([Parameter(Mandatory = $true)][string]$CodexHome,[Parameter(Mandatory = $true)][string]$OriginalSnapshot)
    $store=Join-Path $CodexHome '.ai-instructions-txn'
    $transactions=@(Get-ChildItem -LiteralPath $store -Directory -Force -ErrorAction SilentlyContinue)
    if($transactions.Count-ne1){return $null}
    $journal=$null
    foreach($leaf in @('journal.json','journal.prev','journal.stage')){
        $path=Join-Path $transactions[0].FullName $leaf
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try{$journal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $path) -ExpectedTransactionId $transactions[0].Name;break}catch{}
    }
    if($null-eq$journal){return $null}
    $snapshot=$OriginalSnapshot|ConvertFrom-Json
    foreach($operation in @($journal.operations)){
        $key=[string]$operation.targetRelativePath
        if([string]$operation.kind -in @('swap-directory','create-directory')){
            $value=[pscustomobject][ordered]@{exists=[bool]$operation.applied.exists;identity=$operation.applied.identity;inventorySha256=$operation.applied.inventorySha256;entryCount=$operation.applied.entryCount;permissions=$null}
        }
        else{
            $value=[pscustomobject][ordered]@{exists=[bool]$operation.applied.exists;sha256=$operation.applied.sha256;length=$operation.applied.length;identity=$operation.applied.identity;permissions=$null}
        }
        $snapshot.PSObject.Properties[$key].Value=$value
    }
    return ($snapshot|ConvertTo-Json -Depth 20 -Compress)
}

function Get-InstallerTransactionRecoveryState {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot,[Parameter(Mandatory = $true)][string]$CodexHome)
    $store=Join-Path $CodexHome '.ai-instructions-txn'
    $transactions=@(Get-ChildItem -LiteralPath $store -Force -ErrorAction SilentlyContinue)
    if($transactions.Count-eq0){return [pscustomobject]@{RecoveryAction='no-transaction';JournalPhase=$null;Journal=$null;TransactionPath=$null}}
    if($transactions.Count-ne1){throw "Expected one installer transaction, found $($transactions.Count)."}
    $entry=$transactions[0]
    $entryKind=if($entry.PSIsContainer -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){'directory'}else{'other'}
    $readJournalEntry={param($Leaf)
        $path=Join-Path $entry.FullName $Leaf
        if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Kind=$null;Json=$null}}
        $item=Get-Item -Force -LiteralPath $path
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return [pscustomobject]@{Kind='other';Json=$null}}
        return [pscustomobject]@{Kind='file';Json=(Get-Content -Raw -Encoding UTF8 -LiteralPath $path)}
    }
    $journal=&$readJournalEntry 'journal.json'
    $previous=&$readJournalEntry 'journal.prev'
    $classification=Get-AiInstructionsInstallTransactionClassification -Name $entry.Name -EntryKind $entryKind -JournalEntryKind $journal.Kind -JournalJson $journal.Json -PreviousJournalEntryKind $previous.Kind -PreviousJournalJson $previous.Json
    $disposition=Get-AiInstructionsInstallTransactionDisposition -Classification ([string]$classification.classification) -Component installer
    if([string]$disposition.action-cne'recover'){
        return [pscustomobject]@{RecoveryAction=[string]$disposition.action;JournalPhase=$null;Journal=$classification.journal;TransactionPath=$entry.FullName}
    }
    Import-Module (Join-Path $RepositoryRoot 'scripts\platform-runtime.psd1') -Force
    Import-Module (Join-Path $RepositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force
    $transactionLease=Open-PlatformDirectory -Root $CodexHome -RelativePath ('.ai-instructions-txn/'+$entry.Name)
    try{
        $observations=Get-AiInstructionsInstallRecoveryObservations -Journal $classification.journal -CodexHome $CodexHome -TransactionLease $transactionLease -TransactionPath $entry.FullName
        $decision=Get-AiInstructionsInstallRecoveryDecision -Journal $classification.journal -Observations $observations
        return [pscustomobject]@{RecoveryAction=[string]$decision.action;JournalPhase=[string]$classification.journal.phase;Journal=$classification.journal;TransactionPath=$entry.FullName}
    }
    finally{$transactionLease.Dispose()}
}

function Invoke-InstallerRecoveryMutationProbe {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerScript,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$MutationPath,
        [Parameter(Mandatory = $true)][string]$ExternalText,
        [Parameter(Mandatory = $true)][bool]$ExternalReadOnly,
        [Parameter(Mandatory = $true)][string]$ProbeRoot
    )
    $wrapperPath=Join-Path $ProbeRoot ('recovery-mutation-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    $resultPath=Join-Path $ProbeRoot ('recovery-mutation-'+[Guid]::NewGuid().ToString('N')+'.txt')
    Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string]$InstallerScript,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ArchiveSha256,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$MutationPath,
    [Parameter(Mandatory = $true)][string]$ExternalText,
    [Parameter(Mandatory = $true)][int]$ExternalReadOnlyFlag,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
$recoveryLine=@(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallRecoveryPlan -Journal \$record\.Classification\.journal' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if($recoveryLine.Count-ne1){throw 'Could not locate the installer recovery mutation boundary.'}
$global:RecoveryMutationPath=$MutationPath
$global:RecoveryMutationText=$ExternalText
$global:RecoveryMutationReadOnly=($ExternalReadOnlyFlag-ne0)
$breakpoint=Set-PSBreakpoint -Script $InstallerScript -Line $recoveryLine[0] -Action {
    if(Test-Path -LiteralPath $global:RecoveryMutationPath -PathType Leaf){
        (Get-Item -Force -LiteralPath $global:RecoveryMutationPath).IsReadOnly=$false
        [IO.File]::Delete($global:RecoveryMutationPath)
    }
    [IO.File]::WriteAllText($global:RecoveryMutationPath,$global:RecoveryMutationText,[Text.UTF8Encoding]::new($false))
    (Get-Item -Force -LiteralPath $global:RecoveryMutationPath).IsReadOnly=$global:RecoveryMutationReadOnly
}
try{
    try{
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath|Out-Null
        $exitCode=0;$message='';$inner=''
    }
    catch{
        $exitCode=1;$message=$_.Exception.Message
        $inner=if($null-ne$_.Exception.InnerException){$_.Exception.InnerException.Message}else{''}
    }
}
finally{
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable RecoveryMutationPath,RecoveryMutationText,RecoveryMutationReadOnly -Scope Global -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText($ResultPath,(@($exitCode,$message,$inner)-join"`n"),[Text.UTF8Encoding]::new($false))
'@
    $arguments=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
        '-InstallerScript',$InstallerScript,'-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome,
        '-SourceCommit',$SourceCommit,'-ArchiveSha256',$ArchiveSha256,'-ArchivePath',$ArchivePath,
        '-MutationPath',$MutationPath,'-ExternalText',$ExternalText,
        '-ExternalReadOnlyFlag',$(if($ExternalReadOnly){'1'}else{'0'}),'-ResultPath',$resultPath
    )
    $output=& $script:TestPowerShellExecutable @arguments 2>&1
    if($LASTEXITCODE-ne0){throw "Recovery mutation probe failed: $($output-join[Environment]::NewLine)"}
    return Get-Content -Raw -LiteralPath $resultPath
}

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    # Register installation-success and journal-recovery cases only on the native
    # host because directory-publication is intentionally unavailable on Unix.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: An exact source archive supplies its licensing declarations alongside the runtime.
    # Purpose: Bind installed license bytes to the bundle inventory and immutable source commit.
    It 'InterT04_inventories_runtime_licenses_from_the_verified_source_archive' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome | Out-Null
        $runtime = Join-Path $codexHome 'hooks/ai-instructions-runtime'
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtime 'runtime-bundle.json') | ConvertFrom-Json
        $license = Join-Path $runtime 'licenses/source/LICENSE'
        (Get-FileHash -LiteralPath $license).Hash | Should Be ((Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'LICENSE')).Hash)
        $receipt = Get-Content -Raw -LiteralPath (Join-Path $runtime 'licenses/delivery.json') | ConvertFrom-Json
        $receipt.sourceCommit | Should Be $bundle.commit
        @($bundle.inventory | Where-Object path -like 'licenses/*').Count | Should Be 7
    }

    # Scenario: A clean Codex Home installs the verified multi-source runtime for the first time.
    # Purpose: Materialize all stable commands and runtime files without restoring SessionStart execution.
    It 'InterT05_installs_the_multi_source_runtime_without_creating_a_SessionStart_hook' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Test-Path -LiteralPath $installedHookScript | Should Be $true
        (Get-Content -Raw -LiteralPath $installedHookScript) | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)

        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        foreach ($relativePath in @(
            'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
            'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'ai-instructions-runtime-contract.psm1','WindowsDacl.psm1','agent-artifact-remediation.psm1','repo-shared-skills-migration.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'ai-instructions-updater.psm1','update-ai-instructions.ps1','agent-environment-reconciler.psm1','update-agent-environment.ps1',
            'cleanup-ai-instructions-pollution.ps1','ai-instructions-install-transaction.psm1',
            'platform-runtime.psd1','platform-runtime.psm1','installer-safe-mutation.psm1','Resolve-StandardValidationTool.ps1',
            'platform\PlatformNative.cs','platform\UnixNative.cs','platform\WindowsNative.cs','platform\WindowsInstallerMutation.cs',
            'platform\OwnedProcess.cs','platform\UnixProcess.cs','platform\WindowsProcess.cs','platform\Unix.psm1',
            'platform\RuntimePreparation.psm1','platform\Windows.psm1','platform\Linux.psm1','platform\MacOS.psm1',
            'runtime-bundle.json','catalog\skills-catalog.json','catalog\skills-catalog-lock.json'
        )) {
            Test-Path -LiteralPath (Join-Path $runtimeRoot $relativePath) | Should Be $true
        }
        $installedPlatformRuntime=Import-Module (Join-Path $runtimeRoot 'platform-runtime.psd1') -Force -PassThru
        & $installedPlatformRuntime {param($root)Assert-PlatformRuntimeInventory -Root $root -ManifestPath (Join-Path $root 'platform-runtime.psd1')|Out-Null} $runtimeRoot
        $platformRuntimeManifest=Import-PowerShellDataFile -LiteralPath (Join-Path $runtimeRoot 'platform-runtime.psd1')
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $bundlePaths=@($bundle.inventory|ForEach-Object{[string]$_.path})
        foreach($declaredPath in @($platformRuntimeManifest.FileList)){
            $normalizedPath=([string]$declaredPath).Replace('\','/')
            Test-Path -LiteralPath (Join-Path $runtimeRoot ([string]$declaredPath)) -PathType Leaf|Should Be $true
            $bundlePaths|Should Contain $normalizedPath
        }
        $installedReconciler=Import-Module (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force -PassThru
        {& $installedReconciler {param($root)Import-AgentEnvironmentRuntimeModules -RuntimeRoot $root} $runtimeRoot}|Should Not Throw

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 4
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryUrls') | Should Be $false
        @($configuration.excludedRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryPaths).Count | Should Be 0
        [string]$configuration.catalog.repository | Should Match '^https://github\.com/.+/.+\.git$'
        [string]$configuration.catalog.ref | Should Match '^[0-9a-f]{40}$'
        [string]$bundle.repository | Should Be ([string]$configuration.catalog.repository)
        [string]$bundle.commit | Should Be ([string]$configuration.catalog.ref)
        $bundle.schemaVersion | Should Be 2
        [string]$bundle.acquisition | Should Be 'github-codeload'
        [string]$bundle.archiveSha256 | Should Match '^[0-9a-f]{64}$'
        [string]$bundle.inventorySha256 | Should Match '^[0-9a-f]{64}$'
        @($bundle.inventory).Count | Should BeGreaterThan 10
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'agent-artifact-remediation.psm1' }).Count | Should Be 1
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'ai-instructions-rollout.psm1' }).Count | Should Be 1
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'invoke-ai-instructions-rollout.ps1' }).Count | Should Be 1
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0
        [string]$configuration.updates.mode | Should Be 'notify-only'
        [string]$configuration.updates.channel | Should Be 'protected-branch'
        [string]$configuration.updates.ref | Should Be 'main'
        [int]$configuration.updates.minimumCheckIntervalMinutes | Should Be 1440
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\update-agent-environment.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1') | Should Be $true

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'production code'
        $agents | Should Match '問問題'
        $agents | Should Match 'reserved Agent artifact'
        $agents | Should Match 'remediation commit'
        $agents | Should Match '不得自動 push'
        $agents | Should Not Match 'fail closed.*污染路徑'
        $agents | Should Not Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'
        $agents | Should Match '目前 Codex Home'
        $agents | Should Not Match ([regex]::Escape('~/.codex/ai-instructions-sync.json'))
        $agents | Should Match 'Agent Skills'
        $agents | Should Match 'customized or unmanaged Instructions or Agent Skills'
        $agents | Should Match '所有 branch 共用的個人 runtime artifacts'
        $agents | Should Match '只包含精確 reserved path deletions 的一次性本機 remediation commit'
        $agents | Should Match '沙箱或權限拒絕'
        $agents | Should Match '核准後重試一次'
        $agents | Should Match 'compatibility、configuration 或 integrity'
        $agents | Should Match '不得重試'
        $agents | Should Match 'notify-only.*available.*未安裝'
        $agents | Should Match '不得偽造 capability evidence'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json') | Should Be $false
    }

    # Scenario: Codex uses its default home because CODEX_HOME is not set when an Agent follows the installed bootstrap instruction.
    # Purpose: Keep the generated instruction executable for the installer's supported $HOME/.codex fallback instead of resolving a root-level hooks path.
    It 'InterT07_installed_bootstrap_instruction_supports_the_default_Codex_Home' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match ([regex]::Escape("[string]::IsNullOrWhiteSpace(`$env:CODEX_HOME)"))
        $agents | Should Match ([regex]::Escape("Join-Path `$HOME '.codex'"))
        $agents | Should Match ([regex]::Escape("Join-Path `$codexHome 'hooks\bootstrap-ai-instructions.ps1'"))
        $agents | Should Not Match ([regex]::Escape('$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1'))
    }

    # Scenario: A prior installation left an outdated stable bootstrap launcher.
    # Purpose: Replace installer-owned launcher bytes with the verified candidate version.
    It 'InterT15_overwrites_a_stale_bootstrap_hook_with_the_installed_launcher' {
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestText -Path $installedHookScript -Value "git stash push --include-untracked --quiet -m PersonalAgent -- AGENTS.md`n"
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $installedHook = Get-Content -Raw -LiteralPath $installedHookScript
        $installedHook | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)
        $installedHook | Should Match 'runtime-bundle\.json'
        $installedHook | Should Not Match "'stash', 'push', '--include-untracked'"
    }

    # Scenario: Codex Home contains personal Agent content and unrelated hooks beside a legacy bootstrap SessionStart entry.
    # Purpose: Remove only installer-owned legacy activation while preserving independent user configuration.
    It 'InterT20_preserves_personal_content_and_unrelated_hooks_while_removing_bootstrap_SessionStart' {
        Set-TestText -Path (Join-Path $codexHome 'AGENTS.md') -Value @'
# Personal Codex Rules

Keep this personal note.

## Repository Instructions Bootstrap

old bootstrap text

## Other Rules

Keep this section too.
'@
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @(
                    [ordered]@{matcher='startup';hooks=@([ordered]@{type='command';command="powershell.exe -File `"$installedBootstrapHook`""})},
                    [ordered]@{matcher='other';hooks=@([ordered]@{type='command';command='powershell.exe -File "C:\keep\other.ps1"'})}
                )
                Stop = @([ordered]@{matcher='keep-stop';hooks=@()})
            }
        })
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Keep this personal note'
        $agents | Should Match 'Keep this section too'
        $agents | Should Not Match 'old bootstrap text'
        ([regex]::Matches($agents, 'Repository Instructions Bootstrap')).Count | Should Be 1
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart | Where-Object { @($_.hooks | Where-Object { $_.command -match 'bootstrap-ai-instructions\.ps1' }).Count -gt 0 }).Count | Should Be 0
        @($hooks.hooks.Stop).Count | Should Be 1
    }

    # Scenario: One SessionStart entry contains both the obsolete bootstrap command and an unrelated personal command.
    # Purpose: Remove only the obsolete hook instead of deleting the user's unrelated hook from the same entry.
    It 'InterT22_preserves_unrelated_hooks_inside_a_mixed_SessionStart_entry' {
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @([ordered]@{
                    matcher = 'startup'
                    hooks = @(
                        [ordered]@{type='command';command="powershell.exe -File `"$installedBootstrapHook`""},
                        [ordered]@{type='command';command='powershell.exe -File "C:\keep\personal-startup.ps1"'}
                    )
                })
            }
        })

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart[0].hooks).Count | Should Be 1
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Match 'personal-startup\.ps1'
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Not Match 'bootstrap-ai-instructions\.ps1'
    }

    # Scenario: A personal SessionStart command invokes a different script that happens to use the bootstrap filename.
    # Purpose: Require installer ownership evidence before deleting a user hook with a colliding basename.
    It 'InterT24_preserves_a_same_named_SessionStart_hook_outside_the_installed_path' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {"matcher":"personal","hooks":[{"type":"command","command":"powershell.exe -File \"C:\\personal-tools\\bootstrap-ai-instructions.ps1\""}]}
    ]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Match 'C:\\personal-tools\\bootstrap-ai-instructions\.ps1'
    }

    # Scenario: SessionStart contains only the obsolete bootstrap command.
    # Purpose: Remove the now-empty hook category instead of leaving background bootstrap behavior.
    It 'InterT25_removes_SessionStart_when_the_legacy_bootstrap_is_its_only_entry' {
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @([ordered]@{
                    matcher = 'startup'
                    hooks = @([ordered]@{type='command';commandWindows="powershell.exe -File `"$installedBootstrapHook`""})
                })
            }
        })
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        ($hooks.hooks.PSObject.Properties.Name -contains 'SessionStart') | Should Be $false
    }

    # Scenario: Installer encounters a legacy configuration with obsolete routing and auto-commit properties.
    # Purpose: Preserve exclusions while producing strict schema v4 with no commit authority.
    It 'InterT30_migrates_legacy_configuration_to_schema_version_4_without_auto_commit_state' {
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 1,
  "autoCommitRepositoryUrls": ["git@example.com:team/old-project.git"],
  "autoCommitRepositoryPaths": ["C:\\Local\\Project"],
  "repositoryUrls": ["https://example.com/team/second-project.git"],
  "excludedRepositoryUrls": ["git@example.com:team/planning-only.git"],
  "excludedRepositoryPaths": ["docs/architecture-planning"]
}
'@
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome `
            -ExcludedRepositoryUrls @('https://example.com/team/architecture-only.git') `
            -ExcludedRepositoryPaths @('design/planning-only')

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 4
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryUrls') | Should Be $false
        ($configuration.PSObject.Properties.Name -contains 'repositoryUrls') | Should Be $false
        @($configuration.excludedRepositoryUrls).Count | Should Be 2
        @($configuration.excludedRepositoryPaths).Count | Should Be 2
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryPaths') | Should Be $false
        @($configuration.catalog.profiles) | Should Be @('core')
        $configuration.updates.mode | Should Be 'notify-only'
    }

    # Scenario: A valid schema-v4 installation is refreshed to a newer canonical bundle commit.
    # Purpose: Advance the immutable pin while preserving the user's Skill selection and update policy.
    It 'InterT35_preserves_schema_v4_selections_and_update_policy_while_advancing_the_same_bundle_pin' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        $configuration.catalog.profiles = @('observability')
        $configuration.catalog.includeSkills = @('work-with-jira')
        $configuration.catalog.excludeSkills = @('search-with-felo')
        $configuration.updates.mode = 'auto-install-approved'
        $configuration.updates.minimumCheckIntervalMinutes = 60
        Set-TestJson -Path $configurationPath -Document $configuration

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $updated = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $expectedHead = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        [string]$updated.catalog.ref | Should Be $expectedHead
        @($updated.catalog.profiles) | Should Be @('observability')
        @($updated.catalog.includeSkills) | Should Be @('work-with-jira')
        @($updated.catalog.excludeSkills) | Should Be @('search-with-felo')
        [string]$updated.updates.mode | Should Be 'auto-install-approved'
        [int]$updated.updates.minimumCheckIntervalMinutes | Should Be 60
    }

    # Scenario: An existing v4 configuration repeats a Skill already selected by its active profile.
    # Purpose: Normalize the legacy overlap during installation so profile compatibility remains soft in every Codex Home.
    It 'InterT36_normalizes_redundant_profile_and_includeSkills_selection_during_installation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.profiles = @('atlassian')
        $configuration.catalog.includeSkills = @('work-with-jira','plan-production-change')
        Set-TestJson -Path $configurationPath -Document $configuration

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $updated = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        @($updated.catalog.profiles) | Should Be @('atlassian')
        @($updated.catalog.includeSkills) | Should Be @('plan-production-change')
    }

    # Scenario: An existing schema-v4 configuration was manually changed to a mutable Catalog ref.
    # Purpose: Fail before installation mutation rather than normalizing an untrusted bundle identity.
    It 'InterT37_rejects_a_mutable_schema_v4_bundle_ref_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = 'main'
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $hookBefore = Get-Content -Raw -LiteralPath $hookPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'catalog.ref must be a full lowercase 40-character commit SHA'
        (Get-Content -Raw -LiteralPath $hookPath) | Should Be $hookBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: Existing personal configuration declares a future schema unknown to this installer.
    # Purpose: Fail closed before replacing any active runtime or configuration bytes.
    It 'InterT40_rejects_unknown_configuration_schema_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value '{"schemaVersion":99,"excludedRepositoryUrls":[],"excludedRepositoryPaths":[]}'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Unsupported AI instruction sync configuration schemaVersion'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: The active configuration already uses projection-aware schema v5.
    # Purpose: Keep the legacy installer from downgrading or replacing active bytes.
    It 'InterT41_rejects_sync_v5_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.schemaVersion = 5
        $configuration | Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{user=@('user-agents');project=@()})
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = [IO.File]::ReadAllBytes($configurationPath)
        $bundleBefore = [IO.File]::ReadAllBytes($bundlePath)
        $hookBefore = [IO.File]::ReadAllBytes($hookPath)

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'AI Instructions sync configuration schema version 5 requires a projection-aware installer\.'
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be unsupported-version
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($hookPath)) | Should Be ([Convert]::ToBase64String($hookBefore))
    }

    # Scenario: The stable launcher sees sync configuration v5.
    # Purpose: Fail before bootstrap can update, recover, or mutate consumer bytes.
    It 'InterT39_rejects_sync_v5_in_the_launcher_before_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $launcherPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.schemaVersion = 5
        $configuration | Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{user=@('user-agents');project=@()})
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = [IO.File]::ReadAllBytes($configurationPath)
        $bundleBefore = [IO.File]::ReadAllBytes($bundlePath)
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $launcherPath -ValidateOnly -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'AI Instructions sync configuration schema version 5 requires a projection-aware installer\.'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
    }

    # Scenario: An existing schema-v4 configuration points at a noncanonical bundle repository.
    # Purpose: Preserve the single canonical trust boundary before any active runtime replacement.
    It 'InterT42_rejects_a_schema_v4_bundle_repository_from_another_repo' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.repository = 'https://github.com/example/other-ai-instructions.git'
        Set-TestJson -Path $configurationPath -Document $configuration
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'accepts only the canonical repository'
    }

    # Scenario: A supplied codeload archive does not match its declared immutable SHA-256.
    # Purpose: Reject altered download bytes before any Codex Home mutation.
    It 'InterT43_rejects_a_codeload_archive_hash_mismatch_before_mutating_CodexHome' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -InvalidArchiveHash

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match '(?s)SourceArchivePath SHA-256.*does\s+not\s+match'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: A caller pairs a valid canonical commit and archive hash with an unrelated local RepositoryRoot.
    # Purpose: Bind github-codeload provenance to the archive bytes that actually supply the installed runtime.
    It 'InterT44_rejects_a_codeload_archive_that_does_not_supply_the_runtime_sources' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -UnrelatedArchive

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'archive.*runtime source|runtime source.*archive'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: Git-checkout installation sources differ from their immutable HEAD commit.
    # Purpose: Materialize the runtime directly from immutable Git objects so mutable worktree bytes never execute or install.
    It 'InterT45_installs_immutable_HEAD_sources_when_the_worktree_is_dirty' {
        $cloneRoot = Join-Path $TestDrive 'dirty-source'
        $origin = (@(& git -C $repositoryRoot remote get-url origin) -join '').Trim()
        & git clone --quiet $repositoryRoot $cloneRoot
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create installer source clone.' }
        & git -C $cloneRoot remote set-url origin $origin
        if ($LASTEXITCODE -ne 0) { throw 'Failed to reset installer source clone origin.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1') -Destination (Join-Path $cloneRoot 'scripts\install-ai-instructions-bootstrap.ps1') -Force
        $platformManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1')
        foreach ($fileName in @(@(
            'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1',
            'safe-zip.psm1','skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'ai-instructions-runtime-contract.psm1','WindowsDacl.psm1','agent-artifact-remediation.psm1','repo-shared-skills-migration.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'ai-instructions-updater.psm1','update-ai-instructions.ps1','agent-environment-reconciler.psm1','update-agent-environment.ps1',
            'cleanup-ai-instructions-pollution.ps1','license-delivery.psm1','ai-instructions-install-transaction.psm1'
        ) + @($platformManifest.FileList) | Sort-Object -Unique)) {
            $destination = Join-Path $cloneRoot "scripts\$fileName"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licensing-scope.json') -Destination (Join-Path $cloneRoot 'licensing-scope.json') -Force
        & git -C $cloneRoot add -- scripts licensing-scope.json
        & git -C $cloneRoot -c user.name='Installer Test' -c user.email='installer@example.test' commit --quiet --allow-empty -m 'installer fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to commit installer source fixture.' }
        $executionEvidence = Join-Path $TestDrive 'dirty-contract-executed.txt'
        $licenseExecutionEvidence = Join-Path $TestDrive 'dirty-license-module-executed.txt'
        [IO.File]::AppendAllText((Join-Path $cloneRoot 'scripts/license-delivery.psm1'), "`n[IO.File]::WriteAllText('$licenseExecutionEvidence','executed')`n")
        $committedRuntimeSource = [System.IO.File]::ReadAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n")
        [System.IO.File]::AppendAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1'),
            "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n"
        )
        $committedLicense = [IO.File]::ReadAllText((Join-Path $cloneRoot 'LICENSE')).Replace("`r`n","`n")
        Set-TestText -Path (Join-Path $cloneRoot 'LICENSE') -Value 'Dirty working tree license must not install'

        $savedInstallScript = $script:InstallScript
        try {
            $script:InstallScript = Join-Path $cloneRoot 'scripts/install-ai-instructions-bootstrap.ps1'
            $result = Invoke-InstallExpectFailure -RepositoryRoot $cloneRoot -CodexHome $codexHome -GitCheckout
        }
        finally { $script:InstallScript = $savedInstallScript }
        $result.ExitCode | Should Be 0
        Test-Path -LiteralPath $executionEvidence | Should Be $false
        Test-Path -LiteralPath $licenseExecutionEvidence | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $true
        [System.IO.File]::ReadAllText(
            (Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n") | Should Be $committedRuntimeSource
        [IO.File]::ReadAllText((Join-Path $codexHome 'hooks/ai-instructions-runtime/licenses/source/LICENSE')).Replace("`r`n","`n") | Should Be $committedLicense
    }

    # Scenario: A malformed codeload candidate fails during staged PowerShell validation.
    # Purpose: Remove the pre-journal transaction directory when failure occurs before active runtime mutation.
    It 'InterT46_cleans_transaction_directories_after_staging_validation_failure' {
        $invalidSource = Join-Path $TestDrive 'invalid-staging-source'
        & git clone --quiet $repositoryRoot $invalidSource
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create invalid staging source clone.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\installer-safe-mutation.psm1') `
            -Destination (Join-Path $invalidSource 'scripts\installer-safe-mutation.psm1') -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\platform\WindowsInstallerMutation.cs') `
            -Destination (Join-Path $invalidSource 'scripts\platform\WindowsInstallerMutation.cs') -Force
        $platformManifest=Import-PowerShellDataFile -LiteralPath (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1')
        foreach ($fileName in @(@(
            'agent-artifact-remediation.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'agent-environment-reconciler.psm1','update-agent-environment.ps1','license-delivery.psm1',
            'ai-instructions-runtime-contract.psm1','ai-instructions-install-transaction.psm1'
        )+@($platformManifest.FileList)|Sort-Object -Unique)) {
            $destination=Join-Path $invalidSource "scripts\$fileName"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination)|Out-Null
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") `
                -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licensing-scope.json') -Destination (Join-Path $invalidSource 'licensing-scope.json') -Force
        [System.IO.File]::AppendAllText((Join-Path $invalidSource 'scripts\skills-selection.psm1'), "`nfunction Invalid-StagingFixture {`n")

        $result = Invoke-InstallExpectFailure -RepositoryRoot $invalidSource -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'PowerShell parse error'
        $transactions = Join-Path $codexHome '.ai-instructions-txn'
        @(Get-ChildItem -LiteralPath $transactions -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    # Scenario: Another installer owns the per-Codex-Home installation transaction lock.
    # Purpose: Prevent concurrent runtime swaps and rollback from overwriting a successful installation.
    It 'InterT47_refuses_installation_while_the_install_lock_is_held' {
        New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $lockStream = [System.IO.File]::Open($installLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        }
        finally {
            $lockStream.Dispose()
        }

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'another AI instructions installer is already running'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\ai-instructions-runtime') | Should Be $false
    }

    # Scenario: The installed runtime changes after updater candidate selection but before the installer acquires its lock.
    # Purpose: Refuse a stale candidate transaction instead of overwriting a newer or divergent installed runtime.
    It 'InterT48_revalidates_the_expected_current_commit_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -ExpectedCurrentCommit ('0' * 40)

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'installed runtime changed before installation'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: The active runtime keeps the expected commit string but one inventory file drifts before install lock acquisition.
    # Purpose: Revalidate the complete active state, not only attacker-controllable bundle metadata, before candidate swap.
    It 'InterT49_revalidates_the_complete_active_runtime_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $expectedCommit = [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).commit
        $runtimeFile = Join-Path $runtimeRoot 'skills-selection.psm1'
        [System.IO.File]::AppendAllText($runtimeFile,"`n# drift before installer lock`n")
        $driftedBytes = Get-Content -Raw -LiteralPath $runtimeFile

        $result = Invoke-InstallExpectFailure `
            -RepositoryRoot $repositoryRoot `
            -CodexHome $codexHome `
            -ExpectedCurrentCommit $expectedCommit

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'installed runtime changed before installation'
        $result.Output | Should Match 'inventory'
        (Get-Content -Raw -LiteralPath $runtimeFile) | Should Be $driftedBytes
    }

    # Scenario: A stable Codex Home script path is already an unrelated user directory.
    # Purpose: Fail before mutation rather than copying into or deleting a path whose type proves it is not installer-owned.
    It 'InterT50_rejects_an_unsafe_existing_directory_at_a_stable_file_path' {
        $unsafePath = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        New-Item -ItemType Directory -Force -Path $unsafePath | Out-Null
        Set-TestText -Path (Join-Path $unsafePath 'personal.txt') -Value "preserve me`n"

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'unsafe installer mutation path'
        Test-Path -LiteralPath $unsafePath -PathType Container | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $unsafePath 'personal.txt')) | Should Be "preserve me`n"
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: Hooks-file transformation fails before the prepared journal is made durable.
    # Purpose: Preserve launcher, runtime, configuration, Agent, and hook bytes with no target mutation.
    It 'InterT51_rolls_back_runtime_config_and_agent_files_when_a_late_install_step_fails' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        $hookBefore = Get-Content -Raw -LiteralPath $hookPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath
        $configurationBefore = Get-Content -Raw -LiteralPath $configurationPath
        $agentsBefore = Get-Content -Raw -LiteralPath $agentsPath
        $badHooks = '{not-json'
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value $badHooks

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'hooks file is not valid JSON'
        (Get-Content -Raw -LiteralPath $hookPath) | Should Be $hookBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
        (Get-Content -Raw -LiteralPath $configurationPath) | Should Be $configurationBefore
        (Get-Content -Raw -LiteralPath $agentsPath) | Should Be $agentsBefore
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json')) | Should Be $badHooks
    }

    # Scenario: Auto-install approval is revoked after candidate acquisition but before the installer takes its lock.
    # Purpose: Revalidate opt-in policy before any runtime, launcher, configuration, Agent, or hook mutation.
    It 'InterT52_revalidates_expected_update_policy_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.updates.mode = 'auto-install-approved'
        Set-TestJson -Path $configurationPath -Document $configuration
        $expectedCurrentCommit = [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).commit
        $configuration.updates.mode = 'notify-only'
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = Get-Content -Raw -LiteralPath $configurationPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome `
            -ExpectedCurrentCommit $expectedCurrentCommit `
            -ExpectedUpdateMode 'auto-install-approved' `
            -ExpectedUpdateChannel 'protected-branch' `
            -ExpectedUpdateRef 'main'

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'update policy changed before installation'
        (Get-Content -Raw -LiteralPath $configurationPath) | Should Be $configurationBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: A projection-aware installer replaces the legacy bundle after preflight but before this installer owns the install lock.
    # Purpose: Reread schema compatibility under the lock so the legacy installer cannot overwrite the newer runtime or begin staging.
    It 'InterT52a_rejects_a_v3_bundle_replaced_while_acquiring_the_install_lock_without_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $v3Bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $v3Bundle.schemaVersion = 3
        $v3BundleBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((($v3Bundle | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"))
        $runtimeFilePath = Join-Path $runtimeRoot 'skills-selection.psm1'
        $runtimeFileBefore = [System.IO.File]::ReadAllBytes($runtimeFilePath)
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configurationBefore = [System.IO.File]::ReadAllBytes($configurationPath)
        $resultPath = Join-Path $TestDrive 'installer-v3-lock-race-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-v3-lock-race-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $BundlePath,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$lockLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*try \{ \$installLockLease = Enter-PlatformLock ' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($lockLine.Count -ne 1) { throw 'Could not locate the installer lock acquisition boundary.' }
$global:InstallerV3RaceBundlePath = $BundlePath
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $lockLine[0] -Action {
    $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $global:InstallerV3RaceBundlePath | ConvertFrom-Json
    $bundle.schemaVersion = 3
    [System.IO.File]::WriteAllText(
        $global:InstallerV3RaceBundlePath,
        (($bundle | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    $installerExit = 0
    $installerError = ''
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerV3RaceBundlePath -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@
        $archivePath = Join-Path $TestDrive 'installer-v3-lock-race-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-BundlePath',$bundlePath,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match 'Runtime bundle schema version 3 requires a projection-aware installer\.'
        (Get-AiInstructionsRefusalCode (Get-Content -Raw -LiteralPath $resultPath)) | Should Be unsupported-version
        $bundleAfter = [System.IO.File]::ReadAllBytes($bundlePath)
        [Convert]::ToBase64String($bundleAfter) | Should Be ([Convert]::ToBase64String($v3BundleBytes))
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).schemaVersion | Should Be 3
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($runtimeFilePath)) | Should Be ([Convert]::ToBase64String($runtimeFileBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    # Scenario: A verified launcher is actively executing runtime fan-out while another installation starts for the same Codex Home.
    # Purpose: Hold a shared runtime read lock through execution so the installer cannot swap files into a mixed running bundle.
    It 'InterT53_blocks_runtime_installation_while_verified_fan_out_is_running' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $markerPath = Join-Path $TestDrive 'fan-out-running.marker'
        $slowBootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'
        Set-TestText -Path $slowBootstrapPath -Value @"
param([string]`$CatalogPath,[string]`$LockPath,[string]`$ConfigurationPath,[string]`$TargetRoot)
[System.IO.File]::WriteAllText('$markerPath','running')
Start-Sleep -Seconds 15
"@
        $runtimeContractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $updatedBundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository ([string]$bundle.repository) `
            -Commit ([string]$bundle.commit) `
            -Acquisition ([string]$bundle.acquisition) `
            -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $hookPath + '"'),'-SkipUpdateCheck')
        $fanOutOutput = Join-Path $TestDrive 'fan-out-running.stdout.txt'
        $fanOutError = Join-Path $TestDrive 'fan-out-running.stderr.txt'
        $fanOutProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $fanOutOutput -RedirectStandardError $fanOutError
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $fanOutProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $markerPath)) {
                $diagnostic = @(
                    "exit=$(if ($fanOutProcess.HasExited) { $fanOutProcess.ExitCode } else { '<still running>' })",
                    $(if (Test-Path -LiteralPath $fanOutOutput) { Get-Content -Raw -LiteralPath $fanOutOutput } else { '<no stdout>' }),
                    $(if (Test-Path -LiteralPath $fanOutError) { Get-Content -Raw -LiteralPath $fanOutError } else { '<no stderr>' })
                ) -join [Environment]::NewLine
                throw "Verified fan-out did not start: $diagnostic"
            }

            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'installer is already running|runtime is being installed'
        }
        finally {
            if (-not $fanOutProcess.HasExited) { Stop-Process -Id $fanOutProcess.Id -Force }
            $fanOutProcess.Dispose()
        }
    }

    # Scenario: The launcher starts its automatic update check while another installation targets the same Codex Home.
    # Purpose: Dispatch the verified stable updater so its shared runtime lock prevents a swap during child module loading and use.
    It 'InterT54_launcher_update_check_uses_the_locked_stable_updater_path' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $stableUpdaterPath = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $runtimeUpdaterPath = Join-Path $runtimeRoot 'update-ai-instructions.ps1'
        $markerPath = Join-Path $TestDrive 'launcher-updater-running.marker'
        $slowUpdater = @"
param([string]`$CodexHome)
`$entryPointDirectoryName = Split-Path -Leaf ([System.IO.Path]::GetFullPath(`$PSScriptRoot).TrimEnd([char[]]@('\','/')))
if (`$entryPointDirectoryName -ieq 'hooks') {
    `$lockPath = Join-Path `$CodexHome 'ai-instructions-install.lock'
    `$runtimeReadLock = [System.IO.File]::Open(`$lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    try {
        [System.IO.File]::WriteAllText('$markerPath','stable')
        Start-Sleep -Seconds 15
    }
    finally { `$runtimeReadLock.Dispose() }
}
else {
    [System.IO.File]::WriteAllText('$markerPath','runtime')
    Start-Sleep -Seconds 15
}
"@
        Set-TestText -Path $stableUpdaterPath -Value $slowUpdater
        Set-TestText -Path $runtimeUpdaterPath -Value $slowUpdater
        $runtimeContractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $updatedBundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository ([string]$bundle.repository) `
            -Commit ([string]$bundle.commit) `
            -Acquisition ([string]$bundle.acquisition) `
            -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle

        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $hookPath + '"'))
        $launcherOutput = Join-Path $TestDrive 'launcher-updater-running.stdout.txt'
        $launcherError = Join-Path $TestDrive 'launcher-updater-running.stderr.txt'
        $launcherProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $launcherOutput -RedirectStandardError $launcherError
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $launcherProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $markerPath)) {
                $diagnostic = @(
                    "exit=$(if ($launcherProcess.HasExited) { $launcherProcess.ExitCode } else { '<still running>' })",
                    $(if (Test-Path -LiteralPath $launcherOutput) { Get-Content -Raw -LiteralPath $launcherOutput } else { '<no stdout>' }),
                    $(if (Test-Path -LiteralPath $launcherError) { Get-Content -Raw -LiteralPath $launcherError } else { '<no stderr>' })
                ) -join [Environment]::NewLine
                throw "Verified launcher update check did not start: $diagnostic"
            }
            (Get-Content -Raw -LiteralPath $markerPath) | Should Be 'stable'

            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'installer is already running|runtime is being installed'
        }
        finally {
            if (-not $launcherProcess.HasExited) { Stop-Process -Id $launcherProcess.Id -Force }
            $launcherProcess.Dispose()
        }
    }

    # Scenario: Apply runs while a newer AI-Instructions candidate may exist under the separate updater policy.
    # Purpose: Reconcile only the current verified runtime without invoking the updater or silently approving a candidate.
    It 'InterT54a_agent_environment_apply_uses_the_current_verified_runtime_without_invoking_the_updater' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $updaterMarker = Join-Path $TestDrive 'environment-updater-lock.marker'
        $reconcilerMarker = Join-Path $TestDrive 'environment-reconciler-lock.marker'
        $escapedInstallLockPath = $installLockPath.Replace("'","''")
        $escapedUpdaterMarker = $updaterMarker.Replace("'","''")
        $escapedReconcilerMarker = $reconcilerMarker.Replace("'","''")

        $updaterFixture = @"
param([string]`$CodexHome,[switch]`$ForceCheck,[switch]`$InstallApproved)
[System.IO.File]::WriteAllText('$escapedUpdaterMarker','unexpected-invocation')
throw 'Agent environment reconciliation must not invoke the AI-Instructions updater.'
"@
        Set-TestText -Path (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -Value $updaterFixture
        Set-TestText -Path (Join-Path $runtimeRoot 'update-ai-instructions.ps1') -Value $updaterFixture

        $reconcilerFixture = @"
Set-StrictMode -Version 2.0
function Assert-UserProjectionRuntimeGate {
    param([string]`$RuntimeRoot)
    throw 'Projection runtime gate is not expected for the v2/v4 fixture.'
}
function New-AgentEnvironmentInstallReadLeaseEvidence {
    param([System.IO.FileStream]`$Lease)
    `$trustedStream=[System.IO.File]::Open(`$Lease.Name,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    `$evidence=[pscustomobject]@{Stream=`$trustedStream}
    `$evidence|Add-Member -MemberType ScriptMethod -Name Dispose -Value { `$this.Stream.Dispose() }
    return `$evidence
}
function Get-UserSkillsDesiredState {
    param(
        [string]`$RuntimeRoot,
        [object]`$Configuration,
        [string]`$CatalogRepository,
        [string]`$CatalogCommit,
        [string]`$WorkingRoot
    )
    `$exclusive = `$null
    `$lockOutcome = 'exclusive-acquired'
    try {
        `$exclusive = [System.IO.File]::Open(
            '$escapedInstallLockPath',
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] { `$lockOutcome = 'blocked-by-read-lock' }
    finally { if (`$null -ne `$exclusive) { `$exclusive.Dispose() } }
    [System.IO.File]::WriteAllText('$escapedReconcilerMarker',`$lockOutcome)
    return [pscustomobject]@{
        RuntimeRoot = `$RuntimeRoot
        Catalog = [pscustomobject]@{ skills = @() }
        Files = @()
        Manifest = [pscustomobject]@{
            catalogRepository = `$CatalogRepository
            catalogCommit = `$CatalogCommit
            lockSha256 = ('a' * 64)
        }
    }
}
function Invoke-UserSkillsReconciliation {
    param(
        [object]`$DesiredState,
        [string]`$UserHome,
        [string]`$Mode,
        [switch]`$ForceReinstallManagedSkills,
        [switch]`$MigrateLegacyCatalogSkills,
        [object]`$InstallReadLease
    )
    return [pscustomobject]@{
        schemaVersion=1; outcome='current'; exitCode=0
        catalogCommit=[string]`$DesiredState.Manifest.catalogCommit
        catalogLockSha256=[string]`$DesiredState.Manifest.lockSha256
        installed=@(); updated=@(); removed=@(); preserved=@(); failed=@()
        rollbackState='not-started'; backupPath=`$null
    }
}
function Invoke-UserSkillsRecovery {
    param(
        [string]`$UserHome,
        [object]`$InstallReadLease,
        [ValidateSet('Apply','VerifyOnly','WhatIf')][string]`$Mode = 'Apply'
    )
    if (`$Mode -in @('VerifyOnly','WhatIf')) {
        return [pscustomobject]@{
            schemaVersion=1; outcome='nothing-to-recover'; exitCode=0; rollbackState='not-needed'
        }
    }
    throw 'Apply recovery is not expected in this fixture.'
}
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
"@
        Set-TestText -Path (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Value $reconcilerFixture

        $runtimeContractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $updatedBundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository ([string]$bundle.repository) `
            -Commit ([string]$bundle.commit) `
            -Acquisition ([string]$bundle.acquisition) `
            -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle

        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        $userHome = Join-Path $TestDrive 'locked-environment-user'
        New-Item -ItemType Directory -Path $userHome | Out-Null
        $runspaceResult=Invoke-TestAgentEnvironmentEntryWithExclusiveLockProbe -EntryPath $environmentUpdater -CodexHome $codexHome -UserHome $userHome -InstallLockPath $installLockPath
        $output=$runspaceResult.EntryOutput
        $entryResult=($output[-1]|ConvertFrom-Json)

        $entryResult.exitCode | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match '"outcome":"current"'
        Test-Path -LiteralPath $updaterMarker | Should Be $false
        [System.IO.File]::ReadAllText($reconcilerMarker) | Should Be 'blocked-by-read-lock'
        @($runspaceResult.ExclusiveOutput)[-1]|Should Be 'exclusive-acquired'
    }

    # Scenario: The stable Agent environment entry creates a trusted install read lease and reconciliation then fails in the same reusable PowerShell runspace.
    # Purpose: Release the trusted lease before the entry returns through its trap so an installer can immediately acquire the exclusive install lock.
    It 'InterT54b_agent_environment_failure_releases_the_trusted_install_read_lease' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot=Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $installLockPath=Join-Path $codexHome 'ai-instructions-install.lock'
        $escapedFailureLockPath=$installLockPath.Replace("'","''")
        $failureFixture=@"
Set-StrictMode -Version 2.0
function Assert-UserProjectionRuntimeGate { param([string]`$RuntimeRoot);throw 'Projection runtime gate is not expected for the v2/v4 fixture.' }
function New-AgentEnvironmentInstallReadLeaseEvidence {
    param([System.IO.FileStream]`$Lease)
    `$trustedStream=[System.IO.File]::Open('$escapedFailureLockPath',[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    `$evidence=[pscustomobject]@{Stream=`$trustedStream}
    `$evidence|Add-Member -MemberType ScriptMethod -Name Dispose -Value { `$this.Stream.Dispose() }
    return `$evidence
}
function Get-UserSkillsDesiredState {
    param([string]`$RuntimeRoot,[object]`$Configuration,[string]`$CatalogRepository,[string]`$CatalogCommit,[string]`$WorkingRoot)
    throw 'injected reconciliation setup failure after trusted lease creation'
}
function Invoke-UserSkillsReconciliation { param([object]`$DesiredState,[string]`$UserHome,[string]`$Mode,[switch]`$ForceReinstallManagedSkills,[switch]`$MigrateLegacyCatalogSkills,[object]`$InstallReadLease);throw 'unexpected reconciliation call' }
function Invoke-UserSkillsRecovery { param([string]`$UserHome,[object]`$InstallReadLease,[ValidateSet('Apply','VerifyOnly','WhatIf')][string]`$Mode='Apply');throw 'unexpected recovery call' }
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
"@
        Set-TestText -Path (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Value $failureFixture
        $runtimeContractPath=Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $bundlePath=Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle=Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath|ConvertFrom-Json
        $updatedBundle=New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository ([string]$bundle.repository) -Commit ([string]$bundle.commit) -Acquisition ([string]$bundle.acquisition) -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle
        $entryPath=Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        $userHome=Join-Path $TestDrive 'failed-environment-user';New-Item -ItemType Directory -Path $userHome|Out-Null

        $runspaceResult=Invoke-TestAgentEnvironmentEntryWithExclusiveLockProbe -EntryPath $entryPath -CodexHome $codexHome -UserHome $userHome -InstallLockPath $installLockPath
        $entryResult=(@($runspaceResult.EntryOutput)[-1]|ConvertFrom-Json)

        $entryResult.outcome|Should Be 'failed'
        $entryResult.exitCode|Should Be 1
        @($entryResult.failed)[0]|Should Match 'injected reconciliation setup failure'
        @($runspaceResult.ExclusiveOutput)[-1]|Should Be 'exclusive-acquired'
    }

    # Scenario: The installed configuration pin is changed without replacing the runtime bundle.
    # Purpose: Make the stable launcher reject mixed configuration/runtime identity before bootstrap.
    It 'InterT55_installed_launcher_rejects_a_runtime_bundle_pin_mismatch' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('f' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1
        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime bundle does not match'
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }

    # Scenario: An interrupted swap leaves a strict configuration and verified runtime bundle pinned to different canonical commits.
    # Purpose: Keep ordinary launch fail closed while allowing the same stable updater to repair only this proven mismatch.
    It 'InterT56_same_updater_recovers_a_verified_bundle_configuration_pin_mismatch' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $receipt = [ordered]@{
            schemaVersion = 1
            checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            mode = [string]$configuration.updates.mode
            channel = [string]$configuration.updates.channel
            ref = [string]$configuration.updates.ref
            currentCommit = [string]$bundle.commit
            candidateCommit = $null
            outcome = 'current'
            archiveSha256 = $null
            message = 'Verified runtime was current before the interrupted config write.'
        }
        Set-TestJson -Path (Join-Path $codexHome 'ai-instructions-update-receipt.json') -Document $receipt
        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'

        $blockedOutput = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome 2>&1
        $blockedExitCode = $LASTEXITCODE
        $recoveryOutput = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater `
            -CodexHome $codexHome -RecoverInterruptedInstall 2>&1
        $recoveryExitCode = $LASTEXITCODE

        $blockedExitCode | Should Not Be 0
        ($blockedOutput -join [Environment]::NewLine) | Should Match 'runtime bundle does not match'
        ($recoveryOutput -join [Environment]::NewLine) | Should Match 'Recovered interrupted AI instructions installation'
        ($recoveryOutput -join [Environment]::NewLine) | Should Not Match 'AI instructions update outcome'
        $recoveryExitCode | Should Be 0
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ([string]$bundle.commit)
        @(Get-ChildItem -LiteralPath $codexHome -Force -File | Where-Object {
            $_.Name -match '^\.ai-instructions-sync\.json\.(recovery|backup|failed)-'
        }).Count | Should Be 0
    }

    # Scenario: A verified pin mismatch exists while another installer owns the per-home install lock.
    # Purpose: Prevent recovery from racing a transactional runtime/config swap and writing a stale pin afterward.
    It 'InterT57_interrupted_install_recovery_refuses_a_concurrent_installer' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $installLock = [System.IO.File]::Open(
            $installLockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater `
                -CodexHome $codexHome -RecoverInterruptedInstall 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $installLock.Dispose() }

        $exitCode | Should Not Be 0
        $outputText = $output -join [Environment]::NewLine
        $outputText | Should Match 'recovery refused to run while another AI instructions installer is active'
        $outputText | Should Match 'classification=concurrency; retryable=false'
        $outputText | Should Not Match 'classification=operational'
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ('0' * 40)
    }

    # Scenario: The installed configuration carries an update interval above the v4 schema and migration boundary.
    # Purpose: Make the trusted stable-launcher preflight reject out-of-contract policy before importing runtime code.
    It 'InterT58_installed_launcher_rejects_an_out_of_range_update_interval' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.updates.minimumCheckIntervalMinutes = [long][int]::MaxValue + 1
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'update policy is invalid'
        ($output -join [Environment]::NewLine) | Should Match 'classification=configuration; retryable=false'
    }

    # Scenario: The installed updater module is missing and an unmanaged sibling module is placed beside the stable command.
    # Purpose: Make the stable updater fail closed before importing fallback code from an incomplete installed layout.
    It 'InterT59_manual_updater_rejects_a_missing_installed_module_before_sibling_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeUpdater = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-updater.psm1'
        $siblingUpdater = Join-Path $codexHome 'hooks\ai-instructions-updater.psm1'
        $executionEvidence = Join-Path $codexHome 'fallback-updater-executed.txt'
        Remove-Item -LiteralPath $runtimeUpdater -Force
        Set-Content -Encoding UTF8 -LiteralPath $siblingUpdater -Value "[System.IO.File]::WriteAllText('$executionEvidence','executed')"

        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome -ForceCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'installed updater module is missing'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: One installed runtime module is changed after its bundle inventory was created.
    # Purpose: Stop the stable launcher before executing any tampered runtime code.
    It 'InterT60_installed_launcher_rejects_runtime_inventory_tampering_before_execution' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A user runs the stable manual updater after an installed runtime module is tampered.
    # Purpose: Reuse trusted launcher preflight before importing any runtime updater code.
    It 'InterT61_manual_updater_preflights_runtime_before_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-updater.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-updater-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome -ForceCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A user runs the stable cleanup command after its runtime contracts are tampered.
    # Purpose: Refuse cleanup before importing or executing the unverified contract modules.
    It 'InterT62_cleanup_command_preflights_runtime_before_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\skills-catalog-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-cleanup-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $cleanupCommand = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $cleanupCommand -TargetRoot $repositoryRoot -Authorize 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: The stable launcher bytes drift from the reference copy covered by the active runtime inventory.
    # Purpose: Detect an interrupted mixed-version install before update or target bootstrap code executes.
    It 'InterT63_installed_launcher_rejects_stable_launcher_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [System.IO.File]::AppendAllText($hookPath,"`n# stable launcher drift`n")

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable launcher does not match'
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }

    # Scenario: The stable Agent environment updater drifts from its immutable runtime reference copy.
    # Purpose: Stop an already-installed but tampered user-scoped entry point during its trusted launcher preflight.
    It 'InterT63a_agent_environment_updater_rejects_stable_entry_point_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        [System.IO.File]::AppendAllText($environmentUpdater,"`n# stable Agent environment updater drift`n")
        $userHome = Join-Path $TestDrive 'environment-updater-user'
        New-Item -ItemType Directory -Path $userHome | Out-Null

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $environmentUpdater `
            -CodexHome $codexHome -UserHome $userHome -VerifyOnly -OutputFormat Json 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable Agent environment updater does not match'
    }

    # Scenario: The stable Agent environment updater is missing from an otherwise installed runtime.
    # Purpose: Treat the stable entry point as required runtime inventory instead of silently accepting a partial install.
    It 'InterT63b_installed_launcher_rejects_a_missing_stable_agent_environment_updater' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        Remove-Item -LiteralPath $environmentUpdater -Force
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match '(?s)runtime is incomplete:.*update-agent-environment\.ps1'
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }

    # Scenario: The installed runtime directory is replaced by a file while unmanaged cleanup contracts exist beside the stable command.
    # Purpose: Make cleanup reject the malformed installed layout before importing fallback contract modules or mutating the target index.
    It 'InterT64_cleanup_rejects_a_non_directory_runtime_before_sibling_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $siblingContract = Join-Path $codexHome 'hooks\skills-catalog-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'fallback-cleanup-contract-executed.txt'
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
        Set-Content -Encoding UTF8 -LiteralPath $runtimeRoot -Value 'not a directory'
        Set-Content -Encoding UTF8 -LiteralPath $siblingContract -Value "[System.IO.File]::WriteAllText('$executionEvidence','executed')"

        $cleanupCommand = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $cleanupCommand -TargetRoot $repositoryRoot -Authorize 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'installed runtime directory is missing or invalid'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A stable installer destination is a hard-link alias of a file outside Codex Home.
    # Purpose: Reject ambiguous stable-file ownership before installation can change any external alias bytes.
    It 'InterT65_installer_rejects_a_hard_linked_stable_file' {
        $outsidePath = Join-Path $TestDrive 'installer-hard-link-outside.ps1'
        $stablePath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stablePath) | Out-Null
        Set-TestText -Path $outsidePath -Value "# outside original`n"
        New-Item -ItemType HardLink -Path $stablePath -Target $outsidePath | Out-Null
        $outsideBefore = [System.IO.File]::ReadAllBytes($outsidePath)

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'hard link|multiple file-system links|exclusive ownership'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outsidePath)) |
            Should Be ([Convert]::ToBase64String($outsideBefore))
        (Get-Item -Force -LiteralPath $stablePath).LinkType | Should Be 'HardLink'
    }

    # Scenario: The hooks directory is replaced by a junction after the installer's last path check but before active copies begin.
    # Purpose: Hold a handle-bound directory guard across the complete active swap so stable commands and runtime cannot escape Codex Home.
    It 'InterT66_installer_blocks_a_parent_junction_swap_during_active_mutation' {
        $archivePath = Join-Path $TestDrive 'installer-junction-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $outsideRoot = Join-Path $TestDrive 'installer-junction-outside'
        $savedHooks = Join-Path $codexHome 'hooks-original'
        $resultPath = Join-Path $TestDrive 'installer-junction-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-junction-probe.ps1'
        New-Item -ItemType Directory -Force -Path $outsideRoot | Out-Null
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $OutsideRoot,
    [Parameter(Mandatory = $true)][string] $SavedHooks,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$mutationLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallOperation -Operation ' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($mutationLine.Count -ne 1) { throw 'Could not locate the installer active-mutation boundary.' }
$global:InstallerProbeHooks = Join-Path $CodexHome 'hooks'
$global:InstallerProbeSavedHooks = $SavedHooks
$global:InstallerProbeOutside = $OutsideRoot
$global:InstallerProbeSwapResult = 'not-attempted'
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $mutationLine[0] -Action {
    try {
        Move-Item -LiteralPath $global:InstallerProbeHooks -Destination $global:InstallerProbeSavedHooks
        New-Item -ItemType Junction -Path $global:InstallerProbeHooks -Target $global:InstallerProbeOutside | Out-Null
        $global:InstallerProbeSwapResult = 'swapped'
    }
    catch { $global:InstallerProbeSwapResult = 'blocked: ' + $_.Exception.Message }
}
try {
    $installerError = ''
    & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
        -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
        -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
    $installerExit = 0
}
catch {
    $installerExit = 1
    $installerError = $_.Exception.Message
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
}
$result = @($installerExit,$global:InstallerProbeSwapResult,$installerError) -join "`n"
[System.IO.File]::WriteAllText($ResultPath,$result,(New-Object System.Text.UTF8Encoding($false)))
Remove-Variable -Name InstallerProbeHooks,InstallerProbeSavedHooks,InstallerProbeOutside,InstallerProbeSwapResult -Scope Global -ErrorAction SilentlyContinue
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-OutsideRoot',$outsideRoot,
            '-SavedHooks',$savedHooks,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^0\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^blocked:'
        Test-Path -LiteralPath (Join-Path $outsideRoot 'bootstrap-ai-instructions.ps1') | Should Be $false
        Test-Path -LiteralPath (Join-Path $outsideRoot 'ai-instructions-runtime') | Should Be $false
        (Get-Item -Force -LiteralPath (Join-Path $codexHome 'hooks')).LinkType | Should BeNullOrEmpty
    }

    # Scenario: A user edits AGENTS.md after the installer snapshots stable files but before that file is replaced.
    # Purpose: Preserve the writer's bytes, restore every unaffected target to its original state, and complete transaction cleanup when no original backup was displaced.
    It 'InterT67_preserves_a_concurrent_stable_file_edit_before_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $archivePath = Join-Path $TestDrive 'installer-cas-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        Set-TestText -Path $agentsPath -Value "# Personal instructions before the concurrent edit`n"
        $hookBefore = [System.IO.File]::ReadAllBytes($hookPath)
        $bundleBefore = [System.IO.File]::ReadAllBytes($bundlePath)
        $configurationBefore = [System.IO.File]::ReadAllBytes($configurationPath)
        $externalAgents = "# Concurrent personal instructions`n"
        $resultPath = Join-Path $TestDrive 'installer-cas-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-cas-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $AgentsPath,
    [Parameter(Mandatory = $true)][string] $ExternalAgents,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$mutationLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallOperation -Operation ' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($mutationLine.Count -ne 1) { throw 'Could not locate the installer active-mutation boundary.' }
$global:InstallerCasAgentsPath = $AgentsPath
$global:InstallerCasExternalAgents = $ExternalAgents
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $mutationLine[0] -Action {
    [System.IO.File]::WriteAllText(
        $global:InstallerCasAgentsPath,
        $global:InstallerCasExternalAgents,
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerCasAgentsPath,InstallerCasExternalAgents -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-AgentsPath',$agentsPath,
            '-ExternalAgents',$externalAgents,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match 'changed concurrently'
        (Get-Content -Raw -LiteralPath $agentsPath) | Should Be $externalAgents
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($hookPath)) | Should Be ([Convert]::ToBase64String($hookBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        # Scenario: An active install fails after publishing a file, while external writers replace both its target and original backup before the journal records the operation as applied.
        # Purpose: Preserve both external artifacts and return the interrupted-install refusal marker with the original install error as its inner exception.
        It 'InterT83_active_install_recovery_returns_typed_refusal_when_artifacts_are_retained' {
            Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
            $candidateRoot=Join-Path $TestDrive ('active-retained-candidate-'+[Guid]::NewGuid().ToString('N'))
            New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
            $candidateTransactionModule=Join-Path $candidateRoot 'scripts\ai-instructions-install-transaction.psm1'
            $candidateTransactionBody=Get-Content -Raw -LiteralPath $candidateTransactionModule
            $probeBoundary='    Invoke-AiInstructionsInstallFailpoint -Name "after-operation-$sequence-before-journal"'
            $probeInjection=@'
    if ($sequence -eq 1 -and [Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_PROBE','Process') -ceq '1') {
        $probeHome=[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_HOME','Process')
        $probeTransaction=@(Get-ChildItem -LiteralPath (Join-Path $probeHome '.ai-instructions-txn') -Directory -Force)[0]
        $probeTarget=Join-Path $probeHome ([string]$Operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $probeBackup=Join-Path $probeTransaction.FullName ([string]$Operation.backupLeaf)
        [IO.File]::Delete($probeTarget)
        [IO.File]::Delete($probeBackup)
        [IO.File]::WriteAllText($probeTarget,[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_TARGET','Process'),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($probeBackup,[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_BACKUP','Process'),[Text.UTF8Encoding]::new($false))
        throw 'active install recovery probe failure'
    }
'@
            if(-not$candidateTransactionBody.Contains($probeBoundary)){throw 'Could not locate the active installer operation-return boundary.'}
            Set-TestText -Path $candidateTransactionModule -Value ($candidateTransactionBody.Replace($probeBoundary,($probeInjection+"`n"+$probeBoundary)))
            $archivePath=Join-Path $TestDrive ('active-retained-source-'+[Guid]::NewGuid().ToString('N')+'.zip')
            $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
            $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
            $externalTarget="# external target during active install`n"
            $externalBackup="# external backup during active install`n"
            $resultPath=Join-Path $TestDrive 'active-retained-result.txt'
            $wrapperPath=Join-Path $TestDrive 'active-retained-probe.ps1'
            Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $ExternalTarget,
    [Parameter(Mandatory = $true)][string] $ExternalBackup,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$env:P7D2_ACTIVE_RETAINED_PROBE='1'
$env:P7D2_ACTIVE_RETAINED_HOME=$CodexHome
$env:P7D2_ACTIVE_RETAINED_TARGET=$ExternalTarget
$env:P7D2_ACTIVE_RETAINED_BACKUP=$ExternalBackup
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit=0
        $installerError=''
        $innerError=''
    }
    catch {
        $installerExit=1
        $installerError=$_.Exception.Message
        $innerError=if($null-ne$_.Exception.InnerException){$_.Exception.InnerException.Message}else{''}
    }
}
finally {
    Remove-Item Env:\P7D2_ACTIVE_RETAINED_PROBE,Env:\P7D2_ACTIVE_RETAINED_HOME,Env:\P7D2_ACTIVE_RETAINED_TARGET,Env:\P7D2_ACTIVE_RETAINED_BACKUP -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError,$innerError)-join"`n"),[Text.UTF8Encoding]::new($false))
'@
            $arguments=@(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
                '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
                '-RepositoryRoot',$repositoryRoot,
                '-CodexHome',$codexHome,
                '-SourceCommit',$sourceCommit,
                '-ArchiveSha256',$archiveSha256,
                '-ArchivePath',$archivePath,
                '-ExternalTarget',$externalTarget,
                '-ExternalBackup',$externalBackup,
                '-ResultPath',$resultPath
            )

            $output=& $script:TestPowerShellExecutable @arguments 2>&1

            $LASTEXITCODE|Should Be 0
            $result=Get-Content -Raw -LiteralPath $resultPath
            $result|Should Match '(?m)^1\r?$'
            (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
            (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText (Join-Path $codexHome '.ai-instructions-txn'))))
            (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText 'active install recovery probe failure')))
            $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
            $transaction.Count|Should Be 1
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            $operation=@($journal.operations|Where-Object sequence -eq 1)[0]
            (Get-Content -Raw -LiteralPath (Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)))|Should Be $externalTarget
            (Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName ([string]$operation.backupLeaf)))|Should Be $externalBackup
        }
    }

    # Scenario: A crash leaves an applied launcher and its original backup, then the backup bytes are modified.
    # Purpose: Refuse journal recovery without changing either the applied target or any transaction evidence.
    It 'InterT68_preserves_concurrent_stable_file_bytes_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot = Join-Path $TestDrive 'installer-backup-tamper-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)
        }
        [IO.File]::AppendAllText((Join-Path $candidateRoot 'scripts\bootstrap-ai-instructions-installed.ps1'),"`n# crash candidate`n",[Text.UTF8Encoding]::new($false))
        $archivePath = Join-Path $TestDrive 'installer-backup-tamper-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-SourceArchivePath',$archivePath
        )
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $operation=@($journal.operations|Where-Object sequence -eq 1)[0]
        $backupPath=Join-Path $transaction[0].FullName ([string]$operation.backupLeaf)
        Set-TestText -Path $backupPath -Value "tampered backup evidence`n"
        $targetPath=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/','\')
        $targetBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))
        $evidenceBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath))

        $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be $targetBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath))|Should Be $evidenceBefore
        Test-Path -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|Should Be $true
    }

    # Scenario: A crash leaves the candidate runtime active, then an external writer adds a file to that complete tree.
    # Purpose: Refuse recovery and retain both the drifted target and the original runtime backup in the journal transaction.
    It 'InterT69_preserves_concurrent_runtime_content_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimePath = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $candidateRoot = Join-Path $TestDrive 'installer-runtime-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)}
        $candidateSourcePath = Join-Path $candidateRoot 'scripts\safe-zip.psm1'
        [System.IO.File]::AppendAllText($candidateSourcePath,"`n# runtime rollback candidate`n",(New-Object System.Text.UTF8Encoding($false)))
        $archivePath = Join-Path $TestDrive 'installer-runtime-rollback-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath
        )
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $runtimeOperation=@($journal.operations|Where-Object kind -eq 'swap-directory')[0]
        $runtimeOperation.sequence|Should Be 1
        $externalRuntimeContent="Concurrent runtime content`n"
        Set-TestText -Path (Join-Path $runtimePath 'concurrent-runtime-note.txt') -Value $externalRuntimeContent
        $backupPath=Join-Path $transaction[0].FullName ([string]$runtimeOperation.backupLeaf)
        $backupDigest=(Get-FileHash -LiteralPath (Join-Path $backupPath 'safe-zip.psm1') -Algorithm SHA256).Hash

        $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath (Join-Path $runtimePath 'concurrent-runtime-note.txt'))|Should Be $externalRuntimeContent
        (Get-FileHash -LiteralPath (Join-Path $backupPath 'safe-zip.psm1') -Algorithm SHA256).Hash|Should Be $backupDigest
        Test-Path -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|Should Be $true
    }

    # Register only on the native host because junction replacement and Windows delete sharing are platform-specific.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: The active journal transaction directory is swapped for an outside junction when recovery begins.
    # Purpose: Hold a no-delete-sharing directory lease so the swap cannot redirect rollback, and retain journal evidence at .ai-instructions-txn/<txid> after the guarded refusal.
    It 'InterT70_blocks_a_backup_root_junction_swap_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot=Join-Path $TestDrive 'installer-transaction-guard-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot|Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)}
        [IO.File]::AppendAllText((Join-Path $candidateRoot 'scripts\bootstrap-ai-instructions-installed.ps1'),"`n# transaction guard candidate`n",[Text.UTF8Encoding]::new($false))
        $archivePath = Join-Path $TestDrive 'installer-transaction-guard-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $crashArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @crashArguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $outsideRoot = Join-Path $TestDrive 'installer-transaction-guard-outside'
        $savedBackupRoot = Join-Path $TestDrive 'transaction-root-swapped'
        $resultPath = Join-Path $TestDrive 'installer-transaction-guard-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-transaction-guard-probe.ps1'
        New-Item -ItemType Directory -Force -Path $outsideRoot | Out-Null
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $OutsideRoot,
    [Parameter(Mandatory = $true)][string] $SavedBackupRoot,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$rollbackLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallRecoveryPlan -Journal \$record\.Classification\.journal' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($rollbackLine.Count -ne 1) { throw 'Could not locate the installer rollback boundary.' }
$global:InstallerBackupGuardCodexHome = $CodexHome
$global:InstallerBackupGuardOutside = $OutsideRoot
$global:InstallerBackupGuardSaved = $SavedBackupRoot
$global:InstallerBackupGuardSwapResult = 'not-attempted'
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $rollbackLine[0] -Action {
    try {
        $backupRoot = @(Get-ChildItem -LiteralPath (Join-Path $global:InstallerBackupGuardCodexHome '.ai-instructions-txn') -Directory -Force)
        if ($backupRoot.Count -ne 1) { throw 'Could not identify the active installer backup root.' }
        Move-Item -LiteralPath $backupRoot[0].FullName -Destination $global:InstallerBackupGuardSaved -ErrorAction Stop
        New-Item -ItemType Junction -Path $backupRoot[0].FullName -Target $global:InstallerBackupGuardOutside -ErrorAction Stop | Out-Null
        $global:InstallerBackupGuardSwapResult = 'swapped'
    }
    catch {
        $global:InstallerBackupGuardSwapResult = 'blocked: ' + $_.Exception.Message
        if($null-eq$record-or$null-eq$record.Plan){throw 'Could not bind the active recovery plan after the guarded swap was blocked.'}
        $record.Plan.action='refuse'
    }
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText(
    $ResultPath,
    (@($installerExit,$global:InstallerBackupGuardSwapResult,$installerError) -join "`n"),
    (New-Object System.Text.UTF8Encoding($false)))
Remove-Variable -Name InstallerBackupGuardCodexHome,InstallerBackupGuardOutside,InstallerBackupGuardSaved,InstallerBackupGuardSwapResult -Scope Global -ErrorAction SilentlyContinue
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-OutsideRoot',$outsideRoot,
            '-SavedBackupRoot',$savedBackupRoot,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^blocked:'
        $transactions=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transactions.Count | Should Be 1
        $transactions[0].LinkType | Should BeNullOrEmpty
        $journalPath=Join-Path $transactions[0].FullName 'journal.json'
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
        $journal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath) -ExpectedTransactionId $transactions[0].Name
        @($journal.operations).Count | Should BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $transactions[0].FullName -Force -Recurse).Count | Should BeGreaterThan 1
        if(Test-Path -LiteralPath $savedBackupRoot){@(Get-ChildItem -LiteralPath $savedBackupRoot -Force).Count|Should Be 0}
        @(Get-ChildItem -LiteralPath $outsideRoot -Force).Count | Should Be 0
    }
    }

    }

    # Scenario: The transaction module publishes the complete failpoint grammar used by subprocess crash tests.
    # Purpose: Keep every journal, operation, cleanup, and rollback crash boundary discoverable without enabling it.
    It 'InterT71_exports_the_install_failpoint_v1_patterns' {
        $module = Import-Module (Join-Path $repositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force -PassThru
        @(& $module { Get-AiInstructionsInstallFailpointPatterns }) | Should Be @(
            'after-journal-prepared','after-journal-stage-flush','after-journal-publish-before-parent-flush',
            'after-recovery-before-install',
            'before-operation-<sequence>','after-original-to-backup-<sequence>',
            'after-operation-<sequence>-before-journal','after-operation-<sequence>',
            'after-committed-before-cleanup','before-cleanup-<artifact-leaf>',
            'during-cleanup-<artifact-leaf>','after-cleanup-<artifact-leaf>','after-rollback-operation-<sequence>'
        )
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: A killed pre-journal process leaves only a private transaction directory.
    # Purpose: Purge an orphan before preparing the next install and leave the retained store empty.
    It 'InterT72_purges_an_orphan_transaction_before_installing' {
        $transaction = Join-Path $codexHome ('.ai-instructions-txn\' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $transaction | Out-Null
        Set-TestText -Path (Join-Path $transaction 'journal.stage') -Value "partial`n"

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome | Out-Null

        Test-Path -LiteralPath $transaction | Should Be $false
        @(Get-ChildItem -Force -LiteralPath (Join-Path $codexHome '.ai-instructions-txn')).Count | Should Be 0
    }

    # Scenario: Residue has malformed journal bytes or a non-transaction name.
    # Purpose: Refuse the complete residue set without changing evidence or installation targets.
    It 'InterT73_refuses_malformed_and_invalid_name_transaction_residue_without_mutation' -TestCases @(
        @{Name=[Guid]::NewGuid().ToString('N');Journal='{not-json'},
        @{Name='invalid-transaction-name';Journal=$null}
    ) {
        param($Name,$Journal)
        $transaction = Join-Path $codexHome ".ai-instructions-txn\$Name"
        New-Item -ItemType Directory -Force -Path $transaction | Out-Null
        if($null -ne $Journal){Set-TestText -Path (Join-Path $transaction 'journal.json') -Value $Journal}
        $evidenceBefore = @(Get-ChildItem -LiteralPath $transaction -Force -Recurse | ForEach-Object { $_.FullName })

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be interrupted-install
        @(Get-ChildItem -LiteralPath $transaction -Force -Recurse | ForEach-Object { $_.FullName }) | Should Be $evidenceBefore
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: A legacy installer left one of the pre-journal staging namespaces.
    # Purpose: List and preserve legacy evidence instead of interpreting it as journal v1 state.
    It 'InterT74_refuses_and_preserves_legacy_installer_residue' -TestCases @(
        @{Leaf='.ai-instructions-install-0123456789abcdef0123456789abcdef'},
        @{Leaf='.ai-instructions-backup-0123456789abcdef0123456789abcdef'}
    ) {
        param($Leaf)
        $residue = Join-Path $codexHome $Leaf
        New-Item -ItemType Directory -Force -Path $residue | Out-Null
        Set-TestText -Path (Join-Path $residue 'evidence.txt') -Value "preserve`n"

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match ([regex]::Escape($residue))
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be interrupted-install
        (Get-Content -Raw -LiteralPath (Join-Path $residue 'evidence.txt')) | Should Be "preserve`n"
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -and $null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        # Scenario: Windows PowerShell 5.1 starts the PowerShell-7-only installer.
        # Purpose: Return the typed baseline refusal before creating Codex Home or transaction artifacts.
        It 'InterT75_windows_powershell_5_1_returns_typed_runtime_baseline_refusal_without_mutation' {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome 2>&1
            $LASTEXITCODE | Should Not Be 0
            (Get-AiInstructionsRefusalCode ($output -join [Environment]::NewLine)) | Should Be runtime-baseline-unavailable
            Test-Path -LiteralPath $codexHome | Should Be $false
        }
    }
    }

    # Scenario: One required capability has a real unavailable receipt with diagnostic evidence.
    # Purpose: Map capability selection to a typed installer refusal without a production override switch.
    It 'InterT76_maps_an_unavailable_capability_receipt_to_a_typed_refusal' {
        $module=Import-Module (Join-Path $repositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force -PassThru
        $names=@('directory-lease','file-lease','file-identity','lock','publication','owned-file-removal','permissions','directory-publication')
        $receipt=[pscustomobject]@{capabilities=@($names|ForEach-Object{[pscustomobject]@{name=$_;status=$(if($_ -ceq 'publication'){'unavailable'}else{'available'});evidence=@("probe evidence for $_")}})}
        $caught=$null
        try{& $module {param($value)Assert-AiInstructionsInstallerCapabilities -Receipt $value} $receipt|Out-Null}catch{$caught=$_}
        $caught|Should Not BeNullOrEmpty
        (Get-AiInstructionsRefusalCode $caught)|Should Be capability-unavailable
        $caught.Exception.Message|Should Match 'publication=unavailable: probe evidence for publication'
    }

    # Scenario: The immutable installer source closure has a missing file or a bound hash mismatch.
    # Purpose: Return the D16 closure-invalid code before importing candidate runtime code or mutating Codex Home.
    It 'InterT80_refuses_an_invalid_installer_source_closure_without_mutation' -TestCases @(
        @{Variant='missing'},
        @{Variant='hash-mismatch'}
    ) {
        param($Variant)
        $candidateRoot=Join-Path $TestDrive ("closure-invalid-$Variant-"+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $candidateRoot|Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)
        }
        $boundFile=Join-Path $candidateRoot 'scripts\platform\Windows.psm1'
        if($Variant -ceq 'missing'){Remove-Item -LiteralPath $boundFile -Force}
        else{[IO.File]::AppendAllText($boundFile,"`n# invalid closure fixture`n",[Text.UTF8Encoding]::new($false))}
        $archivePath=Join-Path $TestDrive ("closure-invalid-$Variant.zip")
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $output=& $script:TestPowerShellExecutable @arguments 2>&1
        $LASTEXITCODE|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be closure-invalid
        Test-Path -LiteralPath $codexHome|Should Be $false
    }

    # Register only on Unix because directory publication is deliberately deferred there.
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        # Scenario: The installer runs on a Linux or macOS Core host without directory publication.
        # Purpose: Refuse with capability evidence before creating or changing Codex Home.
        It 'InterT79_unix_refuses_unavailable_directory_publication_without_mutation' {
            $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
            $result.ExitCode|Should Not Be 0
            (Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            $result.Output|Should Match 'directory-publication'
            Test-Path -LiteralPath $codexHome|Should Be $false
        }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: Each failpoint grammar family kills a subprocess at a durable install or recovery boundary.
    # Purpose: Stop after recovery, prove one complete original/applied state, then install and prove an identity-stable rerun.
    It 'InterT77_recovers_the_install_journal_failpoint_matrix_to_an_idempotent_complete_state' -TestCases @(
        @{Failpoint='after-recovery-before-install';PreCrash=$null;Fresh=$true;ExpectedRecovery='no-transaction';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-prepared';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='after-journal-stage-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='purge-orphan';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-publish-before-parent-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='before-operation-1';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='before-operation-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='before-operation-6';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-original-to-backup-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-1-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-6-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-1';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-6';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-committed-before-cleanup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='before-cleanup-op-01-bootstrap.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-cleanup-op-01-bootstrap.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='before-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='during-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-rollback-operation-1';PreCrash='after-operation-1-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-rollback-operation-5';PreCrash='after-operation-5-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-rollback-operation-6';PreCrash='after-operation-6-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-operation-1-before-journal';PreCrash=$null;Fresh=$true;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5-before-journal';PreCrash=$null;Fresh=$true;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'}
    ) {
        param($Failpoint,$PreCrash,$Fresh,$ExpectedRecovery,$ExpectedPhase,$ExpectedFinal)
        if(-not$Fresh){
            Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
            Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{hooks=[ordered]@{SessionStart=@([ordered]@{matcher='startup';hooks=@([ordered]@{type='command';command="powershell.exe -File `"$(Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1')`""})})}})
        }
        $originalSnapshot=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot=Join-Path $TestDrive ("failpoint-candidate-"+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ("failpoint-source-"+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $invokeCrash={param($Name)$saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT;try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$Name;& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;return $LASTEXITCODE}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}}
        if($null-ne$PreCrash){(& $invokeCrash $PreCrash)|Should Not Be 0}
        (& $invokeCrash $Failpoint)|Should Not Be 0
        $recoveryState=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $recoveryState.RecoveryAction|Should Be $ExpectedRecovery
        $recoveryState.JournalPhase|Should Be $ExpectedPhase
        $appliedSnapshot=Get-InstallerAppliedSnapshotFromTransaction -CodexHome $codexHome -OriginalSnapshot $originalSnapshot
        (& $invokeCrash 'after-recovery-before-install')|Should Not Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
        $recoveredSnapshot=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        if($ExpectedFinal-ceq'original'){$recoveredSnapshot|Should Be $originalSnapshot}
        else{
            $ExpectedFinal|Should Be 'applied'
            $appliedSnapshot|Should Not BeNullOrEmpty
            $recoveredSnapshot|Should Be $appliedSnapshot
        }

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$installOutput=& $script:TestPowerShellExecutable @arguments 2>&1;$installExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $installExit|Should Be 0
        $stableMarkerSources=[ordered]@{
            'bootstrap-ai-instructions.ps1'='bootstrap-ai-instructions-installed.ps1'
            'update-ai-instructions.ps1'='update-ai-instructions.ps1'
            'update-agent-environment.ps1'='update-agent-environment.ps1'
            'cleanup-ai-instructions-pollution.ps1'='cleanup-ai-instructions-pollution.ps1'
        }
        foreach($relative in @($stableMarkerSources.Keys)){
            (Get-Content -Raw -LiteralPath (Join-Path $codexHome "hooks\$relative"))|Should Match ([regex]::Escape("# failpoint candidate: $($stableMarkerSources[$relative])"))
        }
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks\ai-instructions-runtime\safe-zip.psm1'))|Should Match '# failpoint candidate: safe-zip\.psm1'
        $before=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$idempotentOutput=& $script:TestPowerShellExecutable @arguments 2>&1;$idempotentExit=$LASTEXITCODE}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $idempotentExit|Should Be 0
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $before
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: A create-file crash is followed by an external replacement of the target with a directory.
    # Purpose: Refuse the type-confused observation and preserve both the external target and transaction evidence.
    It 'InterT81_recovery_refuses_a_create_file_target_replaced_by_a_directory' {
        $archivePath=Join-Path $TestDrive 'type-confusion-source.zip'
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $target=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Remove-Item -LiteralPath $target -Force
        New-Item -ItemType Directory -Path $target|Out-Null
        Set-TestText -Path (Join-Path $target 'external.txt') -Value "external`n"
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $evidenceBefore=@(Get-ChildItem -LiteralPath $transaction[0].FullName -Force -Recurse|ForEach-Object FullName)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$output=& $script:TestPowerShellExecutable @arguments 2>&1;$exitCode=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $exitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be interrupted-install
        Test-Path -LiteralPath (Join-Path $target 'external.txt') -PathType Leaf|Should Be $true
        @(Get-ChildItem -LiteralPath $transaction[0].FullName -Force -Recurse|ForEach-Object FullName)|Should Be $evidenceBefore
    }

    # Scenario: A pending write-file already displaced its original into backup, then an external writer replaces the published target before the journal records applied.
    # Purpose: Refuse recovery without mutating any target, the identity-bound original backup, or the durable journal evidence.
    It 'InterT82_refuses_a_pending_write_with_a_valid_original_backup_and_external_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('valid-backup-external-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('valid-backup-external-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0

        $recoveryState=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($recoveryState.Journal.operations|Where-Object sequence -eq 1)[0]
        $operation.state|Should Be 'pending'
        $operation.backupLeaf|Should Not BeNullOrEmpty
        $target=Join-Path $codexHome ($operation.targetRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))
        Set-TestText -Path $target -Value "# external replacement after original backup`n"
        $backup=Join-Path $recoveryState.TransactionPath ([string]$operation.backupLeaf)
        Test-Path -LiteralPath $backup -PathType Leaf|Should Be $true

        $targetsBefore=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $backupBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))
        $journalPath=Join-Path $recoveryState.TransactionPath 'journal.json'
        $journalBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))
        $entriesBefore=@(Get-ChildItem -LiteralPath $recoveryState.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($recoveryState.TransactionPath.Length)})

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$output=& $script:TestPowerShellExecutable @arguments 2>&1;$exitCode=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $exitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be interrupted-install
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $targetsBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))|Should Be $backupBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should Be $journalBefore
        @(Get-ChildItem -LiteralPath $recoveryState.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($recoveryState.TransactionPath.Length)})|Should Be $entriesBefore
    }

    # Scenario: Recovery classifies an applied write-file target, then an external writer replaces it before restore-original runs.
    # Purpose: Bind rollback publication to operation.applied so the external bytes and permissions survive and transaction evidence remains available.
    It 'InterT84_refuses_a_rollback_target_replaced_after_recovery_observation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('rollback-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('rollback-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.RecoveryAction|Should Be 'roll-back'
        $operation=@($state.Journal.operations|Where-Object sequence -eq 1)[0]
        $target=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $external="# external rollback target`n"

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $target -ExternalText $external -ExternalReadOnly $true -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $target)|Should Be $external
        (Get-Item -Force -LiteralPath $target).IsReadOnly|Should Be $true
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $state.TransactionPath ([string]$operation.backupLeaf)) -PathType Leaf|Should Be $true
    }

    # Scenario: Recovery selects restore-permissions for original bytes, then an external writer replaces the target before the permission step.
    # Purpose: Verify journal original identity and content through the target lease before changing permissions, leaving the replacement untouched on refusal.
    It 'InterT85_refuses_permission_restore_for_a_replaced_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('permission-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('permission-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-journal-prepared';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($state.Journal.operations|Where-Object sequence -eq 1)[0]
        $target=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        (Get-Item -Force -LiteralPath $target).IsReadOnly=$true
        (Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome).RecoveryAction|Should Be 'roll-back'
        $external="# external permission target`n"

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $target -ExternalText $external -ExternalReadOnly $false -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $target)|Should Be $external
        (Get-Item -Force -LiteralPath $target).IsReadOnly|Should Be $false
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
    }

    # Scenario: A committed transaction is ready for terminal cleanup, then an external writer replaces an original backup after the recovery plan is built.
    # Purpose: Delete only a backup whose full journal-bound identity and content still match, preserving a replacement and all recovery evidence on refusal.
    It 'InterT86_refuses_cleanup_of_a_replaced_transaction_artifact' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('cleanup-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('cleanup-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $operation=@($state.Journal.operations|Where-Object{$null-ne$_.backupLeaf -and [string]$_.kind -eq 'write-file'}|Select-Object -First 1)
        $operation.Count|Should Be 1
        $backup=Join-Path $state.TransactionPath ([string]$operation[0].backupLeaf)
        $external="# external cleanup artifact`n"
        $targetsBefore=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $backup -ExternalText $external -ExternalReadOnly $true -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $backup)|Should Be $external
        (Get-Item -Force -LiteralPath $backup).IsReadOnly|Should Be $true
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $targetsBefore
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
    }

    # Scenario: Recovery classifies a committed journal store, then an external writer replaces journal.json with the same valid bytes on a different inode before cleanup starts.
    # Purpose: Bind terminal cleanup to the classified journal identity as well as its content, refusing without deleting the replacement or any transaction evidence.
    It 'InterT87_refuses_cleanup_of_a_same_bytes_replaced_journal_store_file' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('journal-store-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('journal-store-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $journalPath=Join-Path $state.TransactionPath 'journal.json'
        [byte[]]$journalBytes=[IO.File]::ReadAllBytes($journalPath)
        $journalText=[Text.UTF8Encoding]::new($false,$true).GetString($journalBytes)
        $transactionRelative='.ai-instructions-txn/'+(Split-Path -Leaf $state.TransactionPath)
        $transactionLease=Open-PlatformDirectory -Root $codexHome -RelativePath $transactionRelative
        try{$originalState=Get-AiInstructionsInstallFileState -ParentLease $transactionLease -Leaf journal.json -LiteralPath $journalPath -PlatformOs windows}
        finally{$transactionLease.Dispose()}
        $entriesBefore=@(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $journalPath -ExternalText $journalText -ExternalReadOnly $false -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText $state.TransactionPath)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should Be ([Convert]::ToBase64String($journalBytes))
        $transactionLease=Open-PlatformDirectory -Root $codexHome -RelativePath $transactionRelative
        try{$replacementState=Get-AiInstructionsInstallFileState -ParentLease $transactionLease -Leaf journal.json -LiteralPath $journalPath -PlatformOs windows}
        finally{$transactionLease.Dispose()}
        ($replacementState.identity|ConvertTo-Json -Compress)|Should Not Be ($originalState.identity|ConvertTo-Json -Compress)
        @(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})|Should Be $entriesBefore
    }

    # Scenario: Recovery classifies a valid committed journal beside a UTF-8 journal.stage whose JSON is malformed.
    # Purpose: Require journal.stage to be the current or next journal generation before cleanup, refusing and retaining all evidence otherwise.
    It 'InterT88_refuses_cleanup_of_a_malformed_journal_stage_generation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('journal-stage-generation-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('journal-stage-generation-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $stagePath=Join-Path $state.TransactionPath 'journal.stage'
        $malformedStage="{malformed`n"
        Set-TestText -Path $stagePath -Value $malformedStage
        $entriesBefore=@(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})

        $output=& $script:TestPowerShellExecutable @arguments 2>&1
        $recoveryExit=$LASTEXITCODE
        $result=$output-join[Environment]::NewLine

        $recoveryExit|Should Not Be 0
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText $state.TransactionPath)))
        (Get-Content -Raw -LiteralPath $stagePath)|Should Be $malformedStage
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
        @(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})|Should Be $entriesBefore
    }


    # Scenario: An existing read-only stable file is displaced, then the installer is interrupted after publishing its replacement.
    # Purpose: Recovery must publish the read-only backup through a read lease and restore its exact bytes and ReadOnly attribute.
    It 'InterT89_rolls_back_a_readonly_stable_file_after_an_operation_interrupt' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $stablePath=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [byte[]]$originalBytes=[IO.File]::ReadAllBytes($stablePath)
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly=$true
        $candidateRoot=Join-Path $TestDrive ('readonly-rollback-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('readonly-rollback-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($state.Journal.operations|Where-Object{[string]$_.targetRelativePath-ceq'hooks/bootstrap-ai-instructions.ps1'})
        $operation.Count|Should Be 1
        (Get-Item -Force -LiteralPath (Join-Path $state.TransactionPath ([string]$operation[0].backupLeaf))).IsReadOnly|Should Be $true

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-recovery-before-install';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$recoveryExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $recoveryExit|Should Not Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($stablePath))|Should Be ([Convert]::ToBase64String($originalBytes))
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly|Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: A prepared rollback finds original bytes and identity on a target whose ReadOnly attribute drifted to true.
    # Purpose: The restore-permissions step must reopen the read-only target without GENERIC_WRITE and restore the journal snapshot.
    It 'InterT90_restores_permissions_on_a_readonly_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $stablePath=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [byte[]]$originalBytes=[IO.File]::ReadAllBytes($stablePath)
        $candidateRoot=Join-Path $TestDrive ('readonly-permissions-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('readonly-permissions-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-journal-prepared';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly=$true
        (Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome).RecoveryAction|Should Be 'roll-back'

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-recovery-before-install';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$recoveryExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $recoveryExit|Should Not Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($stablePath))|Should Be ([Convert]::ToBase64String($originalBytes))
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly|Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }
    }

    # Register only on the native host because FileShare is the Windows lock interoperability protocol.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        # Scenario: The new platform lock and the legacy File.Open lock contend in both protocol directions.
        # Purpose: Preserve FileShare.Read/None compatibility while migrating only the installer lock implementation.
        It 'InterT78_preserves_windows_install_lock_interoperability_with_the_legacy_protocol' {
            New-Item -ItemType Directory -Force -Path $codexHome|Out-Null
            Import-Module (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1') -Force
            $root=Open-PlatformDirectory -Root $codexHome -RootOnly
            $lease=Enter-PlatformLock -ParentLease $root -Leaf ai-instructions-install.lock -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            try{
                $legacyCaught=$null
                try{$legacy=[IO.File]::Open((Join-Path $codexHome 'ai-instructions-install.lock'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$legacy.Dispose()}catch{$legacyCaught=$_}
                $legacyCaught|Should Not BeNullOrEmpty
            }finally{$lease.Dispose();$root.Dispose()}
            $legacy=[IO.File]::Open((Join-Path $codexHome 'ai-instructions-install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{$result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome}finally{$legacy.Dispose()}
            $result.ExitCode|Should Not Be 0
            $result.Output|Should Match 'Another AI instructions installer is already running for this Codex Home\.'
        }
    }
}
