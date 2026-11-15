# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:ModulePath=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'
$script:Module=Import-Module $script:ModulePath -PassThru -Force

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

Describe 'PR-K1 trust-anchor cryptography contract' {
    # Scenario: A fresh 3072-bit RSA key is exported and its EncryptedPrivateKeyInfo ASN.1 is parsed independently.
    # Purpose: Prove the artifact itself uses PBES2, PBKDF2-HMAC-SHA256, AES-256-CBC, and 600000 iterations.
    It 'UnitT10_exports_the_exact_encrypted_PKCS8_profile_and_round_trips' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$imported=$null
        try{
            $pem=Invoke-TrustAnchorModule {param($r,$p)Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password);$profile=Read-TestEncryptedPrivateKeyProfile $pem
            $profile.pbes2|Should Be '1.2.840.113549.1.5.13';$profile.kdf|Should Be '1.2.840.113549.1.5.12';$profile.prf|Should Be '1.2.840.113549.2.9';$profile.cipher|Should Be '2.16.840.1.101.3.4.1.42'
            $profile.iterations|Should Be 600000;$profile.ivLength|Should Be 16;($profile.saltLength -gt 0)|Should Be $true;($profile.encryptedLength -gt 0)|Should Be $true
            $imported=Invoke-TrustAnchorModule {param($text,$p)Import-TrustAnchorEncryptedPrivateKey $text $p} @($pem,$password)
            [Convert]::ToHexString($imported.ExportSubjectPublicKeyInfo())|Should Be ([Convert]::ToHexString($rsa.ExportSubjectPublicKeyInfo()))
        }finally{if($null-ne$imported){$imported.Dispose()};$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Runtime-generated encrypted PKCS#8 inputs vary cipher, PRF, or iteration count one dimension at a time.
    # Purpose: Reject every encrypted-key profile outside the exact approved profile before decryption.
    It 'UnitT20_rejects_wrong_cipher_PRF_or_iteration_count' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;[char[]]$characters='fixture-password-xxxxxxxxxxxxxxxxxxxx'.ToCharArray()
        try{
            $profiles=@(
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes128Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA512,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,599999)
            )
            foreach($profile in $profiles){$pem=$rsa.ExportEncryptedPkcs8PrivateKeyPem($characters,$profile);$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($text,$p)Import-TrustAnchorEncryptedPrivateKey $text $p} @($pem,$password)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}
        }finally{[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters);$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Unencrypted PKCS#1, unencrypted PKCS#8, XML private-key, and PKCS#12-shaped inputs reach the importer.
    # Purpose: Only encrypted PKCS#8 PEM may cross the private-key import boundary and failures retain the required error ID.
    It 'UnitT30_rejects_every_unsupported_private_key_format' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword
        try{foreach($fixture in @($rsa.ExportRSAPrivateKeyPem(),$rsa.ExportPkcs8PrivateKeyPem(),'<RSAKeyValue><D>AQ==</D></RSAKeyValue>',[Convert]::ToBase64String([byte[]](1,2,3,4)))){$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($text,$p)Import-TrustAnchorEncryptedPrivateKey $text $p} @($fixture,$password)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}}finally{$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML is produced twice from the same public key and parsed back.
    # Purpose: Preserve UTF-8-without-BOM, one LF, no CR, and stable canonical bytes.
    It 'UnitT40_emits_stable_canonical_XML_bytes' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$copy=$null
        try{[byte[]]$first=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa);$first[0..2]|Should Not Be @(0xef,0xbb,0xbf);$first|Should Not Contain 13;$first[-1]|Should Be 10;$first[-2]|Should Not Be 10;$copy=Invoke-TrustAnchorModule {param($b)Import-TrustAnchorPublicXml $b} @(,$first);[byte[]]$second=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($copy);[Convert]::ToHexString($second)|Should Be ([Convert]::ToHexString($first))}finally{if($null-ne$copy){$copy.Dispose()};$rsa.Dispose()}
    }

    # Scenario: Fingerprints are calculated independently from canonical XML and SPKI DER.
    # Purpose: Bind both published fingerprint representations to their exact bytes.
    It 'UnitT50_calculates_XML_and_SPKI_SHA256' {
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        try{$actual=Invoke-TrustAnchorModule {param($r)Get-TrustAnchorFingerprint $r} @($rsa);$xml=Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa);$actual.xmlSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xml)).ToLowerInvariant());$actual.spkiSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant())}finally{$rsa.Dispose()}
    }

    # Scenario: A 2048-bit key and a 3072-bit exponent-3 key reach the public-key assertion.
    # Purpose: Enforce both minimum modulus length and exponent 65537.
    It 'UnitT60_rejects_weak_RSA_profiles' {
        $weak=[Security.Cryptography.RSA]::Create(2048);$source=[Security.Cryptography.RSA]::Create(3072);$wrongExponent=[Security.Cryptography.RSA]::Create()
        try{{Invoke-TrustAnchorModule {param($r)Assert-TrustAnchorPublicKey $r} @($weak)}|Should Throw 'at least 3072 bits';$parameters=$source.ExportParameters($false);$parameters.Exponent=[byte[]](3);$wrongExponent.ImportParameters($parameters);{Invoke-TrustAnchorModule {param($r)Assert-TrustAnchorPublicKey $r} @($wrongExponent)}|Should Throw 'at least 3072 bits'}finally{$wrongExponent.Dispose();$source.Dispose();$weak.Dispose()}
    }
}

