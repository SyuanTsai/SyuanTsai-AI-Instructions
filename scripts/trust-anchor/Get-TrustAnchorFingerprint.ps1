# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding(DefaultParameterSetName='Xml')]
param(
    [Parameter(Mandatory,ParameterSetName='Xml')][string]$PublicKeyXmlPath,
    [Parameter(Mandatory,ParameterSetName='Pem')][string]$PublicKeyPemPath,
    [Parameter(Mandatory,ParameterSetName='Private')][string]$EncryptedPrivateKeyPath
)
$module=Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop
& $module {param($xmlPath,$pemPath,$privatePath) Assert-TrustAnchorInteractiveHost;Invoke-GetTrustAnchorFingerprintAction -PublicKeyXmlPath $xmlPath -PublicKeyPemPath $pemPath -EncryptedPrivateKeyPath $privatePath} $PublicKeyXmlPath $PublicKeyPemPath $EncryptedPrivateKeyPath
