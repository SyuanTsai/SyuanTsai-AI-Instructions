# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]$KeyId,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$PublicKeyXmlPath
)
$module=Import-Module (Join-Path $PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop
Assert-TrustAnchorInteractiveHost
$privateTarget=Assert-TrustAnchorKeyPath -Path $PrivateKeyPath -Purpose PrivateKey
$publicTarget=Assert-TrustAnchorKeyPath -Path $PublicKeyXmlPath -Purpose PublicOutput
$password=$null;$rsa=$null;$privateBytes=$null;$privateLease=$null;$publicLease=$null
try{
    $password=Read-TrustAnchorPassword -Confirm
    $rsa=[Security.Cryptography.RSA]::Create(3072);Assert-TrustAnchorPublicKey $rsa
    $pem=Export-TrustAnchorEncryptedPrivateKey -Rsa $rsa -Password $password
    $privateBytes=[Text.UTF8Encoding]::new($false).GetBytes($pem+$(if($pem.EndsWith("`n")){''}else{"`n"}))
    $privateLease=& $module {param($target,$bytes) New-TrustAnchorKeyFile -PathEvidence $target -Bytes $bytes} $privateTarget $privateBytes
    try{
        $publicBytes=ConvertTo-TrustAnchorCanonicalXml $rsa
        try{$publicLease=& $module {param($target,$bytes) New-TrustAnchorKeyFile -PathEvidence $target -Bytes $bytes} $publicTarget $publicBytes}
        finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($publicBytes)}
    }catch{& $module {param($lease) Remove-TrustAnchorCreatedFile $lease} $privateLease;$privateLease=$null;throw}
    $fingerprint=Get-TrustAnchorFingerprint $rsa
    [pscustomobject][ordered]@{keyId=$KeyId;xmlSha256=$fingerprint.xmlSha256;spkiSha256=$fingerprint.spkiSha256}
}finally{
    & $module {param($lease) Close-TrustAnchorCreatedFile $lease} $publicLease
    & $module {param($lease) Close-TrustAnchorCreatedFile $lease} $privateLease
    if($null-ne$privateBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateBytes)}
    if($null-ne$rsa){$rsa.Dispose()};if($null-ne$password){$password.Dispose()}
}
