# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PublicKeyPemPath,[Parameter(Mandatory)][string]$OutputPath)
$module=Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop
Assert-TrustAnchorInteractiveHost
$target=Assert-TrustAnchorKeyPath -Path $OutputPath -Purpose PublicOutput
$pem=[IO.File]::ReadAllText([IO.Path]::GetFullPath($PublicKeyPemPath),[Text.UTF8Encoding]::new($false,$true))
if($pem -notmatch '\A-----BEGIN PUBLIC KEY-----\r?\n' -or $pem -notmatch '\r?\n-----END PUBLIC KEY-----\s*\z' -or $pem -match 'PRIVATE KEY'){throw 'Only a PUBLIC KEY PEM without private-key content is supported.'}
$rsa=[Security.Cryptography.RSA]::Create();$lease=$null;$bytes=$null
try{$rsa.ImportFromPem($pem);Assert-TrustAnchorPublicKey $rsa;$bytes=ConvertTo-TrustAnchorCanonicalXml $rsa;$lease=& $module {param($t,$b) New-TrustAnchorKeyFile -PathEvidence $t -Bytes $b} $target $bytes;Get-TrustAnchorFingerprint $rsa}
finally{& $module {param($l) Close-TrustAnchorCreatedFile $l} $lease;if($null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$rsa.Dispose()}
