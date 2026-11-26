# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Self-contained native-Unix fixture for the independently filterable Pester 4 Describe.
# The caller sets $UnixFixtureName before dot-sourcing this file from BeforeAll.
if ([string]::IsNullOrWhiteSpace([string]$UnixFixtureName)) { throw 'UnixFixtureName is required.' }

$script:UnixRepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/agent-environment-setup.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $script:UnixRepositoryRoot 'scripts/platform-runtime.psd1') -DisableNameChecking
Add-Type -AssemblyName System.Formats.Tar
# Resolve only the trusted test anchor (macOS /var -> /private/var).
$physical = '/'
foreach ($part in ([IO.Path]::GetFullPath($TestDrive)).Trim('/').Split('/')) {
    $item = [IO.DirectoryInfo]::new((Join-Path $physical $part))
    $target = $item.ResolveLinkTarget($true)
    $physical = if ($null -eq $target) { $item.FullName } else { $target.FullName }
}
$script:UnixRoot = Join-Path $physical $UnixFixtureName
[void][IO.Directory]::CreateDirectory($script:UnixRoot)
$script:UnixVersion = $PSVersionTable.PSVersion.ToString()
$script:UnixRid = Get-AgentEnvironmentSetupRid
$script:UnixAssetName = "powershell-$($script:UnixVersion)-$($script:UnixRid).tar.gz"

function New-UnixTarball {
    param([string]$Path,[ValidateSet('runtime','symlink','parent','absolute','hardlink','device')][string]$Kind)
    $file = [IO.File]::Create($Path)
    $gzip = [IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Compress,$false)
    $writer = [System.Formats.Tar.TarWriter]::new($gzip,$false)
    try {
        if ($Kind -ceq 'runtime') {
            # Copy bytes of every PSHOME file (links dereferenced) as regular members.
            $root = [IO.Path]::GetFullPath($PSHOME).TrimEnd('/')
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($root.Length + 1)
                if ($item.PSIsContainer -and $null -eq $item.LinkType) {
                    $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::Directory,$relative + '/')
                    $entry.Mode = [IO.UnixFileMode]448
                    $writer.WriteEntry($entry)
                    continue
                }
                if ($item.PSIsContainer) { continue }
                $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,$relative)
                $entry.Mode = [IO.UnixFileMode]448
                $entry.DataStream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($item.FullName))
                $writer.WriteEntry($entry)
            }
        } else {
            $pwsh = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,'pwsh')
            $pwsh.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("#!/bin/sh`nexit 0`n"))
            $writer.WriteEntry($pwsh)
            $name = switch ($Kind) { 'parent' { '../escape' } 'absolute' { '/escape' } default { 'extra' } }
            $type = switch ($Kind) { 'symlink' { [System.Formats.Tar.TarEntryType]::SymbolicLink } 'hardlink' { [System.Formats.Tar.TarEntryType]::HardLink } 'device' { [System.Formats.Tar.TarEntryType]::CharacterDevice } default { [System.Formats.Tar.TarEntryType]::RegularFile } }
            $entry = [System.Formats.Tar.PaxTarEntry]::new($type,$name)
            if ($Kind -in @('symlink','hardlink')) { $entry.LinkName = 'pwsh' }
            elseif ($Kind -ceq 'device') { $entry.DeviceMajor = 1; $entry.DeviceMinor = 3 }
            else { $entry.DataStream = [IO.MemoryStream]::new([byte[]]@(1)) }
            $writer.WriteEntry($entry)
        }
    } finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
}

