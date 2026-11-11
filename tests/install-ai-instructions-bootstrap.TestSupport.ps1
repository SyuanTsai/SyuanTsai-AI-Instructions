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

function Get-InstallerFullTreeSnapshot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return '<root-absent>'}
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $entries=New-Object System.Collections.Generic.List[string]
    foreach($item in @((Get-Item -Force -LiteralPath $rootPath)) + @(Get-ChildItem -Force -LiteralPath $rootPath -Recurse)){
        $relative=if($item.FullName-ceq$rootPath){'.'}else{$item.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')}
        $kind=if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse'}elseif($item.PSIsContainer){'directory'}else{'file'}
        $hash=if($kind-ceq'file'){(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}else{'-'}
        $entries.Add("$relative`t$kind`t$([int64]$item.Attributes)`t$hash")
    }
    $values=$entries.ToArray();[Array]::Sort($values,[StringComparer]::Ordinal)
    return ($values-join"`n")
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

$script:InstallAiInstructionsBootstrapBeforeEach = {
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
}
