[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'test-syp101-production-smoke.ps1') @PSBoundParameters