$script:UnixArchives = @{}
foreach ($kind in @('runtime','symlink','parent','absolute','hardlink','device')) {
    $directory = Join-Path $script:UnixRoot "archive-$kind"; [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $script:UnixAssetName
    New-UnixTarball $path $kind
    $script:UnixArchives[$kind] = [pscustomobject]@{ Path = $path; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

# Fixture repository with one commit per fixture policy (hash bound to each archive).
$script:UnixRepo = Join-Path $script:UnixRoot 'repo'
[void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'scripts'))
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:UnixRepositoryRoot 'scripts/platform-runtime.psd1')
$files = @(@($manifest.FileList) + @(Get-AgentEnvironmentSetupBoundFiles | ForEach-Object { $_.Substring('scripts/'.Length) }))
foreach ($relative in $files) {
    $target = Join-Path (Join-Path $script:UnixRepo 'scripts') $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    Copy-Item -LiteralPath (Join-Path (Join-Path $script:UnixRepositoryRoot 'scripts') $relative) -Destination $target
}
$fixtureUpdater = @'
function Invoke-AiInstructionsUpdateWorkflow {
 param([string]$CodexHome,[switch]$ForceCheck,[switch]$InstallApproved,[scriptblock]$ResolveCandidate,[scriptblock]$AcquireCandidate,[scriptblock]$InstallCandidate)
 $bundle=Get-Content -Raw (Join-Path $CodexHome 'hooks/ai-instructions-runtime/runtime-bundle.json')|ConvertFrom-Json
 $configuration=Get-Content -Raw (Join-Path $CodexHome 'ai-instructions-sync.json')|ConvertFrom-Json
 $request=[pscustomobject]@{CodexHome=$CodexHome;CurrentCommit=[string]$bundle.commit;Mode=[string]$configuration.updates.mode;Channel=[string]$configuration.updates.channel;Ref=[string]$configuration.updates.ref}
 $candidate=& $ResolveCandidate $request
 if([string]$candidate.Commit-ceq[string]$bundle.commit){return [pscustomobject]@{outcome='current'}}
 $request|Add-Member CandidateCommit ([string]$candidate.Commit);$package=& $AcquireCandidate $request;$again=& $ResolveCandidate $request
 if([string]$again.Commit-cne[string]$candidate.Commit){return [pscustomobject]@{outcome='drift'}}
 & $InstallCandidate ([pscustomobject]@{CurrentCommit=[string]$bundle.commit;CandidateCommit=[string]$candidate.Commit;Mode=$request.Mode;Channel=$request.Channel;Ref=$request.Ref;Package=$package})
 [pscustomobject]@{outcome='installed'}
}
Export-ModuleMember -Function Invoke-AiInstructionsUpdateWorkflow
'@
$fixtureCoordinator = @'
[CmdletBinding()]param([string]$CodexHome,[string]$UserHome,[switch]$Apply,[switch]$VerifyOnly,[string]$OutputFormat)
$runtime=Join-Path $CodexHome 'hooks/ai-instructions-runtime';$bundle=Get-Content -Raw (Join-Path $runtime 'runtime-bundle.json')|ConvertFrom-Json
$skill=Join-Path $UserHome '.agents/skills/plan-production-change/SKILL.md';$manifest=Join-Path $UserHome '.agents/catalog-skills.manifest.json';$claude=Join-Path $UserHome '.claude/CLAUDE.md'
$desired="fixture commit=$($bundle.commit)`n";$section=[IO.File]::ReadAllText((Join-Path $runtime 'bootstrap-section.md'))
if($Apply){
 if((Test-Path $skill -PathType Leaf)-and-not(Test-Path $manifest -PathType Leaf)){[pscustomobject]@{outcome='failed';exitCode=1;failureDetails=@([pscustomobject]@{code='unmanaged-collision'})}|ConvertTo-Json -Compress -Depth 5;exit 1}
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($skill));[IO.File]::WriteAllText($skill,$desired);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($manifest));[IO.File]::WriteAllText($manifest,'{"schemaVersion":3,"projections":["user-agents","user-claude"],"files":[{"skillId":"plan-production-change","targetPath":".agents/skills/plan-production-change/SKILL.md"}]}');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($claude));[IO.File]::WriteAllText($claude,$section)
 [pscustomobject]@{outcome='applied';exitCode=0;failureDetails=@()}|ConvertTo-Json -Compress;exit 0
}
$current=(Test-Path $skill -PathType Leaf)-and([IO.File]::ReadAllText($skill)-ceq$desired)-and(Test-Path $manifest -PathType Leaf)-and(Test-Path $claude -PathType Leaf)-and([IO.File]::ReadAllText($claude)-ceq$section)
[pscustomobject]@{outcome=$(if($current){'current'}else{'failed'});exitCode=$(if($current){0}else{1});failureDetails=@()}|ConvertTo-Json -Compress;exit $(if($current){0}else{1})
'@
$fixtureInstaller = @'
[CmdletBinding()]param([string]$RepositoryRoot,[string]$CodexHome,[string]$SourceCommit,[string]$ExpectedCurrentCommit,[string]$ExpectedUpdateMode,[string]$ExpectedUpdateChannel,[string]$ExpectedUpdateRef,[string]$ExpectedCurrentGeneration,[string]$WriterSchema)
$runtime=Join-Path $CodexHome 'hooks/ai-instructions-runtime';[void][IO.Directory]::CreateDirectory($runtime)
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-ai-instructions-updater.psm1') -Destination (Join-Path $runtime 'ai-instructions-updater.psm1') -Force
[void][IO.Directory]::CreateDirectory((Join-Path $runtime 'catalog'))
foreach($leaf in @('skills-catalog.json','skills-catalog-lock.json')){Copy-Item -LiteralPath (Join-Path $RepositoryRoot "catalog/$leaf") -Destination (Join-Path $runtime "catalog/$leaf") -Force}
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-source.zip') -Destination (Join-Path $runtime 'fixture-source.zip') -Force
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-skills-source-retrieval.psm1') -Destination (Join-Path $runtime 'skills-source-retrieval.psm1') -Force
[void][IO.Directory]::CreateDirectory((Join-Path $CodexHome 'hooks'))
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/fixture-update-agent-environment.ps1') -Destination (Join-Path $CodexHome 'hooks/update-agent-environment.ps1') -Force
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'instructions/common/bootstrap-section.md') -Destination (Join-Path $runtime 'bootstrap-section.md') -Force
$configuration=[pscustomobject][ordered]@{schemaVersion=5;catalog=[pscustomobject]@{repository='https://example.com/catalog.git';ref=$SourceCommit};updates=[pscustomobject]@{mode='notify-only';channel='protected-branch';ref='main'};projections=[pscustomobject]@{user=@('user-agents','user-claude');project=@()}}
[IO.File]::WriteAllText((Join-Path $CodexHome 'ai-instructions-sync.json'),($configuration|ConvertTo-Json -Depth 8 -Compress))
[IO.File]::WriteAllText((Join-Path $runtime 'runtime-bundle.json'),('{"schemaVersion":3,"commit":"'+$SourceCommit+'"}'))
'@
[IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-ai-instructions-updater.psm1'),$fixtureUpdater,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-update-agent-environment.ps1'),$fixtureCoordinator,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/install-ai-instructions-bootstrap.ps1'),$fixtureInstaller,[Text.UTF8Encoding]::new($false))
[void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'catalog'))
Copy-Item (Join-Path $script:UnixRepositoryRoot 'catalog/skills-catalog.json') (Join-Path $script:UnixRepo 'catalog/skills-catalog.json')
Copy-Item (Join-Path $script:UnixRepositoryRoot 'scripts/skills-selection.psm1') (Join-Path $script:UnixRepo 'scripts/skills-selection.psm1')
# Match the native CloudT fixtures: keep real cache publication and replace only
# remote acquisition with a local ZIP whose bytes are bound by every lock source.
# The setup process already loads platform-runtime from the bound fixture files.
$fixtureZip=Join-Path $script:UnixRepo 'scripts/fixture-source.zip'
$zipStream=[IO.File]::Create($fixtureZip)
$zip=[IO.Compression.ZipArchive]::new($zipStream,[IO.Compression.ZipArchiveMode]::Create,$false)
try{
    $writer=[IO.StreamWriter]::new($zip.CreateEntry('fixture-source/README.md').Open())
    try{$writer.Write('Local setup source fixture')}finally{$writer.Dispose()}
}finally{$zip.Dispose();$zipStream.Dispose()}
$fixtureLock=Get-Content -Raw (Join-Path $script:UnixRepositoryRoot 'catalog/skills-catalog-lock.json')|ConvertFrom-Json
$fixtureSourceHash=(Get-FileHash -LiteralPath $fixtureZip -Algorithm SHA256).Hash.ToLowerInvariant()
foreach($source in $fixtureLock.sources){$source.archiveSha256=$fixtureSourceHash}
[IO.File]::WriteAllText((Join-Path $script:UnixRepo 'catalog/skills-catalog-lock.json'),($fixtureLock|ConvertTo-Json -Depth 30))
$localRetrieval=@'
function Get-SkillsSourceArchives {
    param($Plan,[string]$DestinationRoot,[hashtable]$LocalArchiveOverrides=@{})
    $result=@{}
    foreach($source in $Plan.Sources){
        $destination=Join-Path $DestinationRoot ($source.id+'.zip')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture-source.zip') -Destination $destination
        $result[[string]$source.id]=$destination
    }
    return $result
}
'@
[IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/fixture-skills-source-retrieval.psm1'),([IO.File]::ReadAllText((Join-Path $script:UnixRepositoryRoot 'scripts/skills-source-retrieval.psm1'))+"`n"+$localRetrieval))
[void][IO.Directory]::CreateDirectory((Join-Path $script:UnixRepo 'instructions/common'))
Copy-Item (Join-Path $script:UnixRepositoryRoot 'instructions/common/bootstrap-section.md') (Join-Path $script:UnixRepo 'instructions/common/bootstrap-section.md')
& git -C $script:UnixRepo init -q 2>$null | Out-Null
$script:UnixCommits = @{}
foreach ($kind in @('runtime','symlink','parent','absolute','hardlink','device')) {
    $policy = [IO.File]::ReadAllText((Join-Path $script:UnixRepositoryRoot 'scripts/setup-agent-environment.policy.json')) | ConvertFrom-Json
    $policy.powerShell.version = $script:UnixVersion
    foreach ($asset in @($policy.powerShell.assets)) {
        $asset.name = if ($asset.rid.StartsWith('win-')) { "PowerShell-$($script:UnixVersion)-$($asset.rid).zip" } else { "powershell-$($script:UnixVersion)-$($asset.rid).tar.gz" }
        if ($asset.rid -ceq $script:UnixRid) { $asset.sha256 = $script:UnixArchives[$kind].Sha256 }
    }
    [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.json'),($policy | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $script:UnixRepo 'scripts/setup-agent-environment.policy.tsv'),(ConvertTo-AgentEnvironmentSetupPolicyTsv $policy),[Text.UTF8Encoding]::new($false))
    & git -C $script:UnixRepo add -A 2>$null | Out-Null
    & git -C $script:UnixRepo -c user.name=setup-test -c user.email=setup-test@example.invalid commit -q --allow-empty -m $kind 2>$null | Out-Null
    $script:UnixCommits[$kind] = [string](& git -C $script:UnixRepo rev-parse HEAD)
}
& git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null
$script:UnixShell = Join-Path $script:UnixRepo 'scripts/setup-agent-environment.sh'
$script:UnixSentinel = Join-Path $script:UnixRoot 'outside-sentinel'
[IO.File]::WriteAllText($script:UnixSentinel,'sentinel')

function New-UnixHome {
    param([string]$Name,[string]$Kind='runtime',[switch]$WithoutCache)
    $userHome = Join-Path $script:UnixRoot "home-$Name"
    [void][IO.Directory]::CreateDirectory($userHome)
    [IO.File]::SetUnixFileMode($userHome,[IO.UnixFileMode]448)
    if (-not $WithoutCache) {
        $cache = Join-Path $userHome '.local/share/ai-instructions-setup/cache'
        [void][IO.Directory]::CreateDirectory($cache)
        foreach ($relative in @('.local','.local/share','.local/share/ai-instructions-setup','.local/share/ai-instructions-setup/cache')) {
            [IO.File]::SetUnixFileMode((Join-Path $userHome $relative),[IO.UnixFileMode]448)
        }
        Copy-Item -LiteralPath $script:UnixArchives[$Kind].Path -Destination (Join-Path $cache $script:UnixAssetName)
        [IO.File]::SetUnixFileMode((Join-Path $cache $script:UnixAssetName),[IO.UnixFileMode]384)
    }
    return $userHome
}

function Invoke-UnixSetup {
    param([string]$UserHome,[string[]]$Arguments,[string]$Kind='runtime',[hashtable]$Environment=@{},[string]$ExpectedCommit=$script:UnixCommits[$Kind],[switch]$NoCheckout,[switch]$UnsetHome,[string]$EntryPath=$script:UnixShell)
    if (-not $NoCheckout) { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits[$Kind] 2>$null | Out-Null }
    $start = [Diagnostics.ProcessStartInfo]::new('sh')
    foreach ($argument in @($EntryPath,'--expected-commit',$ExpectedCommit) + $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
    if($UnsetHome){[void]$start.Environment.Remove('HOME')}else{$start.Environment['HOME'] = $UserHome}
    # Any accidental network use fails fast instead of reaching the internet.
    $start.Environment['HTTPS_PROXY'] = 'http://127.0.0.1:9'
    [void]$start.Environment.Remove('CODEX_HOME')
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Close()
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(900000)) { $process.Kill($true); throw 'Shell setup fixture run timed out.' }
        $process.WaitForExit()
        $lines = @($stdoutTask.Result.Split("`n") | Where-Object { $_.Length -gt 0 })
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; Json = $(if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }) }
    } finally { $process.Dispose() }
}

