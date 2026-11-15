# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:ModulePath=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'
$script:Module=Import-Module $script:ModulePath -PassThru -Force

if($null-eq('SyuanTsai.AIInstructions.TrustAnchor.Tests.CryptoProbe'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security.Cryptography;
using System.Security;
namespace SyuanTsai.AIInstructions.TrustAnchor.Tests {
    public static class CryptoProbe {
        public static bool CanDecrypt(byte[] der, char[] password) {
            using (RSA rsa = RSA.Create()) { int read; rsa.ImportEncryptedPkcs8PrivateKey(password.AsSpan(), der, out read); return read == der.Length; }
        }
    }
    public sealed class SecureStringHost : PSHost {
        private readonly Guid instanceId=Guid.NewGuid();
        private readonly SecureStringHostUi ui;
        public SecureStringHost(SecureString[] responses){ui=new SecureStringHostUi(responses);}
        public int ReadCount { get { return ui.ReadCount; } }
        public override Guid InstanceId { get { return instanceId; } }
        public override string Name { get { return "TrustAnchorSecureStringHost"; } }
        public override Version Version { get { return new Version(1,0); } }
        public override PSHostUserInterface UI { get { return ui; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
        public override void EnterNestedPrompt(){throw new NotSupportedException();}
        public override void ExitNestedPrompt(){throw new NotSupportedException();}
        public override void NotifyBeginApplication(){}
        public override void NotifyEndApplication(){}
        public override void SetShouldExit(int exitCode){}
    }
    public sealed class SecureStringHostUi : PSHostUserInterface {
        private readonly Queue<SecureString> responses;
        private readonly SecureStringHostRawUi raw=new SecureStringHostRawUi();
        public int ReadCount { get; private set; }
        public SecureStringHostUi(SecureString[] values){responses=new Queue<SecureString>(values??Array.Empty<SecureString>());}
        private SecureString NextSecureString(){ReadCount++;if(responses.Count==0)throw new InvalidOperationException("No secure response remains.");return responses.Dequeue();}
        public override PSHostRawUserInterface RawUI { get { return raw; } }
        public override string ReadLine(){throw new NotSupportedException();}
        public override SecureString ReadLineAsSecureString(){return NextSecureString();}
        public override void Write(string value){}
        public override void Write(ConsoleColor foregroundColor,ConsoleColor backgroundColor,string value){}
        public override void WriteLine(string value){}
        public override void WriteErrorLine(string value){}
        public override void WriteDebugLine(string message){}
        public override void WriteProgress(long sourceId,ProgressRecord record){}
        public override void WriteVerboseLine(string message){}
        public override void WriteWarningLine(string message){}
        public override Dictionary<string,PSObject> Prompt(string caption,string message,Collection<FieldDescription> descriptions){var result=new Dictionary<string,PSObject>();foreach(var field in descriptions)result[field.Name]=PSObject.AsPSObject(NextSecureString());return result;}
        public override int PromptForChoice(string caption,string message,Collection<ChoiceDescription> choices,int defaultChoice){throw new NotSupportedException();}
        public override PSCredential PromptForCredential(string caption,string message,string userName,string targetName){throw new NotSupportedException();}
        public override PSCredential PromptForCredential(string caption,string message,string userName,string targetName,PSCredentialTypes allowedCredentialTypes,PSCredentialUIOptions options){throw new NotSupportedException();}
    }
    public sealed class SecureStringHostRawUi : PSHostRawUserInterface {
        public override ConsoleColor BackgroundColor { get; set; }
        public override Size BufferSize { get; set; }
        public override Coordinates CursorPosition { get; set; }
        public override int CursorSize { get; set; }
        public override ConsoleColor ForegroundColor { get; set; }
        public override bool KeyAvailable { get { return false; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(120,40); } }
        public override Size MaxWindowSize { get { return new Size(120,40); } }
        public override Coordinates WindowPosition { get; set; }
        public override Size WindowSize { get; set; }
        public override string WindowTitle { get; set; }
        public override void FlushInputBuffer(){}
        public override BufferCell[,] GetBufferContents(Rectangle rectangle){throw new NotSupportedException();}
        public override KeyInfo ReadKey(ReadKeyOptions options){throw new NotSupportedException();}
        public override void ScrollBufferContents(Rectangle source,Coordinates destination,Rectangle clip,BufferCell fill){throw new NotSupportedException();}
        public override void SetBufferContents(Coordinates origin,BufferCell[,] contents){throw new NotSupportedException();}
        public override void SetBufferContents(Rectangle rectangle,BufferCell fill){throw new NotSupportedException();}
    }
}
'@
}

function Invoke-TrustAnchorModule {param([scriptblock]$Action,[object[]]$Arguments=@())& $script:Module $Action @Arguments}
function New-TestPassword {param([string]$Text=('fixture-password-'+('x'*20)))return ($Text|ConvertTo-SecureString -AsPlainText -Force)}
function Get-TestFailure {param([scriptblock]$Action)try{& $Action;throw 'Expected the action to fail.'}catch{return $_}}
function Invoke-TestTrustAnchorCli {
    param(
        [Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Parameters,[Security.SecureString[]]$Responses=@(),
        [scriptblock]$ModuleSetup,[object[]]$ModuleSetupArguments=@(),[scriptblock]$ModuleResult
    )
    $testHost=[SyuanTsai.AIInstructions.TrustAnchor.Tests.SecureStringHost]::new($Responses);$runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($testHost);$powershell=[Management.Automation.PowerShell]::Create()
    try{
        $runspace.Open();$powershell.Runspace=$runspace;$runspace.SessionStateProxy.SetVariable('TrustAnchorModuleSetup',$ModuleSetup);$runspace.SessionStateProxy.SetVariable('TrustAnchorModuleSetupArguments',$ModuleSetupArguments);$runspace.SessionStateProxy.SetVariable('TrustAnchorModuleResult',$ModuleResult)
        $escaped=$script:ModulePath.Replace("'","''");[void]$powershell.AddScript("`$module=Import-Module '$escaped' -PassThru -Force; & `$module { `$script:TrustAnchorInteractiveStateTestHook={ [pscustomobject][ordered]@{InputRedirected=`$false;UserInteractive=`$true} } }; if(`$null-ne`$TrustAnchorModuleSetup){& `$module `$TrustAnchorModuleSetup @TrustAnchorModuleSetupArguments}")
        [void]$powershell.Invoke();if($powershell.HadErrors){throw $powershell.Streams.Error[0]};$powershell.Commands.Clear();$powershell.Streams.Error.Clear()
        [void]$powershell.AddCommand($Path);foreach($name in $Parameters.Keys){[void]$powershell.AddParameter($name,$Parameters[$name])}
        $invokeFailure=$null;try{$output=@($powershell.Invoke())}catch{$invokeFailure=$_;$output=@()};$cliErrors=@($powershell.Streams.Error);if($null-ne$invokeFailure-and$cliErrors.Count-eq0){$cliErrors=@($invokeFailure)};$hadErrors=$powershell.HadErrors-or$null-ne$invokeFailure;$moduleOutput=@()
        if($null-ne$ModuleResult){$powershell.Commands.Clear();$powershell.Streams.Error.Clear();[void]$powershell.AddScript('if($null-ne$TrustAnchorModuleResult){& $module $TrustAnchorModuleResult}');$moduleOutput=@($powershell.Invoke());if($powershell.HadErrors){throw $powershell.Streams.Error[0]}}
        return [pscustomobject]@{Output=$output;Errors=$cliErrors;ReadCount=$testHost.ReadCount;HadErrors=$hadErrors;ModuleOutput=$moduleOutput}
    }finally{$powershell.Dispose();$runspace.Dispose()}
}
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
function Get-CompactAstText {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    return ($Ast.Extent.Text -replace '\s','')
}
function Get-TestSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text)
    try{return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
    finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
}
function Get-TestPowerShellTokenRecords {
    param([Parameter(Mandatory)][string]$Source,[switch]$ExpandCSharpHereString)
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    if(@($errors).Count-ne0){return $null}
    $records=[Collections.Generic.List[string]]::new()
    foreach($token in @($tokens|Where-Object{$_.Kind-cnotin @('Comment','NewLine','LineContinuation','EndOfInput')})){
        $text=[string]$token.Text
        if($ExpandCSharpHereString-and$token.Kind-ceq[Management.Automation.Language.TokenKind]::HereStringLiteral){
            $normalized=$text.Replace("`r`n","`n").Replace("`r","`n");$first=$normalized.IndexOf("`n",[StringComparison]::Ordinal);$last=$normalized.LastIndexOf("`n",[StringComparison]::Ordinal)
            if($first-lt0-or$last-le$first){return $null}
            $csharp=$normalized.Substring($first+1,$last-$first-1);$tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($csharp)
            if(@($tree.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){return $null}
            $csharpRecords=@($tree.GetRoot().DescendantTokens()|ForEach-Object{$kind=[Enum]::GetName([Microsoft.CodeAnalysis.CSharp.SyntaxKind],$_.RawKind);$value=$_.Text.Replace("`r`n","`n").Replace("`r","`n");"$kind|$($value.Length):$value"})
            $text="CSharpTokens{"+($csharpRecords-join"`n")+'}'
        }
        $records.Add("$($token.Kind)|$($token.TokenFlags)|$($text.Length):$text")
    }
    return ,$records.ToArray()
}
function Get-TestAstContract {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    $source=$Ast.Extent.Text;$tokens=Get-TestPowerShellTokenRecords $source
    if($null-eq$tokens){return $null}
    $parsedTokens=$null;$errors=$null;$root=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$parsedTokens,[ref]$errors)
    if(@($errors).Count-ne0){return $null}
    $nodes=@($root.FindAll({param($node)$true},$true));$records=[Collections.Generic.List[string]]::new();$ordinal=0
    foreach($node in $nodes){
        $nodeTokens=@($parsedTokens|Where-Object{$_.Kind-cnotin@('Comment','NewLine','LineContinuation','EndOfInput')-and$_.Extent.StartOffset-ge$node.Extent.StartOffset-and$_.Extent.EndOffset-le$node.Extent.EndOffset}|ForEach-Object{$value=[string]$_.Text;"$($_.Kind)|$($_.TokenFlags)|$($value.Length):$value"})
        $parent=if($null-eq$node.Parent){'<root>'}else{$node.Parent.GetType().Name}
        $records.Add("$ordinal|$($node.GetType().Name)|$parent|$($nodeTokens.Count)|$(Get-TestSha256Text ($nodeTokens-join"`n"))");$ordinal++
    }
    $serialized=(@($tokens|ForEach-Object{"TOKEN|$_"})+@($records|ForEach-Object{"AST|$_"}))-join"`n"
    return [pscustomobject]@{TokenCount=$tokens.Count;NodeCount=$nodes.Count;Sha256=(Get-TestSha256Text $serialized);Records=$records.ToArray()}
}
function Test-TestAstContract {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,[Parameter(Mandatory)][int]$TokenCount,[Parameter(Mandatory)][int]$NodeCount,[Parameter(Mandatory)][string]$Sha256)
    $actual=Get-TestAstContract $Ast
    return $null-ne$actual-and$actual.TokenCount-eq$TokenCount-and$actual.NodeCount-eq$NodeCount-and$actual.Sha256-ceq$Sha256
}
function Get-TrustAnchorProtectedTokenContract {
    param([Parameter(Mandatory)][string]$Source)
    $records=Get-TestPowerShellTokenRecords $Source -ExpandCSharpHereString
    if($null-eq$records){return $null}
    return [pscustomobject]@{TokenCount=$records.Count;Sha256=(Get-TestSha256Text ($records-join"`n"))}
}
function Get-TrustAnchorProtectedContracts {
    return @{
        'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'=@{TokenCount=3778;Sha256='be24f9c615ec23405c352ad18f7608ee1590d452513780d336f330ffdd76fa66'}
        'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1'=@{TokenCount=102;Sha256='512c1be2ce8fd5f4ba57d5bef19ebaab1b3ec95937acfcd2180b28e32fd2207f'}
        'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1'=@{TokenCount=78;Sha256='c6de147913690c4bf77f44d1c093a558cebb688d8eb0a7b43edd789f42c3b65d'}
        'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'=@{TokenCount=109;Sha256='c5f2c20e1d3f9f86f073fe75f8a8ee578138cf51dad1a97c3bce2b5feac7994b'}
    }
}
function Test-TrustAnchorProtectedContract {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Source)
    $expected=(Get-TrustAnchorProtectedContracts)[$RelativePath];if($null-eq$expected){return $false}
    $actual=Get-TrustAnchorProtectedTokenContract $Source
    return $null-ne$actual-and$actual.TokenCount-eq$expected.TokenCount-and$actual.Sha256-ceq$expected.Sha256
}
function Get-TrustAnchorEmbeddedCSharpSource {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($ModuleSource,[ref]$tokens,[ref]$errors)
    if(@($errors).Count-ne0){return $null}
    $hereStrings=@($tokens|Where-Object{$_.Kind-ceq[Management.Automation.Language.TokenKind]::HereStringLiteral})
    if($hereStrings.Count-ne1){return $null}
    $text=$hereStrings[0].Text.Replace("`r`n","`n").Replace("`r","`n");$first=$text.IndexOf("`n",[StringComparison]::Ordinal);$last=$text.LastIndexOf("`n",[StringComparison]::Ordinal)
    if($first-lt0-or$last-le$first){return $null}
    return $text.Substring($first+1,$last-$first-1)
}
function Get-TrustAnchorCSharpAnalysis {
    param([Parameter(Mandatory)][string]$Source)
    $tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($Source.Replace("`r`n","`n").Replace("`r","`n"))
    $references=[Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    foreach($path in ([string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)){if($path){$references.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($path))}}
    $options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('TrustAnchorSemanticContract',[Microsoft.CodeAnalysis.SyntaxTree[]]@(,$tree),[Microsoft.CodeAnalysis.MetadataReference[]]$references.ToArray(),$options)
    if(@($compilation.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){return $null}
    return [pscustomobject]@{Tree=$tree;Root=$tree.GetRoot();Model=$compilation.GetSemanticModel($tree)}
}
function Get-TestCSharpOperations {
    param([Parameter(Mandatory)]$Operation)
    $queue=[Collections.Generic.Queue[object]]::new();$result=[Collections.Generic.List[object]]::new();$queue.Enqueue($Operation)
    while($queue.Count-gt0){$current=$queue.Dequeue();$result.Add($current);foreach($child in $current.ChildOperations){$queue.Enqueue($child)}}
    return $result.ToArray()
}
function Get-TestCleanupContext {
    param([Parameter(Mandatory)]$Node)
    $cursor=$Node
    while($null-ne$cursor){
        if($cursor.GetType().Name-ceq'FinallyClauseSyntax'){return 'finally'}
        if($cursor.GetType().Name-ceq'CatchClauseSyntax'){return 'catch'}
        if($cursor-is[Management.Automation.Language.StatementBlockAst]-and$cursor.Parent-is[Management.Automation.Language.TryStatementAst]){if($cursor.Parent.Finally-eq$cursor){return 'finally'}}
        if($cursor-is[Management.Automation.Language.CatchClauseAst]){return 'catch'}
        $cursor=$cursor.Parent
    }
    return 'body'
}
function Get-TrustAnchorCleanupRecords {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $records=[Collections.Generic.List[string]]::new();$csharp=Get-TrustAnchorEmbeddedCSharpSource $ModuleSource;$analysis=Get-TrustAnchorCSharpAnalysis $csharp
    if($null-eq$analysis){return $null}
    foreach($method in @($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'})){
        if($null-eq$method.Body){continue}
        $operation=$analysis.Model.GetOperation($method.Body);if($null-eq$operation){return $null}
        foreach($item in @(Get-TestCSharpOperations $operation|Sort-Object{$_.Syntax.SpanStart})){
            if($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation-and$item.TargetMethod.ContainingType.ToString()-ceq'System.Security.Cryptography.CryptographicOperations'-and$item.TargetMethod.Name-ceq'ZeroMemory'){
                $records.Add("CSharp|$($method.Identifier.ValueText)|ZeroMemory|$($item.Arguments[0].Value.Syntax.ToString())|$(Get-TestCleanupContext $item.Syntax)")
            }
        }
    }
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ModuleSource,[ref]$tokens,[ref]$errors);if(@($errors).Count-ne0){return $null}
    foreach($member in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){
        $type=if($member.Static-and$member.Expression-is[Management.Automation.Language.TypeExpressionAst]){$member.Expression.TypeName.FullName}else{''};$name=[string]$member.Member.Value;$target=$null;$api=$null
        if($type-ceq'Runtime.InteropServices.Marshal'-and$name-ceq'ZeroFreeGlobalAllocUnicode'){$api='ZeroFreeGlobalAllocUnicode';$target=$member.Arguments[0].Extent.Text}
        elseif($type-ceq'Security.Cryptography.CryptographicOperations'-and$name-ceq'ZeroMemory'){$api='ZeroMemory';$target=$member.Arguments[0].Extent.Text}
        elseif($type-ceq'SyuanTsai.AIInstructions.TrustAnchor.SecretBridge'-and$name-ceq'Zero'){$api='ZeroCharacters';$target=$member.Arguments[0].Extent.Text}
        elseif(-not$member.Static-and$name-ceq'Free'-and$member.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$member.Expression.VariablePath.UserPath-ceq'pin'){$api='FreePin';$target='$pin'}
        if($null-ne$api){$records.Add("PowerShell|$(Get-TestAncestorFunctionName $member)|$api|$target|$(Get-TestCleanupContext $member)")}
    }
    return ,$records.ToArray()
}
function Test-TrustAnchorCleanupContract {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $actual=Get-TrustAnchorCleanupRecords $ModuleSource;if($null-eq$actual){return $false}
    $expected=@'
CSharp|Zero|ZeroMemory|MemoryMarshal.AsBytes(value.AsSpan())|body
CSharp|RequirePublicPemEnvelope|ZeroMemory|der|catch
CSharp|RequirePublicPemEnvelope|ZeroMemory|encoded|finally
CSharp|DecodePublicPem|ZeroMemory|der|finally
CSharp|ValidateEncryptedPemProfile|ZeroMemory|der|body
CSharp|ValidateEncryptedPemProfile|ZeroMemory|salt|finally
CSharp|ValidateEncryptedPemProfile|ZeroMemory|iv|finally
CSharp|ValidateEncryptedPemProfile|ZeroMemory|encrypted|finally
CSharp|ValidateEncryptedPemProfile|ZeroMemory|der|finally
PowerShell|Use-TrustAnchorPassword|ZeroFreeGlobalAllocUnicode|$buffer|finally
PowerShell|Use-TrustAnchorPassword|ZeroCharacters|$characters|finally
PowerShell|Use-TrustAnchorPassword|FreePin|$pin|finally
PowerShell|Read-TrustAnchorInputBytes|ZeroMemory|$bytes|finally
PowerShell|Open-TrustAnchorPrivateKey|ZeroMemory|$bytes|finally
PowerShell|Get-TrustAnchorFingerprint|ZeroMemory|$spki|finally
PowerShell|Invoke-NewTrustAnchorKeyPairAction|ZeroMemory|$publicBytes|finally
PowerShell|Invoke-NewTrustAnchorKeyPairAction|ZeroMemory|$privateBytes|finally
PowerShell|Invoke-ConvertToTrustAnchorPublicKeyXmlAction|ZeroMemory|$inputBytes|finally
PowerShell|Invoke-ConvertToTrustAnchorPublicKeyXmlAction|ZeroMemory|$bytes|finally
PowerShell|Invoke-GetTrustAnchorFingerprintAction|ZeroMemory|$inputBytes|finally
'@
    return ($actual-join"`n")-ceq$expected.Trim()
}
function Set-TestSourceSpan {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][int]$Start,[Parameter(Mandatory)][int]$Length,[Parameter(Mandatory)][AllowEmptyString()][string]$Replacement)
    return $Source.Substring(0,$Start)+$Replacement+$Source.Substring($Start+$Length)
}
function Test-TrustAnchorCliGuardAst {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][hashtable]$Contract
    )
    if(-not(Test-TestAstContract $Ast $Contract.WholeTokenCount $Contract.WholeNodeCount $Contract.WholeSha256)){return $false}
    $statements=@($Ast.EndBlock.Statements);if($statements.Count-ne2-or$statements[1]-isnot[Management.Automation.Language.TryStatementAst]){return $false}
    $try=$statements[1];if(@($try.Body.Statements).Count-ne1-or-not(Test-TestAstContract $try.Body.Statements[0] $Contract.TryTokenCount $Contract.TryNodeCount $Contract.TrySha256)){return $false}
    $outerPipeline=$try.Body.Statements[0];if($outerPipeline-isnot[Management.Automation.Language.PipelineAst]-or$outerPipeline.PipelineElements.Count-ne1){return $false}
    $outer=$outerPipeline.PipelineElements[0];if($outer-isnot[Management.Automation.Language.CommandAst]-or$outer.InvocationOperator-cne[Management.Automation.Language.TokenKind]::Ampersand){return $false}
    $elements=@($outer.CommandElements);if($elements.Count-ne(2+$Contract.OuterArguments.Count)){return $false}
    if($elements[0]-isnot[Management.Automation.Language.VariableExpressionAst]-or$elements[0].VariablePath.UserPath-cne'module'){return $false}
    if($elements[1]-isnot[Management.Automation.Language.ScriptBlockExpressionAst]){return $false}
    for($index=0;$index-lt$Contract.OuterArguments.Count;$index++){$value=$elements[$index+2];if($value-isnot[Management.Automation.Language.VariableExpressionAst]-or$value.VariablePath.UserPath-cne$Contract.OuterArguments[$index]){return $false}}
    $inner=$elements[1].ScriptBlock
    if($null-eq$inner.ParamBlock-or$null-ne$inner.BeginBlock-or$null-ne$inner.ProcessBlock-or$null-ne$inner.CleanBlock-or$null-ne$inner.DynamicParamBlock){return $false}
    $innerParameters=@($inner.ParamBlock.Parameters|ForEach-Object{if($_.Attributes.Count-eq0){$type='<none>'}else{$type=($_.Attributes|ForEach-Object{$_.TypeName.FullName})-join','};if($null-ne$_.DefaultValue){$type+='|default'};$_.Name.VariablePath.UserPath+'|'+$type})
    if(($innerParameters-join"`n")-cne($Contract.InnerParameters-join"`n")){return $false}
    $innerStatements=@($inner.EndBlock.Statements);if($innerStatements.Count-ne2){return $false}
    $innerCommands=@()
    foreach($statement in $innerStatements){if($statement-isnot[Management.Automation.Language.PipelineAst]-or$statement.PipelineElements.Count-ne1-or$statement.PipelineElements[0]-isnot[Management.Automation.Language.CommandAst]){return $false};$innerCommands+=$statement.PipelineElements[0]}
    if($innerCommands[0].InvocationOperator-cne[Management.Automation.Language.TokenKind]::Unknown-or$innerCommands[0].GetCommandName()-cne'Assert-TrustAnchorInteractiveHost'-or$innerCommands[0].CommandElements.Count-ne1){return $false}
    $action=$innerCommands[1];if($action.InvocationOperator-cne[Management.Automation.Language.TokenKind]::Unknown-or$action.GetCommandName()-cne$Contract.Action-or$action.CommandElements.Count-ne(1+2*$Contract.ActionArguments.Count)){return $false}
    for($index=0;$index-lt$Contract.ActionArguments.Count;$index++){
        $parts=$Contract.ActionArguments[$index]-split'=',2;$parameter=$action.CommandElements[1+2*$index];$value=$action.CommandElements[2+2*$index]
        if($parameter-isnot[Management.Automation.Language.CommandParameterAst]-or$null-ne$parameter.Argument-or$parameter.ParameterName-cne$parts[0]){return $false}
        if($value-isnot[Management.Automation.Language.VariableExpressionAst]-or$value.VariablePath.UserPath-cne$parts[1]){return $false}
    }
    return $true
}
function Get-TrustAnchorCliContracts {
    return @{
        'New-TrustAnchorKeyPair.ps1'=@{
            Action='Invoke-NewTrustAnchorKeyPairAction';CmdletBinding='[CmdletBinding()]';Parameters=@(
                "KeyId|[Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]",
                'PrivateKeyPath|[Parameter(Mandatory)][string]',
                'PublicKeyXmlPath|[Parameter(Mandatory)][string]'
            );InnerParameters=@('id|<none>','privatePath|<none>','publicPath|<none>');OuterArguments=@('KeyId','PrivateKeyPath','PublicKeyXmlPath');ActionArguments=@('KeyId=id','PrivateKeyPath=privatePath','PublicKeyXmlPath=publicPath');WholeTokenCount=102;WholeNodeCount=82;WholeSha256='f5ee5482361d16e3938f8bec8c7b5df96b75868b1fbadde5b7725141f49aea4a';TryTokenCount=24;TryNodeCount=30;TrySha256='31e3057472486f3ee6dc6e0cfecbb36a70b2e1ebf81d0a7addc718b2d0a0ed84'
        }
        'ConvertTo-TrustAnchorPublicKeyXml.ps1'=@{
            Action='Invoke-ConvertToTrustAnchorPublicKeyXmlAction';CmdletBinding='[CmdletBinding()]';Parameters=@(
                'PublicKeyPemPath|[Parameter(Mandatory)][string]',
                'OutputPath|[Parameter(Mandatory)][string]'
            );InnerParameters=@('inputPath|<none>','outputPath|<none>');OuterArguments=@('PublicKeyPemPath','OutputPath');ActionArguments=@('PublicKeyPemPath=inputPath','OutputPath=outputPath');WholeTokenCount=78;WholeNodeCount=68;WholeSha256='26a531529651063f8cb72d35aced4208216a9845c2f2a3ba269cc3121b71cd49';TryTokenCount=19;TryNodeCount=25;TrySha256='71ecd62780be11717df10a16b44ec768af37f8b109b5f27bba14c3498a60263b'
        }
        'Get-TrustAnchorFingerprint.ps1'=@{
            Action='Invoke-GetTrustAnchorFingerprintAction';CmdletBinding="[CmdletBinding(DefaultParameterSetName='Xml')]";Parameters=@(
                "PublicKeyXmlPath|[Parameter(Mandatory,ParameterSetName='Xml')][string]",
                "PublicKeyPemPath|[Parameter(Mandatory,ParameterSetName='Pem')][string]",
                "EncryptedPrivateKeyPath|[Parameter(Mandatory,ParameterSetName='Private')][string]"
            );InnerParameters=@('xmlPath|<none>','pemPath|<none>','privatePath|<none>');OuterArguments=@('PublicKeyXmlPath','PublicKeyPemPath','EncryptedPrivateKeyPath');ActionArguments=@('PublicKeyXmlPath=xmlPath','PublicKeyPemPath=pemPath','EncryptedPrivateKeyPath=privatePath');WholeTokenCount=109;WholeNodeCount=87;WholeSha256='55f2d09ae71f724139f63b1fd90a56d9e0689147c4ddb842c7febf6682f06c41';TryTokenCount=24;TryNodeCount=30;TrySha256='cdde2705e23f9b4451932a35af22391fa15d243c539569210f0de44711f1b71b'
        }
    }
}
function Test-TestCSharpOperationDependsOnParameter {
    param([Parameter(Mandatory)]$Operation,[Parameter(Mandatory)][string]$ParameterName)
    foreach($item in Get-TestCSharpOperations $Operation){if($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::ParameterReference-and$item.Parameter.Name-ceq$ParameterName){return $true}}
    return $false
}
function Test-TrustAnchorPublicDecoderOperations {
    param([Parameter(Mandatory)][string]$CSharpSource)
    $analysis=Get-TrustAnchorCSharpAnalysis $CSharpSource;if($null-eq$analysis){return $false}
    $methods=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'})
    $pem=@($methods|Where-Object{$_.Identifier.ValueText-ceq'DecodePublicPem'});$xml=@($methods|Where-Object{$_.Identifier.ValueText-ceq'DecodePublicXml'})
    if($pem.Count-ne1-or$xml.Count-ne1){return $false}
    $records=[Collections.Generic.List[string]]::new();$xmlValidator=$null;$xmlString=$null
    foreach($method in $methods){
        if($null-eq$method.Body){continue}
        $bodyOperation=$analysis.Model.GetOperation($method.Body);if($null-eq$bodyOperation){return $false}
        $byteParameters=@($method.ParameterList.Parameters|Where-Object{($analysis.Model.GetDeclaredSymbol($_).Type.ToString())-ceq'byte[]'}|ForEach-Object{$analysis.Model.GetDeclaredSymbol($_).Name})
        foreach($operation in Get-TestCSharpOperations $bodyOperation){
            if($operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation){
                $target=$operation.TargetMethod
                if($method.Identifier.ValueText-ceq'DecodePublicXml'-and$target.Name-ceq'RequirePublicXmlStructure'){$xmlValidator=$operation}
            }
            if($null-ne$operation.Type-and$operation.Type.SpecialType-ceq[Microsoft.CodeAnalysis.SpecialType]::System_String-and-not$operation.ConstantValue.HasValue){
                $sources=@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnParameter $operation $_})
                if($sources.Count-gt0){
                    $symbol=if($operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation){$operation.TargetMethod.ContainingType.ToString()+'.'+$operation.TargetMethod.Name}else{$operation.Kind.ToString()}
                    $records.Add("$($method.Identifier.ValueText)|$($operation.Kind)|$symbol|$($sources-join',')")
                    if($method.Identifier.ValueText-ceq'DecodePublicXml'){$xmlString=$operation}
                }
            }
        }
    }
    if(($records-join"`n")-cne'DecodePublicXml|Invocation|System.Text.Encoding.GetString|value'){return $false}
    if($null-eq$xmlValidator-or$null-eq$xmlString-or$xmlValidator.Syntax.SpanStart-ge$xmlString.Syntax.SpanStart){return $false}
    if($xmlString.Kind-cne[Microsoft.CodeAnalysis.OperationKind]::Invocation-or$xmlString.Instance.Type.ToString()-cne'System.Text.UTF8Encoding'-or$xmlString.Arguments.Length-ne1){return $false}
    $argument=$xmlString.Arguments[0].Value
    if($argument.Kind-cne[Microsoft.CodeAnalysis.OperationKind]::ParameterReference-or$argument.Parameter.Name-cne'value'){return $false}
    $validatorArgument=$xmlValidator.Arguments[0].Value
    if($xmlValidator.Arguments.Length-ne1-or$validatorArgument.Kind-cne[Microsoft.CodeAnalysis.OperationKind]::ParameterReference-or$validatorArgument.Parameter.Name-cne'value'){return $false}
    return $true
}
function Get-TestAncestorFunctionName {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $parent=$Node.Parent
    while($null-ne$parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){return $parent.Name};$parent=$parent.Parent}
    return $null
}
function Get-TrustAnchorSensitiveFunctionContracts {
    return @{
        'Get-TrustAnchorInteractiveState'=@{TokenCount=45;NodeCount=40;Sha256='d302f30d93ff251a9d0c0e62e341e3ce538c77427510a6b5ce31577219370967'}
        'Assert-TrustAnchorInteractiveHost'=@{TokenCount=79;NodeCount=70;Sha256='2304c31b95ef0f4cc706d54d9edcebcb137f90645dc0c5b9e95f235d330daeae'}
        'Use-TrustAnchorPassword'=@{TokenCount=175;NodeCount=127;Sha256='220b44c28a28ce17d62a7392aa1fc1f17daab61168d78a8a832d2955544c072d'}
        'Read-TrustAnchorPassword'=@{TokenCount=143;NodeCount=135;Sha256='b2f7e57957217513d8137de32613c9d4dbae5fe982aa74dbeeacc56ddef3f5f9'}
        'Invoke-NewTrustAnchorKeyPairAction'=@{TokenCount=319;NodeCount=316;Sha256='4c4eddceaa0122ebdc5284faf726189add624f7957b724426025dc87dce201ec'}
        'Invoke-ConvertToTrustAnchorPublicKeyXmlAction'=@{TokenCount=138;NodeCount=134;Sha256='e9ac0c1f60fe96f1ef0eb4c387352af72c5b4c0121232cd65a85f2a32c403a2f'}
        'Invoke-GetTrustAnchorFingerprintAction'=@{TokenCount=189;NodeCount=180;Sha256='e572d804140b536d682e5be82be60faa1dc3a37d7e090924ec07a73552ffad08'}
    }
}
function Test-TrustAnchorSensitiveFunctionAsts {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    foreach($entry in (Get-TrustAnchorSensitiveFunctionContracts).GetEnumerator()){
        $function=@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$entry.Key},$true))
        if($function.Count-ne1-or-not(Test-TestAstContract $function[0] $entry.Value.TokenCount $entry.Value.NodeCount $entry.Value.Sha256)){return $false}
    }
    return $true
}
function Test-ExactInventory {
    param([Parameter(Mandatory)][string[]]$Actual,[Parameter(Mandatory)][string]$Expected)
    $actualText=(@($Actual|Group-Object|Sort-Object Name|ForEach-Object{"$($_.Count)|$($_.Name)"})-join"`n")
    $expectedText=(@($Expected.Trim()-split'\r?\n'|Sort-Object{($_-split'\|',2)[1]})-join"`n")
    return $actualText -ceq $expectedText
}
function Get-TrustAnchorCSharpInventory {
    param([Parameter(Mandatory)][string]$Source)
    $csharp=Get-TrustAnchorEmbeddedCSharpSource $Source;if($null-eq$csharp){return $null}
    $tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($csharp)
    $references=[Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    foreach($path in ([string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)){if($path){$references.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($path))}}
    $options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('TrustAnchorClosedInventory',[Microsoft.CodeAnalysis.SyntaxTree[]]@(,$tree),[Microsoft.CodeAnalysis.MetadataReference[]]$references.ToArray(),$options)
    if(@($compilation.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){return $null}
    $model=$compilation.GetSemanticModel($tree);$nodes=@($tree.GetRoot().DescendantNodes());$members=[Collections.Generic.List[string]]::new();$types=[Collections.Generic.List[string]]::new()
    foreach($node in @($nodes|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'})){
        $symbol=$model.GetSymbolInfo($node).Symbol
        if($null-eq$symbol){if($node.Expression.ToString()-ceq'nameof'){$members.Add('builtin|nameof');continue};return $null}
        $members.Add("$(if($symbol.IsStatic){'static'}else{'instance'})|$($symbol.ContainingType.ToString())|$($symbol.Name)")
    }
    foreach($node in @($nodes|Where-Object{$_.GetType().Name-ceq'ObjectCreationExpressionSyntax'})){$type=$model.GetTypeInfo($node).Type;if($null-eq$type){return $null};$types.Add($type.ToString())}
    return [pscustomobject]@{Members=$members.ToArray();Types=$types.ToArray()}
}
function Test-TrustAnchorPasswordSourceAst {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    $commands=@($Ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
    if(@($commands|Where-Object{$null-eq$_.GetCommandName()}).Count-ne0){return $false}
    $commandNames=@($commands|ForEach-Object{$_.GetCommandName()})
    $expectedCommands=@'
1|Add-Type
10|Assert-PlatformFileIdentity
3|Assert-TrustAnchorInteractiveHost
3|Assert-TrustAnchorKeyPath
1|Assert-TrustAnchorOutsideWorktree
4|Assert-TrustAnchorPrivatePermissions
3|Assert-TrustAnchorPublicKey
3|Close-TrustAnchorCreatedFile
4|Close-TrustAnchorPathEvidence
2|ConvertTo-Json
3|ConvertTo-TrustAnchorCanonicalXml
1|Export-ModuleMember
1|Export-TrustAnchorEncryptedPrivateKey
1|Get-Command
3|Get-TrustAnchorFingerprint
1|Get-TrustAnchorInteractiveState
3|Get-TrustAnchorLeaseHandle
3|Get-TrustAnchorMetadataEvidence
1|Get-TrustAnchorPhysicalParent
1|git
1|Import-Module
1|Import-TrustAnchorEncryptedPrivateKey
2|Import-TrustAnchorPublicPem
1|Import-TrustAnchorPublicXml
3|Join-Path
8|New-TrustAnchorError
3|New-TrustAnchorKeyFile
2|New-TrustAnchorPathEvidence
1|Open-PlatformDirectory
2|Open-PlatformFile
1|Open-TrustAnchorPrivateKey
23|Out-Null
2|Read-Host
3|Read-TrustAnchorInputBytes
2|Read-TrustAnchorPassword
1|Remove-TrustAnchorCreatedFile
1|Resolve-PlatformPhysicalPath
2|Set-PlatformPermissions
1|Set-StrictMode
4|Split-Path
1|Test-TrustAnchorMetadataEqual
4|Use-TrustAnchorPassword
2|Where-Object
'@
    if(-not(Test-ExactInventory $commandNames $expectedCommands)){return $false}
    $readHost=@($commands|Where-Object{$_.GetCommandName()-ceq'Read-Host'})
    if($readHost.Count-ne2){return $false}
    $expectedPrompts=@('Private-key password (minimum 16 characters)','Confirm private-key password')
    $actualPrompts=[Collections.Generic.List[string]]::new()
    foreach($command in $readHost){
        if((Get-TestAncestorFunctionName $command)-cne'Read-TrustAnchorPassword'){return $false}
        $elements=@($command.CommandElements)
        if($command.InvocationOperator-cne[Management.Automation.Language.TokenKind]::Unknown-or$elements.Count-ne3){return $false}
        if($elements[1]-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$elements[2]-isnot[Management.Automation.Language.CommandParameterAst]){return $false}
        if($elements[2].ParameterName-cne'AsSecureString'-or$null-ne$elements[2].Argument){return $false}
        $actualPrompts.Add([string]$elements[1].Value)
    }
    if(($actualPrompts-join"`n")-cne($expectedPrompts-join"`n")){return $false}
    $variables=@($Ast.FindAll({param($node)$node -is [Management.Automation.Language.VariableExpressionAst]},$true))
    $members=@($Ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true))
    $memberNames=@($members|ForEach-Object{$kind=if($_.Static){'static'}else{'instance'};$type=if($_.Expression-is[Management.Automation.Language.TypeExpressionAst]){$_.Expression.TypeName.FullName}else{$_.Expression.StaticType.FullName};"$kind|$type|$($_.Member.Value)"})
    $expectedMembers=@'
1|instance|System.Object|Complete
21|instance|System.Object|Dispose
1|instance|System.Object|EndsWith
2|instance|System.Object|ExportParameters
1|instance|System.Object|ExportSubjectPublicKeyInfo
1|instance|System.Object|Free
2|instance|System.Object|GetBytes
1|instance|System.Object|GetField
1|instance|System.Object|GetType
1|instance|System.Object|GetValue
1|instance|System.Object|ImportParameters
9|instance|System.Object|Invoke
1|instance|System.Object|Read
1|instance|System.Object|ReadAllBytes
3|instance|System.Object|ToLowerInvariant
1|instance|System.Object|WriteNewBytes
1|static|byte[]|new
1|static|char[]|new
2|static|Convert|FromBase64String
2|static|Convert|ToBase64String
3|static|Convert|ToHexString
1|static|Environment|GetEnvironmentVariable
1|static|InvalidOperationException|new
3|static|IO.Directory|Exists
2|static|IO.File|Exists
1|static|IO.File|Open
1|static|IO.IOException|new
1|static|IO.Path|GetFileName
6|static|IO.Path|GetFullPath
1|static|Management.Automation.ErrorRecord|new
1|static|Runtime.InteropServices.GCHandle|Alloc
1|static|Runtime.InteropServices.GCHandle|new
1|static|Runtime.InteropServices.Marshal|Copy
1|static|Runtime.InteropServices.Marshal|SecureStringToGlobalAllocUnicode
1|static|Runtime.InteropServices.Marshal|ZeroFreeGlobalAllocUnicode
8|static|Security.Cryptography.CryptographicOperations|ZeroMemory
2|static|Security.Cryptography.RSA|Create
3|static|Security.Cryptography.SHA256|HashData
2|static|Security.Principal.WindowsIdentity|GetCurrent
1|static|string|IsNullOrEmpty
7|static|string|IsNullOrWhiteSpace
1|static|System.Numerics.BigInteger|new
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|DecodePublicPem
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|DecodePublicXml
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|EffectiveUid
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|ExportEncryptedPem
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|FixedTimeEquals
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|ImportEncryptedPem
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|Zero
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector|Inspect
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|AssertSafeParent
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|Begin
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|DeleteExact
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|Inspect
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|InspectMetadata
2|static|Text.UTF8Encoding|new
'@
    if(-not(Test-ExactInventory $memberNames $expectedMembers)){return $false}
    $providerPaths=@($variables|Where-Object{$_.VariablePath.DriveName}|ForEach-Object{"variable|$($_.VariablePath.DriveName)|$($_.VariablePath.UserPath)"})
    if($providerPaths.Count-ne0){return $false}
    $types=@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.TypeExpressionAst]-or$node-is[Management.Automation.Language.TypeConstraintAst]},$true)|ForEach-Object{$_.TypeName.FullName})
    $expectedTypes=@'
