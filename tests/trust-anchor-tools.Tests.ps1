# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:ModulePath=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'
$script:Module=Import-Module $script:ModulePath -PassThru -Force

if($null-eq('SyuanTsai.AIInstructions.TrustAnchor.Tests.CryptoProbe'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
namespace SyuanTsai.AIInstructions.TrustAnchor.Tests {
    public static class CryptoProbe {
        public static bool CanDecrypt(byte[] der, char[] password) {
            using (RSA rsa = RSA.Create()) { int read; rsa.ImportEncryptedPkcs8PrivateKey(password.AsSpan(), der, out read); return read == der.Length; }
        }
    }
}
'@
}

function Invoke-TrustAnchorModule {param([scriptblock]$Action,[object[]]$Arguments=@())& $script:Module $Action @Arguments}
function New-TestPassword {param([string]$Text=('fixture-password-'+('x'*20)))return ($Text|ConvertTo-SecureString -AsPlainText -Force)}
function Get-TestFailure {param([scriptblock]$Action)try{& $Action;throw 'Expected the action to fail.'}catch{return $_}}
function Read-TestEncryptedPrivateKeyProfile {
    param([Parameter(Mandatory)][string]$Pem)
    $body=(($Pem -split '\r?\n')|Where-Object{$_ -notmatch '^-----'}) -join '';[byte[]]$der=[Convert]::FromBase64String($body)
    try{
        $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($der),[Formats.Asn1.AsnEncodingRules]::DER)
        $outer=$reader.ReadSequence();$algorithm=$outer.ReadSequence();$pbes2Oid=$algorithm.ReadObjectIdentifier();$pbes2=$algorithm.ReadSequence();$algorithm.ThrowIfNotEmpty()
        $kdf=$pbes2.ReadSequence();$kdfOid=$kdf.ReadObjectIdentifier();$pbkdf2=$kdf.ReadSequence();$kdf.ThrowIfNotEmpty()
        [byte[]]$salt=$pbkdf2.ReadOctetString();$iterations=[int]$pbkdf2.ReadInteger();$keyLength=$null
        if($pbkdf2.HasData -and $pbkdf2.PeekTag().HasSameClassAndValue([Formats.Asn1.Asn1Tag]::Integer)){$keyLength=[int]$pbkdf2.ReadInteger()}
        $prf=$pbkdf2.ReadSequence();$prfOid=$prf.ReadObjectIdentifier();if($prf.HasData){$prf.ReadNull()};$prf.ThrowIfNotEmpty();$pbkdf2.ThrowIfNotEmpty()
        $cipher=$pbes2.ReadSequence();$cipherOid=$cipher.ReadObjectIdentifier();[byte[]]$iv=$cipher.ReadOctetString();$cipher.ThrowIfNotEmpty();$pbes2.ThrowIfNotEmpty()
        [byte[]]$encrypted=$outer.ReadOctetString();$outer.ThrowIfNotEmpty();$reader.ThrowIfNotEmpty()
        [pscustomobject]@{pbes2=$pbes2Oid;kdf=$kdfOid;iterations=$iterations;keyLength=$keyLength;prf=$prfOid;cipher=$cipherOid;saltLength=$salt.Length;ivLength=$iv.Length;encryptedLength=$encrypted.Length}
    }finally{foreach($value in @($salt,$iv,$encrypted,$der)){if($null-ne$value){[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)}}}
}
function Set-TestReadHostResponses {
    param([Security.SecureString[]]$Responses)
    $queue=[Collections.Queue]::new();foreach($response in $Responses){$queue.Enqueue($response)}
    Invoke-TrustAnchorModule {param($value)$script:TrustAnchorPasswordTestResponses=$value} @(,$queue)
}
function ConvertTo-TestUtf8Bytes {param([Parameter(Mandatory)][string]$Text)return ,([Text.UTF8Encoding]::new($false).GetBytes($Text))}
function New-TestShortSaltEncryptedPrivateKey {
    param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa,[Parameter(Mandatory)][byte[]]$PasswordBytes)
    [byte[]]$plain=$Rsa.ExportPkcs8PrivateKey();[byte[]]$salt=[byte[]](7);[byte[]]$iv=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($iv);$key=$null;$encrypted=$null;$der=$null;$aes=$null
    try{
        $key=[Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2($PasswordBytes,$salt,600000,[Security.Cryptography.HashAlgorithmName]::SHA256,32)
        $aes=[Security.Cryptography.Aes]::Create();$aes.Key=$key;$aes.IV=$iv;$aes.Mode=[Security.Cryptography.CipherMode]::CBC;$aes.Padding=[Security.Cryptography.PaddingMode]::PKCS7;$encryptor=$aes.CreateEncryptor();try{$encrypted=$encryptor.TransformFinalBlock($plain,0,$plain.Length)}finally{$encryptor.Dispose()}
        $writer=[Formats.Asn1.AsnWriter]::new([Formats.Asn1.AsnEncodingRules]::DER);[void]$writer.PushSequence();[void]$writer.PushSequence();$writer.WriteObjectIdentifier('1.2.840.113549.1.5.13');[void]$writer.PushSequence();[void]$writer.PushSequence();$writer.WriteObjectIdentifier('1.2.840.113549.1.5.12');[void]$writer.PushSequence();$writer.WriteOctetString($salt);$writer.WriteInteger(600000);[void]$writer.PushSequence();$writer.WriteObjectIdentifier('1.2.840.113549.2.9');$writer.WriteNull();$writer.PopSequence();$writer.PopSequence();$writer.PopSequence();[void]$writer.PushSequence();$writer.WriteObjectIdentifier('2.16.840.1.101.3.4.1.42');$writer.WriteOctetString($iv);$writer.PopSequence();$writer.PopSequence();$writer.PopSequence();$writer.WriteOctetString($encrypted);$writer.PopSequence();$der=$writer.Encode()
        [pscustomobject]@{Pem=[Security.Cryptography.PemEncoding]::WriteString('ENCRYPTED PRIVATE KEY',$der);Der=$der.Clone()}
    }finally{if($null-ne$aes){$aes.Dispose()};foreach($value in @($plain,$salt,$iv,$key,$encrypted,$der)){if($null-ne$value){[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)}}}
}
function Test-TrustAnchorCliGuardAst {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,[Parameter(Mandatory)][string]$ActionName)
    $blocks=@($Ast.FindAll({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Extent.Text -match 'Assert-TrustAnchorInteractiveHost'},$true));if($blocks.Count-ne1){return $false}
    $commands=@($blocks[0].ScriptBlock.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true));if($commands.Count-ne2){return $false}
    if($commands[0].GetCommandName()-cne'Assert-TrustAnchorInteractiveHost' -or $commands[1].GetCommandName()-cne$ActionName){return $false}
    if(@($blocks[0].ScriptBlock.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)).Count-ne0){return $false}
    return $true
}

