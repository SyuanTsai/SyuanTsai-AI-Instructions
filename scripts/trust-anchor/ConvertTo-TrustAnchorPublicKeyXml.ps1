# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PublicKeyPemPath,[Parameter(Mandatory)][string]$OutputPath)
$module=Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -Force -ErrorAction Stop
try {
    & $module {param($inputPath,$outputPath) Assert-TrustAnchorInteractiveHost;Invoke-ConvertToTrustAnchorPublicKeyXmlAction -PublicKeyPemPath $inputPath -OutputPath $outputPath} $PublicKeyPemPath $OutputPath
} catch {
    [Console]::Error.WriteLine($_.FullyQualifiedErrorId)
    throw
}