2|bool
5|byte[]
5|char[]
1|Console
7|Convert
2|Environment
3|int
11|int64
2|IntPtr
1|InvalidOperationException
3|IO.Directory
3|IO.File
1|IO.FileAccess
1|IO.FileMode
1|IO.FileShare
1|IO.IOException
7|IO.Path
1|Management.Automation.ErrorCategory
1|Management.Automation.ErrorRecord
2|Microsoft.Win32.SafeHandles.SafeFileHandle
6|ordered
7|pscustomobject
1|Reflection.BindingFlags
2|Runtime.InteropServices.GCHandle
1|Runtime.InteropServices.GCHandleType
3|Runtime.InteropServices.Marshal
1|Runtime.InteropServices.SafeHandle
1|scriptblock
8|Security.Cryptography.CryptographicOperations
6|Security.Cryptography.RSA
1|Security.Cryptography.RSAParameters
3|Security.Cryptography.SHA256
2|Security.Principal.WindowsIdentity
3|Security.SecureString
29|string
1|string[]
2|switch
1|System.Numerics.BigInteger
7|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge
1|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector
2|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease
3|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector
2|Text.UTF8Encoding
1|type
3|uint32
15|uint64
'@
    if(-not(Test-ExactInventory $types $expectedTypes)){return $false}
    $environmentCalls=@($members|Where-Object{[string]$_.Member.Value-ceq'GetEnvironmentVariable'})
    if($environmentCalls.Count-ne1 -or (Get-TestAncestorFunctionName $environmentCalls[0])-cne'Assert-TrustAnchorInteractiveHost' -or $environmentCalls[0].Extent.Text -cne '[Environment]::GetEnvironmentVariable($name)'){return $false}
    $interactive=@($Ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq'Assert-TrustAnchorInteractiveHost'},$true))
    if($interactive.Count-ne1){return $false}
    $csharp=Get-TrustAnchorCSharpInventory $Ast.Extent.Text;if($null-eq$csharp){return $false}
    $expectedCSharpMembers=@'
