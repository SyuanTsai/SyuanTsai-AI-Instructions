Set-StrictMode -Version 2.0

function Get-GitHubArchiveUri {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $ResolvedCommit
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Repository, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "Skills source repository must be an absolute HTTPS URL: $Repository"
    }
    if (-not $uri.Host.Equals('github.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote Skills source retrieval currently supports github.com repositories only: $Repository"
    }
    if ($ResolvedCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Skills source resolvedCommit must be a full 40-character SHA: $ResolvedCommit"
    }

    $path = $uri.AbsolutePath.Trim('/')
    if ($path.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(0, $path.Length - 4)
    }
    $parts = @($path.Split('/'))
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Skills source repository must identify a GitHub owner/repository pair: $Repository"
    }

    $owner = [System.Uri]::EscapeDataString($parts[0])
    $repo = [System.Uri]::EscapeDataString($parts[1])
    return "https://codeload.github.com/$owner/$repo/zip/$ResolvedCommit"
}

function Get-SkillsSourceArchives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [hashtable] $LocalArchiveOverrides = @{}
    )

    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not (Test-Path -LiteralPath $destination)) {
        New-Item -ItemType Directory -Path $destination | Out-Null
    }

    $result = @{}
    foreach ($source in @($Plan.Sources)) {
        $sourceId = [string]$source.id
        if ($sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "Unsafe source ID for retrieval: $sourceId"
        }

        if ($LocalArchiveOverrides.ContainsKey($sourceId)) {
            $override = [System.IO.Path]::GetFullPath([string]$LocalArchiveOverrides[$sourceId])
            if (-not (Test-Path -LiteralPath $override -PathType Leaf)) {
                throw "Local archive override for source '$sourceId' does not exist: $override"
            }
            $result[$sourceId] = $override
            continue
        }

        $archivePath = Join-Path $destination "$sourceId.zip"
        $archiveUri = Get-GitHubArchiveUri -Repository ([string]$source.repository) -ResolvedCommit ([string]$source.resolvedCommit)
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{ 'User-Agent'='Codex-Agent-Skills-Bootstrap' } -OutFile $archivePath
        $result[$sourceId] = $archivePath
    }

    return $result
}

function Assert-AiSourceCacheOwner {
    param($Lease,[switch]$Directory)
    $permissions=Get-PlatformPermissions -Lease $Lease
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $owner=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetOwnerSid($Lease)
            $tokenOwner=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetCurrentProcessTokenOwnerSid()
            if (-not [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::IsAcceptedOwnerSid($owner,$identity.User.Value,$tokenOwner)) { throw 'Source cache entry is not owned by the current user.' }
        } finally { $identity.Dispose() }
    } else {
        $mode=if($Directory){448}else{384}
        if ([uint64]$permissions.Uid -ne [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetEffectiveUserId() -or
            [Convert]::ToUInt32([string]$permissions.Mode,8) -ne $mode) { throw 'Source cache requires current-user ownership and private 0700/0600 modes.' }
    }
}

function Get-AiSourceCacheHash {
    param([byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-AiSourceCacheObject {
    param($Value,[string[]]$Properties)
    if ($null -eq $Value -or $Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Properties.Count) { throw 'Malformed source cache object.' }
    foreach($name in $Properties){if($null -eq $Value.PSObject.Properties[$name]){throw 'Malformed source cache object properties.'}}
}

function Read-AiSourceCacheFile {
    param($Parent,[string]$Leaf)
    # Platform leases open regular files without following links and identity-check
    # before/after reading. Hash these bytes, never a second path-based read.
    $file=Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try {
        Assert-AiSourceCacheOwner $file
        $observed=Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        $bytes=[byte[]]$file.ReadAllBytes([int]$observed.Size)
        $hash=Get-AiSourceCacheHash $bytes
        $identity=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
            [pscustomobject]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$observed.Device);fileId=('0x{0:x}' -f [uint64]$observed.Inode)}
        }else{[pscustomobject]@{kind='unix-device-inode';device=([uint64]$observed.Device).ToString();fileId=([uint64]$observed.Inode).ToString()}}
        return [pscustomobject]@{Bytes=$bytes;Hash=$hash;State=[pscustomobject]@{exists=$true;sha256=$hash;length=[int64]$bytes.Length;identity=$identity}}
    } finally { $file.Dispose() }
}