Describe 'PR-K1 password and public command boundary' {
    # Scenario: Read-Host returns a password shorter than sixteen characters.
    # Purpose: Enforce the minimum password length at the only password acquisition boundary.
    It 'UnitT10_rejects_passwords_shorter_than_sixteen_characters' {
        $response=New-TestPassword 'short';Set-TestReadHostResponses @($response);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $failure=Get-TestFailure {Invoke-TrustAnchorModule {Read-TrustAnchorPassword}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.WeakPassword';Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 1;$response.Dispose()
    }

    # Scenario: Two valid-length interactive password responses differ.
    # Purpose: Refuse a mistyped confirmation without converting either secret to a managed string.
    It 'UnitT20_rejects_mismatched_password_confirmation' {
        $first=New-TestPassword ('a'*20);$second=New-TestPassword ('b'*20);Set-TestReadHostResponses @($first,$second);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $failure=Get-TestFailure {Invoke-TrustAnchorModule {Read-TrustAnchorPassword -Confirm}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.PasswordMismatch';Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 2
    }

    # Scenario: Two valid-length interactive password responses match.
    # Purpose: Return the confirmed SecureString for the caller to dispose.
    It 'UnitT30_accepts_matching_password_confirmation' {
        $first=New-TestPassword ('c'*20);$second=New-TestPassword ('c'*20);Set-TestReadHostResponses @($first,$second);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()}
        $actual=Invoke-TrustAnchorModule {Read-TrustAnchorPassword -Confirm};try{$actual.Length|Should Be 20;Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 2}finally{$actual.Dispose()}
    }

    # Scenario: The imported helper module and all three formal CLI parameter blocks are inspected.
    # Purpose: No public command or formal CLI may accept Password, SecureString, char[], environment-secret, or password-file input.
    It 'UnitT40_exposes_no_password_bearing_public_command_or_CLI_parameter' {
        @($script:Module.ExportedCommands.Values).Count|Should Be 0
        foreach($name in @('New-TrustAnchorKeyPair.ps1','ConvertTo-TrustAnchorPublicKeyXml.ps1','Get-TrustAnchorFingerprint.ps1')){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;foreach($parameter in @($ast.ParamBlock.Parameters)){$parameter.Name.VariablePath.UserPath|Should Not Match '(?i)password|secure|file';[string]$parameter.StaticType|Should Not Match 'SecureString|Char\[\]'};$ast.Extent.Text|Should Not Match '(?i)GetEnvironmentVariable.*password|password(file|path)'}
    }
}

Describe 'PR-K1 trust-anchor CLI boundary' {
    # Scenario: Every CLI AST is inspected for the guard and the first delegated action.
    # Purpose: A missing guard must fail, and the guard must precede path, file, password, or RSA work.
    It 'UnitT10_requires_the_interactive_guard_before_every_action' {
        foreach($name in @('New-TrustAnchorKeyPair.ps1','ConvertTo-TrustAnchorPublicKeyXml.ps1','Get-TrustAnchorFingerprint.ps1')){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true));$guard=@($commands|Where-Object{$_.GetCommandName() -ceq 'Assert-TrustAnchorInteractiveHost'});$guard.Count|Should Be 1;$work=@($commands|Where-Object{$_.GetCommandName() -match '^Invoke-(NewTrustAnchorKeyPair|ConvertToTrustAnchorPublicKeyXml|GetTrustAnchorFingerprint)Action$'});$work.Count|Should Be 1;($guard[0].Extent.StartOffset -ge 0)|Should Be $true;($guard[0].Extent.StartOffset -lt $work[0].Extent.StartOffset)|Should Be $true}
    }

    # Scenario: Each CI marker is set independently before the interactive guard runs.
    # Purpose: Refuse accidental key operations in common CI environments and retain the required error ID.
    It 'UnitT20_rejects_CI_marker_<Marker>' -TestCases @(@{Marker='CI'},@{Marker='GITHUB_ACTIONS'},@{Marker='TF_BUILD'},@{Marker='BUILD_BUILDID'},@{Marker='RUNNER_TEMP'}) {
        param($Marker)$prior=[Environment]::GetEnvironmentVariable($Marker)
        try{[Environment]::SetEnvironmentVariable($Marker,'1');$failure=Get-TestFailure {Invoke-TrustAnchorModule {Assert-TrustAnchorInteractiveHost}};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.NonInteractive'}finally{[Environment]::SetEnvironmentVariable($Marker,$prior)}
    }

    # Scenario: The fingerprint CLI is launched with redirected stdin and no CI marker.
    # Purpose: A non-interactive pipe must fail before reading any key path and report TrustAnchor.NonInteractive.
    It 'InterT30_rejects_redirected_stdin_with_the_required_error_ID' {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-File');$info.ArgumentList.Add((Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'));$info.ArgumentList.Add('-PublicKeyXmlPath');$info.ArgumentList.Add((Join-Path $TestDrive 'missing.xml'));$info.RedirectStandardInput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false;foreach($marker in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')){$info.Environment.Remove($marker)|Out-Null}
        $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Close();$process.WaitForExit();try{$process.ExitCode|Should Not Be 0;$process.StandardError.ReadToEnd()|Should Match 'interactive host'}finally{$process.Dispose()}
    }

    # Scenario: Runtime public and private PEM inputs exercise the conversion action with the host guard mocked only in module scope.
    # Purpose: Produce canonical XML while rejecting private PEM and weak public keys through the same action used by the formal CLI.
    It 'InterT40_converts_public_PEM_and_rejects_private_or_weak_inputs' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {}
        $rsa=[Security.Cryptography.RSA]::Create(3072);$weak=[Security.Cryptography.RSA]::Create(2048)
        try{$publicPath=Join-Path $TestDrive 'public.pem';$outputPath=Join-Path $TestDrive 'public.xml';[IO.File]::WriteAllText($publicPath,$rsa.ExportSubjectPublicKeyInfoPem());$result=Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($publicPath,$outputPath);[Convert]::ToHexString([IO.File]::ReadAllBytes($outputPath))|Should Be ([Convert]::ToHexString((Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa))));$result.xmlSha256|Should Match '^[0-9a-f]{64}$';$privatePath=Join-Path $TestDrive 'private-input.pem';[IO.File]::WriteAllText($privatePath,$rsa.ExportPkcs8PrivateKeyPem());(Get-TestFailure {Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($privatePath,(Join-Path $TestDrive 'private.xml'))}).FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';$weakPath=Join-Path $TestDrive 'weak.pem';[IO.File]::WriteAllText($weakPath,$weak.ExportSubjectPublicKeyInfoPem());{Invoke-TrustAnchorModule {param($sourcePath,$destinationPath)Invoke-ConvertToTrustAnchorPublicKeyXmlAction $sourcePath $destinationPath} @($weakPath,(Join-Path $TestDrive 'weak.xml'))}|Should Throw 'at least 3072 bits'}finally{$weak.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML, PUBLIC KEY PEM, and an encrypted private key all represent the same runtime-generated RSA key.
    # Purpose: Exercise all fingerprint CLI orchestration paths while the private-key password still comes only from Read-Host.
    It 'InterT50_fingerprints_XML_public_PEM_and_encrypted_private_PEM' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {}
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$privateTarget=$null;$privateLease=$null
        try{$expected=Invoke-TrustAnchorModule {param($r)Get-TrustAnchorFingerprint $r} @($rsa);$xmlPath=Join-Path $TestDrive 'fingerprint.xml';[IO.File]::WriteAllBytes($xmlPath,(Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa)));$pemPath=Join-Path $TestDrive 'fingerprint.pem';[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());$encrypted=Invoke-TrustAnchorModule {param($r,$p)Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password);$privatePath=Join-Path $TestDrive 'fingerprint-private.pem';$privateTarget=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($privatePath);$privateLease=Invoke-TrustAnchorModule {param($t,$b)New-TrustAnchorKeyFile $t $b} @($privateTarget,[Text.UTF8Encoding]::new($false).GetBytes($encrypted+"`n"));Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease);$privateLease=$null;Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget);$privateTarget=$null;Set-TestReadHostResponses @($password);Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$xml=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -PublicKeyXmlPath $p} @($xmlPath);$pem=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -PublicKeyPemPath $p} @($pemPath);$private=Invoke-TrustAnchorModule {param($p)Invoke-GetTrustAnchorFingerprintAction -EncryptedPrivateKeyPath $p} @($privatePath);foreach($actual in @($xml,$pem,$private)){$actual.xmlSha256|Should Be $expected.xmlSha256;$actual.spkiSha256|Should Be $expected.spkiSha256};Assert-MockCalled Read-Host -ModuleName $script:Module.Name -Times 1}finally{if($null-ne$privateLease){Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease)};if($null-ne$privateTarget){Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget)};$password.Dispose();$rsa.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor path lease and rollback safety' {
    # Scenario: An output path is placed below this repository worktree.
    # Purpose: Prevent private keys and generated public output from entering Git history.
    It 'UnitT10_rejects_output_inside_a_worktree' {{Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $script:RepositoryRoot 'fixture-key.pem'))}|Should Throw 'outside every Git worktree'}

    # Scenario: A retained preflight parent is renamed and a Git worktree replaces its pathname before create-new.
    # Purpose: Bind physical/worktree preflight evidence to the exact parent lease used by creation.
    It 'InterT20_reuses_the_preflight_parent_lease_or_fails_closed' {
        $parent=Join-Path $TestDrive 'approved';$moved=Join-Path $TestDrive 'approved-moved';[void][IO.Directory]::CreateDirectory($parent);$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $parent 'key.pem'));$blocked=$false
        try{try{Move-Item -LiteralPath $parent -Destination $moved -ErrorAction Stop;[void][IO.Directory]::CreateDirectory($parent);& git -C $parent init --quiet;if($LASTEXITCODE -ne 0){throw 'git init failed'}}catch{$blocked=$true};if($blocked){$blocked|Should Be $true}else{{Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target)}|Should Throw}}finally{Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)}
    }

    # Scenario: A target parent is reached through a native symlink or junction.
    # Purpose: Resolve every ancestor physically before accepting an output location.
    It 'InterT30_rejects_native_link_ancestor' {
        $physical=Join-Path $TestDrive 'physical';$alias=Join-Path $TestDrive 'alias';[void][IO.Directory]::CreateDirectory($physical);if($IsWindows){New-Item -ItemType Junction -Path $alias -Target $physical|Out-Null}else{New-Item -ItemType SymbolicLink -Path $alias -Target $physical|Out-Null};{Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $alias 'key.pem'))}|Should Throw
    }

    # Scenario: A valid private file is given a second hard link before it is opened.
    # Purpose: Refuse aliases that defeat exclusive key ownership.
    It 'InterT40_rejects_a_multiply_linked_private_key' {
        $path=Join-Path $TestDrive 'linked.pem';[IO.File]::WriteAllText($path,'fixture');if(-not$IsWindows){chmod 600 $path};New-Item -ItemType HardLink -Path (Join-Path $TestDrive 'alias.pem') -Target $path|Out-Null;{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'exactly one link'
    }

    # Scenario: Public output fails after the private key is created by the same internal action used by the CLI.
    # Purpose: Prove CLI orchestration removes the unchanged private identity on public-write failure.
    It 'InterT50_CLI_orchestration_rolls_back_the_unchanged_private_identity' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'rollback-private.pem';$public=Join-Path $TestDrive 'rollback-public.xml';Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'}}
        try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction humanApproval $privatePath $publicPath} @($private,$public)}|Should Throw 'Injected public output failure';(Test-Path -LiteralPath $private)|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null}}
    }

    # Scenario: Public output fails and the private pathname is replaced immediately before rollback.
    # Purpose: Preserve the replacement, reject identity drift, and fail closed through CLI orchestration.
    It 'InterT60_CLI_rollback_preserves_a_replaced_private_pathname' {
        Mock -CommandName Assert-TrustAnchorInteractiveHost -ModuleName $script:Module.Name -MockWith {};Set-TestReadHostResponses @((New-TestPassword),(New-TestPassword));Mock -CommandName Read-Host -ModuleName $script:Module.Name -MockWith {$script:TrustAnchorPasswordTestResponses.Dequeue()};$private=Join-Path $TestDrive 'replaced-private.pem';$moved=Join-Path $TestDrive 'original-private.moved';$public=Join-Path $TestDrive 'replaced-public.xml'
        Invoke-TrustAnchorModule {param($movedPath)$script:TrustAnchorRollbackMovedPath=$movedPath;$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorBeforeRollbackRemovalTestHook={param($lease)Move-Item -LiteralPath $lease.Path -Destination $script:TrustAnchorRollbackMovedPath -ErrorAction Stop;[IO.File]::WriteAllText($lease.Path,'replacement')}} @($moved)
        try{{Invoke-TrustAnchorModule {param($privatePath,$publicPath)Invoke-NewTrustAnchorKeyPairAction supervisor $privatePath $publicPath} @($private,$public)}|Should Throw 'rollback failed closed';(Test-Path -LiteralPath $private)|Should Be $true;[IO.File]::ReadAllText($private)|Should Be 'replacement';(Test-Path -LiteralPath $moved)|Should Be $true}finally{Invoke-TrustAnchorModule {$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null;$script:TrustAnchorRollbackMovedPath=$null}}
    }

    # Scenario: Source order for private-file creation is inspected without invoking the helper.
    # Purpose: Permission tightening and readback must precede the first key-byte write.
    It 'UnitT70_orders_permission_readback_before_key_bytes' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$body=[regex]::Match($source,'(?s)function New-TrustAnchorKeyFile \{(.*?)\n\}').Groups[1].Value;$set=$body.IndexOf('Set-PlatformPermissions',[StringComparison]::Ordinal);$readback=$body.IndexOf('Assert-TrustAnchorPrivatePermissions',[StringComparison]::Ordinal);$write=$body.IndexOf('.WriteNewBytes(',[StringComparison]::Ordinal);($set -ge 0 -and $readback -gt $set -and $write -gt $readback)|Should Be $true
    }
}

