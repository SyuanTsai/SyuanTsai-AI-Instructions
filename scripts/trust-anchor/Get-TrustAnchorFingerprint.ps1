# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding(DefaultParameterSetName='Xml')]
param(
    [Parameter(Mandatory,ParameterSetName='Xml')][string]$PublicKeyXmlPath,
    [Parameter(Mandatory,ParameterSetName='Pem')][string]$PublicKeyPemPath,
    [Parameter(Mandatory,ParameterSetName='Private')][string]$EncryptedPrivateKeyPath
)
$module=Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop
Assert-TrustAnchorInteractiveHost
$rsa=$null;$password=$null;$privateBytes=$null
try{
    if($PSCmdlet.ParameterSetName -ceq 'Xml'){$rsa=& $module {param($p) Import-TrustAnchorPublicXml ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($p)))} $PublicKeyXmlPath}
    elseif($PSCmdlet.ParameterSetName -ceq 'Pem'){$pem=[IO.File]::ReadAllText([IO.Path]::GetFullPath($PublicKeyPemPath),[Text.UTF8Encoding]::new($false,$true));if($pem -notmatch '\A-----BEGIN PUBLIC KEY-----' -or $pem -match 'PRIVATE KEY'){throw 'Only a PUBLIC KEY PEM is supported.'};$rsa=[Security.Cryptography.RSA]::Create();$rsa.ImportFromPem($pem)}
    else{$password=Read-TrustAnchorPassword;$privateBytes=Open-TrustAnchorPrivateKey $EncryptedPrivateKeyPath;$pem=[Text.UTF8Encoding]::new($false,$true).GetString($privateBytes);$rsa=Import-TrustAnchorEncryptedPrivateKey -Pem $pem -Password $password}
    Assert-TrustAnchorPublicKey $rsa;Get-TrustAnchorFingerprint $rsa
}finally{if($null-ne$privateBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateBytes)};if($null-ne$rsa){$rsa.Dispose()};if($null-ne$password){$password.Dispose()}}
