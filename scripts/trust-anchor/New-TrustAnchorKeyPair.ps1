# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]$KeyId,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$PublicKeyXmlPath
)
$module=Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,'TrustAnchorPrivateKey.psm1')) -PassThru -Force -ErrorAction Stop
try {
    & $module {param($id,$privatePath,$publicPath) Assert-TrustAnchorInteractiveHost;Invoke-NewTrustAnchorKeyPairAction -KeyId $id -PrivateKeyPath $privatePath -PublicKeyXmlPath $publicPath} $KeyId $PrivateKeyPath $PublicKeyXmlPath
} catch {
    [Console]::Error.WriteLine($_.FullyQualifiedErrorId)
    throw
}
