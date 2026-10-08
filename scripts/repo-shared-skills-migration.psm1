Set-StrictMode -Version Latest

function Get-RepoSkillSafePath {
    param([string]$Root, [string]$Relative)
    if ($Relative -cnotmatch '^\.agents/(?:skills/[a-z0-9][a-z0-9-]*/.+|catalog-skills\.manifest\.json)$' -or
        $Relative.Contains('\') -or @($Relative.Split('/') | Where-Object { $_ -in @('','.', '..') -or $_.Contains(':') }).Count) {
        throw 'Unsafe Skill inventory path.'
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $full = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Skill path escapes its root.' }
    $current = $full
    while ($current.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -Force -LiteralPath $current
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Skill inventory crosses a reparse point.' }
        }
        if ($current -ceq $rootPath) { break }
        $current = Split-Path -Parent $current
    }
    return $full
}

function Get-RepoSkillTreeFiles {
    param([string]$Root, [string]$SkillId)
    $prefix = ".agents/skills/$SkillId/"
    $skillRoot = Get-RepoSkillSafePath $Root ($prefix + 'SKILL.md')
    $skillRoot = Split-Path -Parent $skillRoot
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) { throw 'Skill root is missing.' }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($skillRoot)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -Force -LiteralPath $pending.Pop() -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Skill tree contains a reparse point.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $paths.Add($item.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')) }
        }
    }
    return @($paths | Sort-Object)
}