3|builtin|nameof
1|instance|System.Collections.Generic.List<string>|Add
1|instance|System.Collections.Generic.List<string>|ToArray
1|instance|System.Enum|ToString
1|instance|System.Formats.Asn1.Asn1Tag|HasSameClassAndValue
1|instance|System.Formats.Asn1.AsnReader|PeekTag
2|instance|System.Formats.Asn1.AsnReader|ReadInteger
1|instance|System.Formats.Asn1.AsnReader|ReadNull
4|instance|System.Formats.Asn1.AsnReader|ReadObjectIdentifier
3|instance|System.Formats.Asn1.AsnReader|ReadOctetString
7|instance|System.Formats.Asn1.AsnReader|ReadSequence
8|instance|System.Formats.Asn1.AsnReader|ThrowIfNotEmpty
2|instance|System.Guid|ToString
9|instance|System.MemoryExtensions|AsSpan
1|instance|System.MemoryExtensions|SequenceEqual
3|instance|System.Range|GetOffsetAndLength
25|instance|System.Runtime.InteropServices.SafeHandle|DangerousGetHandle
7|instance|System.Runtime.InteropServices.SafeHandle|Dispose
2|instance|System.Security.Cryptography.AsymmetricAlgorithm|Dispose
1|instance|System.Security.Cryptography.AsymmetricAlgorithm|ExportEncryptedPkcs8PrivateKeyPem
1|instance|System.Security.Cryptography.RSA|ImportFromEncryptedPem
1|instance|System.Security.Cryptography.RSA|ImportSubjectPublicKeyInfo
1|instance|System.Text.Encoding|GetCharCount
1|instance|System.Text.Encoding|GetString
1|instance|System.Text.UTF8Encoding|GetChars
1|instance|string|ToLowerInvariant
1|static|System.Buffers.Text.Base64|DecodeFromUtf8
1|static|System.Convert|ToHexString
1|static|System.Convert|TryFromBase64Chars
2|static|System.Guid|NewGuid
2|static|System.IO.Path|Combine
2|static|System.Runtime.InteropServices.Marshal|AllocHGlobal
1|static|System.Runtime.InteropServices.Marshal|Copy
2|static|System.Runtime.InteropServices.Marshal|FreeHGlobal
20|static|System.Runtime.InteropServices.Marshal|GetLastWin32Error
6|static|System.Runtime.InteropServices.Marshal|PtrToStructure
1|static|System.Runtime.InteropServices.Marshal|ReadInt16
2|static|System.Runtime.InteropServices.Marshal|SizeOf
2|static|System.Runtime.InteropServices.Marshal|WriteInt64
1|static|System.Runtime.InteropServices.MemoryMarshal|AsBytes
7|static|System.Runtime.InteropServices.RuntimeInformation|IsOSPlatform
9|static|System.Security.Cryptography.CryptographicOperations|ZeroMemory
1|static|System.Security.Cryptography.PemEncoding|TryFind
2|static|System.Security.Cryptography.RSA|Create
3|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|ContainsAscii
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|DecodePrivatePem
2|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|EffectiveUid
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|getEuid
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|getEuidDarwin
2|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|IsAsciiWhitespace
2|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|MatchAscii
4|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequireAscii
2|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequireBase64XmlText
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequireEncryptedPrivatePemHeader
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequirePublicPemEnvelope
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequirePublicXmlStructure
6|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|RequireXmlTag
7|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|SkipAsciiWhitespace
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|ValidateEncryptedPemProfile
1|static|SyuanTsai.AIInstructions.TrustAnchor.SecretBridge|Zero
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector|fstatDarwin
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector|fstatDarwinX64
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector|fstatLinux
7|static|SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector|Inspect
4|static|SyuanTsai.AIInstructions.TrustAnchor.UnixNativeFlagSet|Current
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixNativeFlagSet|Select
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|AssertSafeParent
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|AssertNoMacExtendedAcl
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|acl_free
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|acl_get_entry
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|acl_get_fd_np
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|fstatatDarwin
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|fstatatDarwinX64
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|fstatatLinux
2|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|fsyncDarwin
2|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|fsyncLinux
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|MkdirAt
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|mkdiratDarwin
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|mkdiratLinux
2|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|OpenAt
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|openatDarwin
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|openatLinux
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|renameat2
1|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|renameatx
4|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|SameDirectory
5|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|SameFile
5|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|Stat
3|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|unlinkatDarwin
3|static|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease|unlinkatLinux
2|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|CreateFile
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|GetFileBasicInformation
2|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|GetFileInformationByHandle
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|GetSecurityDescriptorControl
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|GetSecurityInfo
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|LocalFree
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|MarkDeleteOnClose
1|static|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector|SetFileDispositionByHandle
1|static|char|IsWhiteSpace
2|static|char|ToUpperInvariant
'@
    if(-not(Test-ExactInventory $csharp.Members $expectedCSharpMembers)){return $false}
    $expectedCSharpTypes=@'