if($IsWindows){
    Describe 'PR-K1 Windows native handle safety' {
        # Scenario: A broad-DACL original is held open while a module-only barrier attempts to replace its pathname with a restricted file.
        # Purpose: Open-TrustAnchorPrivateKey must inspect the original handle; Windows may additionally block the rename through sharing.
        It 'InterT80_rejects_the_original_broad_DACL_through_the_open_barrier' {
            $path=Join-Path $TestDrive 'windows-broad.pem';$replacement=Join-Path $TestDrive 'windows-safe.pem';$moved=Join-Path $TestDrive 'windows-broad.moved';[IO.File]::WriteAllText($path,'original');$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($replacement);$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([Text.Encoding]::UTF8.GetBytes('replacement'))} @($target);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)
            Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorBarrierReplacement=$replacementPath;$script:TrustAnchorBarrierMoved=$movedPath;$script:TrustAnchorBarrierRan=$false;$script:TrustAnchorOpenBeforePermissionTestHook={param($openedPath,$file)$script:TrustAnchorBarrierRan=$true;try{Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorBarrierMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorBarrierReplacement -Destination $openedPath -ErrorAction Stop}catch{}}} @($replacement,$moved)
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'protected DACL';(Invoke-TrustAnchorModule {$script:TrustAnchorBarrierRan})|Should Be $true}finally{Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null}}
        }
    }
}else{
    Describe 'PR-K1 Unix native handle safety' {
        # Scenario: An owner-only 0400 private file is opened.
        # Purpose: Accept every owner-only mode rather than requiring mode exactly 0600.
        It 'InterT80_accepts_owner_only_mode_0400' {
            $path=Join-Path $TestDrive 'readonly.pem';[IO.File]::WriteAllText($path,'fixture');chmod 400 $path;[Text.Encoding]::UTF8.GetString((Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)))|Should Be 'fixture'
        }

        # Scenario: A broad-mode original is opened, then a module-only barrier replaces its pathname with a 0600 file.
        # Purpose: Permission validation must remain bound to the original open handle.
        It 'InterT90_rejects_the_original_broad_mode_after_pathname_replacement' {
            $path=Join-Path $TestDrive 'unix-broad.pem';$replacement=Join-Path $TestDrive 'unix-safe.pem';$moved=Join-Path $TestDrive 'unix-broad.moved';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 640 $path;chmod 600 $replacement
            Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorBarrierReplacement=$replacementPath;$script:TrustAnchorBarrierMoved=$movedPath;$script:TrustAnchorOpenBeforePermissionTestHook={param($openedPath,$file)Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorBarrierMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorBarrierReplacement -Destination $openedPath -ErrorAction Stop}} @($replacement,$moved)
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'deny every group/other permission';[IO.File]::ReadAllText($path)|Should Be 'replacement'}finally{Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null}}
        }

        # Scenario: A same-inode, same-length rewrite occurs after the bounded read and before final metadata capture.
        # Purpose: Detect mtime/ctime change even when identity, size, owner, mode, and link count remain valid.
        It 'InterT95_rejects_metadata_change_during_read' {
            $path=Join-Path $TestDrive 'metadata.pem';[IO.File]::WriteAllText($path,'before!!');chmod 600 $path;Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook={param($openedPath,$file)[IO.File]::WriteAllText($openedPath,'after!!!')}}
            try{{Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'metadata changed'}finally{Invoke-TrustAnchorModule {$script:TrustAnchorAfterReadTestHook=$null}}
        }
    }
}

Describe 'PR-K1 trust-anchor regression inventory' {
    AfterAll {Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null;$script:TrustAnchorAfterReadTestHook=$null;$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null};Remove-Module $script:Module.Name -Force -ErrorAction SilentlyContinue}

    # Scenario: The test AST is inspected for native-host registration and runtime-only RSA generation.
    # Purpose: Every platform-specific It must live below one explicit native Windows/Unix conditional without committed keys or skips.
    It 'UnitT10_registers_each_native_case_under_the_correct_AST_condition' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$conditional=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'PR-K1 Windows native handle safety' -and $node.Extent.Text -match 'PR-K1 Unix native handle safety'},$true));$conditional.Count|Should Be 1;$conditional[0].Clauses[0].Item1.Extent.Text|Should Match '\$IsWindows';$conditional[0].Clauses[0].Item2.Extent.Text|Should Match 'Windows native handle safety';$conditional[0].ElseClause.Extent.Text|Should Match 'Unix native handle safety';$source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$source|Should Match 'RSA\]::Create\(3072\)';$source|Should Not Match 'BEGIN (RSA )?PRIVATE KEY';(Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'docs/standards/core-test-skip-inventory.json'))|Should Not Match 'trust-anchor-tools'
    }
}