function Remove-AiSourceCacheSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return }
    try {
        foreach ($leaf in $Snapshot.Files) {
            $file=Read-AiSourceCacheFile $Snapshot.Lease $leaf
            Remove-PlatformOwnedFile -ParentLease $Snapshot.Lease -Leaf $leaf -ExpectedState $file.State | Out-Null
        }
    } finally { $Snapshot.Lease.Dispose() }
    # Nonrecursive removal cannot traverse a substituted link or unknown entry.
    [IO.Directory]::Delete($Snapshot.Path,$false)
    try { [IO.Directory]::Delete($Snapshot.StorePath,$false) } catch { Write-Verbose 'Other source cache snapshots still use the private store.' }
}

function Open-AiInstructionsSourceCache {
    param([string]$CodexHome,[string]$RuntimeRoot,$Configuration,$Bundle)
    Set-StrictMode -Version Latest
    $cacheRoot=Join-Path $CodexHome 'ai-instructions-source-cache'
    $entry=@(Get-ChildItem -Force -LiteralPath $CodexHome | Where-Object Name -CEQ 'ai-instructions-source-cache')
    if ($entry.Count -eq 0) { return $null }
    $root=$null;$lock=$null;$cache=$null;$snapshot=$null
    try {
        $cache=Open-PlatformDirectory -Root $CodexHome -RelativePath 'ai-instructions-source-cache'
        Assert-AiSourceCacheOwner $cache -Directory
        $root=Open-PlatformDirectory -Root $CodexHome -RootOnly
        $lock=Enter-PlatformLock -ParentLease $root -Leaf 'ai-instructions-source-cache.lock' -Mode Shared -Timeout ([TimeSpan]::FromSeconds(30))
        $manifestEntry=@(Get-ChildItem -Force -LiteralPath $cacheRoot | Where-Object Name -CEQ 'manifest.json')
        if ($manifestEntry.Count -eq 0) { return $null }
        $manifestFile=Read-AiSourceCacheFile $cache 'manifest.json'
        $manifest=[Text.UTF8Encoding]::new($false,$true).GetString($manifestFile.Bytes) | ConvertFrom-Json -ErrorAction Stop
        # Parse the identity first. A proven different pin/lock is stale, not corrupt.
        # Missing/unparseable identity cannot establish staleness and fails closed.
        if ($manifest.commit -isnot [string] -or $manifest.commit -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.lockSha256 -isnot [string] -or $manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Malformed source cache identity.' }
        $lockBytes=[IO.File]::ReadAllBytes((Join-Path $RuntimeRoot 'catalog/skills-catalog-lock.json'))
        if ($manifest.commit -cne [string]$Configuration.catalog.ref -or $manifest.commit -cne [string]$Bundle.commit -or
            $manifest.lockSha256 -cne (Get-AiSourceCacheHash $lockBytes)) {
            [Console]::Error.WriteLine('AI instructions source cache is stale; using the configured download path.')
            return $null
        }
        Assert-AiSourceCacheObject $manifest @('schemaVersion','commit','repository','lockSha256','instruction','sources')
        Assert-AiSourceCacheObject $manifest.instruction @('fileName','sha256')
        if (($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or $manifest.schemaVersion -ne 1 -or
            $manifest.repository -isnot [string] -or $manifest.repository -cne [string]$Configuration.catalog.repository -or
            $manifest.sources -isnot [array]) { throw 'Malformed source cache manifest.' }
        $lockDocument=[Text.Encoding]::UTF8.GetString($lockBytes) | ConvertFrom-Json -ErrorAction Stop
        $locked=@{};foreach($source in $lockDocument.sources){$locked[[string]$source.id]=$source}
        $specs=[Collections.Generic.List[object]]::new()
        $specs.Add([pscustomobject]@{Id=$null;FileName=$manifest.instruction.fileName;Hash=$manifest.instruction.sha256})
        $seen=@{}
        foreach($source in $manifest.sources){
            Assert-AiSourceCacheObject $source @('id','resolvedCommit','archiveSha256','fileName')
            if ($source.id -isnot [string] -or $source.id -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or $seen.ContainsKey($source.id) -or
                -not $locked.ContainsKey($source.id)) { throw 'Malformed source cache source ID.' }
            $seen[$source.id]=$true;$expected=$locked[$source.id]
            if ($source.resolvedCommit -isnot [string] -or $source.resolvedCommit -cne $expected.resolvedCommit -or $source.archiveSha256 -cne $expected.archiveSha256) { throw 'Source cache differs from the runtime lock.' }
            $specs.Add([pscustomobject]@{Id=$source.id;FileName=$source.fileName;Hash=$source.archiveSha256})
        }
        foreach($spec in $specs){
            if ($spec.Hash -isnot [string] -or $spec.Hash -cnotmatch '^[0-9a-f]{64}$' -or $spec.FileName -isnot [string] -or $spec.FileName -cne ($spec.Hash+'.zip')) { throw 'Malformed content-addressed source cache file name.' }
        }
        $store=Open-PlatformDirectory -Root $cacheRoot -RelativePath '.ai-instructions-txn' -CreatePrivate
        try {
            Assert-AiSourceCacheOwner $store -Directory
            $leaf='.ai-instructions-txn/'+[guid]::NewGuid().ToString('N')
            $snapshot=[pscustomobject]@{Path=(Join-Path $cacheRoot $leaf);StorePath=(Join-Path $cacheRoot '.ai-instructions-txn');Lease=(Open-PlatformDirectory -Root $cacheRoot -RelativePath $leaf -CreatePrivate);Files=[Collections.Generic.List[string]]::new()}
        } finally { $store.Dispose() }
        $arguments=@{InstructionSourceCommit=[string]$manifest.commit;SourceArchivePaths=@{}}
        foreach($spec in $specs){
            $file=Read-AiSourceCacheFile $cache $spec.FileName
            if ($file.Hash -cne $spec.Hash) { throw 'Source cache archive SHA-256 mismatch.' }
            if (-not $snapshot.Files.Contains($spec.FileName)) {
                $copy=Open-PlatformFile -ParentLease $snapshot.Lease -Leaf $spec.FileName -Access ReadWrite -CreateMode CreateNew
                $snapshot.Files.Add($spec.FileName)
                try {$copy.WriteNewBytes($file.Bytes)}finally{$copy.Dispose()}
            }
            # Copy the verified bytes into a unique private snapshot; multisource
            # receives that snapshot, so later cache replacement cannot change input.
            $path=Join-Path $snapshot.Path $spec.FileName
            if ($null -eq $spec.Id) {$arguments.InstructionSourceArchivePath=$path}else{$arguments.SourceArchivePaths[$spec.Id]=$path}
        }
        # Complete setup emits every lock source, so a selected source cannot be
        # absent after that path. An incomplete/external manifest intentionally
        # leaves omitted overrides on Get-SkillsSourceArchives' download path.
        $result=[pscustomobject]@{Arguments=$arguments;Snapshot=$snapshot};$snapshot=$null
        return $result
    } finally {
        try { if($null -ne $snapshot){Remove-AiSourceCacheSnapshot $snapshot} }
        finally { if($null -ne $lock){$lock.Dispose()};if($null -ne $root){$root.Dispose()};if($null -ne $cache){$cache.Dispose()} }
    }
}

function Publish-AiInstructionsSourceCache {
    param([string]$CodexHome,[string]$RuntimeRoot,[string]$ExpectedCommit,[byte[]]$InstructionArchiveBytes)
    Set-StrictMode -Version Latest
    $configuration=[IO.File]::ReadAllText((Join-Path $CodexHome 'ai-instructions-sync.json')) | ConvertFrom-Json -ErrorAction Stop
    $bundle=[IO.File]::ReadAllText((Join-Path $RuntimeRoot 'runtime-bundle.json')) | ConvertFrom-Json -ErrorAction Stop
    # Fan-out uses catalog.ref, not setup HEAD by inference. A mismatch must not
    # publish a cache that silently changes which instruction commit it consumes.
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$' -or $configuration.catalog.ref -cne $ExpectedCommit -or $bundle.commit -cne $ExpectedCommit) {
        throw 'Source cache requires catalog.ref, installed bundle commit and expected commit to be identical.'
    }
    $lockBytes=[IO.File]::ReadAllBytes((Join-Path $RuntimeRoot 'catalog/skills-catalog-lock.json'))
    $lockDocument=[Text.Encoding]::UTF8.GetString($lockBytes) | ConvertFrom-Json -ErrorAction Stop
    $cacheRoot=Join-Path $CodexHome 'ai-instructions-source-cache'
    $root=$null;$cache=$null;$lock=$null;$store=$null;$transaction=$null
    $transactionId=[guid]::NewGuid().ToString('N')
    $transactionPath=Join-Path $cacheRoot ".ai-instructions-txn/$transactionId"
    try {
        $root=Open-PlatformDirectory -Root $CodexHome -RootOnly
        $lock=Enter-PlatformLock -ParentLease $root -Leaf 'ai-instructions-source-cache.lock' -Mode Exclusive -Timeout ([TimeSpan]::FromSeconds(30))
        $cache=Open-PlatformDirectory -Root $CodexHome -RelativePath 'ai-instructions-source-cache' -CreatePrivate
        Assert-AiSourceCacheOwner $cache -Directory
        Confirm-PlatformDirectoryDurability -DirectoryLease $root | Out-Null
        # Inspect existing entries without recursing through links. Unknown regular
        # private files are preserved; unsafe ownership or links refuse publication.
        $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($cacheRoot)
        while($pending.Count -gt 0){
            $directory=$pending.Dequeue()
            $guard=Open-PlatformDirectory -Root $directory -RootOnly
            try {
                Assert-AiSourceCacheOwner $guard -Directory
                foreach($entry in Get-ChildItem -Force -LiteralPath $directory){
                    if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Source cache contains a reparse point.'}
                    if($entry.PSIsContainer){$pending.Enqueue($entry.FullName)}else{
                        $file=Open-PlatformFile -ParentLease $guard -Leaf $entry.Name -Access Read -CreateMode OpenExisting
                        try{Assert-AiSourceCacheOwner $file;Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath | Out-Null}finally{$file.Dispose()}
                    }
                }
            } finally {$guard.Dispose()}
        }
        $store=Open-PlatformDirectory -Root $cacheRoot -RelativePath '.ai-instructions-txn' -CreatePrivate
        $transaction=Open-PlatformDirectory -Root $cacheRoot -RelativePath ".ai-instructions-txn/$transactionId" -CreatePrivate
        Confirm-PlatformDirectoryDurability -DirectoryLease $cache | Out-Null
        Confirm-PlatformDirectoryDurability -DirectoryLease $store | Out-Null
        $archives=Get-SkillsSourceArchives -Plan ([pscustomobject]@{Sources=@($lockDocument.sources)}) -DestinationRoot $transactionPath
        $content=@{}
        $instructionHash=Get-AiSourceCacheHash $InstructionArchiveBytes
        $content[$instructionHash+'.zip']=$InstructionArchiveBytes
        $sources=@(foreach($source in $lockDocument.sources){
            $path=[string]$archives[[string]$source.id]
            # Retrieval created these files in our new private stage. Set private
            # file mode before guarded reading, and publish only the locked bytes.
            $download=Open-PlatformFile -ParentLease $transaction -Leaf ([IO.Path]::GetFileName($path)) -Access Read -CreateMode OpenExisting
            try{
                $permissions=Get-PlatformPermissions -Lease $download
                if([uint64]$permissions.Uid -ne [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetEffectiveUserId()){throw 'Downloaded source archive is not owned by the current user.'}
                Assert-PlatformFileIdentity -Lease $download -Expected $download.Observation -SingleLink -VerifyPath | Out-Null
                Set-PlatformPermissions -Lease $download -Policy @{Mode=384} | Out-Null
            }finally{$download.Dispose()}
            $file=Read-AiSourceCacheFile $transaction ([IO.Path]::GetFileName($path))
            if($file.Hash -cne [string]$source.archiveSha256){throw 'Source cache acquisition SHA-256 differs from the runtime lock.'}
            $content[$file.Hash+'.zip']=$file.Bytes
            [ordered]@{id=[string]$source.id;resolvedCommit=[string]$source.resolvedCommit;archiveSha256=$file.Hash;fileName=($file.Hash+'.zip')}
        })
        $manifest=[ordered]@{schemaVersion=1;commit=$ExpectedCommit;repository=[string]$configuration.catalog.repository;lockSha256=(Get-AiSourceCacheHash $lockBytes);instruction=[ordered]@{fileName=($instructionHash+'.zip');sha256=$instructionHash};sources=$sources}
        $content['manifest.json']=[Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress)+"`n")
        # Content-addressed archives first, manifest last. Atomic platform rename
        # flushes the file and directories; the old manifest always has its files.
        foreach($leaf in @(@($content.Keys | Where-Object {$_ -cne 'manifest.json'} | Sort-Object) + 'manifest.json')){
            $bytes=[byte[]]$content[$leaf]
            $existing=@(Get-ChildItem -Force -LiteralPath $cacheRoot | Where-Object Name -CEQ $leaf)
            $current=if($existing.Count -gt 0){Read-AiSourceCacheFile $cache $leaf}else{$null}
            if($null -ne $current -and $current.Hash -ceq (Get-AiSourceCacheHash $bytes)){continue}
            $stageLeaf='stage-'+[guid]::NewGuid().ToString('N')
            $stage=Open-PlatformFile -ParentLease $transaction -Leaf $stageLeaf -Access ReadWrite -CreateMode CreateNew
            try{
                $stage.WriteNewBytes($bytes)
                $expected=if($null -eq $current){[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}}else{$current.State}
                $desired=[pscustomobject]@{exists=$true;sha256=(Get-AiSourceCacheHash $bytes);length=[int64]$bytes.Length;identity=$null}
                Publish-PlatformFile -ParentLease $cache -Leaf $leaf -TransactionLease $transaction -StageLease $stage -ExpectedState $expected -ExpectedStage $desired -DisplacedLeaf $(if($null -eq $current){$null}else{'displaced-'+$stageLeaf}) -NoReplace:($null -eq $current) | Out-Null
            }finally{$stage.Dispose()}
        }
        # Shared reader/exclusive writer locking protects readers until they own
        # snapshots. Only superseded content-addressed regular files are pruned.
        foreach($entry in Get-ChildItem -Force -LiteralPath $cacheRoot){
            if($entry.Name -cmatch '^[0-9a-f]{64}\.zip$' -and -not $content.ContainsKey($entry.Name)){
                try{$old=Read-AiSourceCacheFile $cache $entry.Name;Remove-PlatformOwnedFile -ParentLease $cache -Leaf $entry.Name -ExpectedState $old.State -TransactionLease $transaction -TombstoneLeaf ('superseded-'+[guid]::NewGuid().ToString('N')) | Out-Null}catch{Write-Verbose 'Superseded source cache archive cleanup was deferred.'}
            }
        }
    } finally {
        if($null -ne $transaction){
            try{
                foreach($entry in Get-ChildItem -Force -LiteralPath $transactionPath){
                    $file=Read-AiSourceCacheFile $transaction $entry.Name
                    Remove-PlatformOwnedFile -ParentLease $transaction -Leaf $entry.Name -ExpectedState $file.State | Out-Null
                }
                $transaction.Dispose();[IO.Directory]::Delete($transactionPath,$false)
            }catch{Write-Verbose 'Private source cache staging cleanup was deferred.'}
            finally{$transaction.Dispose()}
        }
        if($null -ne $store){$store.Dispose();try{[IO.Directory]::Delete((Join-Path $cacheRoot '.ai-instructions-txn'),$false)}catch{Write-Verbose 'Source cache staging directory cleanup was deferred.'}}
        if($null -ne $cache){$cache.Dispose()};if($null -ne $lock){$lock.Dispose()};if($null -ne $root){$root.Dispose()}
    }
}

Export-ModuleMember -Function Get-GitHubArchiveUri, Get-SkillsSourceArchives, Open-AiInstructionsSourceCache, Remove-AiSourceCacheSnapshot, Publish-AiInstructionsSourceCache