function Invoke-UnixSetupPowerShellChild {
    param(
        [Parameter(Mandatory=$true)][string]$UserHome,
        [Parameter(Mandatory=$true)][ValidateSet('Prepare','Offline')][string]$Mode,
        [hashtable]$Environment=@{},
        [string]$ExpectedCommit=$script:UnixCommits['runtime'],
        [switch]$NoCheckout,
        [string]$EntryPath=(Join-Path $script:UnixRepo 'scripts/setup-agent-environment.ps1')
    )
    if (-not $NoCheckout) { & git -C $script:UnixRepo checkout -q --detach $script:UnixCommits['runtime'] 2>$null | Out-Null }
    $archive = Join-Path $UserHome ".local/share/ai-instructions-setup/cache/$($script:UnixAssetName)"
    $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$EntryPath,"-$Mode",'-ExpectedCommit',$ExpectedCommit,'-ArchivePath',$archive)) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    $start.Environment['HOME']=$UserHome;[void]$start.Environment.Remove('CODEX_HOME')
    foreach($key in $Environment.Keys){$start.Environment[$key]=[string]$Environment[$key]}
    $process=[Diagnostics.Process]::Start($start)
    $process.StandardInput.Close()
    try{
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(900000)){$process.Kill($true);throw 'PowerShell setup fixture run timed out.'}
        $process.WaitForExit();$lines=@($stdoutTask.Result.Split("`n")|Where-Object{$_.Length -gt 0})
        return [pscustomobject]@{ExitCode=$process.ExitCode;Lines=$lines;Stdout=$stdoutTask.Result;Stderr=$stderrTask.Result;Json=$(if($lines.Count -eq 1){$lines[0]|ConvertFrom-Json}else{$null})}
    }finally{$process.Dispose()}
}