1|Microsoft.Win32.SafeHandles.SafeFileHandle
1|nint
3|System.ArgumentNullException
1|System.Collections.Generic.List<string>
21|System.ComponentModel.Win32Exception
1|System.Formats.Asn1.AsnReader
1|System.IO.InvalidDataException
7|System.IO.IOException
2|System.PlatformNotSupportedException
1|System.ReadOnlyMemory<byte>
2|System.ReadOnlySpan<byte>
1|System.Security.AccessControl.RawAcl
26|System.Security.Cryptography.CryptographicException
1|System.Security.Cryptography.PbeParameters
1|System.Security.Principal.SecurityIdentifier
2|System.Text.UTF8Encoding
7|SyuanTsai.AIInstructions.TrustAnchor.NativeMetadataEvidence
3|SyuanTsai.AIInstructions.TrustAnchor.UnixNativeFlagSet
1|SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease
1|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclEvidence
1|SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector.FileDispositionInfo
'@
    if(-not(Test-ExactInventory $csharp.Types $expectedCSharpTypes)){return $false}
    if(-not(Test-TrustAnchorSensitiveFunctionAsts $Ast)){return $false}
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
        $private=Join-Path $TestDrive 'weak-private.pem';$public=Join-Path $TestDrive 'weak-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword ('x'*15)))
        $result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.WeakPassword';$result.ReadCount|Should Be 1
    }

    # Scenario: Read-Host returns a sixteen-character password.
    # Purpose: Bind the acceptance boundary exactly at sixteen characters.
    It 'UnitT09_accepts_a_sixteen_character_password' {
        $private=Join-Path $TestDrive 'minimum-private.pem';$public=Join-Path $TestDrive 'minimum-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword ('x'*16)),(New-TestPassword ('x'*16)))
        $result.HadErrors|Should Be $false;$result.ReadCount|Should Be 2;(Test-Path -LiteralPath $private)|Should Be $true
    }

    # Scenario: Two valid-length interactive password responses differ.
    # Purpose: Refuse a mistyped confirmation without converting either secret to a managed string.
    It 'UnitT10_rejects_mismatched_password_confirmation' {
        $private=Join-Path $TestDrive 'mismatch-private.pem';$public=Join-Path $TestDrive 'mismatch-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword ('a'*20)),(New-TestPassword ('b'*20)))
        $result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.PasswordMismatch';$result.ReadCount|Should Be 2
    }

    # Scenario: Two valid-length interactive password responses match.
    # Purpose: Return the confirmed SecureString for the caller to dispose.
    It 'UnitT11_accepts_matching_password_confirmation' {
        $private=Join-Path $TestDrive 'matching-private.pem';$public=Join-Path $TestDrive 'matching-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword ('c'*20)),(New-TestPassword ('c'*20)))
        $result.HadErrors|Should Be $false;$result.ReadCount|Should Be 2;(Test-Path -LiteralPath $public)|Should Be $true
    }

    # Scenario: The imported helper module and all three formal CLI parameter blocks are inspected.
    # Purpose: No public command or formal CLI may accept Password, SecureString, char[], environment-secret, or password-file input.
    It 'UnitT12_exposes_only_the_exact_CLI_parameter_allowlists' {
        @($script:Module.ExportedCommands.Values).Count|Should Be 0
        $expected=Get-TrustAnchorCliContracts
        foreach($name in $expected.Keys){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$contract=$expected[$name];(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $true}
    }

    # Scenario: The module AST is inspected for every password acquisition and possible fallback source.
    # Purpose: Require Read-Host -AsSecureString as the only password source, without environment or file fallback.
    It 'UnitT13_uses_only_Read_Host_AsSecureString_for_password_acquisition' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:ModulePath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $ast)|Should Be $true
        $otherHelper="function Assert-TrustAnchorInteractiveHost { foreach(`$name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')) { [Environment]::GetEnvironmentVariable(`$name) } }`nfunction Read-TrustAnchorPassword { Read-Host -AsSecureString; Read-Host -AsSecureString }`nfunction Get-PasswordFallback { [Environment]::GetEnvironmentVariable('TRUST_ANCHOR_SECRET') | ConvertTo-SecureString -AsPlainText -Force }"
        $errors=$null;$negative=[Management.Automation.Language.Parser]::ParseInput($otherHelper,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $negative)|Should Be $false
        $directEnvironment="function Assert-TrustAnchorInteractiveHost { foreach(`$name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')) { [Environment]::GetEnvironmentVariable(`$name) } }`nfunction Read-TrustAnchorPassword { `$env:TRUST_ANCHOR_SECRET; Read-Host -AsSecureString; Read-Host -AsSecureString }"
        $errors=$null;$negative=[Management.Automation.Language.Parser]::ParseInput($directEnvironment,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $negative)|Should Be $false
    }
}