function Invoke-RepoSkillGit {
    param([string]$Repository, [string]$GitExecutable, [string[]]$Arguments)
    $output = & $GitExecutable -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Skill migration Git observation failed: $($Arguments[0])" }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-RepoSkillMigrationGitState {
    param([string]$Repository, [string]$GitExecutable)
    $head = (Invoke-RepoSkillGit $Repository $GitExecutable @('rev-parse','HEAD')) -join ''
    $index = (Invoke-RepoSkillGit $Repository $GitExecutable @('rev-parse','--git-path','index')) -join ''
    if (-not [IO.Path]::IsPathRooted($index)) { $index = Join-Path $Repository $index }
    if ((Get-Item -Force -LiteralPath $index).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Git index is a reparse point.' }
    $indexHash = (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash.ToLowerInvariant()
    $tracked = @()
    foreach ($gitArguments in @(@('ls-files','-z'), @('ls-tree','-rz','--name-only','HEAD'))) {
        $tracked += @(((Invoke-RepoSkillGit $Repository $GitExecutable $gitArguments) -join "`n").Split([char]0) | Where-Object { $_ })
    }
    return [pscustomobject]@{head=$head; indexSha256=$indexHash; tracked=$tracked}
}

function Get-UserSharedSkillObservation {
    param([string]$UserHome, [string]$CatalogId)
    $path = Get-RepoSkillSafePath $UserHome '.agents/catalog-skills.manifest.json'
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json
    Assert-UserSkillsManagedManifest -Manifest $manifest
    if ([string]$manifest.catalogId -cne $CatalogId) { throw 'USER Catalog identity differs.' }
    if (Test-Path -LiteralPath (Join-Path $UserHome '.agents/update-agent-environment.recovery.json')) { throw 'USER transaction requires recovery.' }
    return [pscustomobject]@{manifest=$manifest; sha256=$hash}
}

function Get-UserSharedSkillEvidence {
    param([string]$UserHome, [object]$Observation, [object]$Source)
    $id = [string]$Source.id
    if ($null -eq $Source.PSObject.Properties['files'] -or @($Source.files).Count -eq 0) { throw 'Trusted immutable source inventory unavailable.' }
    $userEntries = @($Observation.manifest.files | Where-Object { [string]$_.skillId -ceq $id })
    $sourcePaths = @($Source.files | ForEach-Object { [string]$_.targetPath } | Sort-Object)
    if ($sourcePaths -cnotcontains ".agents/skills/$id/SKILL.md" -or
        ($sourcePaths -join "`n") -cne ((@($userEntries | ForEach-Object targetPath | Sort-Object)) -join "`n") -or
        ((Get-RepoSkillTreeFiles $UserHome $id) -join "`n") -cne ($sourcePaths -join "`n")) { throw 'USER immutable source inventory is incomplete or contains extra files.' }
    $evidence = @()
    foreach ($entry in $userEntries) {
        if ([string]$entry.sourceId -cne [string]$Source.sourceId -or [string]$entry.sourceRepository -cne [string]$Source.sourceRepository -or
            [string]$entry.sourceCommit -cne [string]$Source.sourceCommit -or [string]$entry.sourceVersion -cne [string]$Source.sourceVersion) { throw 'USER immutable source identity/version differs; repair or update USER explicitly.' }
        $sourceFile = @($Source.files | Where-Object { $_.targetPath -ceq $entry.targetPath })
        $full = Get-RepoSkillSafePath $UserHome $entry.targetPath
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($sourceFile.Count -ne 1 -or $hash -cne [string]$entry.sha256 -or $hash -cne [string]$sourceFile[0].sha256) { throw 'USER integrity verification failed.' }
        $evidence += [pscustomobject]@{root=$UserHome; path=$entry.targetPath; sha256=$hash}
    }
    return $evidence
}

function Get-UserSharedSkillsReadiness {
    param([string]$UserHome, [string]$CatalogId, [AllowEmptyCollection()][object[]]$TrustedSkills)
    foreach ($source in $TrustedSkills) {
        $reason = $null
        try {
            $observation = Get-UserSharedSkillObservation $UserHome $CatalogId
            Get-UserSharedSkillEvidence $UserHome $observation $source | Out-Null
        }
        catch { $reason = $_.Exception.Message }
        [pscustomobject]@{id=$source.id; ready=($null -eq $reason); reason=$reason}
    }
}

function Get-RepoSharedSkillsMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][object]$Manifest,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$TrustedSkills,
        [Parameter(Mandatory=$true)][string]$UserHome,
        [string]$GitExecutable='git'
    )
    $results = New-Object 'System.Collections.Generic.List[object]'
    $user = $null
    $userError = 'USER installation unavailable; repair USER Skills before migration.'
    $userManifestHash = $null
    try {
        $userObservation = Get-UserSharedSkillObservation $UserHome $Manifest.catalogId
        $user = $userObservation.manifest
        $userManifestHash = $userObservation.sha256
    }
    catch { $user = $null; $userError = "USER installation unavailable; repair USER Skills: $($_.Exception.Message)" }
    $gitState = Get-RepoSkillMigrationGitState $Repository $GitExecutable
    $ids = @($Manifest.files | Where-Object { [string]$_.targetPath -like '.agents/skills/*' } | ForEach-Object { ([string]$_.targetPath).Split('/')[2] } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $prefix = ".agents/skills/$id/"
        $entries = @($Manifest.files | Where-Object { ([string]$_.targetPath).StartsWith($prefix,[StringComparison]::Ordinal) })
        $observations = @()
        $reason = $null
        try {
            if ($Manifest.schemaVersion -notin @(2,3)) { throw 'Historical manifest has no per-file source ownership.' }
            if ($null -eq $user) { throw $userError }
            $trusted = @($TrustedSkills | Where-Object { [string]$_.id -ceq $id })
            if ($trusted.Count -ne 1 -or $null -eq $trusted[0].PSObject.Properties['files'] -or @($trusted[0].files).Count -eq 0) { throw 'Trusted immutable source inventory unavailable.' }
            $source = $trusted[0]
            $observations += @(Get-UserSharedSkillEvidence $UserHome $userObservation $source)
            foreach ($entry in $entries) {
                if ([string]$entry.artifactType -cne 'skill' -or [string]$entry.artifactId -cne $id -or
                    [string]$entry.sourceId -cne [string]$source.sourceId -or [string]$entry.sourceRepository -cne [string]$source.sourceRepository) { throw 'REPO shared source ownership is unknown.' }
            }
            if (@($entries | Where-Object { $_.targetPath -ceq ($prefix + 'SKILL.md') }).Count -ne 1 -or
                @($entries | ForEach-Object sourceCommit | Sort-Object -Unique).Count -ne 1 -or
                @($entries | ForEach-Object sourceVersion | Sort-Object -Unique).Count -ne 1) { throw 'REPO Skill ownership is incomplete or mixed.' }
            if (@($gitState.tracked | Where-Object { $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Tracked or staged project Skill is protected.' }
            if (((Get-RepoSkillTreeFiles $Repository $id) -join "`n") -cne ((@($entries | ForEach-Object targetPath | Sort-Object)) -join "`n")) { throw 'REPO Skill has extra or missing files.' }
            foreach ($entry in $entries) {
                $full = Get-RepoSkillSafePath $Repository $entry.targetPath
                $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($hash -cne [string]$entry.sha256) { throw 'Customized REPO Skill is protected.' }
                & $GitExecutable -C $Repository check-ignore --quiet -- $entry.targetPath
                if ($LASTEXITCODE -ne 0) { throw 'REPO Skill is not ignored and untracked.' }
                $observations += [pscustomobject]@{root=$Repository; path=$entry.targetPath; sha256=$hash}
            }

        }
        catch { $reason = $_.Exception.Message }
        $results.Add([pscustomobject]@{id=$id; removable=($null -eq $reason); reason=$reason; entries=$entries
            observations=$observations; userHome=$UserHome; userManifestSha256=$userManifestHash; gitState=$gitState})
    }
    return @($results.ToArray())
}

function Assert-RepoSharedSkillsMigrationEvidence {
    param([string]$Repository, [object]$Skill, [string[]]$RemovedPaths=@(), [string]$GitExecutable='git')
    $current = Get-RepoSkillMigrationGitState $Repository $GitExecutable
    if ($current.head -cne $Skill.gitState.head -or $current.indexSha256 -cne $Skill.gitState.indexSha256) { throw 'Skill migration Git state changed concurrently.' }
    $userPath = Get-RepoSkillSafePath $Skill.userHome '.agents/catalog-skills.manifest.json'
    if ((Get-FileHash -LiteralPath $userPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Skill.userManifestSha256 -or
        (Test-Path -LiteralPath (Join-Path $Skill.userHome '.agents/update-agent-environment.recovery.json'))) { throw 'USER state changed concurrently before Skill migration.' }
    foreach ($observation in $Skill.observations) {
        if ($observation.root -ceq $Repository -and $RemovedPaths -ccontains [string]$observation.path) { continue }
        $full = Get-RepoSkillSafePath $observation.root $observation.path
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $observation.sha256) { throw 'Skill migration file changed concurrently.' }
        if ($observation.root -ceq $Repository) {
            & $GitExecutable -C $Repository check-ignore --quiet -- $observation.path
            if ($LASTEXITCODE -ne 0) { throw 'Skill migration ignore state changed concurrently.' }
        }
    }
    foreach ($root in @($Repository, $Skill.userHome)) {
        $expected = @($Skill.observations | Where-Object { $_.root -ceq $root -and -not ($root -ceq $Repository -and $RemovedPaths -ccontains [string]$_.path) } | ForEach-Object path | Sort-Object)
        if (((Get-RepoSkillTreeFiles $root $Skill.id) -join "`n") -cne ($expected -join "`n")) { throw 'Skill migration inventory changed concurrently.' }
    }
}

Export-ModuleMember -Function Get-RepoSharedSkillsMigrationPlan, Assert-RepoSharedSkillsMigrationEvidence, Get-RepoSkillMigrationGitState, Get-UserSharedSkillsReadiness