Describe 'PR-K1 trust-anchor cryptography contract' {
    # Scenario: A fresh 3072-bit RSA key is exported and its EncryptedPrivateKeyInfo ASN.1 is parsed independently.
    # Purpose: Prove the artifact itself uses PBES2, PBKDF2-HMAC-SHA256, AES-256-CBC, and 600000 iterations.
    It 'UnitT01_exports_the_exact_encrypted_PKCS8_profile_and_round_trips' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$imported=$null
        try{
            $pem=Invoke-TrustAnchorModule {param($r,$p)Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password);$profile=Read-TestEncryptedPrivateKeyProfile $pem
            $profile.pbes2|Should Be '1.2.840.113549.1.5.13';$profile.kdf|Should Be '1.2.840.113549.1.5.12';$profile.prf|Should Be '1.2.840.113549.2.9';$profile.cipher|Should Be '2.16.840.1.101.3.4.1.42'
            $profile.iterations|Should Be 600000;$profile.ivLength|Should Be 16;($profile.saltLength -ge 16)|Should Be $true;($profile.encryptedLength -gt 0)|Should Be $true
            [byte[]]$pemBytes=ConvertTo-TestUtf8Bytes $pem;$imported=Invoke-TrustAnchorModule {param($value,$p)Import-TrustAnchorEncryptedPrivateKey $value $p} @($pemBytes,$password)
            [Convert]::ToHexString($imported.ExportSubjectPublicKeyInfo())|Should Be ([Convert]::ToHexString($rsa.ExportSubjectPublicKeyInfo()))
        }finally{if($null-ne$pemBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($pemBytes)};if($null-ne$imported){$imported.Dispose()};$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Runtime-generated encrypted PKCS#8 inputs vary cipher, PRF, or iteration count one dimension at a time.
    # Purpose: Reject every encrypted-key profile outside the exact approved profile before decryption.
    It 'UnitT02_rejects_wrong_cipher_PRF_or_iteration_count' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;[char[]]$characters='fixture-password-xxxxxxxxxxxxxxxxxxxx'.ToCharArray()
        try{
            $profiles=@(
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes128Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA512,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,599999)
            )
            foreach($profile in $profiles){$pem=$rsa.ExportEncryptedPkcs8PrivateKeyPem($characters,$profile);[byte[]]$value=ConvertTo-TestUtf8Bytes $pem;try{$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($bytes,$p)Import-TrustAnchorEncryptedPrivateKey $bytes $p} @($value,$password)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)}}
        }finally{[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters);$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Unencrypted PKCS#1, unencrypted PKCS#8, XML private-key, and PKCS#12-shaped inputs reach the importer.
    # Purpose: Only encrypted PKCS#8 PEM may cross the private-key import boundary and failures retain the required error ID.
    It 'UnitT03_rejects_every_unsupported_private_key_format' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword
        try{foreach($fixture in @($rsa.ExportRSAPrivateKeyPem(),$rsa.ExportPkcs8PrivateKeyPem(),'<RSAKeyValue><D>AQ==</D></RSAKeyValue>',[Convert]::ToBase64String([byte[]](1,2,3,4)))){[byte[]]$value=ConvertTo-TestUtf8Bytes $fixture;try{$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($bytes,$p)Import-TrustAnchorEncryptedPrivateKey $bytes $p} @($value,$password)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)}}}finally{$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML is produced twice from the same public key and parsed back.
    # Purpose: Preserve UTF-8-without-BOM, one LF, no CR, and stable canonical bytes.
    It 'UnitT04_emits_stable_canonical_XML_bytes' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$copy=$null
        try{[byte[]]$first=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa);$first[0..2]|Should Not Be @(0xef,0xbb,0xbf);$first|Should Not Contain 13;$first[-1]|Should Be 10;$first[-2]|Should Not Be 10;$copy=Invoke-TrustAnchorModule {param($b)Import-TrustAnchorPublicXml $b} @(,$first);[byte[]]$second=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($copy);[Convert]::ToHexString($second)|Should Be ([Convert]::ToHexString($first))}finally{if($null-ne$copy){$copy.Dispose()};$rsa.Dispose()}
    }

    # Scenario: Fingerprints are calculated independently from canonical XML and SPKI DER.
    # Purpose: Bind both published fingerprint representations to their exact bytes.
    It 'UnitT05_calculates_XML_and_SPKI_SHA256' {
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        try{$actual=Invoke-TrustAnchorModule {param($r)Get-TrustAnchorFingerprint $r} @($rsa);$xml=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa);$actual.xmlSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xml)).ToLowerInvariant());$actual.spkiSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant())}finally{$rsa.Dispose()}
    }

    # Scenario: A 2048-bit key and a 3072-bit exponent-3 key reach the public-key assertion.
    # Purpose: Enforce both minimum modulus length and exponent 65537.
    It 'UnitT06_rejects_weak_RSA_profiles' {
        $weak=[Security.Cryptography.RSA]::Create(2048);$source=[Security.Cryptography.RSA]::Create(3072);$wrongExponent=[Security.Cryptography.RSA]::Create()
        try{{Invoke-TrustAnchorModule {param($r)Assert-TrustAnchorPublicKey $r} @($weak)}|Should Throw 'at least 3072 bits';$parameters=$source.ExportParameters($false);$parameters.Exponent=[byte[]](3);$wrongExponent.ImportParameters($parameters);{Invoke-TrustAnchorModule {param($r)Assert-TrustAnchorPublicKey $r} @($wrongExponent)}|Should Throw 'at least 3072 bits'}finally{$wrongExponent.Dispose();$source.Dispose();$weak.Dispose()}
    }

    # Scenario: A valid encrypted PKCS#8 fixture uses the approved algorithms and password but a one-byte PBKDF2 salt.
    # Purpose: Reject decryptable encrypted keys whose offline-password salt is below sixteen bytes.
    It 'UnitT07_rejects_a_decryptable_private_key_with_a_short_PBKDF2_salt' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$passwordText='fixture-password-xxxxxxxx';[byte[]]$passwordBytes=ConvertTo-TestUtf8Bytes $passwordText;$password=New-TestPassword $passwordText;$fixture=$null;[char[]]$characters=$passwordText.ToCharArray();[byte[]]$pemBytes=$null
        try{$fixture=New-TestShortSaltEncryptedPrivateKey $rsa $passwordBytes;[SyuanTsai.AIInstructions.TrustAnchor.Tests.CryptoProbe]::CanDecrypt($fixture.Der,$characters)|Should Be $true;$pemBytes=ConvertTo-TestUtf8Bytes $fixture.Pem;$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($bytes,$p)Import-TrustAnchorEncryptedPrivateKey $bytes $p} @($pemBytes,$password)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{if($null-ne$passwordBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes)};if($null-ne$pemBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($pemBytes)};if($null-ne$fixture){[Security.Cryptography.CryptographicOperations]::ZeroMemory([byte[]]$fixture.Der)};[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters);$password.Dispose();$rsa.Dispose()}
    }
}