Describe 'PR-K1 trust-anchor CLI boundary' {
    # Scenario: Every CLI AST is inspected for the guard and the first delegated action.
    # Purpose: A missing guard must fail, and the guard must precede path, file, password, or RSA work.
    It 'UnitT14_allows_only_the_guard_then_one_action_in_each_CLI_module_invocation' {
        $expected=Get-TrustAnchorCliContracts
        foreach($name in $expected.Keys){$path=Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name";$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$contract=$expected[$name];(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $true}
    }

    # Scenario: A synthetic CLI performs File.ReadAllText before the interactive guard.
    # Purpose: Prove the closed AST allowlist fails when any I/O is inserted ahead of the guard.
    It 'UnitT15_AST_guard_self_check_rejects_pre_guard_file_IO' {
        $contract=(Get-TrustAnchorCliContracts)['New-TrustAnchorKeyPair.ps1']
        $source="param([string]`$PrivateKeyPath)`n`$module=Import-Module (Join-Path `$PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop`n[IO.File]::ReadAllText(`$PrivateKeyPath)`ntry { & `$module { Assert-TrustAnchorInteractiveHost; Invoke-NewTrustAnchorKeyPairAction } } catch { [Console]::Error.WriteLine(`$_.FullyQualifiedErrorId); throw }"
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $false
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
        $rsa=[Security.Cryptography.RSA]::Create(3072);$weak=[Security.Cryptography.RSA]::Create(2048)
        try{$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1';$publicPath=Join-Path $TestDrive 'public.pem';$outputPath=Join-Path $TestDrive 'public.xml';[IO.File]::WriteAllText($publicPath,$rsa.ExportSubjectPublicKeyInfoPem());$result=Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$publicPath;OutputPath=$outputPath};$result.HadErrors|Should Be $false;[Convert]::ToHexString([IO.File]::ReadAllBytes($outputPath))|Should Be ([Convert]::ToHexString((Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa))));$privatePath=Join-Path $TestDrive 'private-input.pem';[IO.File]::WriteAllText($privatePath,$rsa.ExportPkcs8PrivateKeyPem());$rejected=Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$privatePath;OutputPath=(Join-Path $TestDrive 'private.xml')};$rejected.HadErrors|Should Be $true;$rejected.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';$weakPath=Join-Path $TestDrive 'weak.pem';[IO.File]::WriteAllText($weakPath,$weak.ExportSubjectPublicKeyInfoPem());(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$weakPath;OutputPath=(Join-Path $TestDrive 'weak.xml')}).HadErrors|Should Be $true}finally{$weak.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML, PUBLIC KEY PEM, and an encrypted private key all represent the same runtime-generated RSA key.
    # Purpose: Exercise all fingerprint CLI orchestration paths while the private-key password still comes only from Read-Host.
    It 'InterT19_fingerprints_XML_public_PEM_and_encrypted_private_PEM' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$password=New-TestPassword;$privateTarget=$null;$privateLease=$null
        try{$expected=Invoke-TrustAnchorModule {param($r)Get-TrustAnchorFingerprint $r} @($rsa);$xmlPath=Join-Path $TestDrive 'fingerprint.xml';[IO.File]::WriteAllBytes($xmlPath,(Invoke-TrustAnchorModule {param($r)ConvertTo-TrustAnchorCanonicalXml $r} @($rsa)));$pemPath=Join-Path $TestDrive 'fingerprint.pem';[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());$encrypted=Invoke-TrustAnchorModule {param($r,$p)Export-TrustAnchorEncryptedPrivateKey $r $p} @($rsa,$password);$privatePath=Join-Path $TestDrive 'fingerprint-private.pem';$privateTarget=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($privatePath);$privateLease=Invoke-TrustAnchorModule {param($t,$b)New-TrustAnchorKeyFile $t $b} @($privateTarget,[Text.UTF8Encoding]::new($false).GetBytes($encrypted+"`n"));Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease);$privateLease=$null;Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget);$privateTarget=$null;$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1';$xml=(Invoke-TestTrustAnchorCli $cli @{PublicKeyXmlPath=$xmlPath}).Output[0];$pem=(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$pemPath}).Output[0];$privateResult=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$privatePath} @((New-TestPassword));$privateResult.HadErrors|Should Be $false;$privateResult.ReadCount|Should Be 1;$private=$privateResult.Output[0];foreach($actual in @($xml,$pem,$private)){$actual.xmlSha256|Should Be $expected.xmlSha256;$actual.spkiSha256|Should Be $expected.spkiSha256}}finally{if($null-ne$privateLease){Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($privateLease)};if($null-ne$privateTarget){Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($privateTarget)};$password.Dispose();$rsa.Dispose()}
    }

    # Scenario: Fingerprint inputs contain unencrypted PKCS#8, unencrypted PKCS#1, or private RSA XML generated at runtime.
    # Purpose: Reject private material at the byte boundary before any immutable managed string can be created.
    It 'InterT20_rejects_unencrypted_private_key_files_and_private_XML_at_the_byte_boundary' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'
        try{
            $fixtures=@(@{Name='plain-pkcs8.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportPkcs8PrivateKeyPem()))},@{Name='plain-pkcs1.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportRSAPrivateKeyPem()))})
            foreach($fixture in $fixtures){$path=Join-Path $TestDrive $fixture.Name;$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=Invoke-TrustAnchorModule {param($t,$b)New-TrustAnchorKeyFile $t $b} @($target,$fixture.Bytes);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target);$result=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$path} @((New-TestPassword));$result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';[Security.Cryptography.CryptographicOperations]::ZeroMemory($fixture.Bytes)}
            $parameters=$rsa.ExportParameters($true);$xml='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent><D>'+[Convert]::ToBase64String($parameters.D)+'</D></RSAKeyValue>';$xmlPath=Join-Path $TestDrive 'private.xml';[IO.File]::WriteAllBytes($xmlPath,(ConvertTo-TestUtf8Bytes $xml));$xmlResult=Invoke-TestTrustAnchorCli $cli @{PublicKeyXmlPath=$xmlPath};$xmlResult.HadErrors|Should Be $true;$xmlResult.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'
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
        $private=Join-Path $TestDrive 'rollback-private.pem';$public=Join-Path $TestDrive 'rollback-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword)) -ModuleSetup {$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'}}
        $result.HadErrors|Should Be $true;$result.Errors[0].Exception.Message|Should Match 'Injected public output failure';(Test-Path -LiteralPath $private)|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false
    }

    # Scenario: Public output fails and the private pathname is replaced immediately before rollback.
    # Purpose: Preserve the replacement, reject identity drift, and fail closed through CLI orchestration.
    It 'InterT27_CLI_rollback_preserves_a_replaced_private_pathname' {
        $private=Join-Path $TestDrive 'replaced-private.pem';$moved=Join-Path $TestDrive 'original-private.moved';$public=Join-Path $TestDrive 'replaced-public.xml';$setup={param($movedPath)$script:TrustAnchorRollbackMovedPath=$movedPath;$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorBeforeRollbackRemovalTestHook={param($lease)Move-Item -LiteralPath $lease.Path -Destination $script:TrustAnchorRollbackMovedPath -ErrorAction Stop;[IO.File]::WriteAllText($lease.Path,'replacement')}}
        $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword)) -ModuleSetup $setup -ModuleSetupArguments @($moved);$result.HadErrors|Should Be $true;$result.Errors[0].Exception.Message|Should Match 'rollback failed closed';(Test-Path -LiteralPath $private)|Should Be $true;[IO.File]::ReadAllText($private)|Should Be 'replacement';(Test-Path -LiteralPath $moved)|Should Be $true
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

        # Scenario: A restrictive original is retained with delete sharing while its pathname is replaced by a broad-DACL file.
        # Purpose: Pass ACL validation through the retained handle, then fail closed only when final pathname identity drift is detected.
        It 'InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence' {
            $path=Join-Path $TestDrive 'delete-share-safe.pem';$replacement=Join-Path $TestDrive 'delete-share-broad.pem';$moved=Join-Path $TestDrive 'delete-share-safe.moved';$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([Text.Encoding]::UTF8.GetBytes('original'))} @($target);Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease);Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target);[IO.File]::WriteAllText($replacement,'replacement')
            Invoke-TrustAnchorModule {param($replacementPath,$movedPath)$script:TrustAnchorBarrierReplacement=$replacementPath;$script:TrustAnchorBarrierMoved=$movedPath;$script:TrustAnchorBarrierSwapped=$false;$script:TrustAnchorOpenBeforePermissionTestHook={param($openedPath,$file)$field=$file.GetType().GetField('Handle',[Reflection.BindingFlags]'Instance,NonPublic');$original=$field.GetValue($file);$deleteSharing=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::OpenReadWithDeleteSharing($openedPath);$field.SetValue($file,$deleteSharing);$original.Dispose();Move-Item -LiteralPath $openedPath -Destination $script:TrustAnchorBarrierMoved -ErrorAction Stop;Move-Item -LiteralPath $script:TrustAnchorBarrierReplacement -Destination $openedPath -ErrorAction Stop;$script:TrustAnchorBarrierSwapped=$true}} @($replacement,$moved)
            try{$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($path)};(Invoke-TrustAnchorModule {$script:TrustAnchorBarrierSwapped})|Should Be $true;$failure.Exception.Message|Should Not Match 'protected DACL';$failure.Exception.Message|Should Match '(?i)identity|path'}finally{Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null}}
        }

        # Scenario: The private-key leaf is a file symlink, with a directory-junction fallback when symlink creation is unavailable.
        # Purpose: Reject every Windows leaf reparse point and explicitly prove the fixture carries ReparsePoint.
        It 'InterT33_rejects_a_private_key_leaf_reparse_point' {
            $target=Join-Path $TestDrive 'reparse-target.pem';$leaf=Join-Path $TestDrive 'reparse-leaf.pem';[IO.File]::WriteAllText($target,'fixture');try{New-Item -ItemType SymbolicLink -Path $leaf -Target $target -ErrorAction Stop|Out-Null}catch{$targetDirectory=Join-Path $TestDrive 'reparse-target-dir';[void][IO.Directory]::CreateDirectory($targetDirectory);$leaf=Join-Path $TestDrive 'reparse-leaf-dir';New-Item -ItemType Junction -Path $leaf -Target $targetDirectory -ErrorAction Stop|Out-Null};(([IO.File]::GetAttributes($leaf)-band[IO.FileAttributes]::ReparsePoint)-ne0)|Should Be $true;$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($p)Open-TrustAnchorPrivateKey $p} @($leaf)};$failure.Exception.Message|Should Match '(?i)reparse'
        }

        # Scenario: The formal key-pair action creates a private file and returns before native ACL readback.
        # Purpose: Independently verify the resulting DACL is protected and grants allow access only to approved SIDs.
        It 'InterT34_formal_creation_has_an_independently_verified_restrictive_DACL' {
            $private=Join-Path $TestDrive 'acl-private.pem';$public=Join-Path $TestDrive 'acl-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword));$result.HadErrors|Should Be $false;$acl=Get-Acl -LiteralPath $private;$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$owner|Should Be $identity.User.Value;$acl.AreAccessRulesProtected|Should Be $true;$rules=@($acl.Access);$rules.Count|Should Be 1;$rule=$rules[0];$rule.IsInherited|Should Be $false;$rule.AccessControlType|Should Be ([Security.AccessControl.AccessControlType]::Allow);$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value|Should Be $identity.User.Value;(($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::Read)-eq[Security.AccessControl.FileSystemRights]::Read)|Should Be $true;(($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::Write)-eq[Security.AccessControl.FileSystemRights]::Write)|Should Be $true}finally{$identity.Dispose()}
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
            $private=Join-Path $TestDrive 'mode-private.pem';$public=Join-Path $TestDrive 'mode-public.xml';(Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword))).HadErrors|Should Be $false;$mode=[IO.File]::GetUnixFileMode($private);([int]$mode-band511)|Should Be 384;$handle=[IO.File]::OpenHandle($private,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$evidence=[SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector]::Inspect($handle);([uint32]$evidence.Mode-band0xF000)|Should Be 0x8000;[uint64]$evidence.Uid|Should Be ([SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::EffectiveUid())}finally{$handle.Dispose()}
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
            $private=Join-Path $TestDrive 'tombstone-private.pem';$public=Join-Path $TestDrive 'tombstone-public.xml';$setup={$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorAfterRollbackRenameTestHook={param($rollback)$script:RollbackDisplaced=$rollback.TombstonePath+'.displaced';Move-Item -LiteralPath $rollback.TombstonePath -Destination $script:RollbackDisplaced -ErrorAction Stop;[IO.File]::WriteAllText($rollback.TombstonePath,'replacement');chmod 600 $rollback.TombstonePath}};$resultScript={@($script:RollbackDisplaced,$script:RollbackDisplaced.Substring(0,$script:RollbackDisplaced.Length-10))};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword)) -ModuleSetup $setup -ModuleResult $resultScript;$result.HadErrors|Should Be $true;$result.Errors[0].Exception.Message|Should Match 'rollback failed closed';(Test-Path -LiteralPath $result.ModuleOutput[0])|Should Be $true;(Test-Path -LiteralPath $result.ModuleOutput[1])|Should Be $true
        }

        # Scenario: A hard link to the tombstone is created after rename and before unlink.
        # Purpose: Require single-link evidence immediately before unlink and retain the key when another link exists.
        It 'InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink' {
            $private=Join-Path $TestDrive 'hardlink-private.pem';$public=Join-Path $TestDrive 'hardlink-public.xml';$setup={$script:TrustAnchorBeforePublicWriteTestHook={throw 'Injected public output failure.'};$script:TrustAnchorAfterRollbackRenameTestHook={param($rollback)$script:RollbackHardLink=$rollback.TombstonePath+'.link';New-Item -ItemType HardLink -Path $script:RollbackHardLink -Target $rollback.TombstonePath|Out-Null;$script:RollbackTombstone=$rollback.TombstonePath}};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestPassword),(New-TestPassword)) -ModuleSetup $setup -ModuleResult {@($script:RollbackTombstone,$script:RollbackHardLink)};$result.HadErrors|Should Be $true;$result.Errors[0].Exception.Message|Should Match 'rollback failed closed';foreach($path in $result.ModuleOutput){(Test-Path -LiteralPath $path)|Should Be $true}
        }

        # Scenario: A private output parent is group-writable without sticky protection, or world-writable with sticky protection.
        # Purpose: Reject cross-UID entry replacement before file creation while accepting the standard sticky-directory boundary.
        It 'InterT48_enforces_the_rollback_parent_boundary_for_<Mode>' -TestCases @(
            @{Mode='0770';Accept=$false},
            @{Mode='1777';Accept=$true}
        ) {
            param($Mode,$Accept)
            $parent=Join-Path $TestDrive "rollback-parent-$Mode";[void][IO.Directory]::CreateDirectory($parent);chmod $Mode $parent
            $path=Join-Path $parent 'private.pem';$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);$lease=$null
            try{
                if($Accept){$lease=Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target);(Test-Path -LiteralPath $path)|Should Be $true}
                else{{Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target)}|Should Throw 'owner-only or sticky';(Test-Path -LiteralPath $path)|Should Be $false;@(Get-ChildItem -Force -LiteralPath $parent).Count|Should Be 0}
            }finally{if($null-ne$lease){Invoke-TrustAnchorModule {param($l)Close-TrustAnchorCreatedFile $l} @($lease)}else{Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)}}
        }

        if($IsLinux){
            # Scenario: A Linux 0700 parent receives a named-user writable POSIX ACL through setfacl.
            # Purpose: Prove the ACL mask is reflected in group class mode bits and the retained-handle mode check rejects it.
            It 'InterT68_rejects_a_Linux_named_user_writable_parent_ACL' {
                $setfacl=Get-Command setfacl -CommandType Application -ErrorAction Stop;$parent=Join-Path $TestDrive 'linux-acl-parent';[void][IO.Directory]::CreateDirectory($parent);chmod 700 $parent;& $setfacl.Source -m 'u:nobody:rwx' $parent;if($LASTEXITCODE-ne0){throw 'setfacl failed to create the required Linux ACL fixture.'}
                $path=Join-Path $parent 'private.pem';$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);try{{Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target)}|Should Throw 'owner-only or sticky';(Test-Path -LiteralPath $path)|Should Be $false}finally{Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)}
            }
        }
        if($IsMacOS){
            # Scenario: A macOS 0700 parent receives an extended ACL granting nobody add_file and delete_child.
            # Purpose: Reject extended ACLs through acl_get_fd_np on the retained directory descriptor before any entry is created.
            It 'InterT69_rejects_a_macOS_extended_parent_ACL' {
                $parent=Join-Path $TestDrive 'macos-acl-parent';[void][IO.Directory]::CreateDirectory($parent);chmod 700 $parent;chmod +a 'user:nobody allow add_file,delete_child' $parent;if($LASTEXITCODE-ne0){throw 'chmod failed to create the required macOS ACL fixture.'}
                $path=Join-Path $parent 'private.pem';$target=Invoke-TrustAnchorModule {param($p)Assert-TrustAnchorKeyPath $p PrivateKey} @($path);try{{Invoke-TrustAnchorModule {param($t)New-TrustAnchorKeyFile $t ([byte[]](1,2,3))} @($target)}|Should Throw 'extended ACL';(Test-Path -LiteralPath $path)|Should Be $false}finally{Invoke-TrustAnchorModule {param($t)Close-TrustAnchorPathEvidence $t} @($target)}
            }
        }
    }
}

