[CmdletBinding()]
param(
    [string] $EventName,
    [string] $BaseSha,
    [string] $HeadRef = 'HEAD',
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputPath,
    [switch] $DefineFunctionsOnly
)

function Test-UnixCoreRelevantPaths {
    param([string[]] $Paths)

    $excludedMarkdownDirectories = @(
        'docs/delivery/' # Delivery notes; authority and shard tests have no content dependency here.
        'delivery/'      # Delivery reports; executable and data artifacts stay relevant.
    )
    if ($Paths.Count -eq 0) { return $true }

    foreach ($path in $Paths) {
        $normalized = $path.Replace('\', '/')
        if ($normalized.Contains('..') -or -not $normalized.EndsWith('.md', [StringComparison]::Ordinal)) {
            return $true
        }
        $excluded = $false
        foreach ($directory in $excludedMarkdownDirectories) {
            if ($normalized.StartsWith($directory, [StringComparison]::Ordinal)) {
                $excluded = $true
                break
            }
        }
        if (-not $excluded) { return $true }
    }
    return $false
}

function Invoke-UnixCoreScopeGit {
    param([string] $Root, [string[]] $Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::Start($startInfo)
    $buffer = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Git exited with code $($process.ExitCode)." }
        return [Text.UTF8Encoding]::new($false, $true).GetString($buffer.ToArray())
    }
    finally {
        $buffer.Dispose()
        $process.Dispose()
    }
}

function Get-UnixCoreChangeScope {
    param([string] $EventName, [string] $BaseSha, [string] $HeadRef, [string] $RepositoryRoot)

    if ($EventName -cne 'pull_request' -or [string]::IsNullOrWhiteSpace($BaseSha)) { return $true }

    try {
        $diffArguments = @('--no-renames', '--ignore-submodules=none', '--end-of-options', $BaseSha, $HeadRef, '--')
        # Read NUL-delimited paths so unusual filenames cannot be mistaken for multiple edits.
        $diff = Invoke-UnixCoreScopeGit -Root $RepositoryRoot -Arguments (
            @('diff', '--name-only', '-z') + $diffArguments)
        if (-not $diff.EndsWith([string][char]0, [StringComparison]::Ordinal)) { return $true }
        $paths = $diff.Substring(0, $diff.Length - 1).Split([char]0)
        if (Test-UnixCoreRelevantPaths $paths) { return $true }

        # The licensing test inventories all tracked paths. Skip only modifications.
        Invoke-UnixCoreScopeGit -Root $RepositoryRoot -Arguments (
            @('diff', '--quiet', '--diff-filter=m') + $diffArguments) | Out-Null
        return $false
    }
    catch {
        Write-Verbose "Unix Core scope could not be determined: $_"
        return $true
    }
}

if ($DefineFunctionsOnly) { return }

$relevant = Get-UnixCoreChangeScope -EventName $EventName -BaseSha $BaseSha -HeadRef $HeadRef -RepositoryRoot $RepositoryRoot
if ($OutputPath) {
    $value = $relevant.ToString().ToLowerInvariant()
    [IO.File]::AppendAllText($OutputPath, "relevant=$value`n", [Text.UTF8Encoding]::new($false))
}
$relevant
