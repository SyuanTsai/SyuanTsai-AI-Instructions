[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = (Resolve-Path (Join-Path $scriptDir '..')).Path
$distDir = Join-Path $repoDir 'dist'
$parentDir = (Resolve-Path (Join-Path $repoDir '..')).Path

if (-not (Test-Path $distDir -PathType Container)) {
    Write-Error "dist directory not found at $distDir. Switch to a tool/* branch that provides dist/."
}

$files = Get-ChildItem -Path $distDir -File -Recurse -Force | Sort-Object FullName
if ($files.Count -eq 0) {
    Write-Host 'No files found in dist/ to install.'
    exit 0
}

$copied = 0
$skipped = 0
$overwritten = 0

foreach ($file in $files) {
    $relativePath = [System.IO.Path]::GetRelativePath($distDir, $file.FullName)
    $targetPath = Join-Path $parentDir $relativePath
    $targetDir = Split-Path -Parent $targetPath

    if ($DryRun) {
        if (Test-Path $targetPath -PathType Leaf) {
            if ($Force) {
                Write-Host "[DRY-RUN] overwrite: $relativePath"
            }
            else {
                Write-Host "[DRY-RUN] prompt overwrite: $relativePath"
            }
        }
        else {
            Write-Host "[DRY-RUN] copy: $relativePath"
        }
        continue
    }

    if (-not (Test-Path $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-Path $targetPath -PathType Leaf) {
        if ($Force) {
            Copy-Item -Path $file.FullName -Destination $targetPath -Force
            $overwritten++
        }
        else {
            $answer = Read-Host "Overwrite '$targetPath'? [y/N]"
            if ($answer -match '^(y|yes)$') {
                Copy-Item -Path $file.FullName -Destination $targetPath -Force
                $overwritten++
            }
            else {
                $skipped++
            }
        }
    }
    else {
        Copy-Item -Path $file.FullName -Destination $targetPath -Force
        $copied++
    }
}

if ($DryRun) {
    Write-Host "`nSummary (dry-run):"
    Write-Host '  copied:      preview only'
    Write-Host '  skipped:     preview only'
    Write-Host '  overwritten: preview only'
}
else {
    Write-Host "`nSummary:"
    Write-Host "  copied:      $copied"
    Write-Host "  skipped:     $skipped"
    Write-Host "  overwritten: $overwritten"
    Write-Host "  project dir: $parentDir"
}
