[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BindingPath,
    [Parameter(Mandatory = $true)] [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'AI-Instructions local execution is supported on Windows only; Linux, macOS, and WSL are unsupported.'
}
$modulePath = Join-Path $PSScriptRoot 'StandardEntryPointContract.psm1'

try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    [void](Assert-StandardEntryPointResult -ExpectedBindingPath $BindingPath -ResultPath $ResultPath)

    $module = Get-Module -Name StandardEntryPointContract
    $binding = & $module { $script:StandardEntryLastVerifiedBinding }
    if ($null -eq $binding) { throw 'STANDARD_ENTRY_INVALID|The module did not retain the validated binding summary.' }
    $runtime = $binding.runtime
    Write-Output ('Verified entry={0} candidate={1} authority={2} runtime={3}/{4}/{5}' -f `
        $binding.entryId, $binding.candidateRevision, $binding.authorityRevision, $runtime.os, $runtime.psEdition, $runtime.psVersion)
    exit 0
}
catch {
    [Console]::Error.WriteLine([string]$_.Exception.Message)
    exit 1
}
