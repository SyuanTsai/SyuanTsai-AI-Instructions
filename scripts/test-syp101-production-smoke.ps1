[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-SmokeGit {
    param([string]$Repository,[string[]]$Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Get-RawSha256 {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ManagedSnapshot {
    param([string]$TargetRoot,[object]$Manifest)
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Manifest.files | Sort-Object targetPath)) {
        $relative = [string]$entry.targetPath
        $path = Join-Path $TargetRoot $relative.Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Managed smoke file is missing: $relative" }
        $rows.Add("$relative`t$(Get-RawSha256 -Path $path)")
    }
    $manifestPath = Join-Path $TargetRoot '.codex\ai-instructions.manifest.json'
    $rows.Add(".codex/ai-instructions.manifest.json`t$(Get-RawSha256 -Path $manifestPath)")
    return @($rows.ToArray())
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = ((Invoke-SmokeGit -Repository (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('syp101-production-smoke-' + [Guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $tempRoot '.codex'
$targetRoot = Join-Path $tempRoot 'target'

try {
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('init','--quiet') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','user.name','SYP101 Production Smoke') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','user.email','syp101-smoke@example.test') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('remote','add','origin','https://example.com/smoke/branch-independent-target.git') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $targetRoot 'README.md'),"# SYP101 production smoke`n",(New-Object System.Text.UTF8Encoding($false)))
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('add','--','README.md') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','initial smoke target') | Out-Null
    $initialHead = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()

    & (Join-Path $repositoryRootPath 'scripts\install-ai-instructions-bootstrap.ps1') -RepositoryRoot $repositoryRootPath -CodexHome $codexHome
    $hook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) { throw 'Production smoke installer did not create the installed launcher.' }

    & $hook -TargetRoot $targetRoot

    $manifestPath = Join-Path $targetRoot '.codex\ai-instructions.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Production smoke did not create manifest v2.' }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2) { throw "Production smoke expected manifest schemaVersion 2; actual: $($manifest.schemaVersion)" }
    $skillEntries = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })
    if ($skillEntries.Count -lt 1) { throw 'Production smoke selected no real external Skills.' }

    $beforeSnapshot = @(Get-ManagedSnapshot -TargetRoot $targetRoot -Manifest $manifest)
    $beforeStatus = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('status','--porcelain')))
    $beforeStashes = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('stash','list','--format=%H%x00%gs')))
    if (@($beforeStashes | Where-Object { $_ -match 'PersonalAgent' }).Count -ne 1) {
        throw 'Production smoke expected exactly one retained PersonalAgent recovery stash after the first sync.'
    }
    $headAfterFirst = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if ($headAfterFirst -cne $initialHead) { throw 'Branch-independent production smoke unexpectedly committed the bootstrap.' }

    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','core.autocrlf','true') | Out-Null
    & $hook -TargetRoot $targetRoot

    $manifestAfter = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $afterSnapshot = @(Get-ManagedSnapshot -TargetRoot $targetRoot -Manifest $manifestAfter)
    $afterStatus = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('status','--porcelain')))
    $afterStashes = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('stash','list','--format=%H%x00%gs')))

    if (($beforeSnapshot -join "`n") -cne ($afterSnapshot -join "`n")) { throw 'Second production smoke sync changed managed file bytes.' }
    if (($beforeStatus -join "`n") -cne ($afterStatus -join "`n")) { throw 'Second production smoke sync changed working-tree status.' }
    if (($beforeStashes -join "`n") -cne ($afterStashes -join "`n")) { throw 'Second production smoke sync replaced or added a PersonalAgent stash.' }
    $headAfterSecond = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if ($headAfterSecond -cne $initialHead) { throw 'Second branch-independent production smoke unexpectedly committed changes.' }

    Write-Output "SYP101 production smoke passed with $($skillEntries.Count) real external Skill manifest entries."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