Describe 'PR-K1 password and public command boundary' {
    # Scenario: Read-Host returns a fifteen-character password.
    # Purpose: Bind the rejection boundary exactly below sixteen characters.
    It 'UnitT08_rejects_a_fifteen_character_password' {
        $response=New-TestPassword ('x'*15);Set-TestReadHostResponses @($response);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $failure=Get-TestFailure {Invoke-TrustAnchorModule {Read-TrustAnchorPassword}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.WeakPassword';Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 1;$response.Dispose()
    }

    # Scenario: Read-Host returns a sixteen-character password.
    # Purpose: Bind the acceptance boundary exactly at sixteen characters.
    It 'UnitT09_accepts_a_sixteen_character_password' {
        $response=New-TestPassword ('x'*16);Set-TestReadHostResponses @($response);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $actual=Invoke-TrustAnchorModule {Read-TrustAnchorPassword};try{$actual.Length|Should Be 16}finally{$actual.Dispose()}
    }

    # Scenario: Two valid-length interactive password responses differ.
    # Purpose: Refuse a mistyped confirmation without converting either secret to a managed string.
    It 'UnitT10_rejects_mismatched_password_confirmation' {
        $first=New-TestPassword ('a'*20);$second=New-TestPassword ('b'*20);Set-TestReadHostResponses @($first,$second);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $failure=Get-TestFailure {Invoke-TrustAnchorModule {Read-TrustAnchorPassword -Confirm}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.PasswordMismatch';Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 2
    }

    # Scenario: Two valid-length interactive password responses match.
    # Purpose: Return the confirmed SecureString for the caller to dispose.
    It 'UnitT11_accepts_matching_password_confirmation' {
        $first=New-TestPassword ('c'*20);$second=New-TestPassword ('c'*20);Set-TestReadHostResponses @($first,$second);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $actual=Invoke-TrustAnchorModule {Read-TrustAnchorPassword -Confirm};try{$actual.Length|Should Be 20;Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 2}finally{$actual.Dispose()}
    }

    # Scenario: The imported helper module and all three formal CLI parameter blocks are inspected.
    # Purpose: No public command or formal CLI may accept Password, SecureString, char[], environment-secret, or password-file input.
    It 'UnitT12_exposes_only_the_exact_CLI_parameter_allowlists' {
        @($script:Module.ExportedCommands.Values).Count|Should Be 0
        $expected=@{'New-TrustAnchorKeyPair.ps1'=@('KeyId','PrivateKeyPath','PublicKeyXmlPath');'ConvertTo-TrustAnchorPublicKeyXml.ps1'=@('PublicKeyPemPath','OutputPath');'Get-TrustAnchorFingerprint.ps1'=@('PublicKeyXmlPath','PublicKeyPemPath','EncryptedPrivateKeyPath')}
        foreach($name in $expected.Keys){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})-join'|')|Should Be ($expected[$name]-join'|');foreach($parameter in @($ast.ParamBlock.Parameters)){[string]$parameter.StaticType|Should Not Match 'SecureString|Char\[\]'}}
    }

    # Scenario: The module AST is inspected for every password acquisition and possible fallback source.
    # Purpose: Require Read-Host -AsSecureString as the only password source, without environment or file fallback.
    It 'UnitT13_uses_only_Read_Host_AsSecureString_for_password_acquisition' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:ModulePath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$function=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-TrustAnchorPassword'},$true));$function.Count|Should Be 1;$commands=@($function[0].Body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true));$readHost=@($commands|Where-Object{$_.GetCommandName()-ceq'Read-Host'});$readHost.Count|Should Be 2;foreach($command in $readHost){$command.Extent.Text|Should Match '(?i)-AsSecureString'};$function[0].Extent.Text|Should Not Match '(?i)GetEnvironmentVariable|ReadAll(Text|Bytes|Lines)|Get-Content|Password(File|Path)'
    }
}

