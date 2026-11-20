# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# This helper runs inside the platform runtime's owned process boundary. Its Git
# child inherits the Windows Job or Unix process group, while stdout is copied
# without text decoding so callers can inspect arbitrary tree paths and blobs.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GitPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$GitArgumentsBase64
)

$ErrorActionPreference='Stop'
$process=$null;$output=$null;$stderr=$null
try{
    $json=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($GitArgumentsBase64))
    $arguments=@($json|ConvertFrom-Json)
    if(@($arguments|Where-Object{$null-eq$_-or$_-isnot[string]}).Count-ne0){throw 'Git argument payload is invalid.'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[IO.Path]::GetFullPath($GitPath)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $arguments){[void]$start.ArgumentList.Add([string]$argument)}
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[void]$start.Environment.Remove($name)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $output=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    [void]$process.Start()
    $stdoutCopy=$process.StandardOutput.BaseStream.CopyToAsync($output)
    $stderr=[Console]::OpenStandardError()
    $stderrCopy=$process.StandardError.BaseStream.CopyToAsync($stderr)
    $process.WaitForExit()
    $stdoutCopy.GetAwaiter().GetResult();$stderrCopy.GetAwaiter().GetResult();$output.Flush($true)
    exit $process.ExitCode
}finally{
    if($null-ne$output){$output.Dispose()}
    if($null-ne$stderr){$stderr.Dispose()}
    if($null-ne$process){$process.Dispose()}
}
