# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]$KeyId,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$PublicKeyXmlPath
)
$module=Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop
try {
    & $module {param($id,$privatePath,$publicPath) Assert-TrustAnchorInteractiveHost;Invoke-NewTrustAnchorKeyPairAction -KeyId $id -PrivateKeyPath $privatePath -PublicKeyXmlPath $publicPath} $KeyId $PrivateKeyPath $PublicKeyXmlPath
} catch {
    [Console]::Error.WriteLine($_.FullyQualifiedErrorId)
    throw
}