Describe 'PR-K1 trust-anchor CLI boundary' {
    # Scenario: Every CLI AST is inspected for the guard and the first delegated action.
    # Purpose: A missing guard must fail, and the guard must precede path, file, password, or RSA work.
    It 'UnitT14_allows_only_the_guard_then_one_action_in_each_CLI_module_invocation' {
        $expected=@{'New-TrustAnchorKeyPair.ps1'='Invoke-NewTrustAnchorKeyPairAction';'ConvertTo-TrustAnchorPublicKeyXml.ps1'='Invoke-ConvertToTrustAnchorPublicKeyXmlAction';'Get-TrustAnchorFingerprint.ps1'='Invoke-GetTrustAnchorFingerprintAction'}
        foreach($name in $expected.Keys){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast $expected[$name])|Should Be $true}
    }

    # Scenario: A synthetic CLI performs File.ReadAllText before the interactive guard.
    # Purpose: Prove the closed AST allowlist fails when any I/O is inserted ahead of the guard.
    It 'UnitT15_AST_guard_self_check_rejects_pre_guard_file_IO' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput("`$module=Import-Module x -PassThru`n& `$module { [IO.File]::ReadAllText('x'); Assert-TrustAnchorInteractiveHost; Invoke-NewTrustAnchorKeyPairAction }",[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast 'Invoke-NewTrustAnchorKeyPairAction')|Should Be $false
    }

    # Scenario: Each CI marker is set independently before the interactive guard runs.
    # Purpose: Refuse accidental key operations in common CI environments and retain the required error ID.
    It 'UnitT16_rejects_CI_marker_<Marker>' -TestCases @(@{Marker='CI'},@{Marker='GITHUB_ACTIONS'},@{Marker='TF_BUILD'},@{Marker='BUILD_BUILDID'},@{Marker='RUNNER_TEMP'}) {
        param($Marker)$prior=[Environment]::GetEnvironmentVariable($Marker)
        try{[Environment]::SetEnvironmentVariable($Marker,'1');$failure=Get-TestFailure {Invoke-TrustAnchorModule {Assert-TrustAnchorInteractiveHost}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.NonInteractive'}finally{[Environment]::SetEnvironmentVariable($Marker,$prior)}
    }

    # Scenario: The fingerprint CLI is launched with redirected stdin and no CI marker.
    # Purpose: A non-interactive pipe must fail before reading any key path and report TrustAnchor.NonInteractive.
    It 'InterT17_rejects_redirected_stdin_with_the_required_error_ID' {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-File');$info.ArgumentList.Add((Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'));$info.ArgumentList.Add('-PublicKeyXmlPath');$info.ArgumentList.Add((Join-Path $TestDrive 'missing.xml'));$info.RedirectStandardInput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false;foreach($marker in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')){$info.Environment.Remove($marker)|Out-Null}
        $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Close();$process.WaitForExit();try{$process.ExitCode|Should Not Be 0;$process.StandardError.ReadToEnd()|Should Match 'TrustAnchor\.NonInteractive'}finally{$process.Dispose()}
    }

    # Scenario: Runtime public and private PEM inputs exercise the conversion action with the host guard mocked only in module scope.
    # Purpose: Produce canonical XML while rejecting private PEM and weak public keys through the same action used by the formal CLI.
    It 'InterT18_converts_public_PEM_and_rejects_private_or_weak_inputs' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {}
        $rsa=[Security.Cryptography.RSA]::Create(3072);$weak=[Security.Cryptography.RSA]::Create(2048)
        try{$publicPath=Join-Path $TestDrive 'public.pem';$outputPath=Join-Path $TestDrive 'public.xml';[IO.File]::WriteAllText($publicPath,$rsa.ExportSubjectPublicKeyInfoPem());$result=Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($publicPath,$outputPath);[Convert]::ToHexString([IO.File]::ReadAllBytes($outputPath))|Should Be ([Convert]::ToHexString((Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa))));$result.xmlSha256|Should Match '^[0-9a-f]{64}$';$privatePath=Join-Path $TestDrive 'private-input.pem';[IO.File]::WriteAllText($privatePath,$rsa.ExportPkcs8PrivateKeyPem());(Get-TestFailure {Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($privatePath,(Join-Path $TestDrive 'private.xml'))}).FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';$weakPath=Join-Path $TestDrive 'weak.pem';[IO.File]::WriteAllText($weakPath,$weak.ExportSubjectPublicKeyInfoPem());{Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($weakPath,(Join-Path $TestDrive 'weak.xml'))}|Should Throw 'at least 3072 bits'}finally{$weak.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML, PUBLIC KEY PEM, and an encrypted private key all represent the same runtime-generated RSA key.
    # Purpose: Exercise all fingerprint CLI orchestration paths while the private-key password still comes only from Read-Host.
    It 'InterT19_fingerprints_XML_public_PEM_and_encrypted_private_PEM' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {}
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$privateTarget=$null;$privateLease=$null
        try{$expected=Invoke-TrustAnchorModule {param($r)Get-TrustAnchorFingerprint $r} @($rsa);$xmlPath=Join-Path $TestDrive 'fingerprint.xml';[IO.File]::WriteAllBytes($xmlPath,(Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa)));$pemPath=Join-Path $TestDrive 'fingerprint.pem';[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());$encrypted=Invoke-TrustAnchorModule {param($r,$p)Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password);$privatePath=Join-Path $TestDrive 'fingerprint-private.pem';$privateTarget=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($privatePath);$privateLease=Invoke-TrustAnchorModule {param($t,$b)New-TrustAnchorKeyFile $t $b} @($privateTarget,[Text.UTF8Encoding]::new($false).GetBytes($encrypted+"`n"));Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease);$privateLease=$null;Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget);$privateTarget=$null;Set-TestReadHostResponses @($password);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$xml=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -PublicKeyXmlPath $p} @($xmlPath);$pem=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -PublicKeyPemPath $p} @($pemPath);$private=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -EncryptedPrivateKeyPath $p} @($privatePath);foreach($actual in @($xml,$pem,$private)){$actual.xmlSha256|Should Be $expected.xmlSha256;$actual.spkiSha256|Should Be $expected.spkiSha256};Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 1}finally{if($null-ne$privateLease){Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease)};if($null-ne$privateTarget){Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget)};$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Fingerprint inputs contain unencrypted PKCS#8, unencrypted PKCS#1, or private RSA XML generated at runtime.
    # Purpose: Reject private material at the byte boundary before any immutable managed string can be created.
    It 'InterT20_rejects_unencrypted_private_key_files_and_private_XML_at_the_byte_boundary' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$rsa=[Security.Cryptography.RSA]::Create(3072)
        try{
            $fixtures=@(@{Name='plain-pkcs8.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportPkcs8PrivateKeyPem()))},@{Name='plain-pkcs1.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportRSAPrivateKeyPem()))})
            foreach($fixture in $fixtures){$path=Join-Path $TestDrive $fixture.Name;$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=Invoke-TrustAnchorModule {param($t,$b)New-TrustAnchorKeyFile $t $b} @($target,$fixture.Bytes);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target);$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -EncryptedPrivateKeyPath $p} @($path)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';[Security.Cryptography.CryptographicOperations]::ZeroMemory($fixture.Bytes)}
            $parameters=$rsa.ExportParameters($true);$xml='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent><D>'+[Convert]::ToBase64String($parameters.D)+'</D></RSAKeyValue>';$xmlPath=Join-Path $TestDrive 'private.xml';[IO.File]::WriteAllBytes($xmlPath,(ConvertTo-TestUtf8Bytes $xml));(Get-TestFailure {Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -PublicKeyXmlPath $p} @($xmlPath)}).FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'
        }finally{$rsa.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor path lease and rollback safety' {
    # Scenario: An output path is placed below this repository worktree.
    # Purpose: Prevent private keys and generated public output from entering Git history.
    It 'UnitT21_rejects_output_inside_a_worktree' {{Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $script:RepositoryRoot 'fixture-key.pem'))}|Should Throw 'outside every Git worktree'}

    # Scenario: A retained preflight parent is renamed and a Git worktree replaces its pathname before create-new.
    # Purpose: Bind physical/worktree preflight evidence to the exact parent lease used by creation.
    It 'InterT22_reuses_the_preflight_parent_lease_or_fails_closed' {
        $parent=Join-Path $TestDrive 'approved';$moved=Join-Path $TestDrive 'approved-moved';[void][IO.Directory]::CreateDirectory($parent);$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $parent 'key.pem'));$blocked=$false
        try{try{Move-Item -LiteralPath $parent -Destination $moved -ErrorAction Stop;[void][IO.Directory]::CreateDirectory($parent);& git -C $parent init --quiet;if($LASTEXITCODE -ne 0){throw 'git init failed'}}catch{$blocked=$true};if($blocked){$blocked|Should Be $true}else{{Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target)}|Should Throw}}finally{Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)}
    }

    # Scenario: A target parent is reached through a native symlink or junction.
    # Purpose: Resolve every ancestor physically before accepting an output location.
    It 'InterT23_rejects_native_link_ancestor' {
        $physical=Join-Path $TestDrive 'physical';$alias=Join-Path $TestDrive 'alias';[void][IO.Directory]::CreateDirectory($physical);if($IsWindows){New-Item -ItemType Junction -Path $alias -Target $physical|Out-Null}else{New-Item -ItemType SymbolicLink -Path $alias -Target $physical|Out-Null};{Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $alias 'key.pem'))}|Should Throw
    }

    # Scenario: A valid private file is given a second hard link before it is opened.
    # Purpose: Refuse aliases that defeat exclusive key ownership.
    It 'InterT24_rejects_a_multiply_linked_private_key' {
        $path=Join-Path $TestDrive 'linked.pem';[IO.File]::WriteAllText($path,'fixture');if(-not$IsWindows){chmod 600 $path};New-Item -ItemType HardLink -Path (Join-Path $TestDrive 'alias.pem') -Target $path|Out-Null;{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'exactly one link'
    }

    # Scenario: An existing tracked file inside this worktree is supplied as a private-key input.
    # Purpose: Exercise the existing-file open path and reject all private material inside any worktree.
    It 'InterT25_rejects_an_existing_private_key_path_inside_a_worktree' {
        {Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($script:ModulePath)}|Should Throw 'outside every Git worktree'
    }

    # Scenario: Public output fails after the private key is created by the same internal action used by the CLI.
    # Purpose: Prove CLI orchestration removes the unchanged private identity on public-write failure.
    It 'InterT26_CLI_orchestration_rolls_back_the_unchanged_private_identity' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'rollback-private.pem';$public=Join-Path $TestDrive 'rollback-public.xml';Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'}}
        try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction humanApproval $privatePath $publicPath} @($private,$public)}|Should Throw 'Injected public output failure';(Test-Path -LiteralPath $private)|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null}}
    }

    # Scenario: Public output fails and the private pathname is replaced immediately before rollback.
    # Purpose: Preserve the replacement, reject identity drift, and fail closed through CLI orchestration.
    It 'InterT27_CLI_rollback_preserves_a_replaced_private_pathname' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'replaced-private.pem';$moved=Join-Path $TestDrive 'original-private.moved';$public=Join-Path $TestDrive 'replaced-public.xml'
        Invoke-TrustAnchorModule {param($movedPath)$script:TrustAnchorRollbackMovedPath=$movedPath;$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorBeforeRollbackRemovalTestHook={param($lease)Move-Item -LiteralPath $lease.Path -Destination $script:TrustAnchorRollbackMovedPath -ErrorAction Stop;[IO.File]::WriteAllText($lease.Path,'replacement')}} @($moved)
        try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction supervisor $privatePath $publicPath} @($private,$public)}|Should Throw 'rollback failed closed';(Test-Path -LiteralPath $private)|Should Be $true;[IO.File]::ReadAllText($private)|Should Be 'replacement';(Test-Path -LiteralPath $moved)|Should Be $true}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null;$script:TrustAnchorRollbackMovedPath=$null}}
    }

    # Scenario: Source order for private-file creation is inspected without invoking the helper.
    # Purpose: Permission tightening and readback must precede the first key-byte write.
    It 'UnitT28_orders_permission_readback_before_key_bytes' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$body=[regex]::Match($source,'(?s)function New-TrustAnchorKeyFile \{(.*?)\n\}').Groups[1].Value;$set=$body.IndexOf('Set-PlatformPermissions',[StringComparison]::Ordinal);$readback=$body.IndexOf('Assert-TrustAnchorPrivatePermissions',[StringComparison]::Ordinal);$write=$body.IndexOf('.WriteNewBytes(',[StringComparison]::Ordinal);($set -ge 0 -and $readback -gt $set -and $write -gt $readback)|Should Be $true
    }


    # Scenario: The three private-material input actions are inspected at AST level.
    # Purpose: Forbid unbounded text readers and direct byte-to-string conversion on every possible private-key path.
    It 'UnitT29_private_input_paths_use_only_bounded_clearable_byte_buffers' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:ModulePath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$names=@('Open-TrustAnchorPrivateKey','Invoke-ConvertToTrustAnchorPublicKeyXmlAction','Invoke-GetTrustAnchorFingerprintAction');foreach($name in $names){$function=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));$function.Count|Should Be 1;$function[0].Extent.Text|Should Not Match '(?i)ReadAllText|File\.ReadAllLines|Get-Content'};$fingerprint=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-GetTrustAnchorFingerprintAction'},$true))[0];$fingerprint.Extent.Text|Should Not Match '(?i)GetString\s*\('
    }

    # Scenario: A post-read validation hook throws after retaining a reference to the private byte array.
    # Purpose: Clear the buffer for every identity, metadata, permission, or hook failure after the bounded read.
    It 'InterT30_clears_private_bytes_when_post_read_validation_throws' {
        $path=Join-Path $TestDrive 'post-read-clear.pem';$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3,4,5,6))} @($target);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target);Invoke-TrustAnchorModule {$script:CapturedPrivateBytes=$null;$script:TrustAnchorAfterReadTestHook={param($openedPath,$file,$bytes)$script:CapturedPrivateBytes=$bytes;throw 'Injected post-read validation failure.'}}
        try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'Injected post-read validation failure';$captured=Invoke-TrustAnchorModule {$script:CapturedPrivateBytes};@($captured|Where-Object{$_-ne0}).Count|Should Be 0}finally{Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook=$null;$script:CapturedPrivateBytes=$null}}
    }
}