Describe 'PR-K1 fix4 closed-boundary hardening' {
    # Scenario: OpenSSH private armor and a second armor block are supplied to the public-PEM importer.
    # Purpose: Prove the complete byte envelope is public-only before any immutable string is created.
    It 'UnitT49_rejects_non_public_or_multiple_PEM_envelopes_at_the_byte_boundary' {
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        try{
            $fixtures=@(
                "-----BEGIN OPENSSH PRIVATE KEY-----`nQUJD`n-----END OPENSSH PRIVATE KEY-----`n",
                ($rsa.ExportSubjectPublicKeyInfoPem()+"`n-----BEGIN "+'PRIVATE KEY-----'+"`nQUJD`n-----END "+'PRIVATE KEY-----'+"`n")
            )
            foreach($fixture in $fixtures){[byte[]]$bytes=ConvertTo-TestUtf8Bytes $fixture;try{$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($value)Import-TrustAnchorPublicPem $value} @(,$bytes)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}}
        }finally{$rsa.Dispose()}
    }

    # Scenario: Private RSA XML fields use lower-case and namespace-prefixed element names.
    # Purpose: Require a byte-level closed element allowlist instead of case-sensitive private-field spotting.
    It 'UnitT50_rejects_case_or_namespace_variant_private_XML_at_the_byte_boundary' {
        $fixtures=@(
            '<RSAKeyValue><Modulus>AQ==</Modulus><Exponent>AQAB</Exponent><d>AQ==</d></RSAKeyValue>',
            '<RSAKeyValue xmlns:x="urn:private"><Modulus>AQ==</Modulus><Exponent>AQAB</Exponent><x:D>AQ==</x:D></RSAKeyValue>'
        )
        foreach($fixture in $fixtures){[byte[]]$bytes=ConvertTo-TestUtf8Bytes $fixture;try{$failure=Get-TestFailure {Invoke-TrustAnchorModule {param($value)Import-TrustAnchorPublicXml $value} @(,$bytes)};$failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}}
    }

    # Scenario: A synthetic helper and Read-TrustAnchorPassword itself each gain a forbidden environment fallback.
    # Purpose: Keep the password-source validator closed over the complete module AST.
    It 'UnitT51_password_source_validator_rejects_module_and_function_environment_fallbacks' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:ModulePath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $ast)|Should Be $true
        foreach($source in @(
            "function Assert-TrustAnchorInteractiveHost { foreach(`$name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')) { [Environment]::GetEnvironmentVariable(`$name) } }`nfunction Read-TrustAnchorPassword { Read-Host -AsSecureString; Read-Host -AsSecureString }`nfunction Get-Secret { [Environment]::GetEnvironmentVariable('TRUST_ANCHOR_SECRET') | ConvertTo-SecureString -AsPlainText -Force }",
            "function Assert-TrustAnchorInteractiveHost { foreach(`$name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')) { [Environment]::GetEnvironmentVariable(`$name) } }`nfunction Read-TrustAnchorPassword { `$env:TRUST_ANCHOR_SECRET; Read-Host -AsSecureString; Read-Host -AsSecureString }"
        )){$errors=$null;$negative=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $negative)|Should Be $false}
    }

    # Scenario: The bounded input stream fails after allocation and after a prefix has entered the managed byte array.
    # Purpose: Zero every allocated input buffer that cannot be returned to a caller for disposal.
    It 'InterT52_clears_input_bytes_when_reading_fails_after_allocation' {
        $path=Join-Path $TestDrive 'input-read-failure.pem';[IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4,5,6));Invoke-TrustAnchorModule {$script:CapturedInputBytes=$null;$script:TrustAnchorAfterInputBufferAllocatedTestHook={param($stream,$bytes)[void]$stream.Read($bytes,0,3);$script:CapturedInputBytes=$bytes;$stream.Dispose()}}
        try{{Invoke-TrustAnchorModule {param($p)Read-TrustAnchorInputBytes $p} @($path)}|Should Throw;$captured=Invoke-TrustAnchorModule {$script:CapturedInputBytes};@($captured|Where-Object{$_-ne0}).Count|Should Be 0}finally{Invoke-TrustAnchorModule {$script:TrustAnchorAfterInputBufferAllocatedTestHook=$null;$script:CapturedInputBytes=$null}}
    }

    # Scenario: ABI flags are selected without invoking any Unix syscall on the Windows test host.
    # Purpose: Bind Linux x64/arm64 and macOS x64/arm64 directory, no-follow, and unlink constants.
    It 'UnitT53_selects_native_flags_for_every_supported_Unix_ABI' {
        $cases=@(
            @{Os='linux';Arch='x64';Directory=0x10000;NoFollow=0x20000;Remove=0x200;AtNoFollow=0x100},
            @{Os='linux';Arch='arm64';Directory=0x4000;NoFollow=0x8000;Remove=0x200;AtNoFollow=0x100},
            @{Os='macos';Arch='x64';Directory=0x100000;NoFollow=0x100;Remove=0x80;AtNoFollow=0x20},
            @{Os='macos';Arch='arm64';Directory=0x100000;NoFollow=0x100;Remove=0x80;AtNoFollow=0x20}
        )
        foreach($case in $cases){$actual=[SyuanTsai.AIInstructions.TrustAnchor.UnixNativeFlagSet]::Select($case.Os,$case.Arch);$actual.Directory|Should Be $case.Directory;$actual.NoFollow|Should Be $case.NoFollow;$actual.AtRemoveDirectory|Should Be $case.Remove;$actual.AtSymlinkNoFollow|Should Be $case.AtNoFollow}
        {[SyuanTsai.AIInstructions.TrustAnchor.UnixNativeFlagSet]::Select('linux','riscv64')}|Should Throw 'Unsupported trust-anchor Unix ABI'
    }

    # Scenario: The formal Windows metadata helper is inspected as a complete AST extent.
    # Purpose: Allow ACL evidence only from the retained lease handle, never from pathname ACL APIs.
    It 'UnitT54_binds_Windows_ACL_evidence_to_the_retained_lease_handle' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:ModulePath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$function=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq'Get-TrustAnchorMetadataEvidence'},$true));$function.Count|Should Be 1;$text=$function[0].Extent.Text;$text|Should Match 'WindowsAclInspector\]::Inspect\(\[Microsoft\.Win32\.SafeHandles\.SafeFileHandle\]\$handle\)';$text|Should Not Match '(?i)Get-Acl|GetNamedSecurityInfo|GetAccessControl|FileSecurity\s*\('
    }

    # Scenario: Runtime-generated PKCS#8 and PKCS#1 private DER are mislabeled with PUBLIC KEY armor.
    # Purpose: Reject non-SPKI DER while it is still held only in clearable byte arrays.
    It 'UnitT56_rejects_<Format>_private_DER_mislabeled_as_PUBLIC_KEY' -TestCases @(
        @{Format='PKCS8'},
        @{Format='PKCS1'}
    ) {
        param($Format)
        $rsa=[Security.Cryptography.RSA]::Create(3072);$der=$null;$bytes=$null
        try{
            [byte[]]$der=if($Format-ceq'PKCS8'){$rsa.ExportPkcs8PrivateKey()}else{$rsa.ExportRSAPrivateKey()}
            $bytes=ConvertTo-TestUtf8Bytes ([Security.Cryptography.PemEncoding]::WriteString('PUBLIC KEY',$der))
            $failure=Get-TestFailure {Invoke-TrustAnchorModule {param($value)Import-TrustAnchorPublicPem $value} @(,$bytes)}
            $failure.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'
        }finally{if($null-ne$der){[Security.Cryptography.CryptographicOperations]::ZeroMemory($der)};if($null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$rsa.Dispose()}
    }

    # Scenario: The embedded C# decoder source is checked, then the XML decode order is synthetically reversed.
    # Purpose: Keep every immutable string creation after byte validation and keep the PEM path string-free.
    It 'UnitT57_closes_the_public_decoder_byte_to_string_order' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$csharp=Get-TrustAnchorEmbeddedCSharpSource $source;$null-ne$csharp|Should Be $true
        (Test-TrustAnchorPublicDecoderOperations $csharp)|Should Be $true
        $reversed=[regex]::Replace($csharp,'RequirePublicXmlStructure\(value\);\r?\n\s*return new System\.Text\.UTF8Encoding\(false, true\)\.GetString\(value\);','return new System.Text.UTF8Encoding(false, true).GetString(value);'+[Environment]::NewLine+'            RequirePublicXmlStructure(value);')
        $reversed|Should Not Be $csharp;(Test-TrustAnchorPublicDecoderOperations $reversed)|Should Be $false
    }

    # Scenario: The real module source is mutated with every known environment, file, deserialization, and dynamic-command password fallback.
    # Purpose: Prove exact whole-module command/member/provider/type inventories reject additions regardless of naming or qualification tricks.
    It 'UnitT58_password_source_inventory_rejects_every_closed_boundary_mutation' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath
        $injections=@(
            "function Get-Key { [Environment]::GetEnvironmentVariables()['X'] }",
            "function Get-Key { Microsoft.PowerShell.Security\ConvertTo-SecureString 'x' -AsPlainText -Force }",
            "function Get-Key { Get-Item Env:X }",
            "function Get-Key { Test-Path Env:X }",
            "function Get-Key { [Management.Automation.PSSerializer]::Deserialize('x') }",
            'function Get-Key { param($p) Import-Clixml $p }',
            'function Get-Key { param($p) Get-Content $p }',
            'function Get-Key { param($p) [IO.File]::ReadAllBytes($p) }',
            'function Get-Key { param($x) & $x }',
            'function Get-Key { & (Get-Command Get-Date) }',
            'function Get-Key { $env:X }'
        )
        foreach($injection in $injections){
            $mutated=$source.Replace('Export-ModuleMember -Function @()',"$injection`nExport-ModuleMember -Function @()")
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0
            (Test-TrustAnchorPasswordSourceAst $ast)|Should Be $false
        }
    }

    # Scenario: A valid wrapper gains ValidateScript file I/O, a default expression, or a transformation attribute.
    # Purpose: Make the complete ParamBlock and every pre-body binding behavior a fixed closed allowlist.
    It 'UnitT59_CLI_parameter_guard_rejects_every_pre_body_expression' {
        $contract=(Get-TrustAnchorCliContracts)['New-TrustAnchorKeyPair.ps1']
        $valid="[CmdletBinding()]`nparam([Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]`$KeyId,[Parameter(Mandatory)][string]`$PrivateKeyPath,[Parameter(Mandatory)][string]`$PublicKeyXmlPath)`n`$module=Import-Module (Join-Path `$PSScriptRoot 'TrustAnchorPrivateKey.psm1') -PassThru -ErrorAction Stop`ntry { & `$module {param(`$id,`$privatePath,`$publicPath) Assert-TrustAnchorInteractiveHost;Invoke-NewTrustAnchorKeyPairAction -KeyId `$id -PrivateKeyPath `$privatePath -PublicKeyXmlPath `$publicPath} `$KeyId `$PrivateKeyPath `$PublicKeyXmlPath } catch { [Console]::Error.WriteLine(`$_.FullyQualifiedErrorId); throw }"
        $mutations=@(
            $valid.Replace('[Parameter(Mandatory)][string]$PrivateKeyPath','[Parameter(Mandatory)][ValidateScript({ [IO.File]::ReadAllText($_); $true })][string]$PrivateKeyPath'),
            $valid.Replace('[Parameter(Mandatory)][string]$PrivateKeyPath','[Parameter(Mandatory)][string]$PrivateKeyPath=(Get-Item Env:X).Value'),
            $valid.Replace('[Parameter(Mandatory)][string]$PrivateKeyPath','[Parameter(Mandatory)][FixtureArgumentTransformation()][string]$PrivateKeyPath')
        )
        foreach($source in $mutations){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $false}
    }

    # Scenario: Every protected production file is normalized into its complete PowerShell token sequence, with embedded C# normalized into Roslyn tokens.
    # Purpose: Freeze all executable syntax while allowing comment-only review notes to change without weakening the boundary.
    It 'UnitT60_matches_the_complete_protected_token_goldens' {
        foreach($entry in (Get-TrustAnchorProtectedContracts).GetEnumerator()){
            $source=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot $entry.Key)
            (Test-TrustAnchorProtectedContract $entry.Key $source)|Should Be $true
            (Test-TrustAnchorProtectedContract $entry.Key ("# comment-only mutation`n"+$source))|Should Be $true
        }
    }

    # Scenario: Every reviewer-supplied password, command, and decoder mutation is applied to the real protected module source.
    # Purpose: Require both the semantic boundary and the independent whole-file golden to reject every known bypass.
    It 'UnitT64_rejects_every_secret_and_decoder_mutation_semantically_and_by_golden' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath
        $moduleMutations=@(
            $source.Replace('Read-TrustAnchorPassword -Confirm','Evil\Read-TrustAnchorPassword -Confirm'),
            $source.Replace("Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString","Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString:`$false"),
            $source.Replace("Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString","& Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString"),
            $source.Replace("Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString",". Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString"),
            $source.Replace('    $first=Read-Host',"    `$readOptions=@{AsSecureString=`$true}`n    `$first=Read-Host").Replace("' -AsSecureString","' @readOptions"),
            $source.Replace('        return $Action.Invoke(@(,$characters))',"        if (`$characters[0] -ceq 'q') { throw (-join `$characters) }`n        return `$Action.Invoke(@(,`$characters))"),
            $source.Replace("    `$first=Read-Host", "    `$pipeline=@(`$input);if(`$pipeline.Count-gt0){return `$pipeline[0]}`n    `$first=Read-Host"),
            $source.Replace('$password=Read-TrustAnchorPassword -Confirm',"`$password=`$InjectedPassword;if(`$false){Read-TrustAnchorPassword -Confirm}"),
            $source.Replace('    $first=Read-Host',"    `$_=`$null`n    `$first=Read-Host"),
            $source.Replace('Read-TrustAnchorPassword -Confirm','Read-TrustAnchorPassword @confirmArguments')
        )
        foreach($mutated in $moduleMutations){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $ast)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
        $csharp=Get-TrustAnchorEmbeddedCSharpSource $source
        $decoderMutations=@(
            $csharp.Replace('RequirePublicXmlStructure(value);'+"`n"+'            return new System.Text.UTF8Encoding(false, true).GetString(value);','/* RequirePublicXmlStructure */'+"`n"+'            string text = new System.Text.UTF8Encoding(false, true).GetString(value);'+"`n"+'            RequirePublicXmlStructure(value);'+"`n"+'            return text;'),
            $csharp.Replace('DaclHex = dacl == IntPtr.Zero ? null : Convert.ToHexString(aclBytes)','DaclHex = null').Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            string leaked = Convert.ToHexString(value);'),
            $csharp.Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            string leaked = ""; for (int i = 0; i < value.Length; i++) leaked += (char)value[i];')
        )
        foreach($mutatedCSharp in $decoderMutations){(Test-TrustAnchorPublicDecoderOperations $mutatedCSharp)|Should Be $false;$mutated=$source.Replace($csharp,$mutatedCSharp);(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
    }

    # Scenario: Each C# and PowerShell cleanup point is independently removed and redirected to a different buffer in real module source.
    # Purpose: Bind every secret/input clear operation to its method, target local, and catch/finally control-flow location.
    It 'UnitT65_rejects_deletion_and_relocation_of_every_cleanup_point' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=(Get-Content -Raw -Encoding UTF8 $script:ModulePath).Replace("`r`n","`n").Replace("`r","`n");(Test-TrustAnchorCleanupContract $source)|Should Be $true;$csharp=Get-TrustAnchorEmbeddedCSharpSource $source;$analysis=Get-TrustAnchorCSharpAnalysis $csharp
        $csharpCalls=@()
        foreach($method in @($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$null-ne$_.Body})){foreach($operation in Get-TestCSharpOperations ($analysis.Model.GetOperation($method.Body))){if($operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation-and$operation.TargetMethod.ContainingType.ToString()-ceq'System.Security.Cryptography.CryptographicOperations'-and$operation.TargetMethod.Name-ceq'ZeroMemory'){$csharpCalls+=$operation}}}
        foreach($call in $csharpCalls){
            $deletedCSharp=Set-TestSourceSpan $csharp $call.Syntax.SpanStart $call.Syntax.Span.Length 'System.GC.KeepAlive(null)';$deleted=$source.Replace($csharp,$deletedCSharp);(Test-TrustAnchorCleanupContract $deleted)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $deleted)|Should Be $false
            $argument=$call.Arguments[0].Value.Syntax;$relocatedCSharp=Set-TestSourceSpan $csharp $argument.SpanStart $argument.Span.Length 'new byte[1]';$relocated=$source.Replace($csharp,$relocatedCSharp);(Test-TrustAnchorCleanupContract $relocated)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $relocated)|Should Be $false
        }
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and((($node.Static-and$node.Member.Value-cin@('ZeroFreeGlobalAllocUnicode','ZeroMemory','Zero')))-or(-not$node.Static-and$node.Member.Value-ceq'Free'-and$node.Expression.Extent.Text-ceq'$pin'))},$true))
        foreach($call in $calls){
            $deleted=Set-TestSourceSpan $source $call.Extent.StartOffset ($call.Extent.EndOffset-$call.Extent.StartOffset) '$null';(Test-TrustAnchorCleanupContract $deleted)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $deleted)|Should Be $false
            if($call.Member.Value-ceq'ZeroFreeGlobalAllocUnicode'){$replacement='[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode([IntPtr]::Zero)'}elseif($call.Member.Value-ceq'Zero'){$replacement='[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero([char[]]::new(1))'}elseif($call.Member.Value-ceq'Free'){$replacement='([Runtime.InteropServices.GCHandle]::new()).Free()'}else{$replacement='[Security.Cryptography.CryptographicOperations]::ZeroMemory([byte[]]::new(1))'}
            $relocated=Set-TestSourceSpan $source $call.Extent.StartOffset ($call.Extent.EndOffset-$call.Extent.StartOffset) $replacement;(Test-TrustAnchorCleanupContract $relocated)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $relocated)|Should Be $false
        }
    }

    # Scenario: The four outer/inner wrapper mutations from review are applied to the real key-pair CLI.
    # Purpose: Freeze invocation operator, module target, literal scriptblock, inner parameters, outer arguments, and action arguments.
    It 'UnitT66_rejects_every_complete_CLI_try_body_mutation' {
        $relative='scripts/trust-anchor/New-TrustAnchorKeyPair.ps1';$source=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot $relative);$contract=(Get-TrustAnchorCliContracts)['New-TrustAnchorKeyPair.ps1']
        $mutations=@(
            $source.Replace('$KeyId $PrivateKeyPath $PublicKeyXmlPath','$KeyId ([IO.File]::ReadAllText($PrivateKeyPath)) $PublicKeyXmlPath'),
            $source.Replace('& $module {','& ([scriptblock]::Create([IO.File]::ReadAllText($PrivateKeyPath))) {'),
            $source.Replace('param($id,$privatePath,$publicPath)','param($id,$privatePath,$publicPath,$password)').Replace('-PublicKeyXmlPath $publicPath}', '-PublicKeyXmlPath $publicPath -InjectedPassword $password}').Replace('$KeyId $PrivateKeyPath $PublicKeyXmlPath','$KeyId $PrivateKeyPath $PublicKeyXmlPath @($input)[0]'),
            $source.Replace('-PrivateKeyPath $privatePath','-PrivateKeyPath $env:TRUST_ANCHOR_PRIVATE_KEY')
        )
        foreach($mutated in $mutations){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
    }
}