function Assert-UnixPrivatePath {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Mode)
    $lease=$null;$parent=$null
    try {
        if([IO.Directory]::Exists($Path)){$lease=Open-PlatformDirectory -Root $Path -RootOnly}
        else{
            $parent=Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($Path)) -RootOnly
            $lease=Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($Path)) -Access Read -CreateMode OpenExisting
        }
        $permissions=Get-PlatformPermissions -Lease $lease
        ([string]$permissions.mode).TrimStart('0') | Should BeExactly $Mode.TrimStart('0')
        [string]$permissions.uid | Should BeExactly $script:SetupTestUnixUid
    } finally {
        if($null -ne $lease){$lease.Dispose()}
        if($null -ne $parent){$parent.Dispose()}
    }
}

function Assert-UnixSetupLockReleased {
    param([Parameter(Mandatory=$true)][string]$SetupRoot)
    $setup=Open-PlatformDirectory -Root $SetupRoot -RootOnly
    try{$lock=Enter-PlatformLock -ParentLease $setup -Leaf 'setup.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero);$lock.Dispose()}
    finally{$setup.Dispose()}
}

function Assert-UnixSetupTransactionClean {
    param([Parameter(Mandatory=$true)][string]$SetupRoot)
    $store=Join-Path $SetupRoot '.ai-instructions-txn'
    $residue=@(Get-ChildItem -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {$_.Name -cin @('stage','displaced','journal.json')})
    $residue.Count | Should Be 0
    Test-Path -LiteralPath $store | Should Be $false
}

function New-UnixToolShim {
    param([string]$Name,[string[]]$Exclude=@(),[hashtable]$Replace=@{})
    $bin = Join-Path $script:UnixRoot "bin-$Name"
    [void][IO.Directory]::CreateDirectory($bin)
    foreach ($tool in @('uname','id','awk','sed','find','mkdir','rm','rmdir','chmod','env','dirname','cp','mktemp','git','tar','gzip','sha256sum','shasum','curl','wget','cat','ls','sh')) {
        if ($tool -in $Exclude) { continue }
        if ($Replace.ContainsKey($tool)) {
            $shim = Join-Path $bin $tool
            [IO.File]::WriteAllText($shim,"#!/bin/sh`n$($Replace[$tool])`n")
            [IO.File]::SetUnixFileMode($shim,[IO.UnixFileMode]448)
            continue
        }
        $source = @(Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($source.Count -eq 1) { [void][IO.File]::CreateSymbolicLink((Join-Path $bin $tool),$source[0].Source) }
    }
    return $bin
}