if($IsWindows){
    Describe 'PR-K1 Windows native handle safety' {
        # Scenario: A broad-DACL original is held open while a module-only barrier attempts to replace its pathname with a restricted file.
        # Purpose: Prove the production share lock prevents replacement instead of treating a failed attempt as a completed barrier.
        It 'InterT31_share_lock_explicitly_prevents_pathname_replacement' {
            $path=Join-Path $TestDrive 'windows-broad.pem';$replacement=Join-Path $TestDrive 'windows-safe.pem';$moved=Join-Path $TestDrive 'windows-broad.moved';[IO.File]::WriteAllText($path,'original');$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($replacement);$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([Text.Encoding]::UTF8.GetBytes('replacement'))} @($target);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)
            Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorBarrierReplacement=$replacementPath;$script:TrustAnchorBarrierMoved=$movedPath;$script:TrustAnchorBarrierAttempted=$false;$script:TrustAnchorBarrierSwapped=$false;$script:TrustAnchorBarrierFailure=$null;$script:TrustAnchorOpenBeforePermissionTestHook={param($openedPath,$file)$script:TrustAnchorBarrierAttempted=$true;try{Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorBarrierMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorBarrierReplacement -Destination $openedPath -ErrorAction Stop;$script:TrustAnchorBarrierSwapped=$true}catch{$script:TrustAnchorBarrierFailure=$_}}} @($replacement,$moved)
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'protected DACL';(Invoke-TrustAnchorModule {$script:TrustAnchorBarrierAttempted})|Should Be $true;(Invoke-TrustAnchorModule {$script:TrustAnchorBarrierSwapped})|Should Be $false;(Invoke-TrustAnchorModule {$null-ne$script:TrustAnchorBarrierFailure})|Should Be $true}finally{Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null}}
        }

        # Scenario: A native fixture opens a broad-DACL file with delete sharing, completes both pathname moves, and retains the original handle.
        # Purpose: Distinguish GetSecurityInfo(handle) evidence from the restricted replacement now visible at the pathname.
        It 'InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence' {
            $path=Join-Path $TestDrive 'delete-share-broad.pem';$replacement=Join-Path $TestDrive 'delete-share-safe.pem';$moved=Join-Path $TestDrive 'delete-share-broad.moved';[IO.File]::WriteAllText($path,'original');$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($replacement);$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([Text.Encoding]::UTF8.GetBytes('replacement'))} @($target);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target);$handle=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::OpenReadWithDeleteSharing($path);$replacementHandle=$null;$barrierSwapped=$false
            try{Move-Item -LiteralPath $path -Destination $moved -ErrorAction Stop;Move-Item -LiteralPath $replacement -Destination $path -ErrorAction Stop;$barrierSwapped=$true;$originalEvidence=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect($handle);$replacementHandle=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::OpenReadWithDeleteSharing($path);$replacementEvidence=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect($replacementHandle);$barrierSwapped|Should Be $true;$originalEvidence.DaclHex|Should Not Be $replacementEvidence.DaclHex;$replacementEvidence.DaclProtected|Should Be $true}finally{if($null-ne$replacementHandle){$replacementHandle.Dispose()};$handle.Dispose()}
        }

        # Scenario: The private-key leaf is a file symlink, with a directory-junction fallback when symlink creation is unavailable.
        # Purpose: Reject every Windows leaf reparse point and explicitly prove the fixture carries ReparsePoint.
        It 'InterT33_rejects_a_private_key_leaf_reparse_point' {
            $target=Join-Path $TestDrive 'reparse-target.pem';$leaf=Join-Path $TestDrive 'reparse-leaf.pem';[IO.File]::WriteAllText($target,'fixture');try{New-Item -ItemType SymbolicLink -Path $leaf -Target $target -ErrorAction Stop|Out-Null}catch{$targetDirectory=Join-Path $TestDrive 'reparse-target-dir';[void][IO.Directory]::CreateDirectory($targetDirectory);$leaf=Join-Path $TestDrive 'reparse-leaf-dir';New-Item -ItemType Junction -Path $leaf -Target $targetDirectory -ErrorAction Stop|Out-Null};(([IO.File]::GetAttributes($leaf)-band[IO.FileAttributes]::ReparsePoint)-ne0)|Should Be $true;{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($leaf)}|Should Throw
        }

        # Scenario: The formal key-pair action creates a private file and returns before native ACL readback.
        # Purpose: Independently verify the resulting DACL is protected and grants allow access only to approved SIDs.
        It 'InterT34_formal_creation_has_an_independently_verified_restrictive_DACL' {
            Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'acl-private.pem';$public=Join-Path $TestDrive 'acl-public.xml';Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction humanApproval $privatePath $publicPath} @($private,$public)|Out-Null;$acl=Get-Acl -LiteralPath $private;$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$owner|Should Be $identity.User.Value;$acl.AreAccessRulesProtected|Should Be $true;$allowed=@($identity.User.Value,'S-1-5-18','S-1-5-32-544');foreach($rule in @($acl.Access|Where-Object{$_.AccessControlType -eq 'Allow'})){($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $allowed)|Should Be $true}}finally{$identity.Dispose()}
        }
    }
}else{
    Describe 'PR-K1 Unix native handle safety' {
        # Scenario: An owner-only 0400 private file is opened.
        # Purpose: Accept every owner-only mode rather than requiring mode exactly 0600.
        It 'InterT40_accepts_owner_only_mode_0400' {
            $path=Join-Path $TestDrive 'readonly.pem';[IO.File]::WriteAllText($path,'fixture');chmod 400 $path;[Text.Encoding]::UTF8.GetString((Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)))|Should Be 'fixture'
        }

        # Scenario: A broad-mode original is opened, then a module-only barrier replaces its pathname with a 0600 file.
        # Purpose: Permission validation must remain bound to the original open handle.
        It 'InterT41_rejects_the_original_broad_mode_after_pathname_replacement' {
            $path=Join-Path $TestDrive 'unix-broad.pem';$replacement=Join-Path $TestDrive 'unix-safe.pem';$moved=Join-Path $TestDrive 'unix-broad.moved';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 640 $path;chmod 600 $replacement
            Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorBarrierReplacement=$replacementPath;$script:TrustAnchorBarrierMoved=$movedPath;$script:TrustAnchorOpenBeforePermissionTestHook={param($openedPath,$file)Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorBarrierMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorBarrierReplacement -Destination $openedPath -ErrorAction Stop}} @($replacement,$moved)
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'deny every group/other permission';[IO.File]::ReadAllText($path)|Should Be 'replacement'}finally{Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null}}
        }

        # Scenario: A same-inode, same-length rewrite occurs after the bounded read and before final metadata capture.
        # Purpose: Detect mtime/ctime change even when identity, size, owner, mode, and link count remain valid.
        It 'InterT42_rejects_metadata_change_during_read' {
            $path=Join-Path $TestDrive 'metadata.pem';[IO.File]::WriteAllText($path,'before!!');chmod 600 $path;Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook={param($openedPath,$file)[IO.File]::WriteAllText($openedPath,'after!!!')}}
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'metadata changed'}finally{Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook=$null}}
        }

        # Scenario: The private-key leaf itself is a native symbolic link.
        # Purpose: Require no-follow semantics for the final private-key component.
        It 'InterT43_rejects_a_private_key_leaf_symbolic_link' {
            $target=Join-Path $TestDrive 'leaf-target.pem';$leaf=Join-Path $TestDrive 'leaf-link.pem';[IO.File]::WriteAllText($target,'fixture');chmod 600 $target;New-Item -ItemType SymbolicLink -Path $leaf -Target $target|Out-Null;{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($leaf)}|Should Throw
        }

        # Scenario: The formal key-pair action creates a private file before independent native mode readback.
        # Purpose: Verify the persisted file is regular, owner-only, and not merely accepted by the module's own check.
        It 'InterT44_formal_creation_has_an_independently_verified_owner_only_mode' {
            Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'mode-private.pem';$public=Join-Path $TestDrive 'mode-public.xml';Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction humanApproval $privatePath $publicPath} @($private,$public)|Out-Null;$mode=[IO.File]::GetUnixFileMode($private);(([int]$mode-band63)-eq0)|Should Be $true
        }

        # Scenario: Both original and replacement are mode 0600 regular files, and the pathname identity changes after the read.
        # Purpose: Reach the final identity revalidation independently of permission rejection.
        It 'InterT45_rejects_post_read_identity_replacement_when_both_files_are_restrictive' {
            $path=Join-Path $TestDrive 'identity-original.pem';$replacement=Join-Path $TestDrive 'identity-safe.pem';$moved=Join-Path $TestDrive 'identity-original.moved';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 600 $path;chmod 600 $replacement;Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorIdentityReplacement=$replacementPath;$script:TrustAnchorIdentityMoved=$movedPath;$script:TrustAnchorAfterReadTestHook={param($openedPath,$file,$bytes)Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorIdentityMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorIdentityReplacement -Destination $openedPath -ErrorAction Stop}} @($replacement,$moved)
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw}finally{Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook=$null}}
        }

        # Scenario: After rename validation, the private tombstone is displaced and an unrelated replacement occupies its name.
        # Purpose: Revalidate inside the retained 0700 rollback directory and preserve both entries on uncertainty.
        It 'InterT46_rollback_fails_closed_when_the_tombstone_is_replaced_before_unlink' {
            Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'tombstone-private.pem';$public=Join-Path $TestDrive 'tombstone-public.xml';Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorAfterRollbackRenameTestHook={param($rollback)$script:RollbackDisplaced=$rollback.TombstonePath+'.displaced';Move-Item -LiteralPath $rollback.TombstonePath -Destination $script:RollbackDisplaced -ErrorAction Stop;[IO.File]::WriteAllText($rollback.TombstonePath,'replacement');chmod 600 $rollback.TombstonePath}}
            try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction supervisor $privatePath $publicPath} @($private,$public)}|Should Throw 'rollback failed closed';$evidence=Invoke-TrustAnchorModule {@($script:RollbackDisplaced,$script:RollbackDisplaced.Substring(0,$script:RollbackDisplaced.Length-10))};(Test-Path -LiteralPath $evidence[0])|Should Be $true;(Test-Path -LiteralPath $evidence[1])|Should Be $true}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorAfterRollbackRenameTestHook=$null}}
        }

        # Scenario: A hard link to the tombstone is created after rename and before unlink.
        # Purpose: Require single-link evidence immediately before unlink and retain the key when another link exists.
        It 'InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink' {
            Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'hardlink-private.pem';$public=Join-Path $TestDrive 'hardlink-public.xml';Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorAfterRollbackRenameTestHook={param($rollback)$script:RollbackHardLink=$rollback.TombstonePath+'.link';New-Item -ItemType HardLink -Path $script:RollbackHardLink -Target $rollback.TombstonePath|Out-Null;$script:RollbackTombstone=$rollback.TombstonePath}}
            try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction supervisor $privatePath $publicPath} @($private,$public)}|Should Throw 'rollback failed closed';$paths=Invoke-TrustAnchorModule {@($script:RollbackTombstone,$script:RollbackHardLink)};foreach($path in $paths){(Test-Path -LiteralPath $path)|Should Be $true}}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorAfterRollbackRenameTestHook=$null}}
        }
    }
}

