# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $Commit,
    [Parameter(Mandatory)][ValidateSet('inventory', 'conversion')][string] $Stage,
    [string] $InventoryCommit,
    [Parameter(Mandatory)][string] $Manifest,
    [Parameter(Mandatory)][string] $RepositoryId,
    [Parameter(Mandatory)][string] $AuthorityRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ConsumerManifestClosure.psm1') -Force
$result = Get-ConsumerManifestClosure @PSBoundParameters
$result | ConvertTo-Json -Depth 100
if ($result.result -eq 'FAILED') {
    exit 20
}