Describe 'PR-K1 trust-anchor regression inventory' {
    AfterAll {Invoke-TrustAnchorModule {$script:TrustAnchorOpenBeforePermissionTestHook=$null;$script:TrustAnchorAfterReadTestHook=$null;$script:TrustAnchorBeforePublicWriteTestHook=$null;$script:TrustAnchorBeforeRollbackRemovalTestHook=$null;$script:TrustAnchorAfterRollbackRenameTestHook=$null;$script:TrustAnchorAfterInputBufferAllocatedTestHook=$null};Remove-Module $script:Module.Name -Force -ErrorAction SilentlyContinue}

    # Scenario: The test AST is inspected for native-host registration and runtime-only RSA generation.
    # Purpose: Every platform-specific It must live below one explicit native Windows/Unix conditional without committed keys or skips.
    It 'UnitT55_registers_the_fixed_native_inventory_under_the_correct_AST_clause' {
        $windows=@('InterT31_share_lock_explicitly_prevents_pathname_replacement','InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence','InterT33_rejects_a_private_key_leaf_reparse_point','InterT34_formal_creation_has_an_independently_verified_restrictive_DACL')
        $unix=@('InterT40_accepts_owner_only_mode_0400','InterT41_rejects_the_original_broad_mode_after_pathname_replacement','InterT42_rejects_metadata_change_during_read','InterT43_rejects_a_private_key_leaf_symbolic_link','InterT44_formal_creation_has_an_independently_verified_owner_only_mode','InterT45_rejects_post_read_identity_replacement_when_both_files_are_restrictive','InterT46_rollback_fails_closed_when_the_tombstone_is_replaced_before_unlink','InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink','InterT48_enforces_the_rollback_parent_boundary_for_<Mode>','InterT68_rejects_a_Linux_named_user_writable_parent_ACL','InterT69_rejects_a_macOS_extended_parent_ACL')
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$conditional=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'PR-K1 Windows native handle safety' -and $node.Extent.Text -match 'PR-K1 Unix native handle safety'},$true));$conditional.Count|Should Be 1;$conditional[0].Clauses[0].Item1.Extent.Text|Should Match '\$IsWindows';$windowsExtent=$conditional[0].Clauses[0].Item2.Extent;$unixExtent=$conditional[0].ElseClause.Extent;$nativeIts=@($conditional[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));$actualWindows=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$windowsExtent.StartOffset-and$_.Extent.EndOffset-le$windowsExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});$actualUnix=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$unixExtent.StartOffset-and$_.Extent.EndOffset-le$unixExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});($actualWindows-join'|')|Should Be ($windows-join'|');($actualUnix-join'|')|Should Be ($unix-join'|');@($nativeIts).Count|Should Be ($windows.Count+$unix.Count)
        $allIts=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));foreach($name in @($windows+$unix)){$matches=@($allIts|Where-Object{[string]$_.CommandElements[1].Value-ceq$name});$matches.Count|Should Be 1;($matches[0].Extent.StartOffset-ge$conditional[0].Extent.StartOffset-and$matches[0].Extent.EndOffset-le$conditional[0].Extent.EndOffset)|Should Be $true};$numbers=@($allIts|ForEach-Object{if([string]$_.CommandElements[1].Value-match'^(?:Unit|Inter)T(\d{2})_'){$Matches[1]}});@($numbers|Group-Object|Where-Object Count-gt1).Count|Should Be 0
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$source|Should Match 'RSA\]::Create\(3072\)';$source|Should Not Match 'BEGIN (RSA )?PRIVATE KEY';(Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'docs/standards/core-test-skip-inventory.json'))|Should Not Match 'trust-anchor-tools'
    }
}