Describe 'PR-K1 trust-anchor regression inventory' {
    AfterAll {Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null;$script:TrustAnchorAfterReadTestHook=$null;$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null;$script:TrustAnchorAfterRollbackRenameTestHook=$null};Remove-Module $script:Module.Name -Force -ErrorAction SilentlyContinue}

    # Scenario: The test AST is inspected for native-host registration and runtime-only RSA generation.
    # Purpose: Every platform-specific It must live below one explicit native Windows/Unix conditional without committed keys or skips.
    It 'UnitT48_registers_the_fixed_native_inventory_under_the_correct_AST_clause' {
        $windows=@('InterT31_share_lock_explicitly_prevents_pathname_replacement','InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence','InterT33_rejects_a_private_key_leaf_reparse_point','InterT34_formal_creation_has_an_independently_verified_restrictive_DACL')
        $unix=@('InterT40_accepts_owner_only_mode_0400','InterT41_rejects_the_original_broad_mode_after_pathname_replacement','InterT42_rejects_metadata_change_during_read','InterT43_rejects_a_private_key_leaf_symbolic_link','InterT44_formal_creation_has_an_independently_verified_owner_only_mode','InterT45_rejects_post_read_identity_replacement_when_both_files_are_restrictive','InterT46_rollback_fails_closed_when_the_tombstone_is_replaced_before_unlink','InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink')
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$conditional=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'PR-K1 Windows native handle safety' -and $node.Extent.Text -match 'PR-K1 Unix native handle safety'},$true));$conditional.Count|Should Be 1;$conditional[0].Clauses[0].Item1.Extent.Text|Should Match '\$IsWindows';$windowsExtent=$conditional[0].Clauses[0].Item2.Extent;$unixExtent=$conditional[0].ElseClause.Extent;$nativeIts=@($conditional[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));$actualWindows=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$windowsExtent.StartOffset-and$_.Extent.EndOffset-le$windowsExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});$actualUnix=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$unixExtent.StartOffset-and$_.Extent.EndOffset-le$unixExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});($actualWindows-join'|')|Should Be ($windows-join'|');($actualUnix-join'|')|Should Be ($unix-join'|');@($nativeIts).Count|Should Be ($windows.Count+$unix.Count)
        $allIts=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));foreach($name in @($windows+$unix)){$matches=@($allIts|Where-Object{[string]$_.CommandElements[1].Value-ceq$name});$matches.Count|Should Be 1;($matches[0].Extent.StartOffset-ge$conditional[0].Extent.StartOffset-and$matches[0].Extent.EndOffset-le$conditional[0].Extent.EndOffset)|Should Be $true};$numbers=@($allIts|ForEach-Object{if([string]$_.CommandElements[1].Value-match'^(?:Unit|Inter)T(\d{2})_'){$Matches[1]}});@($numbers|Group-Object|Where-Object Count-gt1).Count|Should Be 0
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$source|Should Match 'RSA\]::Create\(3072\)';$source|Should Not Match 'BEGIN (RSA )?PRIVATE KEY';(Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'docs/standards/core-test-skip-inventory.json'))|Should Not Match 'trust-anchor-tools'
    }
}
