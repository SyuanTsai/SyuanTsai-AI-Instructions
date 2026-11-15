# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:ModulePath=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'
$script:Module=Import-Module $script:ModulePath -PassThru -Force
function Invoke-TrustAnchorModule {param([scriptblock]$Action,[object[]]$Arguments=@()) & $script:Module $Action @Arguments}
function New-TestPassword {[Security.SecureString]('fixture-password-' + ('x'*20) | ConvertTo-SecureString -AsPlainText -Force)}
function Assert-TestThrowsMessage {
    param([scriptblock]$Action,[string]$Pattern)
    $caught=$null
    try{& $Action}catch{$caught=$_}
    $caught|Should Not BeNullOrEmpty
    $caught.Exception.Message|Should Match $Pattern
}

Describe 'PR-K1 trust-anchor cryptography contract' {
    # Scenario: A fresh 3072-bit RSA key is exported with the specified PBE parameters and imported again.
    # Purpose: Protect the encrypted PKCS#8 algorithm, iteration count, and password-only round trip.
    It 'UnitT10_exports_AES256_PBKDF2_SHA256_600000_and_round_trips' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$imported=$null
        try{
            $pem=Invoke-TrustAnchorModule {param($r,$p) Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password)
            $pem | Should Match '^-----BEGIN ENCRYPTED PRIVATE KEY-----'
            $imported=Invoke-TrustAnchorModule {param($text,$p) Import-TrustAnchorEncryptedPrivateKey $text $p} @($pem,$password)
            $imported.ExportSubjectPublicKeyInfo() | Should Be $rsa.ExportSubjectPublicKeyInfo()
            $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath
            $source | Should Match 'Aes256Cbc'
            $source | Should Match 'SHA256, 600000'
        } finally {if($null-ne$imported){$imported.Dispose()};$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Unencrypted PKCS#1, unencrypted PKCS#8, XML private-key, and PKCS#12-shaped inputs reach the importer.
    # Purpose: Only encrypted PKCS#8 PEM may cross the private-key import boundary.
    It 'UnitT20_rejects_every_unsupported_private_key_format' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword
        try{
            $fixtures=@($rsa.ExportRSAPrivateKeyPem(),$rsa.ExportPkcs8PrivateKeyPem(),'<RSAKeyValue><D>AQ==</D></RSAKeyValue>',[Convert]::ToBase64String([byte[]](1,2,3,4)))
            foreach($fixture in $fixtures){
                {Invoke-TrustAnchorModule {param($text,$p) Import-TrustAnchorEncryptedPrivateKey $text $p} @($fixture,$password)} | Should Throw 'Only encrypted PKCS#8 PEM input is supported.'
            }
        } finally {$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML is produced twice from the same public key and parsed back.
    # Purpose: Preserve UTF-8-without-BOM, one LF, no CR, and stable canonical bytes.
    It 'UnitT30_emits_stable_canonical_XML_bytes' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$copy=$null
        try{
            [byte[]]$first=Invoke-TrustAnchorModule {param($r) ConvertTo-TrustAnchorCanonicalXml $r} @($rsa)
            $first[0..2] | Should Not Be @(0xef,0xbb,0xbf)
            $first | Should Not Contain 13
            $first[-1] | Should Be 10
            $first[-2] | Should Not Be 10
            $copy=Invoke-TrustAnchorModule {param($b) Import-TrustAnchorPublicXml $b} @(,$first)
            [byte[]]$second=Invoke-TrustAnchorModule {param($r) ConvertTo-TrustAnchorCanonicalXml $r} @($copy)
            [Convert]::ToHexString($second) | Should Be ([Convert]::ToHexString($first))
        } finally {if($null-ne$copy){$copy.Dispose()};$rsa.Dispose()}
    }

    # Scenario: Fingerprints are calculated independently from canonical XML and SPKI DER.
    # Purpose: Bind both published fingerprint representations to their exact bytes.
    It 'UnitT40_calculates_XML_and_SPKI_SHA256' {
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        try{
            $actual=Invoke-TrustAnchorModule {param($r) Get-TrustAnchorFingerprint $r} @($rsa)
            $xml=Invoke-TrustAnchorModule {param($r) ConvertTo-TrustAnchorCanonicalXml $r} @($rsa)
            $actual.xmlSha256 | Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xml)).ToLowerInvariant())
            $actual.spkiSha256 | Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant())
        } finally {$rsa.Dispose()}
    }

    # Scenario: A 2048-bit key reaches the trust-anchor public-key assertion.
    # Purpose: Reject keys below 3072 bits even when their exponent is otherwise valid.
    It 'UnitT50_rejects_RSA_below_3072_bits' {
        $rsa=[Security.Cryptography.RSA]::Create(2048)
        try {{Invoke-TrustAnchorModule {param($r) Assert-TrustAnchorPublicKey $r} @($rsa)} | Should Throw 'The trust-anchor public key must be at least 3072 bits with exponent 65537.'} finally {$rsa.Dispose()}
    }

    # Scenario: A 3072-bit public key uses exponent 3 instead of 65537.
    # Purpose: Enforce the complete trust-anchor strength profile, not only modulus length.
    It 'UnitT60_rejects_RSA_with_a_nonstandard_exponent' {
        $source=[Security.Cryptography.RSA]::Create(3072);$rsa=[Security.Cryptography.RSA]::Create()
        try{
            $parameters=$source.ExportParameters($false);$parameters.Exponent=[byte[]](3);$rsa.ImportParameters($parameters)
            {Invoke-TrustAnchorModule {param($r) Assert-TrustAnchorPublicKey $r} @($rsa)} | Should Throw 'The trust-anchor public key must be at least 3072 bits with exponent 65537.'
        }finally{$rsa.Dispose();$source.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor CLI boundary' {
    # Scenario: Every formal CLI is parsed and its parameter types are inspected.
    # Purpose: Prevent password, SecureString, or password-file parameters and require the interactive guard first.
    It 'UnitT10_exposes_no_password_parameter_and_guards_before_work' {
        foreach($name in @('New-TrustAnchorKeyPair.ps1','ConvertTo-TrustAnchorPublicKeyXml.ps1','Get-TrustAnchorFingerprint.ps1')){
            $path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            @($errors).Count | Should Be 0
            foreach($parameter in @($ast.ParamBlock.Parameters)){
                $parameter.Name.VariablePath.UserPath | Should Not Match '(?i)password|secure|stringfile'
                [string]$parameter.StaticType | Should Not Be 'System.Security.SecureString'
            }
            $commands=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.PipelineAst]}|ForEach-Object{$_.PipelineElements[0].GetCommandName()})
            [Array]::IndexOf($commands,'Assert-TrustAnchorInteractiveHost') | Should BeLessThan 3
        }
    }

    # Scenario: Each CI marker is set independently before the interactive guard runs.
    # Purpose: Refuse accidental key operations in common CI environments.
    It 'UnitT20_rejects_CI_marker_<Marker>' -TestCases @(@{Marker='CI'},@{Marker='GITHUB_ACTIONS'},@{Marker='TF_BUILD'},@{Marker='BUILD_BUILDID'},@{Marker='RUNNER_TEMP'}) {
        param($Marker)
        $prior=[Environment]::GetEnvironmentVariable($Marker)
        try{[Environment]::SetEnvironmentVariable($Marker,'1');{Invoke-TrustAnchorModule {Assert-TrustAnchorInteractiveHost}}|Should Throw "Trust-anchor key tools cannot run while $Marker is set."}
        finally{[Environment]::SetEnvironmentVariable($Marker,$prior)}
    }

    # Scenario: The fingerprint CLI is launched with redirected stdin and no CI marker.
    # Purpose: A non-interactive pipe must fail before reading any key path.
    It 'InterT30_rejects_redirected_stdin' {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-File');$info.ArgumentList.Add((Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'));$info.ArgumentList.Add('-PublicKeyXmlPath');$info.ArgumentList.Add((Join-Path $TestDrive 'missing.xml'))
        $info.RedirectStandardInput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false
        foreach($marker in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')){$info.Environment.Remove($marker)|Out-Null}
        $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Close();$process.WaitForExit()
        try{$process.ExitCode|Should Not Be 0;$process.StandardError.ReadToEnd()|Should Match 'interactive'}finally{$process.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor path and handle safety' {
    # Scenario: An output path is placed below this repository worktree.
    # Purpose: Prevent private keys and generated public output from entering Git history.
    It 'UnitT10_rejects_output_inside_a_worktree' {
        {Invoke-TrustAnchorModule {param($p) Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $script:RepositoryRoot 'fixture-key.pem'))} | Should Throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'
    }

    # Scenario: A target parent is reached through a native symlink or junction.
    # Purpose: Resolve every ancestor physically before accepting an output location.
    It 'InterT20_rejects_native_link_ancestor' {
        $physical=Join-Path $TestDrive 'physical';$alias=Join-Path $TestDrive 'alias';[void][IO.Directory]::CreateDirectory($physical)
        if($IsWindows){New-Item -ItemType Junction -Path $alias -Target $physical|Out-Null}else{New-Item -ItemType SymbolicLink -Path $alias -Target $physical|Out-Null}
        {Invoke-TrustAnchorModule {param($p) Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $alias 'key.pem'))} | Should Throw
    }

    # Scenario: The private-key leaf itself is a native symbolic link to a restrictive regular file.
    # Purpose: No-follow open must reject the leaf before permissions or bytes can be trusted.
    It 'InterT25_rejects_private_key_symbolic_link_leaf' {
        $target=Join-Path $TestDrive 'real-leaf';$link=Join-Path $TestDrive 'linked-leaf.pem'
        if($IsWindows){
            [void][IO.Directory]::CreateDirectory($target)
            try{New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop|Out-Null}
            catch [UnauthorizedAccessException]{New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop|Out-Null}
            ((Get-Item -Force -LiteralPath $link).Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Not Be 0
            Assert-TestThrowsMessage {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($link)} 'Reparse points are forbidden|NtOpenFile'
        }else{
            [IO.File]::WriteAllText($target,'fixture');chmod 600 $target
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop|Out-Null
            ((Get-Item -Force -LiteralPath $link).Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Not Be 0
            Assert-TestThrowsMessage {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($link)} "Native operation 'openat' failed with ELOOP"
        }
    }

    # Scenario: A private key is created through the helper and its native metadata is read back before and after bytes are written.
    # Purpose: Enforce owner-only DACL on Windows or owner mode 0600 through Unix fstat.
    It 'InterT30_sets_private_permissions_before_writing_and_reads_them_back' {
        $target=Invoke-TrustAnchorModule {param($p) Assert-TrustAnchorKeyPath $p PrivateKey} @((Join-Path $TestDrive 'private.pem'))
        $bytes=[Text.Encoding]::UTF8.GetBytes('encrypted fixture');$lease=$null
        try{
            $lease=Invoke-TrustAnchorModule {param($t,$b) New-TrustAnchorKeyFile $t $b} @($target,$bytes)
            Invoke-TrustAnchorModule {param($l) Assert-TrustAnchorPrivatePermissions $l.FileLease} @($lease)|Should Not BeNullOrEmpty
            [Text.Encoding]::UTF8.GetString($lease.FileLease.ReadAllBytes(1048576))|Should Be 'encrypted fixture'
        } finally {Invoke-TrustAnchorModule {param($l) Close-TrustAnchorCreatedFile $l} @($lease)}
    }

    # Scenario: A valid private file is given a second hard link before it is opened.
    # Purpose: Refuse aliases that defeat exclusive key ownership.
    It 'InterT40_rejects_a_multiply_linked_private_key' {
        $path=Join-Path $TestDrive 'linked.pem';[IO.File]::WriteAllText($path,'fixture');if(-not$IsWindows){chmod 600 $path}
        New-Item -ItemType HardLink -Path (Join-Path $TestDrive 'alias.pem') -Target $path|Out-Null
        {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'A regular file with exactly one link is required.'
    }

    # Scenario: A restrictive private file is stored beneath a newly initialized Git worktree.
    # Purpose: Existing-key reads must enforce the same outside-worktree boundary as key creation.
    It 'InterT45_rejects_existing_private_key_inside_a_worktree' {
        $worktree=Join-Path $TestDrive 'worktree';[void][IO.Directory]::CreateDirectory($worktree);& git -C $worktree init --quiet
        if($LASTEXITCODE -ne 0){throw 'Unable to create the worktree fixture.'}
        $path=Join-Path $worktree 'private.pem';[IO.File]::WriteAllText($path,'fixture');if(-not$IsWindows){chmod 600 $path}
        {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'
    }

    # Scenario: A Unix private file is group-readable, or a Windows file has an extra allow ACE.
    # Purpose: Enforce same-handle owner and permission checks before any bytes are returned.
    It 'InterT50_rejects_overbroad_native_permissions' {
        $path=Join-Path $TestDrive 'broad.pem';[IO.File]::WriteAllText($path,'fixture')
        if($IsWindows){
            $parent=$null;$file=$null;$original=$null
            try{
                $parent=Invoke-TrustAnchorModule {param($p) Open-PlatformDirectory -Root $p -RootOnly} @($TestDrive)
                $file=Invoke-TrustAnchorModule {param($p,$leaf) Open-PlatformFile -ParentLease $p -Leaf $leaf -Access Read -CreateMode OpenExisting} @($parent,[IO.Path]::GetFileName($path))
                $original=Invoke-TrustAnchorModule {param($lease) Get-PlatformPermissions -Lease $lease} @($file)
                $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$owner=$identity.User.Value}finally{$identity.Dispose()}
                Invoke-TrustAnchorModule {param($lease,$sddl) Set-PlatformPermissions -Lease $lease -Policy @{Sddl=$sddl;ReadOnly=$false}} @($file,"D:P(A;;FA;;;$owner)(A;;FR;;;WD)")|Out-Null
                {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'The private-key handle owner or protected DACL is not sufficiently restrictive.'
            }finally{
                if($null-ne$file -and $null-ne$original){Invoke-TrustAnchorModule {param($lease,$snapshot) Set-PlatformPermissions -Lease $lease -Snapshot $snapshot} @($file,$original)|Out-Null}
                if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()}
            }
        }else{
            chmod 640 $path
            {Invoke-TrustAnchorModule {param($p) Open-TrustAnchorPrivateKey $p} @($path)}|Should Throw 'The private-key handle must be owned by the effective user with mode 0600.'
        }
    }

    # Scenario: Public-output creation fails after the private create-new lease was retained.
    # Purpose: Rollback removes only the exact private-file identity created by this run.
    It 'InterT60_rolls_back_only_the_retained_create_new_identity' {
        $path=Join-Path $TestDrive 'rollback.pem';$target=Invoke-TrustAnchorModule {param($p) Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=$null
        try{$lease=Invoke-TrustAnchorModule {param($t) New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target);Invoke-TrustAnchorModule {param($l) Remove-TrustAnchorCreatedFile $l} @($lease);$lease=$null;Test-Path -LiteralPath $path|Should Be $false}
        finally{if($null-ne$lease){Invoke-TrustAnchorModule {param($l) Close-TrustAnchorCreatedFile $l} @($lease)}}
    }

    # Scenario: Source order for private-file creation is inspected without invoking the helper.
    # Purpose: Permission tightening and readback must precede the first key-byte write.
    It 'UnitT65_orders_permission_readback_before_key_bytes' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath
        $body=[regex]::Match($source,'(?s)function New-TrustAnchorKeyFile \{(.*?)\n\}').Groups[1].Value
        $set=$body.IndexOf('Set-PlatformPermissions',[StringComparison]::Ordinal)
        $readback=$body.IndexOf('Assert-TrustAnchorPrivatePermissions',[StringComparison]::Ordinal)
        $write=$body.IndexOf('.WriteNewBytes(',[StringComparison]::Ordinal)
        ($set -ge 0 -and $readback -gt $set -and $write -gt $readback) | Should Be $true
    }

    # Scenario: After a no-follow lease opens a valid file, its pathname is replaced before metadata revalidation.
    # Purpose: The operation must reject the swap or the host must prevent it while the original handle is retained.
    It 'InterT70_rejects_pathname_replacement_after_open' {
        $path=Join-Path $TestDrive 'original.pem';$replacement=Join-Path $TestDrive 'replacement.pem';$moved=Join-Path $TestDrive 'moved.pem'
        [IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement')
        if(-not$IsWindows){chmod 600 $path;chmod 600 $replacement}
        $parent=Invoke-TrustAnchorModule {param($p) Open-PlatformDirectory -Root $p -RootOnly} @($TestDrive);$file=$null
        try{
            $file=Invoke-TrustAnchorModule {param($parentLease,$leaf) Open-PlatformFile -ParentLease $parentLease -Leaf $leaf -Access Read -CreateMode OpenExisting} @($parent,[IO.Path]::GetFileName($path))
            $expected=$file.Observation;$blocked=$false
            try{Move-Item -LiteralPath $path -Destination $moved -ErrorAction Stop;Move-Item -LiteralPath $replacement -Destination $path -ErrorAction Stop}
            catch{$blocked=$true}
            if(-not$blocked){{Invoke-TrustAnchorModule {param($lease,$state) Assert-PlatformFileIdentity -Lease $lease -Expected $state -SingleLink -VerifyPath} @($file,$expected)}|Should Throw}
            else{$blocked|Should Be $true}
        } finally {if($null-ne$file){$file.Dispose()};$parent.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor regression inventory' {
    AfterAll {Remove-Module $script:Module.Name -Force -ErrorAction SilentlyContinue}

    # Scenario: The test source is inspected for native-host registration and runtime-only RSA generation.
    # Purpose: Keep platform-specific safety checks on native hosts without committing private-key fixtures or increasing skips.
    It 'UnitT10_registers_native_cases_without_committed_keys_or_skips' {
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath
        $source|Should Match '\$IsWindows'
        $source|Should Match 'RSA\]::Create\(3072\)'
        $source|Should Not Match 'BEGIN (RSA )?PRIVATE KEY'
        $skip=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'docs/standards/core-test-skip-inventory.json')
        $skip|Should Not Match 'trust-anchor-tools'
    }
}
